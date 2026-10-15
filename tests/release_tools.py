#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Probes of the release tools: the SBOM generator and the candidate inventory."""

import hashlib
import json
from pathlib import Path
import subprocess  # nosec B404 - runs the repository's own scripts on temporary fixtures
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools/release"
VERSION = "20000101-r1"
HOSTS = ["linux-x86_64", "macos-arm64"]
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
            (self.candidate / (archive.name + ".sigstore.json")).write_text("{}")
        source = self.candidate / f"morphos-cross-{VERSION}-source.tar.xz"
        source.write_bytes(b"source")
        (self.candidate / (source.name + ".sigstore.json")).write_text("{}")
        (self.candidate / "install.sh").write_text(f"#!/bin/sh\ndefault_version=v{VERSION}\n")
        (self.candidate / "install.sh.sigstore.json").write_text("{}")
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

    def test_symlinked_asset(self):
        target = self.root / "elsewhere"
        target.write_text("{}")
        link = self.candidate / "install.sh.sigstore.json"
        link.unlink()
        link.symlink_to(target)
        self.failing("non-regular candidate asset")


if __name__ == "__main__":
    unittest.main()
