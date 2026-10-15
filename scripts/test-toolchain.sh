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

    # Every absolute path the compiler reports must lie inside the tree: the include search, the
    # command lines it runs, the sysroot and the library search. Only the "Configured with" line
    # carries build paths by design. (An earlier version looked at the first word of each line only
    # and never saw the sysroot that GCC had not relocated.)
    local report outside
    report=$({ "$cc" -E -v -x c /dev/null -o /dev/null 2>&1; "$cc" -print-sysroot; "$cc" -print-search-dirs; } |
        grep -v -E '^(Configured with:|gcc version)')
    outside=$(printf '%s\n' "$report" | grep -oE "/[A-Za-z0-9._+@%-][^ \"':=]*" | grep -v '^/dev/null$' |
        awk -v t="$t" 'index($0, t) != 1' | sort -u)
    [[ -z $outside ]] || fail "paths outside the tree: $(tr '\n' ' ' <<<"$outside")"
    ok "every path the compiler reports lies inside the tree"
    rm -rf "$out"
}

[[ ! -e $tree/os-include ]] || fail "the archive already contains the SDK"
before=$(cd "$tree" && find . | LC_ALL=C sort)
"$tree/bin/morphos-cross-sdk" status && fail "status claims an SDK before install"

# The installer names the folder after the release, never "morphos-cross", and a user may rename it:
# the compiler must not depend on the folder's name. Test under such a name, then under another.
original=$tree
installed=$(mktemp -d)/v00000000-r0
mv "$tree" "$installed"
"$installed/bin/morphos-cross-sdk" install "$sdk"
"$installed/bin/morphos-cross-sdk" status
check_toolchain "$installed"

moved=$(mktemp -d)/relocated/some-other-name
mkdir -p "$(dirname "$moved")"
mv "$installed" "$moved"
check_toolchain "$moved"
mv "$moved" "$original"
ok "relocation: the tree works under the installer's folder name and after moving and renaming it"

# Removing the SDK must leave the archive's own files and nothing else.
"$original/bin/morphos-cross-sdk" remove
"$original/bin/morphos-cross-sdk" status && fail "status claims an SDK after remove"
after=$(cd "$original" && find . | LC_ALL=C sort)
[[ $after == "$before" ]] || fail "remove changed the tree: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -10 | tr '\n' ' ')"
ok "remove: the tree is back to the files of the archive"
