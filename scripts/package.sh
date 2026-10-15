#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Turn a built toolchain tree into a release archive and refuse to ship any
# file of the MorphOS SDK.
# Usage: scripts/package.sh HOST_ID   (linux-x86_64 | linux-arm64 | macos-arm64)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../pins.env
. "$root/pins.env"
host=${1:?usage: package.sh HOST_ID}
case " $HOSTS " in
    *" $host "*) ;;
    *) printf 'ERROR: %s is not one of the hosts in pins.env: %s\n' "$host" "$HOSTS" >&2; exit 2 ;;
esac
work=${MORPHOS_CROSS_WORK:-$root/work}
out=${MORPHOS_CROSS_OUT:-$root/dist}
stage=$work/stage/morphos-cross
sysroot=$work/sdk-sysroot
name=morphos-cross-$VERSION-$host

sha256_list() { # DIR: "hash  relative-path" for every regular file
    (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
}

[[ -x $stage/bin/ppc-morphos-gcc ]] || { printf 'ERROR: no toolchain in %s\n' "$stage" >&2; exit 1; }

# 0. The SDK was unpacked into the tree for the build: remove every file that
#    is still identical to the SDK copy in $sysroot.
strip_sdk() {
    local rel
    while IFS= read -r -d '' rel; do
        if [[ -L $sysroot/$rel ]]; then
            if [[ -L $stage/$rel && $(readlink "$stage/$rel") == "$(readlink "$sysroot/$rel")" ]]; then
                rm -f "$stage/$rel"
            fi
        elif [[ -f $stage/$rel ]] && cmp -s "$sysroot/$rel" "$stage/$rel"; then
            rm -f "$stage/$rel"
        fi
    done < <(cd "$sysroot" && find . ! -type d -print0)
    find "$stage" -depth -type d -empty -delete
}
strip_sdk

# 1. No SDK file may be inside the tree: neither by name nor by content.
for dir in os-include includestd include; do
    [[ ! -e $stage/$dir ]] || { printf 'ERROR: %s/%s is part of the SDK\n' "$stage" "$dir" >&2; exit 1; }
done
sha256_list "$sysroot" | awk '{ print $1 }' | LC_ALL=C sort -u > "$work/sdk-hashes.txt"
sha256_list "$stage" | awk '{ print $1 }' | LC_ALL=C sort -u > "$work/stage-hashes.txt"
shared=$(LC_ALL=C comm -12 "$work/sdk-hashes.txt" "$work/stage-hashes.txt" | wc -l | tr -d ' ')
[[ $shared -eq 0 ]] || { printf 'ERROR: %s files of the tree are identical to SDK files\n' "$shared" >&2; exit 1; }
printf 'ok: no SDK file in the tree\n'

# 2. Add what a user needs to finish the installation, and the licences and build facts of what
#    is in the tree.
src=$work/src
doc=$stage/share/doc/morphos-cross
mkdir -p "$doc/licenses/gcc" "$doc/licenses/binutils" "$doc/licenses/gmp" "$doc/licenses/mpfr" "$doc/licenses/mpc"
cp "$root/LICENSE" "$root/THIRD-PARTY.md" "$doc/"
cp "$src/gcc15/gcc-$GCC_VERSION/COPYING3" "$src/gcc15/gcc-$GCC_VERSION/COPYING.RUNTIME" \
    "$src/gcc15/gcc-$GCC_VERSION/COPYING3.LIB" "$doc/licenses/gcc/"
cp "$src/binutils/binutils-$BINUTILS_VERSION/COPYING3" "$src/binutils/binutils-$BINUTILS_VERSION/COPYING3.LIB" \
    "$doc/licenses/binutils/"
tar -xJf "$src/libgmp/gmp-$GMP_VERSION.tar.xz" -C "$doc/licenses/gmp" --strip-components=1 \
    "gmp-$GMP_VERSION/COPYING.LESSERv3" "gmp-$GMP_VERSION/COPYINGv2"
tar -xJf "$src/libmpfr/mpfr-$MPFR_VERSION.tar.xz" -C "$doc/licenses/mpfr" --strip-components=1 \
    "mpfr-$MPFR_VERSION/COPYING.LESSER"
tar -xJf "$src/libmpc/mpc-$MPC_VERSION.tar.xz" -C "$doc/licenses/mpc" --strip-components=1 \
    "mpc-$MPC_VERSION/COPYING.LESSER"
commit=${GITHUB_SHA:-$(git -C "$root" rev-parse --verify --quiet HEAD || echo unknown)}
cat > "$doc/BUILD-INFO.txt" <<EOF
morphos-cross $VERSION for $host
MorphOS $SDK_VERSION SDK of $SDK_DATE (not part of this archive)
SDK    $SDK_URL
       SHA-256 $SDK_SHA256
GCC $GCC_VERSION, binutils $BINUTILS_VERSION, GMP $GMP_VERSION, MPFR $MPFR_VERSION, MPC $MPC_VERSION
Built from commit $commit of https://github.com/metaneutrons/morphos-cross
EOF
mkdir -p "$stage/share/morphos-cross/scripts"
cp "$root/pins.env" "$stage/share/morphos-cross/pins.env"
cp "$root/scripts/fetch.sh" "$root/scripts/install-sdk.sh" "$stage/share/morphos-cross/scripts/"
cp "$root/scripts/morphos-cross-sdk" "$stage/bin/morphos-cross-sdk"
printf '%s\n' "$SDK_DATE" > "$stage/share/morphos-cross/SDK_DATE"

# 3. Archive.
mkdir -p "$out"
tar_opts=()
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    tar_opts=(--sort=name --owner=0 --group=0 --numeric-owner --mtime="@${SOURCE_DATE_EPOCH:-0}")
fi
tar -C "$work/stage" ${tar_opts[@]+"${tar_opts[@]}"} -cf - morphos-cross | xz -T0 -9 > "$out/$name.tar.xz"
(cd "$out" && shasum -a 256 "$name.tar.xz" > "$name.tar.xz.sha256")
printf 'Archive: %s\n' "$out/$name.tar.xz"
