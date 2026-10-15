#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Positive probe and counter-probe for every gate of this repository, and the checks that keep
# two lists of the same thing from drifting apart.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

pass() { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# expect_pass NAME COMMAND...      the command must exit 0
# expect_fail NAME PATTERN COMMAND...   the command must exit non-zero and say PATTERN
expect_pass() {
    local name=$1
    shift
    if out=$("$@" 2>&1); then pass "$name"; else fail "$name: $out"; fi
}
expect_fail() {
    local name=$1 pattern=$2
    shift 2
    if out=$("$@" 2>&1); then fail "$name: the invalid input was accepted"
    elif grep -Eq "$pattern" <<<"$out"; then pass "$name"
    else fail "$name: failed for another reason: $out"; fi
}

# --- tools/check-actions-pinned.sh --------------------------------------------------------------
if command -v rg >/dev/null 2>&1; then
    mkdir -p "$tmp/wf-good" "$tmp/wf-tag" "$tmp/wf-nocomment"
    sha=0123456789abcdef0123456789abcdef01234567
    printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@%s # v7.0.1\n' "$sha" > "$tmp/wf-good/a.yml"
    printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v7\n' > "$tmp/wf-tag/a.yml"
    printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@%s\n' "$sha" > "$tmp/wf-nocomment/a.yml"
    expect_pass "actions pinned: a SHA pin with a version comment passes" "$root/tools/check-actions-pinned.sh" "$tmp/wf-good"
    expect_fail "actions pinned: a tag is rejected" "not pinned to a full commit SHA" "$root/tools/check-actions-pinned.sh" "$tmp/wf-tag"
    expect_fail "actions pinned: a pin without a version comment is rejected" "no version comment" "$root/tools/check-actions-pinned.sh" "$tmp/wf-nocomment"
else
    fail "ripgrep is required for the action pin gate"
fi

# --- tools/check-no-binaries.sh -----------------------------------------------------------------
printf 'plain text\n' > "$tmp/text.txt"
head -c 256 /dev/urandom > "$tmp/blob.bin"
expect_pass "no binaries: a text file passes" "$root/tools/check-no-binaries.sh" "$tmp/text.txt"
expect_fail "no binaries: a binary is rejected" "tracked binary artifact" "$root/tools/check-no-binaries.sh" "$tmp/blob.bin"

# --- tools/verify-sha256.sh ---------------------------------------------------------------------
digest=$(if command -v sha256sum >/dev/null; then sha256sum "$tmp/text.txt"; else shasum -a 256 "$tmp/text.txt"; fi | cut -d' ' -f1)
expect_pass "sha256: the right digest passes" "$root/tools/verify-sha256.sh" "$tmp/text.txt" "$digest"
expect_fail "sha256: a wrong digest is rejected" "mismatch" "$root/tools/verify-sha256.sh" "$tmp/text.txt" "$(printf '0%.0s' $(seq 64))"
expect_fail "sha256: a malformed digest is rejected" "lowercase 64-character" "$root/tools/verify-sha256.sh" "$tmp/text.txt" "nothex"

# --- scripts/hooks/check-commit-message.sh ------------------------------------------------------
msg() { printf '%s\n' "$1" > "$tmp/msg"; sh "$root/scripts/hooks/check-commit-message.sh" "$tmp/msg"; }
expect_pass "commit message: a Conventional Commit passes" msg "fix(build): link libstdc++ statically"
expect_fail "commit message: 'initial commit' is rejected" "Conventional Commits" msg "initial commit"
expect_fail "commit message: an unknown type is rejected" "Conventional Commits" msg "update: things"
expect_fail "commit message: an AI attribution trailer is rejected" "AI attribution" msg "$(printf 'fix: x\n\nCo-authored-by: Claude <noreply@anthropic.com>')"

# --- scripts/hooks/check-staged.sh --------------------------------------------------------------
repo=$tmp/repo
git init -q -b main "$repo"
(
    cd "$repo"
    git config user.email test@example.invalid
    git config user.name test
    printf 'x\n' > file.txt && git add file.txt
)
staged() { (cd "$repo" && sh "$root/scripts/hooks/check-staged.sh"); }
expect_fail "staged guard: a direct commit to main is rejected" "Direct commit to 'main'" staged
expect_pass "staged guard: the override allows it" env ALLOW_COMMIT_ON_DEFAULT=1 sh -c "cd '$repo' && sh '$root/scripts/hooks/check-staged.sh'"
(cd "$repo" && git checkout -q -b topic)
expect_pass "staged guard: a topic branch passes" staged
(cd "$repo" && head -c 2048 /dev/urandom > big.dat && git add big.dat)
expect_fail "staged guard: a blob over the limit is rejected" "is 2048 bytes" env MAX_STAGED_BYTES=1024 sh -c "cd '$repo' && sh '$root/scripts/hooks/check-staged.sh'"
(cd "$repo" && git rm -q --cached big.dat && mkdir -p dist && printf 'x\n' > dist/a.txt && git add -f dist/a.txt)
expect_fail "staged guard: a build directory is rejected" "build or dependency directory" staged

# --- scripts/check-linkage.sh -------------------------------------------------------------------
if command -v cc >/dev/null 2>&1 && command -v file >/dev/null 2>&1; then
    mkdir -p "$tmp/tree-ok" "$tmp/tree-bad" "$tmp/tree-minos" "$tmp/lib"
    printf '#include <stdio.h>\nint main(void){puts("x");return 0;}\n' > "$tmp/t.c"
    printf 'int dependency(void){return 1;}\n' > "$tmp/dep.c"
    printf 'int dependency(void);\nint main(void){return dependency();}\n' > "$tmp/use.c"
    if [[ $(uname -s) == Darwin ]]; then
        cc -mmacosx-version-min=13.0 -o "$tmp/tree-ok/prog" "$tmp/t.c"
        cc -dynamiclib -install_name /opt/homebrew/lib/libdep.dylib -o "$tmp/lib/libdep.dylib" "$tmp/dep.c"
        cc -mmacosx-version-min=13.0 -o "$tmp/tree-bad/prog" "$tmp/use.c" -L"$tmp/lib" -ldep
        cc -mmacosx-version-min=14.0 -o "$tmp/tree-minos/prog" "$tmp/t.c"
        expect_fail "linkage: a deployment target above the baseline is rejected" "requires macOS" "$root/scripts/check-linkage.sh" "$tmp/tree-minos"
        bad_pattern="links /opt/homebrew"
    else
        cc -o "$tmp/tree-ok/prog" "$tmp/t.c"
        cc -shared -fPIC -o "$tmp/lib/libdep.so" "$tmp/dep.c"
        cc -o "$tmp/tree-bad/prog" "$tmp/use.c" -L"$tmp/lib" -ldep -Wl,-rpath,"$tmp/lib"
        bad_pattern="needs libdep.so"
    fi
    expect_pass "linkage: a program with base libraries only passes" "$root/scripts/check-linkage.sh" "$tmp/tree-ok"
    expect_fail "linkage: a program that needs another library is rejected" "$bad_pattern" "$root/scripts/check-linkage.sh" "$tmp/tree-bad"
    mkdir -p "$tmp/tree-empty"
    expect_fail "linkage: a tree without host programs is rejected" "no host program found" "$root/scripts/check-linkage.sh" "$tmp/tree-empty"
else
    fail "cc and file are required for the linkage probes"
fi

# --- lists that must agree ----------------------------------------------------------------------
# shellcheck source=../pins.env
. "$root/pins.env"
if [[ $VERSION =~ ^[0-9]{8}-r[1-9][0-9]*$ ]]; then pass "pins.env: VERSION has the form YYYYMMDD-rN ($VERSION)"
else fail "pins.env: VERSION '$VERSION' is malformed"; fi
if [[ $VERSION == "${SDK_DATE}-r${REVISION}" ]]; then pass "pins.env: VERSION is derived from SDK_DATE and REVISION"
else fail "pins.env: VERSION differs from SDK_DATE and REVISION"; fi

workflow_hosts() { grep -oE 'host: (linux|macos)-[a-z0-9_]+' "$1" | sed 's/host: //' | sort -u | tr '\n' ' '; }
read -r -a host_list <<<"$HOSTS"
sorted_hosts=$(printf '%s\n' "${host_list[@]}" | sort -u | tr '\n' ' ')
for workflow in ci.yml release.yml; do
    listed=$(workflow_hosts "$root/.github/workflows/$workflow")
    if [[ $listed == "$sorted_hosts" ]]; then pass "hosts: $workflow builds exactly the hosts of pins.env"
    else fail "hosts: $workflow lists [$listed] but pins.env says [$sorted_hosts]"; fi
done
installer_hosts=$(grep -oE 'host=(linux-x86_64|linux-arm64|macos-arm64)' "$root/install.sh" | sort -u | sed 's/host=//' | tr '\n' ' ')
if [[ $installer_hosts == "$sorted_hosts" ]]; then pass "hosts: install.sh recognises exactly the hosts of pins.env"
else fail "hosts: install.sh recognises [$installer_hosts] but pins.env says [$sorted_hosts]"; fi

# The jobs the CI aggregate waits for are exactly the jobs the result check demands.
ci_jobs=$(awk '/^jobs:/ { in_jobs = 1; next } in_jobs && /^  [a-z-]+:$/ { sub(/:$/, "", $1); print $1 }' "$root/.github/workflows/ci.yml" | grep -v '^ci-success$' | sort | tr '\n' ' ')
needed=$(grep -oE '"[a-z-]+"' "$root/tools/check-ci-results.sh" | head -4 | tr -d '"' | sort | tr '\n' ' ')
if [[ $ci_jobs == "$needed" ]]; then pass "CI: the result check demands exactly the jobs of ci.yml"
else fail "CI: ci.yml has [$ci_jobs] but check-ci-results.sh demands [$needed]"; fi

if grep -qE '^    paths: \[pins\.env\]$' "$root/.github/workflows/release.yml"; then pass "release: the push trigger is limited to pins.env"
else fail "release: the push trigger is not limited to pins.env"; fi

[[ $failures -eq 0 ]] || { printf '%s gate probe(s) failed\n' "$failures" >&2; exit 1; }
printf 'All gate probes passed.\n'
