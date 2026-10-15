#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Probes of install.sh against a fake release directory: a good install, the SDK step, a tampered
# archive, a missing checksum entry, an unsupported host and the signature paths.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
host=$("$root/scripts/host-id.sh")
tag=v20000101-r1
asset=morphos-cross-${tag#v}-$host.tar.xz
rel=$tmp/rel/$tag
failures=0

pass() { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

make_release() {
    rm -rf "$tmp/rel" "$tmp/pkg"
    mkdir -p "$rel" "$tmp/pkg/morphos-cross/bin"
    printf '#!/bin/sh\necho ppc-morphos-gcc\n' > "$tmp/pkg/morphos-cross/bin/ppc-morphos-gcc"
    # shellcheck disable=SC2016  # the script text is written out and runs later
    printf '#!/bin/sh\ntouch "$(dirname "$0")/../SDK_INSTALLED"\n' > "$tmp/pkg/morphos-cross/bin/morphos-cross-sdk"
    chmod +x "$tmp/pkg/morphos-cross/bin/"*
    tar -C "$tmp/pkg" -cJf "$rel/$asset" morphos-cross
    printf '%s  %s\n' "$(sha256_of "$rel/$asset")" "$asset" > "$rel/SHA256SUMS"
    printf '{}\n' > "$rel/$asset.sigstore.json"
}

run_install() { # PREFIX [args]; extra environment is passed through
    local prefix=$1
    shift
    MORPHOS_CROSS_BASE_URL=file://$tmp/rel sh "$root/install.sh" --version "$tag" --prefix "$prefix" "$@"
}

# A fake cosign that records its arguments and succeeds or fails on request.
mkdir -p "$tmp/bin-ok" "$tmp/bin-bad"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s/cosign.args"\nexit 0\n' "$tmp" > "$tmp/bin-ok/cosign"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin-bad/cosign"
chmod +x "$tmp/bin-ok/cosign" "$tmp/bin-bad/cosign"
no_cosign_path=$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do [[ -x $d/cosign ]] || printf '%s:' "$d"; done)
no_cosign_path=${no_cosign_path%:}

# 1 a good install, with the SDK step
make_release
if PATH="$no_cosign_path" run_install "$tmp/p1" >/dev/null 2>&1 &&
   [[ -x $tmp/p1/$tag/bin/ppc-morphos-gcc && -L $tmp/p1/current && -f $tmp/p1/$tag/SDK_INSTALLED ]]; then
    pass "good install: files, current link, SDK step"
else
    fail "good install"
fi

# 2 --no-sdk leaves the SDK alone
if PATH="$no_cosign_path" run_install "$tmp/p2" --no-sdk >/dev/null 2>&1 && [[ ! -e $tmp/p2/$tag/SDK_INSTALLED ]]; then
    pass "--no-sdk skips the SDK step"
else
    fail "--no-sdk"
fi

# 3 a tampered archive is rejected and nothing is installed
make_release
printf 'x' >> "$rel/$asset"
if out=$(PATH="$no_cosign_path" run_install "$tmp/p3" 2>&1); then
    fail "tampered archive was accepted"
elif grep -q 'checksum mismatch' <<<"$out" && [[ ! -e $tmp/p3/$tag ]]; then
    pass "tampered archive: checksum mismatch, nothing installed"
else
    fail "tampered archive failed for the wrong reason: $out"
fi

# 4 an archive that SHA256SUMS does not list
make_release
: > "$rel/SHA256SUMS"
if out=$(PATH="$no_cosign_path" run_install "$tmp/p4" 2>&1); then fail "unlisted asset accepted"
elif grep -q 'not listed in SHA256SUMS' <<<"$out"; then pass "asset missing from SHA256SUMS is rejected"
else fail "unlisted asset failed for the wrong reason: $out"; fi

# 5 an unsupported host
make_release
if out=$(PATH="$no_cosign_path" MORPHOS_CROSS_HOST=freebsd-amd64 run_install "$tmp/p5" 2>&1); then fail "unsupported host accepted"
elif grep -q 'unsupported host' <<<"$out"; then pass "unsupported host is rejected"
else fail "unsupported host failed for the wrong reason: $out"; fi

# 6 signature paths: verified, failed, required but missing, optional and missing
make_release
if PATH="$tmp/bin-ok:$PATH" run_install "$tmp/p6a" --no-sdk >/dev/null 2>&1 &&
   grep -q 'verify-blob' "$tmp/cosign.args" && grep -q -- '--certificate-identity-regexp' "$tmp/cosign.args" &&
   grep -q "metaneutrons/morphos-cross" "$tmp/cosign.args" && grep -q -- '--bundle' "$tmp/cosign.args"; then
    pass "cosign is called with bundle, issuer and workflow identity"
else
    fail "cosign call"
fi
if PATH="$tmp/bin-bad:$PATH" run_install "$tmp/p6b" --no-sdk >/dev/null 2>&1; then fail "failed signature accepted"
elif [[ ! -e $tmp/p6b/$tag ]]; then pass "a failing signature stops the install"
else fail "failed signature left files behind"; fi
if PATH="$no_cosign_path" run_install "$tmp/p6c" --no-sdk --require-signature >/dev/null 2>&1; then fail "--require-signature without cosign accepted"
else pass "--require-signature without cosign stops"; fi
if PATH="$no_cosign_path" run_install "$tmp/p6d" --no-sdk >/dev/null 2>&1; then pass "without cosign the install proceeds with a note"
else fail "install without cosign"; fi

# 7 a release tag in the wrong format
if sh "$root/install.sh" --version latest --prefix "$tmp/p7" >/dev/null 2>&1; then fail "bad tag accepted"
else pass "a malformed release tag is rejected"; fi

[[ $failures -eq 0 ]] || { printf '%s install probe(s) failed\n' "$failures" >&2; exit 1; }
printf 'install.sh probes passed.\n'
