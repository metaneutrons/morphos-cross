#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Probes of morphos-cross-sdk and the scripts it calls, against a fake SDK archive that is served from
# a file URL: install, status, removal, symbolic links, and every way the download can go wrong.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0
cache=$tmp/cache

pass() { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

for tool in bsdtar xz python3 curl; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'FAIL: %s is required for the SDK helper probes\n' "$tool" >&2; exit 1; }
done

# A fake SDK archive with the layout of the real one: an lha (here a zip, which bsdtar reads by its
# content) holding morphossdk/sdk.pack, an xz-compressed tar whose Development/gg has the four
# directories the helper installs. "good" has the marker file os-include/exec/types.h, "bad" lacks it.
make_sdk() { # NAME good|bad
    local name=$1 kind=$2 d=$tmp/build-$1 gg
    gg=$d/Development/gg
    rm -rf "$d"
    mkdir -p "$gg/include/proto" "$gg/includestd" "$gg/ppc-morphos/lib/ldscripts" "$gg/os-include/exec" "$d/morphossdk"
    printf 'header\n' > "$gg/include/proto/exec.h"
    printf 'std\n' > "$gg/includestd/string.h"
    printf 'lib\n' > "$gg/ppc-morphos/lib/libc.a"
    printf 'script\n' > "$gg/ppc-morphos/lib/ldscripts/morphos.x"
    [[ $kind == good ]] && printf 'types\n' > "$gg/os-include/exec/types.h"
    (cd "$d" && tar -cf - Development | xz -c > morphossdk/sdk.pack)
    python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "w").write(sys.argv[2], "morphossdk/sdk.pack")' \
        "$tmp/$name.lha" "$d/morphossdk/sdk.pack"
}

# A toolchain tree with files of its own, which removal must never touch.
write_pins() { # TREE URL SHA256
    printf 'SDK_VERSION=9.9\nSDK_DATE=20000101\nSDK_URL=%s\nSDK_SHA256=%s\n' "$2" "$3" > "$1/share/morphos-cross/pins.env"
}
make_tree() { # TREE URL SHA256
    local t=$1
    rm -rf "$t"
    mkdir -p "$t/bin" "$t/share/morphos-cross/scripts" "$t/ppc-morphos/bin" "$t/lib/gcc-lib"
    cp "$root/scripts/morphos-cross-sdk" "$t/bin/"
    cp "$root/scripts/fetch.sh" "$root/scripts/install-sdk.sh" "$t/share/morphos-cross/scripts/"
    printf 'owned\n' > "$t/ppc-morphos/bin/ld"
    printf 'owned\n' > "$t/lib/gcc-lib/cc1"
    write_pins "$t" "$2" "$3"
}
sdk() { MORPHOS_CROSS_CACHE=$cache "$tree/bin/morphos-cross-sdk" "$@"; }
no_sdk_files() { [[ ! -e $1/include && ! -e $1/includestd && ! -e $1/os-include && ! -e $1/share/morphos-cross/sdk-installed ]]; }

make_sdk sdk-good good
make_sdk sdk-bad bad
good_sum=$(sha256_of "$tmp/sdk-good.lha")
bad_sum=$(sha256_of "$tmp/sdk-bad.lha")
tree=$tmp/tree
make_tree "$tree" "file://$tmp/sdk-good.lha" "$good_sum"

# 1 status before an install
if out=$(sdk status 2>&1); then fail "status succeeded before an install"
elif grep -q "not installed" <<<"$out"; then pass "status: reports a missing SDK with exit 1"
else fail "status: unexpected message: $out"; fi

# 2 install from the pinned URL
expected=$'include\ninclude/proto\ninclude/proto/exec.h\nincludestd\nincludestd/string.h\nos-include\nos-include/exec\nos-include/exec/types.h\nppc-morphos\nppc-morphos/lib\nppc-morphos/lib/libc.a'
if sdk install >/dev/null 2>&1 &&
   [[ -f $tree/include/proto/exec.h && -f $tree/os-include/exec/types.h && -f $tree/ppc-morphos/lib/libc.a ]] &&
   [[ ! -e $tree/ppc-morphos/lib/ldscripts ]] &&
   [[ $(cat "$tree/share/morphos-cross/sdk-files.list") == "$expected" ]] &&
   grep -qx "SDK_SHA256=$good_sum" "$tree/share/morphos-cross/sdk-installed"; then
    pass "install: unpacks the SDK without ldscripts, lists files and directories and records the checksum"
else fail "install: the result is wrong"; fi
if sdk status >/dev/null 2>&1; then pass "status: reports the pinned SDK"; else fail "status: does not report the pinned SDK"; fi

# 3 the second install fetches nothing
write_pins "$tree" "file://$tmp/does-not-exist.lha" "$good_sum"
if out=$(sdk install 2>&1) && grep -q "already installed" <<<"$out"; then pass "install: an installed pinned SDK is not fetched again"
else fail "install: tried to fetch an SDK that is installed: $out"; fi

# 4 the helper finds its tree through symbolic links, absolute and relative
mkdir -p "$tmp/lnk" "$tmp/lnk2"
ln -s "$tree/bin/morphos-cross-sdk" "$tmp/lnk/morphos-cross-sdk"
ln -s ../lnk/morphos-cross-sdk "$tmp/lnk2/sdk"
for link in "$tmp/lnk/morphos-cross-sdk" "$tmp/lnk2/sdk"; do
    if out=$(MORPHOS_CROSS_CACHE=$cache "$link" status 2>&1) && grep -qF "$tree" <<<"$out"; then
        pass "symbolic link: ${link#"$tmp"/} finds the toolchain tree"
    else fail "symbolic link: ${link#"$tmp"/} does not: $out"; fi
done

# 5 an SDK that is not the pinned one is reported
write_pins "$tree" "file://$tmp/sdk-good.lha" "$(printf '0%.0s' $(seq 64))"
if out=$(sdk status 2>&1); then fail "status: an SDK that is not the pinned one passed"
elif grep -q "not the pinned one" <<<"$out"; then pass "status: an installed SDK that differs from the pin is reported with exit 1"
else fail "status: unexpected message: $out"; fi
write_pins "$tree" "file://$tmp/sdk-good.lha" "$good_sum"

# 6 removal takes the SDK and nothing else
if sdk remove >/dev/null 2>&1 && no_sdk_files "$tree" && [[ ! -e $tree/share/morphos-cross/sdk-files.list ]] &&
   [[ ! -e $tree/ppc-morphos/lib && -f $tree/ppc-morphos/bin/ld && -f $tree/lib/gcc-lib/cc1 ]]; then
    pass "remove: deletes the SDK files and the directories it emptied, and leaves the toolchain's own"
else fail "remove: the tree is wrong afterwards"; fi
if sdk remove >/dev/null 2>&1; then pass "remove: a second removal succeeds"; else fail "remove: a second removal failed"; fi
if sdk status >/dev/null 2>&1; then fail "status: succeeds after removal"; else pass "status: reports a missing SDK after removal"; fi

# 7 files that the helper did not install are not removed on a guess
mkdir -p "$tree/os-include/exec"
printf 'foreign\n' > "$tree/os-include/exec/types.h"
if out=$(sdk remove 2>&1); then fail "remove: removed SDK files without a list"
elif [[ -f $tree/os-include/exec/types.h ]] && grep -q "did not install" <<<"$out"; then pass "remove: refuses SDK files it has no list of"
else fail "remove: unexpected result: $out"; fi
rm -rf "$tree/os-include"

# 8 a failed download: a warning and exit 0 with --best-effort, an error without it
write_pins "$tree" "file://$tmp/does-not-exist.lha" "$good_sum"
if out=$(sdk install --best-effort 2>&1) && grep -q "WARNING" <<<"$out" && grep -q "morphos-cross-sdk install" <<<"$out" &&
   no_sdk_files "$tree"; then
    pass "best-effort: a failed download warns, names the command and exits 0"
else fail "best-effort: a failed download is not handled: $out"; fi
if sdk install >/dev/null 2>&1; then fail "install: a failed download exited 0 without --best-effort"
else pass "install: a failed download exits non-zero without --best-effort"; fi

# 9 the skip switch fetches nothing
if out=$(MORPHOS_CROSS_SKIP_SDK=1 sdk install --best-effort 2>&1) && grep -q "Skipping" <<<"$out" && no_sdk_files "$tree"; then
    pass "best-effort: MORPHOS_CROSS_SKIP_SDK skips the step"
else fail "best-effort: the skip switch does not work: $out"; fi

# 10 a wrong checksum installs nothing
write_pins "$tree" "file://$tmp/sdk-good.lha" "$(printf '1%.0s' $(seq 64))"
rm -rf "$cache"
if out=$(sdk install 2>&1); then fail "install: a wrong checksum was accepted"
elif grep -q "checksum mismatch" <<<"$out" && no_sdk_files "$tree"; then pass "install: a wrong checksum fails and installs nothing"
else fail "install: unexpected result for a wrong checksum: $out"; fi
if sdk install --best-effort >/dev/null 2>&1 && no_sdk_files "$tree"; then pass "best-effort: a wrong checksum exits 0 and installs nothing"
else fail "best-effort: a wrong checksum is not handled"; fi

# 11 an archive that is not the SDK installs nothing
write_pins "$tree" "file://$tmp/sdk-bad.lha" "$bad_sum"
rm -rf "$cache"
if out=$(sdk install 2>&1); then fail "install: an archive without the SDK marker was accepted"
elif grep -q "nothing was installed" <<<"$out" && no_sdk_files "$tree" && [[ ! -e $tree/ppc-morphos/lib ]]; then
    pass "install: an archive without os-include/exec/types.h installs nothing"
else fail "install: unexpected result for a damaged archive: $out"; fi

# 12 an interrupted download is resumed, and a stale partial file is replaced
write_pins "$tree" "file://$tmp/sdk-good.lha" "$good_sum"
rm -rf "$cache"
mkdir -p "$cache"
size=$(wc -c < "$tmp/sdk-good.lha")
head -c $((size / 2)) "$tmp/sdk-good.lha" > "$cache/sdk-good.lha.part"
if sdk install >/dev/null 2>&1 && sdk status >/dev/null 2>&1; then pass "download: a partial file is completed"
else fail "download: a partial file was not completed"; fi
sdk remove >/dev/null 2>&1
rm -rf "$cache"
mkdir -p "$cache"
head -c $((size + 4096)) /dev/zero > "$cache/sdk-good.lha.part"
if sdk install >/dev/null 2>&1 && sdk status >/dev/null 2>&1; then pass "download: a stale partial file is replaced"
else fail "download: a stale partial file blocked the install"; fi

# 13 a failing network leaves the partial file for the next run
write_pins "$tree" "file://$tmp/missing/sdk-good.lha" "$good_sum"
rm -rf "$cache"
mkdir -p "$cache"
head -c 1000 "$tmp/sdk-good.lha" > "$cache/sdk-good.lha.part"
sdk install >/dev/null 2>&1 || true
if [[ -s $cache/sdk-good.lha.part ]]; then pass "download: a network failure keeps the partial file"
else fail "download: a network failure deleted the partial file"; fi

[[ $failures -eq 0 ]] || { printf '%s SDK helper probe(s) failed\n' "$failures" >&2; exit 1; }
printf 'SDK helper probes passed.\n'
