#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Validate real SBOMs and prove the official validator rejects a broken reference."""

import copy
import sys

from spdx_tools.spdx.parser.parse_anything import parse_file
from spdx_tools.spdx.validation.document_validator import validate_full_spdx_document


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: validate-sbom.py SBOM [SBOM ...]")
    for path in sys.argv[1:]:
        document = parse_file(path)
        errors = validate_full_spdx_document(document)
        if errors:
            sys.exit("Invalid SPDX document: " + str(errors))
        broken = copy.deepcopy(document)
        broken.relationships[0].related_spdx_element_id = "SPDXRef-Missing-Counterprobe"
        errors = validate_full_spdx_document(broken)
        if not errors or not any("SPDXRef-Missing-Counterprobe" in error.validation_message for error in errors):
            sys.exit("SPDX validator accepted an unresolved relationship counterprobe")
        print(f"SPDX validation and broken-reference counterprobe passed: {path}")


if __name__ == "__main__":
    main()
