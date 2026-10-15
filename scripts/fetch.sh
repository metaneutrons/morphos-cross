#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Download the pinned SDK files into the cache and verify their SHA-256.
# Usage: scripts/fetch.sh [sdk|source|all]
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../pins.env
. "$root/pins.env"
cache=${MORPHOS_CROSS_CACHE:-$root/cache}
mkdir -p "$cache"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

fetch_one() {
    local url=$1 sum=$2 file
    file="$cache/$(basename "$url")"
    if [[ -f $file && $(sha256_of "$file") == "$sum" ]]; then
        printf 'cached: %s\n' "$(basename "$file")"
        return
    fi
    rm -f "$file.part"
    curl --fail --silent --show-error --location --retry 3 --output "$file.part" "$url"
    if [[ $(sha256_of "$file.part") != "$sum" ]]; then
        rm -f "$file.part"
        printf 'ERROR: checksum mismatch for %s\n' "$url" >&2
        exit 1
    fi
    mv -f "$file.part" "$file"
    printf 'fetched: %s\n' "$(basename "$file")"
}

case "${1:-all}" in
    sdk) fetch_one "$SDK_URL" "$SDK_SHA256" ;;
    source) fetch_one "$SDK_SOURCE_URL" "$SDK_SOURCE_SHA256" ;;
    all)
        fetch_one "$SDK_URL" "$SDK_SHA256"
        fetch_one "$SDK_SOURCE_URL" "$SDK_SOURCE_SHA256"
        ;;
    *) printf 'usage: %s [sdk|source|all]\n' "$0" >&2; exit 2 ;;
esac
