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

curl_get() { # URL OUTPUT [extra curl arguments]
    local url=$1 output=$2
    shift 2
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        --connect-timeout "${MORPHOS_CROSS_CONNECT_TIMEOUT:-30}" --speed-limit 10240 --speed-time 60 \
        "$@" --output "$output" "$url"
}

fetch_one() {
    local url=$1 sum=$2 file
    file="$cache/$(basename "$url")"
    if [[ -f $file && $(sha256_of "$file") == "$sum" ]]; then
        printf 'cached: %s\n' "$(basename "$file")"
        return
    fi
    # A partial file of an interrupted download is resumed, and a connection that moves less than
    # 10 KiB/s for a minute counts as stalled. When the network fails, the partial file stays for
    # the next run. When the server refuses the resume (curl exits 22, 33 or 36) the file may be
    # stale, and one more attempt starts from the beginning.
    if [[ -f $file.part && $(sha256_of "$file.part") == "$sum" ]]; then
        :
    elif curl_get "$url" "$file.part" --continue-at -; then
        :
    else
        rc=$?
        [[ $rc -eq 22 || $rc -eq 33 || $rc -eq 36 ]] || exit "$rc"
        rm -f "$file.part"
        curl_get "$url" "$file.part" || { rc=$?; rm -f "$file.part"; exit "$rc"; }
    fi
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
