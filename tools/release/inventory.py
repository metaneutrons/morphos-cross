#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Strict inventory of a release candidate directory. Nothing is extracted or executed.

Usage: inventory.py DIRECTORY VERSION "HOST HOST ..."
"""

import hashlib
import json
from pathlib import Path
import re
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def archive_names(version, hosts):
    return [f"morphos-cross-{version}-{host}.tar.xz" for host in hosts]


def expected_assets(version, hosts):
    """Every asset of a release: per toolchain archive the archive, its SBOM and its signature
    bundle; the source archive and the installer with their signature bundles; the checksums."""
    names = {"SHA256SUMS", "install.sh", "install.sh.sigstore.json"}
    for archive in archive_names(version, hosts):
        names |= {archive, archive + ".spdx.json", archive + ".sigstore.json"}
    source = f"morphos-cross-{version}-source.tar.xz"
    names |= {source, source + ".sigstore.json"}
    return names


def payloads(version, hosts):
    """The files that carry a signature bundle."""
    return archive_names(version, hosts) + [f"morphos-cross-{version}-source.tar.xz", "install.sh"]


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

    installer = (directory / "install.sh").read_text(encoding="utf-8")
    require(f"default_version=v{version}\n" in installer, "install.sh does not name this release")
    require("@VERSION@" not in installer, "install.sh still has the version placeholder")


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    try:
        verify(Path(sys.argv[1]), sys.argv[2], sys.argv[3].split())
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        sys.exit(f"ERROR: {error}")
    print("Release candidate inventory checks passed.")


if __name__ == "__main__":
    main()
