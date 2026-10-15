#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Extract the parts of the MorphOS SDK that the compiler needs (headers and
# libraries) from the SDK archive into DEST. The SDK itself is not part of
# morphos-cross; its owner is the MorphOS Team, see README.md.
# Usage: scripts/install-sdk.sh SDK.lha DEST [LIST]
# The files are unpacked into a scratch directory first and reach DEST only after the SDK has been
# recognised, so a damaged archive changes nothing. LIST, when given, receives the relative path of
# every installed file, link and directory, which morphos-cross-sdk uses to remove them again.
set -euo pipefail

lha=${1:?usage: install-sdk.sh SDK.lha DEST [LIST]}
dest=${2:?usage: install-sdk.sh SDK.lha DEST [LIST]}
list=${3:-}
lha=$(cd "$(dirname "$lha")" && pwd)/$(basename "$lha")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xf "$lha" -C "$tmp" morphossdk/sdk.pack
elif command -v lha >/dev/null 2>&1; then
    (cd "$tmp" && lha -xq "$lha" morphossdk/sdk.pack)
else
    printf 'ERROR: need bsdtar (libarchive) or lha to unpack the SDK archive\n' >&2
    exit 1
fi
pack=$tmp/morphossdk/sdk.pack

# The directory is "gg" in current SDKs and was "GG" in older ones.
listing=$(xz -dc "$pack" | tar -tf -)
# awk reads the whole listing; stopping early would kill printf with SIGPIPE.
gg=$(printf '%s\n' "$listing" | awk -F/ '!found && tolower($2) == "gg" { print $1 "/" $2; found = 1 }')
if [[ -z $gg ]]; then
    printf 'ERROR: no gg directory in the SDK pack\n' >&2
    exit 1
fi

stage=$tmp/stage
mkdir -p "$stage"
xz -dc "$pack" | tar -xf - -C "$stage" --no-same-owner --no-same-permissions --strip-components=2 \
    --exclude ldscripts "$gg/include" "$gg/includestd" "$gg/os-include" "$gg/ppc-morphos"
if [[ ! -f $stage/os-include/exec/types.h ]]; then
    printf 'ERROR: the SDK pack lacks os-include/exec/types.h; nothing was installed\n' >&2
    exit 1
fi

mkdir -p "$dest"
(cd "$stage" && tar -cf - .) | tar -xf - -C "$dest" --no-same-owner --no-same-permissions
if [[ -n $list ]]; then
    (cd "$stage" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort) > "$list.tmp"
    mv -f "$list.tmp" "$list"
fi
printf 'SDK headers and libraries installed in %s\n' "$dest"
