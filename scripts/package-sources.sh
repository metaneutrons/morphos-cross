#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The source archive of a release: the sources of everything GPL-covered that the toolchain is
# built from (GCC, binutils, GMP, MPFR, MPC and the MorphOS patches for them), exactly as they come
# in the pinned SDK sources, plus this repository. Every release carries it, so that the people
# who receive the binaries also receive the corresponding source.
# Run scripts/build.sh unpack first. Usage: scripts/package-sources.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../pins.env
. "$root/pins.env"
work=${MORPHOS_CROSS_WORK:-$root/work}
out=${MORPHOS_CROSS_OUT:-$root/dist}
src=$work/src
name=morphos-cross-$VERSION-source

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dir=$tmp/$name
mkdir -p "$dir/sdk-source"

for component in gcc15 binutils libgmp libmpfr libmpc; do
    [[ -d $src/$component ]] || { printf 'ERROR: %s is missing; run scripts/build.sh unpack first\n' "$src/$component" >&2; exit 1; }
    mkdir -p "$dir/sdk-source/$component"
    # Only the files that came in the SDK sources, not the unpacked trees next to them.
    find "$src/$component" -maxdepth 1 -type f -exec cp {} "$dir/sdk-source/$component/" \;
done

mkdir -p "$dir/morphos-cross"
# MORPHOS_CROSS_TREEISH lets a test archive an uncommitted tree (git write-tree).
git -C "$root" archive "${MORPHOS_CROSS_TREEISH:-HEAD}" | tar -x -C "$dir/morphos-cross"

cat > "$dir/README-SOURCES.txt" <<EOF
Corresponding source of morphos-cross $VERSION

sdk-source/   GCC $GCC_VERSION, binutils $BINUTILS_VERSION, GMP $GMP_VERSION, MPFR $MPFR_VERSION and MPC $MPC_VERSION
              with the MorphOS patches, as distributed by the MorphOS Team in
              $SDK_SOURCE_URL
              (SHA-256 $SDK_SOURCE_SHA256).
morphos-cross/  the tooling and the patches of this repository at the commit that was released.

The toolchain archives were built with morphos-cross/scripts/build.sh from exactly these files.
The MorphOS SDK itself (headers and libraries) is not part of the toolchain archives and not part
of this archive.
EOF

mkdir -p "$out"
tar_opts=()
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    tar_opts=(--sort=name --owner=0 --group=0 --numeric-owner --mtime="@${SOURCE_DATE_EPOCH:-0}")
fi
tar -C "$tmp" "${tar_opts[@]}" -cf - "$name" | xz -T0 -9 > "$out/$name.tar.xz"
printf 'Source archive: %s\n' "$out/$name.tar.xz"
