#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build, package and test the toolchain for this machine, the way a user gets
# it: the archive is unpacked into an empty directory, the SDK is installed
# with the helper from the archive, and only then is the toolchain tested.
# Usage: scripts/ci-build.sh [HOST_ID]
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../pins.env
. "$root/pins.env"
host=${1:-$("$root/scripts/host-id.sh")}
cache=${MORPHOS_CROSS_CACHE:-$root/cache}
out=${MORPHOS_CROSS_OUT:-$root/dist}

"$root/scripts/fetch.sh" all
"$root/scripts/build.sh"
MORPHOS_CROSS_OUT=$out "$root/scripts/package.sh" "$host"

unpacked=$(mktemp -d)
trap 'rm -rf "$unpacked"' EXIT
tar -xf "$out/morphos-cross-$VERSION-$host.tar.xz" -C "$unpacked"
"$root/scripts/check-linkage.sh" "$unpacked/morphos-cross"
"$root/scripts/test-toolchain.sh" "$unpacked/morphos-cross" "$cache"
printf '\nAll checks passed for %s.\n' "$host"
