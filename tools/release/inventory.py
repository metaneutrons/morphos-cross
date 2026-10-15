#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Strict inventory of a release candidate directory. Nothing is extracted or executed.

Usage: inventory.py DIRECTORY VERSION "HOST HOST ..."
       inventory.py DIRECTORY VERSION "HOST HOST ..." --payloads    print the files that carry a signature
"""

import hashlib
import json
from pathlib import Path
import re
import sys

# The Debian architecture of every Linux host; the other hosts have no Debian package.
DEB_ARCHITECTURES = {"linux-x86_64": "amd64", "linux-arm64": "arm64"}
# Metadata of the package channels, generated from the archives of the same candidate.
FORMULA = "morphos-cross.rb"
PKGBUILD = "PKGBUILD"
SRCINFO = "morphos-cross-bin.SRCINFO"
AUR_HOSTS = ("linux-x86_64", "linux-arm64")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def archive_names(version, hosts):
    return [f"morphos-cross-{version}-{host}.tar.xz" for host in hosts]


def deb_names(version, hosts):
    return [f"morphos-cross_{version}_{DEB_ARCHITECTURES[host]}.deb" for host in hosts if host in DEB_ARCHITECTURES]


def payloads(version, hosts):
    """The files that carry a signature bundle."""
    return (archive_names(version, hosts) + deb_names(version, hosts)
            + [f"morphos-cross-{version}-source.tar.xz", "install.sh", FORMULA, PKGBUILD, SRCINFO])


def expected_assets(version, hosts):
    """Every asset of a release: per toolchain archive the archive, its SBOM and its signature bundle;
    the Debian packages, the source archive, the installer and the channel metadata with their
    signature bundles; the checksums."""
    names = {"SHA256SUMS"}
    for payload in payloads(version, hosts):
        names |= {payload, payload + ".sigstore.json"}
    for archive in archive_names(version, hosts):
        names.add(archive + ".spdx.json")
    return names


def check_sbom(path, archive, version):
    document = json.loads(path.read_text(encoding="utf-8"))
    require(document.get("spdxVersion") == "SPDX-2.3", f"{path.name}: not SPDX-2.3")
    described = {r["relatedSpdxElement"] for r in document.get("relationships", [])
                 if r.get("spdxElementId") == "SPDXRef-DOCUMENT" and r.get("relationshipType") == "DESCRIBES"}
    matches = [p for p in document.get("packages", [])
               if p.get("SPDXID") in described and p.get("name") == "morphos-cross"]
    require(len(matches) == 1, f"{path.name}: must describe exactly one morphos-cross package")
    package, = matches
    require(package.get("versionInfo") == version, f"{path.name}: version differs from {version}")
    checksums = [c for c in package.get("checksums", []) if c.get("algorithm") == "SHA256"]
    require(checksums == [{"algorithm": "SHA256", "checksumValue": digest(archive)}],
            f"{path.name}: payload digest differs from {archive.name}")


def check_formula(directory, version, hosts):
    """The formula names this release, each archive of the candidate with its digest, and no other
    release download."""
    text = (directory / FORMULA).read_text(encoding="utf-8")
    require(f'version "{version}"' in text, f"{FORMULA} does not name {version}")
    require(text.count("/releases/download/") == len(hosts),
            f"{FORMULA} must reference exactly {len(hosts)} release downloads")
    for archive in archive_names(version, hosts):
        require(f'/releases/download/v{version}/{archive}"' in text, f"{FORMULA} lacks the URL of {archive}")
        require(f'sha256 "{digest(directory / archive)}"' in text, f"{FORMULA} lacks the digest of {archive}")
    require('resource "sdk"' in text and "using: :nounzip" in text, f"{FORMULA} lacks the SDK resource")


def check_pkgbuild(directory, version, hosts):
    pkgver, _, pkgrel = version.partition("-r")
    text = (directory / PKGBUILD).read_text(encoding="utf-8")
    require(f"\npkgver={pkgver}\n" in text and f"\npkgrel={pkgrel}\n" in text, f"{PKGBUILD} does not name {version}")
    linux = [host for host in hosts if host in AUR_HOSTS]
    require(text.count("/releases/download/") == len(linux),
            f"{PKGBUILD} must reference exactly {len(linux)} release downloads")
    for host in linux:
        archive = archive_names(version, [host])[0]
        require(f"/releases/download/v{version}/{archive}\"" in text, f"{PKGBUILD} lacks the URL of {archive}")
        require(f"'{digest(directory / archive)}'" in text, f"{PKGBUILD} lacks the digest of {archive}")
    require("'!strip'" in text, f"{PKGBUILD} would let makepkg strip the toolchain")
    srcinfo = (directory / SRCINFO).read_text(encoding="utf-8")
    require(f"\tpkgver = {pkgver}\n" in srcinfo and f"\tpkgrel = {pkgrel}\n" in srcinfo,
            f"{SRCINFO} does not name {version}")


def verify(directory, version, hosts):
    require(re.fullmatch(r"\d{8}-r\d+", version), "invalid release version")
    require(directory.is_dir() and not directory.is_symlink(), "invalid candidate directory")
    entries = list(directory.iterdir())
    require({e.name for e in entries} == expected_assets(version, hosts),
            "unexpected candidate asset inventory")
    require(all(e.is_file() and not e.is_symlink() for e in entries), "non-regular candidate asset")

    inventory = {}
    for line in (directory / "SHA256SUMS").read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
        require(match is not None, "malformed checksum entry")
        checksum, name = match.groups()
        require(name not in inventory, "duplicate checksum entry")
        inventory[name] = checksum
    require(set(inventory) == expected_assets(version, hosts) - {"SHA256SUMS"},
            "incomplete checksum inventory")
    for name, checksum in inventory.items():
        require(digest(directory / name) == checksum, f"checksum mismatch: {name}")

    for archive in archive_names(version, hosts):
        check_sbom(directory / (archive + ".spdx.json"), directory / archive, version)
    for deb in deb_names(version, hosts):
        require((directory / deb).stat().st_size > 0, f"{deb} is empty")

    installer = (directory / "install.sh").read_text(encoding="utf-8")
    require(f"default_version=v{version}\n" in installer, "install.sh does not name this release")
    require("@VERSION@" not in installer, "install.sh still has the version placeholder")

    check_formula(directory, version, hosts)
    check_pkgbuild(directory, version, hosts)


def main():
    arguments = sys.argv[1:]
    list_payloads = arguments[-1:] == ["--payloads"]
    if list_payloads:
        arguments = arguments[:-1]
    if len(arguments) != 3:
        sys.exit(__doc__)
    directory, version, hosts = Path(arguments[0]), arguments[1], arguments[2].split()
    if list_payloads:
        print("\n".join(payloads(version, hosts)))
        return
    try:
        verify(directory, version, hosts)
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        sys.exit(f"ERROR: {error}")
    print("Release candidate inventory checks passed.")


if __name__ == "__main__":
    main()
