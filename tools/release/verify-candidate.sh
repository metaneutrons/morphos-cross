#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Verify a release candidate: the exact asset set and checksums, and in supply-chain mode every
# Sigstore signature and every GitHub attestation against the downloaded bytes.
# Usage: tools/release/verify-candidate.sh DIRECTORY TAG [local|supply-chain]
set -euo pipefail

directory=${1:?candidate directory is required}
tag=${2:?release tag is required}
mode=${3:-local}
case "$mode" in
    local | supply-chain) ;;
    *) printf 'ERROR: invalid verification mode.\n' >&2; exit 2 ;;
esac

root=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=../../pins.env
. "$root/pins.env"
version=${tag#v}
repository=metaneutrons/morphos-cross
identity="https://github.com/$repository/.github/workflows/release.yml@refs/heads/main"

python3 "$root/tools/release/inventory.py" "$directory" "$version" "$HOSTS"

if [[ $mode == supply-chain ]]; then
    # The inventory names every file that carries a signature: archives, Debian packages, the source
    # archive, the installer and the channel metadata.
    while IFS= read -r payload; do
        cosign verify-blob \
            --bundle "$directory/$payload.sigstore.json" \
            --certificate-oidc-issuer https://token.actions.githubusercontent.com \
            --certificate-identity "$identity" \
            "$directory/$payload"
    done < <(python3 "$root/tools/release/inventory.py" "$directory" "$version" "$HOSTS" --payloads)
    for asset in "$directory"/*; do
        gh attestation verify "$asset" \
            --repo "$repository" \
            --signer-workflow "$repository/.github/workflows/release.yml" \
            --source-ref refs/heads/main
    done
fi

printf 'Release candidate completeness and integrity checks passed (%s).\n' "$mode"
