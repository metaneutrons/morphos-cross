#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the MorphOS cross toolchain (binutils and GCC) for the machine this
# runs on. Output: $work/stage/morphos-cross, a relocatable tree. The SDK is
# unpacked into that tree while it is built (GCC finds the SDK libraries only
# when sysroot and prefix are the same tree); package.sh removes it again.
# Each step leaves a stamp, so a failed run resumes where it stopped.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../pins.env
. "$root/pins.env"

cache=${MORPHOS_CROSS_CACHE:-$root/cache}
work=${MORPHOS_CROSS_WORK:-$root/work}
jobs=${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}
make_cmd=${MAKE:-$(command -v gmake || command -v make)}
target=ppc-morphos
src=$work/src
libs=$work/libs
build_sysroot=$work/sdk-sysroot
stage=$work/stage/morphos-cross
gcc_src=$src/gcc15/gcc-$GCC_VERSION
binutils_src=$src/binutils/binutils-$BINUTILS_VERSION

step() { printf '\n==> %s\n' "$*"; }
done_step() { [[ -f $work/.done-$1 ]]; }
mark() { : > "$work/.done-$1"; }
apply() { # DIR LEVEL PATCH: the MorphOS patches, default fuzz as in their Makefile
    (cd "$1" && patch -s -p"$2") < "$3"
}
# Our own patches in patches/<SDK_DATE>/<component>/*.diff, applied in name
# order without fuzz: a patch that no longer fits must fail, not guess.
apply_series() { # DIR COMPONENT
    local dir=$root/patches/$SDK_DATE/$2 patch_file
    [[ -d $dir ]] || return 0
    for patch_file in "$dir"/*.diff; do
        [[ -e $patch_file ]] || continue
        printf 'patch %s: %s\n' "$2" "$(basename "$patch_file")"
        (cd "$1" && patch -s -F0 --no-backup-if-mismatch -p1) < "$patch_file"
    done
}

mkdir -p "$work"
# Documentation is not part of the archives. A variable on the make command
# line wins over the one configure writes into the Makefiles; one in the
# environment does not.
make_args=(MAKEINFO=true)

# Options that keep the host programs free of dependencies the user may not have.
# zstd is switched off everywhere: configure would otherwise pick up whatever
# copy (Homebrew, a distribution package) happens to be installed on the build
# machine and link the toolchain against it.
host_flags=(--without-zstd)
binutils_flags=()
gcc_flags=()
case "$(uname -s)" in
    Darwin)
        # The zlib bundled with binutils and GCC does not build against current
        # macOS SDKs (it redefines fdopen); macOS always ships a system libz.
        host_flags+=(--with-system-zlib)
        # Without this the binaries require the macOS version they were built on.
        export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-13.0}
        ;;
    Linux)
        # No dependency on the libstdc++ of the machine the toolchain runs on.
        binutils_flags+=(LDFLAGS="-static-libstdc++ -static-libgcc")
        gcc_flags+=(--with-stage1-ldflags="-static-libstdc++ -static-libgcc")
        ;;
esac

unpack() {
    done_step unpack && return 0
    step "Unpack sources"
    rm -rf "$src"
    mkdir -p "$src"
    tar -xJf "$cache/$(basename "$SDK_SOURCE_URL")" -C "$src" --strip-components=1 \
        sdk-source/gcc15 sdk-source/binutils sdk-source/libgmp sdk-source/libmpfr sdk-source/libmpc
    (cd "$src/gcc15" && tar -xf "gcc-$GCC_VERSION.tar.xz")
    (cd "$src/binutils" && tar -xf "binutils-$BINUTILS_VERSION.tar.xz")

    step "Patch binutils and GCC"
    apply "$binutils_src" 1 "$src/binutils/binutils-$BINUTILS_VERSION-morphos.diff"
    # Same order as sdk-source/gcc15/Makefile, plus the cross-build fix that
    # Makefile does not apply because MorphOS builds GCC natively.
    apply "$gcc_src" 1 "$src/gcc15/gcc-15-morphos.diff"
    apply "$gcc_src" 0 "$src/gcc15/fpic.diff"
    apply "$gcc_src" 1 "$src/gcc15/morphos-std-filesystem-path.diff"
    apply "$gcc_src" 1 "$src/gcc15/morphos-std-fastfloat.diff"
    apply "$gcc_src" 0 "$src/gcc15/fix-saveds.diff"
    apply "$gcc_src" 0 "$src/gcc15/objc-saveds.diff"
    apply "$gcc_src" 1 "$src/gcc15/libcpp-disable-canonicalize.diff"
    apply "$gcc_src" 0 "$src/gcc15/const-baserel.diff"
    apply "$gcc_src" 1 "$src/gcc15/fix-fenv-for-crossbuild.diff"
    step "Apply the patches of this repository"
    apply_series "$binutils_src" binutils
    apply_series "$gcc_src" gcc
    mark unpack
}

sdk_sysroot() {
    done_step sdk && return 0
    step "Unpack the SDK as build sysroot"
    rm -rf "$build_sysroot"
    "$root/scripts/install-sdk.sh" "$cache/$(basename "$SDK_URL")" "$build_sysroot"
    # Same files again inside the toolchain tree; $build_sysroot stays as the
    # reference list of what belongs to the SDK.
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -Rp "$build_sysroot/." "$stage/"
    mark sdk
}

host_libs() {
    done_step libs && return 0
    step "Build GMP, MPFR and MPC for the host"
    rm -rf "$libs" "$work/build/libs"
    mkdir -p "$libs" "$work/build/libs"
    tar -xf "$src/libgmp/gmp-$GMP_VERSION.tar.xz" -C "$work/build/libs"
    tar -xf "$src/libmpfr/mpfr-$MPFR_VERSION.tar.xz" -C "$work/build/libs"
    tar -xf "$src/libmpc/mpc-$MPC_VERSION.tar.xz" -C "$work/build/libs"
    (cd "$work/build/libs/gmp-$GMP_VERSION" && ./configure --prefix="$libs" --disable-shared --enable-static >/dev/null && "$make_cmd" -j"$jobs" >/dev/null && "$make_cmd" install >/dev/null)
    (cd "$work/build/libs/mpfr-$MPFR_VERSION" && ./configure --prefix="$libs" --with-gmp="$libs" --disable-shared --enable-static >/dev/null && "$make_cmd" -j"$jobs" >/dev/null && "$make_cmd" install >/dev/null)
    (cd "$work/build/libs/mpc-$MPC_VERSION" && ./configure --prefix="$libs" --with-gmp="$libs" --with-mpfr="$libs" --disable-shared --enable-static >/dev/null && "$make_cmd" -j"$jobs" >/dev/null && "$make_cmd" install >/dev/null)
    mark libs
}

build_binutils() {
    done_step binutils && return 0
    step "Build binutils"
    rm -rf "$work/build/binutils"
    mkdir -p "$work/build/binutils" "$stage"
    (cd "$work/build/binutils" &&
        "$binutils_src/configure" --target="$target" --prefix="$stage" --with-sysroot="$stage" \
            --enable-plugins=no --disable-initfini-array --disable-nls --disable-werror \
            --disable-gprofng --disable-gdb --disable-sim "${host_flags[@]}" "${binutils_flags[@]}" \
            CFLAGS="-O2 -DMORPHOS_TARGET -DMORPHOS_SDK_RELEASE_ID=$MORPHOS_SDK_RELEASE_ID" &&
        "$make_cmd" -j"$jobs" "${make_args[@]}" && "$make_cmd" "${make_args[@]}" install-strip)
    mark binutils
}

build_gcc() {
    done_step gcc && return 0
    step "Build GCC $GCC_VERSION"
    rm -rf "$work/build/gcc"
    mkdir -p "$work/build/gcc"
    # MorphOS has its own thread model (libgcc/config/rs6000/gthr-morphos.h);
    # the MorphOS libstdc++ patch calls __gthread_once_unlock from it. The
    # Makefile in the SDK sources still says posix, which only suits a build
    # on MorphOS itself.
    # The MorphOS link spec contains -latomic. libatomic cannot link against
    # itself, so the target libraries are built against an empty one.
    local dummy=$work/dummy-lib
    rm -rf "$dummy"
    mkdir -p "$dummy"
    "$stage/bin/$target-ar" rc "$dummy/libatomic.a"
    (cd "$work/build/gcc" &&
        PATH="$stage/bin:$PATH" "$gcc_src/configure" --target="$target" --prefix="$stage" \
            --with-sysroot="$stage" \
            CFLAGS_FOR_TARGET="-O2 -g -L$dummy" CXXFLAGS_FOR_TARGET="-O2 -g -L$dummy" \
            LDFLAGS_FOR_TARGET="-L$dummy" \
            --libexecdir="$stage/lib" --oldincludedir="$stage/include" \
            --program-prefix="$target-" --program-suffix=-15 \
            --enable-languages=c,c++,objc,obj-c++ \
            --enable-threads=morphos --enable-version-specific-runtime-libs \
            --with-plugin-ld=no --disable-bootstrap --disable-nls \
            --with-pkgversion="morphos-cross GCC/MorphOS" \
            --with-gmp="$libs" --with-mpfr="$libs" --with-mpc="$libs" "${host_flags[@]}" "${gcc_flags[@]}" &&
        PATH="$stage/bin:$PATH" "$make_cmd" -j"$jobs" "${make_args[@]}" &&
        PATH="$stage/bin:$PATH" "$make_cmd" "${make_args[@]}" install-strip)
    mark gcc
}

finish() {
    step "Fix the library layout"
    # MorphOS keeps the compiler's own files in lib/gcc-lib. The MorphOS patch
    # covers most of GCC, but libatomic, the LTO plugin and the C++ module
    # mapper still install into lib/gcc.
    if [[ -d $stage/lib/gcc ]]; then
        mkdir -p "$stage/lib/gcc-lib"
        cp -Rp "$stage/lib/gcc/." "$stage/lib/gcc-lib/"
        rm -rf "$stage/lib/gcc"
    fi
    # libtool archives hold absolute build paths and are of no use here.
    find "$stage" -name '*.la' -delete
    # Host libraries for GDB's "compile" command and for compiler plugins: of no
    # use when cross compiling, and they depend on the host's libstdc++.
    rm -f "$stage"/lib/libcc1.*
    rm -rf "$stage/lib/gcc-lib/$target/$GCC_VERSION/plugin"

    step "Add unsuffixed tool names"
    local tool
    for tool in gcc g++ c++ cpp gcov gcc-ar gcc-nm gcc-ranlib; do
        if [[ -e $stage/bin/$target-$tool-15 && ! -e $stage/bin/$target-$tool ]]; then
            ln -s "$target-$tool-15" "$stage/bin/$target-$tool"
        fi
    done
    printf '\nToolchain tree: %s\n' "$stage"
}

case "${1:-all}" in
    unpack)
        # Unpack and patch only: the quick check that the patches still fit.
        unpack
        ;;
    all)
        unpack
        sdk_sysroot
        host_libs
        build_binutils
        build_gcc
        finish
        ;;
    *)
        printf 'usage: %s [unpack|all]\n' "$0" >&2
        exit 2
        ;;
esac
