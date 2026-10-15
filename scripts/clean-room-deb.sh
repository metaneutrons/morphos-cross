#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside a container that has no network: install the Debian package and check what a user gets.
# Usage: clean-room-deb.sh offline|cached|skip     expects /deb/morphos-cross_*.deb, /cache with the SDK
set -euo pipefail

scenario=${1:?usage: clean-room-deb.sh offline|cached|skip}
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../pins.env
. "$root/pins.env"
sdk=$(basename "$SDK_URL")
tree=/usr/lib/morphos-cross
export DEBIAN_FRONTEND=noninteractive

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

install_deb() {
    apt-get install -y --no-install-recommends /deb/morphos-cross_*.deb 2>&1 | tee /tmp/apt.log
}

compile_both() {
    local out
    out=$(mktemp -d)
    ppc-morphos-gcc -O2 -o "$out/c-ixemul" "$root/tests/smoke/hello.c"
    ppc-morphos-gcc -O2 -mclib=libnix -o "$out/c-libnix" "$root/tests/smoke/hello.c"
    ppc-morphos-g++ -O2 -o "$out/cpp" "$root/tests/smoke/hello.cpp"
    ppc-morphos-readelf -h "$out/c-ixemul" | grep -q 'PowerPC' || fail "the output is not PowerPC"
    ppc-morphos-readelf -h "$out/cpp" | grep -q 'big endian' || fail "the output is not big endian"
    rm -rf "$out"
}

case "$scenario" in
    offline)
        # No network: the installation succeeds, warns, and the user installs the SDK from a file.
        install_deb || fail "the installation failed without a network"
        grep -q 'WARNING' /tmp/apt.log || fail "no warning about the missing SDK"
        grep -q 'morphos-cross-sdk install' /tmp/apt.log || fail "the warning does not name the command"
        ppc-morphos-gcc --version | grep -q "$GCC_VERSION" || fail "ppc-morphos-gcc is not on the PATH"
        [[ -L /usr/bin/ppc-morphos-gcc && -L /usr/bin/morphos-cross-sdk ]] || fail "the tools are not linked into /usr/bin"
        morphos-cross-sdk status && fail "status claims an SDK that was never fetched"
        ok "without a network the package installs, warns and names the command"
        morphos-cross-sdk install "/cache/$sdk"
        morphos-cross-sdk status
        compile_both
        ok "the user's own command installs the SDK from a file, through the /usr/bin link, and the compiler works"
        ;;
    cached)
        # The download is in the cache: the maintainer script installs the SDK, then the package goes.
        mkdir -p /var/cache/morphos-cross
        cp "/cache/$sdk" /var/cache/morphos-cross/
        install_deb || fail "the installation failed"
        morphos-cross-sdk status || fail "the maintainer script did not install the SDK"
        [[ ! -e /var/cache/morphos-cross ]] || fail "the download cache stayed behind after a finished install"
        compile_both
        ok "a cached download makes the package ready to use right after the installation"
        apt-get install -y --no-install-recommends --reinstall /deb/morphos-cross_*.deb >/tmp/reinstall.log 2>&1 ||
            fail "reinstalling failed"
        morphos-cross-sdk status || fail "a reinstall lost the SDK"
        grep -q 'already installed' /tmp/reinstall.log || fail "a reinstall fetched the installed SDK again"
        ok "a reinstall keeps the SDK and does not fetch it again"
        apt-get remove -y morphos-cross >/dev/null 2>&1 || fail "removing failed"
        [[ ! -e /usr/bin/ppc-morphos-gcc && ! -e $tree/os-include ]] || fail "SDK files or links stayed after remove"
        leftover=$({ find "$tree" -type f 2>/dev/null || true; } | head -5 | tr '\n' ' ')
        [[ -z $leftover ]] || fail "files stayed after remove: $leftover"
        apt-get purge -y morphos-cross >/dev/null 2>&1 || fail "purging failed"
        [[ ! -e /var/cache/morphos-cross ]] || fail "the cache stayed after purge"
        ok "remove takes the SDK files and the links, purge the cache"
        ;;
    skip)
        MORPHOS_CROSS_SKIP_SDK=1 install_deb || fail "the installation failed"
        grep -q 'Skipping the MorphOS SDK' /tmp/apt.log || fail "the skip switch was not honoured"
        morphos-cross-sdk status && fail "status claims an SDK although the step was skipped"
        ok "MORPHOS_CROSS_SKIP_SDK skips the SDK step"
        ;;
    *)
        fail "unknown scenario: $scenario"
        ;;
esac
