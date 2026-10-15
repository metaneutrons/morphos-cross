#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""SPDX 2.3 document for one toolchain archive: the archive and the components built into it."""

import datetime
import hashlib
import json
from pathlib import Path
import sys

# Licences of what the archive contains. libgcc and libstdc++ fall under the GCC runtime library
# exception; GMP is dual-licensed.
COMPONENTS = (
    ("gcc", "GCC_VERSION", "GPL-3.0-or-later WITH GCC-exception-3.1",
     "GNU Compiler Collection with the MorphOS patches"),
    ("binutils", "BINUTILS_VERSION", "GPL-3.0-or-later", "GNU binutils with the MorphOS patches"),
    ("gmp", "GMP_VERSION", "LGPL-3.0-or-later OR GPL-2.0-or-later", "linked into the compiler"),
    ("mpfr", "MPFR_VERSION", "LGPL-3.0-or-later", "linked into the compiler"),
    ("mpc", "MPC_VERSION", "LGPL-3.0-or-later", "linked into the compiler"),
)


def read_pins(path):
    pins = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            pins[key] = value.strip().strip('"')
    pins["VERSION"] = f"{pins['SDK_DATE']}-r{pins['REVISION']}"
    return pins


def document(payload_name, payload_digest, pins, commit, epoch):
    version = pins["VERSION"]
    created = datetime.datetime.fromtimestamp(epoch, datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    package_id = "SPDXRef-Package-morphos-cross"
    packages = [{
        "name": "morphos-cross", "SPDXID": package_id, "versionInfo": version,
        "downloadLocation": "https://github.com/metaneutrons/morphos-cross/releases/tag/v" + version,
        "filesAnalyzed": False, "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "GPL-3.0-or-later", "copyrightText": "NOASSERTION",
        "checksums": [{"algorithm": "SHA256", "checksumValue": payload_digest}],
        "sourceInfo": f"morphos-cross source commit {commit}",
        "comment": "The MorphOS SDK is not part of this archive. It is fetched at installation "
                   f"time from the pinned location {pins['SDK_URL']} (SHA-256 {pins['SDK_SHA256']}).",
    }]
    relationships = [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES",
                      "relatedSpdxElement": package_id}]
    for name, key, license_id, note in COMPONENTS:
        identifier = f"SPDXRef-Package-{name}"
        packages.append({
            "name": name, "SPDXID": identifier, "versionInfo": pins[key],
            "downloadLocation": pins["SDK_SOURCE_URL"], "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION", "licenseDeclared": license_id,
            "copyrightText": "NOASSERTION", "comment": note,
            "sourceInfo": f"Source archive SHA-256 {pins['SDK_SOURCE_SHA256']}",
        })
        relationships.append({"spdxElementId": package_id, "relationshipType": "CONTAINS",
                              "relatedSpdxElement": identifier})
    return {
        "spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT",
        "name": payload_name,
        "documentNamespace": f"https://github.com/metaneutrons/morphos-cross/sbom/{commit}/{payload_digest}",
        "creationInfo": {"created": created,
                         "creators": ["Organization: metaneutrons", "Tool: morphos-cross-sbom/1"]},
        "packages": packages, "relationships": relationships,
    }


def main():
    if len(sys.argv) != 7:
        sys.exit("usage: generate-sbom.py PINS PAYLOAD OUTPUT VERSION COMMIT EPOCH")
    pins_path, payload, output, version, commit, epoch = sys.argv[1:]
    pins = read_pins(pins_path)
    if pins["VERSION"] != version:
        sys.exit(f"pins.env says {pins['VERSION']} but the release is {version}")
    for _, key, _, _ in COMPONENTS:
        pins.setdefault(key, "NOASSERTION")
    digest = hashlib.sha256(Path(payload).read_bytes()).hexdigest()
    data = document(Path(payload).name, digest, pins, commit, int(epoch))
    Path(output).write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
