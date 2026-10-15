#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Probes of the release tools: the SBOM generator, the channel metadata and the candidate inventory."""

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess  # nosec B404 - runs the repository's own scripts on temporary fixtures
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools/release"
VERSION = "20000101-r1"
HOSTS = ["linux-x86_64", "linux-arm64", "macos-arm64"]
PINS = """SDK_VERSION=1.0
SDK_DATE=20000101
SDK_URL=https://example.invalid/sdk-20000101.lha
SDK_SHA256={sdk}
SDK_SOURCE_URL=https://example.invalid/sdk-source-20000101.tar.xz
SDK_SOURCE_SHA256={source}
GCC_VERSION=1.2.3
BINUTILS_VERSION=4.5
GMP_VERSION=6
MPFR_VERSION=4
MPC_VERSION=1
REVISION=1
"""


def sha(data):
    return hashlib.sha256(data).hexdigest()


def load(name):
    spec = importlib.util.spec_from_file_location(name, TOOLS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


INVENTORY = load("inventory")


def run(*arguments):
    return subprocess.run([sys.executable, *map(str, arguments)], capture_output=True, text=True,  # nosec B603
                          check=False)


class ReleaseToolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.pins = self.root / "pins.env"
        self.pins.write_text(PINS.format(sdk="a" * 64, source="b" * 64))
        self.candidate = self.root / "candidate"
        self.candidate.mkdir()
        self.build()

    def sbom(self, archive):
        result = run(TOOLS / "generate-sbom.py", self.pins, archive, str(archive) + ".spdx.json",
                     VERSION, "c" * 40, "946684800")
        self.assertEqual(result.returncode, 0, result.stderr)

    def sums(self):
        lines = [f"{sha((self.candidate / p.name).read_bytes())}  {p.name}"
                 for p in sorted(self.candidate.iterdir()) if p.name != "SHA256SUMS"]
        (self.candidate / "SHA256SUMS").write_text("\n".join(lines) + "\n")

    def build(self):
        for host in HOSTS:
            archive = self.candidate / f"morphos-cross-{VERSION}-{host}.tar.xz"
            archive.write_bytes(b"archive " + host.encode())
            self.sbom(archive)
        for deb in INVENTORY.deb_names(VERSION, HOSTS):
            (self.candidate / deb).write_bytes(b"package " + deb.encode())
        (self.candidate / f"morphos-cross-{VERSION}-source.tar.xz").write_bytes(b"source")
        (self.candidate / "install.sh").write_text(f"#!/bin/sh\ndefault_version=v{VERSION}\n")
        for kind, name in (("formula", "morphos-cross.rb"), ("pkgbuild", "PKGBUILD")):
            result = run(TOOLS / "channels.py", kind, self.pins, f"v{VERSION}", self.candidate, self.candidate / name)
            self.assertEqual(result.returncode, 0, result.stderr)
        (self.candidate / "morphos-cross-bin.SRCINFO").write_text(
            "pkgbase = morphos-cross-bin\n\tpkgver = 20000101\n\tpkgrel = 1\n")
        for payload in INVENTORY.payloads(VERSION, HOSTS):
            (self.candidate / (payload + ".sigstore.json")).write_text("{}")
        self.sums()

    def check(self):
        return run(TOOLS / "inventory.py", self.candidate, VERSION, " ".join(HOSTS))

    def failing(self, fragment):
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(fragment, result.stderr)

    def test_valid_candidate(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_sbom_names_components_and_the_sdk_pin(self):
        document = json.loads((self.candidate / f"morphos-cross-{VERSION}-linux-x86_64.tar.xz.spdx.json").read_text())
        names = {p["name"]: p for p in document["packages"]}
        self.assertEqual(set(names), {"morphos-cross", "gcc", "binutils", "gmp", "mpfr", "mpc"})
        self.assertIn("a" * 64, names["morphos-cross"]["comment"])
        self.assertEqual(names["gcc"]["licenseDeclared"], "GPL-3.0-or-later WITH GCC-exception-3.1")

    def test_generator_refuses_a_version_that_pins_do_not_name(self):
        archive = self.candidate / f"morphos-cross-{VERSION}-linux-x86_64.tar.xz"
        result = run(TOOLS / "generate-sbom.py", self.pins, archive, self.root / "x.json",
                     "20000101-r2", "c" * 40, "0")
        self.assertNotEqual(result.returncode, 0)

    def test_missing_and_extra_assets(self):
        (self.candidate / "install.sh.sigstore.json").unlink()
        self.failing("unexpected candidate asset inventory")
        self.build()
        (self.candidate / "stray.txt").write_text("x")
        self.failing("unexpected candidate asset inventory")

    def test_tampered_payload(self):
        archive = self.candidate / f"morphos-cross-{VERSION}-macos-arm64.tar.xz"
        archive.write_bytes(archive.read_bytes() + b"x")
        self.failing("checksum mismatch")

    def test_incomplete_or_duplicate_checksums(self):
        lines = (self.candidate / "SHA256SUMS").read_text().splitlines()
        (self.candidate / "SHA256SUMS").write_text("\n".join(lines[1:]) + "\n")
        self.failing("incomplete checksum inventory")
        (self.candidate / "SHA256SUMS").write_text("\n".join(lines + lines[:1]) + "\n")
        self.failing("duplicate checksum entry")
        (self.candidate / "SHA256SUMS").write_text("not a checksum line\n")
        self.failing("malformed checksum entry")

    def test_sbom_of_another_payload(self):
        archive = self.candidate / f"morphos-cross-{VERSION}-linux-x86_64.tar.xz"
        archive.write_bytes(b"rebuilt")
        self.sums()
        self.failing("payload digest differs")

    def test_installer_must_name_this_release(self):
        (self.candidate / "install.sh").write_text("#!/bin/sh\ndefault_version=@VERSION@\n")
        self.sums()
        self.failing("install.sh")
        (self.candidate / "install.sh").write_text("#!/bin/sh\ndefault_version=v20000101-r9\n")
        self.sums()
        self.failing("install.sh does not name this release")

    def test_debian_packages_belong_to_the_linux_hosts(self):
        names = INVENTORY.deb_names(VERSION, HOSTS)
        self.assertEqual(names, [f"morphos-cross_{VERSION}_amd64.deb", f"morphos-cross_{VERSION}_arm64.deb"])
        (self.candidate / names[0]).unlink()
        self.failing("unexpected candidate asset inventory")

    def test_payload_list_covers_everything_that_is_signed(self):
        result = run(TOOLS / "inventory.py", self.candidate, VERSION, " ".join(HOSTS), "--payloads")
        self.assertEqual(result.returncode, 0, result.stderr)
        listed = result.stdout.split()
        self.assertEqual(len(listed), len(set(listed)))
        for expected in (f"morphos-cross-{VERSION}-macos-arm64.tar.xz", f"morphos-cross_{VERSION}_amd64.deb",
                         "morphos-cross.rb", "PKGBUILD", "morphos-cross-bin.SRCINFO", "install.sh"):
            self.assertIn(expected, listed)
        self.assertNotIn(f"morphos-cross_{VERSION}_macos-arm64.deb", listed)
        self.assertEqual({name + ".sigstore.json" for name in listed} | set(listed),
                         INVENTORY.expected_assets(VERSION, HOSTS) - {"SHA256SUMS"}
                         - {n for n in INVENTORY.expected_assets(VERSION, HOSTS) if n.endswith(".spdx.json")})

    def test_formula_must_carry_the_digests_of_this_candidate(self):
        formula = self.candidate / "morphos-cross.rb"
        text = formula.read_text()
        digest = sha(b"archive linux-arm64")
        self.assertIn(digest, text)
        formula.write_text(text.replace(digest, "0" * 64))
        self.sums()
        self.failing("lacks the digest")

    def test_formula_must_not_reference_other_downloads(self):
        formula = self.candidate / "morphos-cross.rb"
        formula.write_text(formula.read_text() + '  url "https://example.invalid/releases/download/v1/x"\n')
        self.sums()
        self.failing("must reference exactly 3 release downloads")

    def test_formula_must_name_this_version(self):
        formula = self.candidate / "morphos-cross.rb"
        formula.write_text(formula.read_text().replace(f'version "{VERSION}"', 'version "20000101-r9"'))
        self.sums()
        self.failing("does not name")

    def test_pkgbuild_must_keep_makepkg_from_stripping(self):
        pkgbuild = self.candidate / "PKGBUILD"
        pkgbuild.write_text(pkgbuild.read_text().replace("'!strip' ", ""))
        self.sums()
        self.failing("would let makepkg strip")

    def test_pkgbuild_and_srcinfo_must_name_this_version(self):
        srcinfo = self.candidate / "morphos-cross-bin.SRCINFO"
        srcinfo.write_text(srcinfo.read_text().replace("pkgrel = 1", "pkgrel = 2"))
        self.sums()
        self.failing("does not name")

    def test_formula_generator(self):
        text = (self.candidate / "morphos-cross.rb").read_text()
        self.assertIn("class MorphosCross < Formula", text)
        self.assertIn("on_macos do\n    depends_on arch: :arm64", text)
        self.assertIn('resource "sdk" do\n    url "https://example.invalid/sdk-20000101.lha", using: :nounzip', text)
        self.assertIn('sha256 "' + "a" * 64 + '"', text)
        # The SDK is a resource of the user's own download: no archive of this release holds it.
        self.assertNotIn("morphos-cross-sdk-", text)

    def test_generators_refuse_another_tag(self):
        for kind in ("formula", "pkgbuild"):
            result = run(TOOLS / "channels.py", kind, self.pins, "v20000101-r2", self.candidate, self.root / "x")
            self.assertNotEqual(result.returncode, 0, kind)
            self.assertIn("not the release of pins.env", result.stderr)

    def test_generators_are_deterministic(self):
        first = (self.candidate / "PKGBUILD").read_text()
        again = self.root / "again"
        result = run(TOOLS / "channels.py", "pkgbuild", self.pins, f"v{VERSION}", self.candidate, again)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(first, again.read_text())

    def test_pkgbuild_generator(self):
        text = (self.candidate / "PKGBUILD").read_text()
        for expected in ("pkgname=morphos-cross-bin", "pkgver=20000101", "pkgrel=1", "arch=('x86_64' 'aarch64')",
                         "noextract=(\"sdk-20000101.lha\")", "options=('!strip' '!debug' '!lto' 'staticlibs')"):
            self.assertIn(expected, text)
        self.assertNotIn("macos", text)

    def test_symlinked_asset(self):
        target = self.root / "elsewhere"
        target.write_text("{}")
        link = self.candidate / "install.sh.sigstore.json"
        link.unlink()
        link.symlink_to(target)
        self.failing("non-regular candidate asset")


if __name__ == "__main__":
    unittest.main()
