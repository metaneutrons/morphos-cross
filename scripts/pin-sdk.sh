#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Pin a MorphOS SDK: download the SDK and its sources, compute their SHA-256 and rewrite pins.env.
# MorphOS publishes no checksums, so the first download is the trust anchor.
# Usage: scripts/pin-sdk.sh [YYYYMMDD]   (default: the newest SDK listed on morphos-team.net)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cache=${MORPHOS_CROSS_CACHE:-$root/cache}
site=https://morphos-team.net
pins=$root/pins.env
mkdir -p "$cache"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
set_pin() { # KEY VALUE
    local tmp
    tmp=$(mktemp)
    sed -E "s|^$1=.*|$1=$2|" "$pins" > "$tmp"
    grep -q "^$1=$2\$" "$tmp" || { rm -f "$tmp"; printf 'ERROR: cannot set %s in pins.env\n' "$1" >&2; exit 1; }
    cat "$tmp" > "$pins"
    rm -f "$tmp"
}
fetch() { # URL: download into the cache unless a file of that name is already there
    local file
    file=$cache/$(basename "$1")
    [[ -f $file ]] || curl --fail --silent --show-error --location --retry 3 --output "$file.part" "$1"
    [[ ! -f $file.part ]] || mv -f "$file.part" "$file"
    printf '%s' "$file"
}

page=$(curl --fail --silent --show-error --location "$site/downloads")
date=${1:-$(grep -oE 'files/sdk-[0-9]{8}\.lha' <<<"$page" | tr -dc '0-9\n' | sort -u | tail -1)}
[[ $date =~ ^[0-9]{8}$ ]] || { printf 'ERROR: no SDK date found; pass one as YYYYMMDD\n' >&2; exit 1; }
version=$(grep -oE 'MorphOS [0-9]+\.[0-9]+ SDK' <<<"$page" | head -1 | grep -oE '[0-9]+\.[0-9]+' || true)
[[ -n $version ]] || { printf 'ERROR: cannot read the MorphOS version from %s/downloads\n' "$site" >&2; exit 1; }

sdk_url=$site/files/sdk-$date.lha
source_url=$site/files/src/sdk/sdk-source-$date.tar.xz
sdk_file=$(fetch "$sdk_url")
source_file=$(fetch "$source_url")

listing=$(tar -tJf "$source_file")
component() { # DIRECTORY PREFIX: the version of the one tarball "PREFIX-<version>.tar.xz" in DIRECTORY
    local found
    found=$(grep -oE "^sdk-source/$1/$2-[0-9][0-9.]*\.tar\.xz\$" <<<"$listing" | sed -E "s|.*/$2-(.*)\.tar\.xz|\1|")
    [[ $(wc -l <<<"$found" | tr -d ' ') -eq 1 && -n $found ]] || { printf 'ERROR: cannot find exactly one %s tarball in %s\n' "$2" "$1" >&2; exit 1; }
    printf '%s' "$found"
}
gcc_dir=$(grep -oE '^sdk-source/gcc[0-9]+/$' <<<"$listing" | sed -E 's|sdk-source/(gcc[0-9]+)/|\1|' | sort -V | tail -1)
[[ $gcc_dir == gcc15 ]] || printf 'WARNING: the newest GCC directory is %s; scripts/build.sh still builds gcc15 (program suffix -15).\n' "$gcc_dir" >&2

old_date=$(sed -n 's/^SDK_DATE=//p' "$pins")
set_pin SDK_VERSION "$version"
set_pin SDK_DATE "$date"
set_pin SDK_URL "$sdk_url"
set_pin SDK_SHA256 "$(sha256_of "$sdk_file")"
set_pin SDK_SOURCE_URL "$source_url"
set_pin SDK_SOURCE_SHA256 "$(sha256_of "$source_file")"
set_pin GCC_VERSION "$(component gcc15 gcc)"
set_pin BINUTILS_VERSION "$(component binutils binutils)"
set_pin GMP_VERSION "$(component libgmp gmp)"
set_pin MPFR_VERSION "$(component libmpfr mpfr)"
set_pin MPC_VERSION "$(component libmpc mpc)"
# The revision counts rebuilds of one SDK; a new SDK starts again at 1.
[[ $old_date == "$date" ]] || set_pin REVISION 1

printf 'Pinned MorphOS %s SDK %s (revision %s).\n' "$version" "$date" "$(sed -n 's/^REVISION=//p' "$pins")"
printf 'Next: make patches-check, and fix any patch that no longer fits patches/%s/.\n' "$date"
