#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Test a toolchain tree: install the SDK next to it, compile and link C and C++
# programs, check the ELF output, then move the tree and test again (the tree
# must be relocatable). The tree is left without SDK files at the end.
# Usage: scripts/test-toolchain.sh TREE CACHE_DIR
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../pins.env
. "$root/pins.env"
tree=$(cd "${1:?usage: test-toolchain.sh TREE CACHE_DIR}" && pwd -P)
cache=${2:?usage: test-toolchain.sh TREE CACHE_DIR}
sdk=$cache/$(basename "$SDK_URL")

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

check_toolchain() { # TREE
    # Physical path: the compiler reports resolved paths (macOS: /private/var, not /var).
    local t out cc cxx readelf
    t=$(cd "$1" && pwd -P)
    cc=$t/bin/ppc-morphos-gcc
    cxx=$t/bin/ppc-morphos-g++
    readelf=$t/bin/ppc-morphos-readelf
    out=$(mktemp -d)

    "$cc" --version | grep -q "$GCC_VERSION" || fail "gcc version is not $GCC_VERSION"
    ok "gcc $GCC_VERSION"

    "$cc" -O2 -o "$out/hello-ixemul" "$root/tests/smoke/hello.c" || fail "C, default (ixemul)"
    "$cc" -O2 -mclib=libnix -o "$out/hello-libnix" "$root/tests/smoke/hello.c" || fail "C, libnix"
    "$cxx" -O2 -o "$out/hello-cpp" "$root/tests/smoke/hello.cpp" || fail "C++"
    ok "C (ixemul, libnix) and C++ compile and link"

    local file header
    for file in hello-ixemul hello-libnix hello-cpp; do
        header=$("$readelf" -h "$out/$file")
        grep -q 'Class: *ELF32' <<<"$header" || fail "$file is not ELF32"
        grep -q "big endian" <<<"$header" || fail "$file is not big endian"
        grep -q 'Machine: *PowerPC$' <<<"$header" || fail "$file is not PowerPC"
        grep -a -q "MorphOS_SDK: $MORPHOS_SDK_RELEASE_ID" "$out/$file" || fail "$file lacks the SDK id note"
    done
    ok "output is ELF32, big endian, PowerPC, with the SDK id note"

    # Every directory the preprocessor and the linker search must lie inside the tree.
    local dirs outside
    dirs=$("$cc" -E -v -x c /dev/null -o /dev/null 2>&1 | awk '/^ \//')
    dirs="$dirs
$("$cc" -print-search-dirs | tr ':=' '\n' | awk '/^\//')"
    outside=$(printf '%s\n' "$dirs" | awk -v t="$t" 'NF && index($1, t) != 1')
    [[ -z $outside ]] || fail "search paths outside the tree: $outside"
    ok "all search paths lie inside the tree"
    rm -rf "$out"
}

[[ ! -e $tree/os-include ]] || fail "the archive already contains the SDK"
"$tree/bin/morphos-cross-sdk" status && fail "status claims an SDK before install"
"$tree/bin/morphos-cross-sdk" install "$sdk"
"$tree/bin/morphos-cross-sdk" status
check_toolchain "$tree"

moved=$(mktemp -d)/relocated/morphos-cross
mkdir -p "$(dirname "$moved")"
mv "$tree" "$moved"
check_toolchain "$moved"
mv "$moved" "$tree"
ok "relocation: tree works after moving it"
