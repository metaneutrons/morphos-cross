#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Check that the host programs in an unpacked toolchain tree depend only on what every machine of
# that host class has, and on nothing the build machine happened to have installed (a Homebrew
# library, a distribution package). The PowerPC objects of the target are not looked at.
# Usage: scripts/check-linkage.sh TREE
set -euo pipefail

tree=$(cd "${1:?usage: check-linkage.sh TREE}" && pwd -P)
max_glibc=${MAX_GLIBC:-2.36}
min_macos=${MIN_MACOS:-13.0}
failures=0

fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

version_le() { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1) == "$2" ]]; }

check_linux() { # FILE
    local file=$1 needed lib symbols version
    needed=$(readelf -d "$file" 2>/dev/null | awk '/\(NEEDED\)/ { gsub(/[][]/, "", $5); print $5 }')
    for lib in $needed; do
        [[ $lib =~ ^(libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|ld-linux-(aarch64|x86-64)\.so\.[0-9])$ ]] ||
            fail "${file#"$tree"/} needs $lib"
    done
    symbols=$(objdump -T "$file" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -u | sed 's/GLIBC_//' || true)
    for version in $symbols; do
        version_le "$version" "$max_glibc" || fail "${file#"$tree"/} needs GLIBC_$version (baseline $max_glibc)"
    done
}

check_macos() { # FILE
    local file=$1 lib minos
    while IFS= read -r lib; do
        [[ $lib =~ ^(/usr/lib/(libSystem\.B|libz\.1|libc\+\+\.1|libiconv\.2|libc\+\+abi)\.dylib|@(rpath|loader_path|executable_path)/.*)$ ]] ||
            fail "${file#"$tree"/} links $lib"
    done < <(otool -L "$file" | tail -n +2 | awk '{ print $1 }')
    minos=$(otool -l "$file" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')
    if [[ -n $minos ]]; then
        version_le "$minos" "$min_macos" || fail "${file#"$tree"/} requires macOS $minos (baseline $min_macos)"
    fi
}

count=0
while IFS= read -r -d '' file; do
    description=$(file -b "$file")
    case "$(uname -s)" in
        Linux) grep -Eq '^ELF .*(ARM aarch64|x86-64)' <<<"$description" || continue; check_linux "$file" ;;
        Darwin) grep -Eq '^Mach-O 64-bit .*arm64' <<<"$description" || continue; check_macos "$file" ;;
        *) printf 'ERROR: unsupported host\n' >&2; exit 2 ;;
    esac
    count=$((count + 1))
done < <(find "$tree" -type f -print0)

[[ $count -gt 0 ]] || { printf 'FAIL: no host program found in %s\n' "$tree" >&2; exit 1; }
[[ $failures -eq 0 ]] || { printf '%s linkage problem(s) in %s host files.\n' "$failures" "$count" >&2; exit 1; }
printf 'ok: %s host programs link only against base system libraries\n' "$count"
