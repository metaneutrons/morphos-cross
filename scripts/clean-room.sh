#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside a fresh container that has none of the build tools: unpack a release archive,
# install the SDK with the helper from the archive, compile and link, move the tree and test again.
# Usage: scripts/clean-room.sh ARCHIVE CACHE_DIR   (CACHE_DIR holds the pinned SDK archive)
set -euo pipefail

archive=${1:?usage: clean-room.sh ARCHIVE CACHE_DIR}
cache=${2:?usage: clean-room.sh ARCHIVE CACHE_DIR}
root=$(cd "$(dirname "$0")/.." && pwd)

# What the README lists as prerequisites for a Linux host, and nothing else.
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq > /dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        ca-certificates curl xz-utils libarchive-tools > /dev/null
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xJf "$archive" -C "$work"
bash "$root/scripts/test-toolchain.sh" "$work/morphos-cross" "$cache"
