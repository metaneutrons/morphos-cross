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

# --- tools/check-empty-arrays.sh ----------------------------------------------------------------
# shellcheck disable=SC2016  # the script text is written out and runs later
printf '#!/usr/bin/env bash\nset -euo pipefail\nflags=()\nrun ${flags[@]+"${flags[@]}"}\nnonempty=(a)\nrun "${nonempty[@]}"\n' > "$tmp/array-ok.sh"
# shellcheck disable=SC2016  # the script text is written out and runs later
printf '#!/usr/bin/env bash\nset -euo pipefail\nflags=()\nrun "${flags[@]}"\n' > "$tmp/array-bad.sh"
expect_pass "empty arrays: the guarded form and a non-empty array pass" "$root/tools/check-empty-arrays.sh" "$tmp/array-ok.sh"
expect_fail "empty arrays: an unguarded expansion is rejected" "expands the possibly empty array flags" "$root/tools/check-empty-arrays.sh" "$tmp/array-bad.sh"
expect_pass "empty arrays: every tracked script is clean" "$root/tools/check-empty-arrays.sh"
# The failure itself, where the system bash is the old one.
if [[ $(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"') -lt 4 ]]; then
    expect_fail "empty arrays: bash 3 really rejects the unguarded form" "unbound variable" /bin/bash "$tmp/array-bad.sh"
    # shellcheck disable=SC2016  # the snippet runs in the other shell
    expect_pass "empty arrays: bash 3 accepts the guarded form" /bin/bash -c 'set -euo pipefail; flags=(); echo ${flags[@]+"${flags[@]}"}'
fi

# --- the sysroot must be given with a trailing slash ---------------------------------------------
# Without it GCC computes the relocated sysroot from the name of the install folder (see build.sh).
# GCC's configure strips one trailing slash, so GCC gets two; binutils gets one.
# shellcheck disable=SC2016  # the patterns are literal text of the script under test
gcc_slashes=$(grep -c -F -e '--with-sysroot="$stage//"' "$root/scripts/build.sh" || true)
# shellcheck disable=SC2016  # literal text of the script under test
binutils_slashes=$(grep -c -F -e '--prefix="$stage" --with-sysroot="$stage/"' "$root/scripts/build.sh" || true)
# shellcheck disable=SC2016  # literal text of the script under test
bare=$(grep -c -F -e '--with-sysroot="$stage"' "$root/scripts/build.sh" || true)
# shellcheck disable=SC2016  # literal text of the script under test
build_sysroot=$(grep -c -F -e '--with-build-sysroot="$stage"' "$root/scripts/build.sh" || true)
if [[ $gcc_slashes -eq 1 && $binutils_slashes -eq 1 && $bare -eq 0 && $build_sysroot -eq 1 ]]; then
    pass "sysroot: GCC has two trailing slashes and an explicit build sysroot, binutils one slash"
else
    fail "sysroot: expected GCC with // and a build sysroot, binutils with / and none bare (found $gcc_slashes, $binutils_slashes, $bare, $build_sysroot)"
fi

# --- tools/plan-ci.sh ---------------------------------------------------------------------------
# What the builds may skip, and the counter-probes that must not be skipped.
plan() { printf '%s\n' "$@" | "$root/tools/plan-ci.sh" 2>/dev/null; }
expect_plan() {
    local name=$1 want=$2 got
    shift 2
    got=$(plan "$@")
    if [[ $got == "build=$want" ]]; then pass "plan: $name"; else fail "plan: $name (wanted build=$want, got '$got')"; fi
}
expect_plan "the README alone skips the builds" false README.md
expect_plan "documentation and its image skip the builds" false README.md docs/images/overview.svg
expect_plan "repository tooling and its gates skip the builds" false tools/check-no-binaries.sh tests/gates.sh tests/install.sh
expect_plan "the installer is checked elsewhere" false install.sh
expect_plan "the release and Dependabot workflows skip the builds" false .github/workflows/release.yml .github/workflows/dependabot-auto-merge.yml .github/dependabot.yml
expect_plan "a build script selects the builds" true scripts/build.sh
expect_plan "a change mixed with documentation selects the builds" true README.md scripts/package.sh docs/images/overview.svg
expect_plan "a patch selects the builds" true patches/20260529/gcc/0001-relocatable-specs.diff
expect_plan "the pins select the builds" true pins.env
expect_plan "the build container selects the builds" true docker/linux.Dockerfile
expect_plan "the smoke sources select the builds" true tests/smoke/hello.c
expect_plan "the CI workflow itself selects the builds" true .github/workflows/ci.yml
expect_plan "the archived licence texts select the builds" true LICENSE THIRD-PARTY.md
expect_plan "an unknown path selects the builds" true src/new-file.c
expect_plan "a hidden file selects the builds" true .gitignore
expect_plan "an empty change list selects the builds" true
expect_plan "a path with a quoted special character selects the builds" true '"docs/\303\244.md"'
# Whatever the build scripts, the patches, the container, the smoke tests and the pins consist of
# must never skip the builds: this keeps the list of skips from growing over a file the builds read.
unplanned=$(git -C "$root" ls-files | grep -E '^(scripts/[^/]+$|patches/|docker/|tests/smoke/|pins\.env$)' | while read -r f; do
    [[ $(plan "$f") == "build=true" ]] || printf '%s ' "$f"
done)
if [[ -z $unplanned ]]; then pass "plan: every build input selects the builds"
else fail "plan: build inputs that skip the builds: $unplanned"; fi

# --- tools/check-ci-results.sh ------------------------------------------------------------------
needs() { # HYGIENE BUILD PLAN_RESULT PLAN_BUILD
    printf '{"commit-hygiene":{"result":"%s"},"quality":{"result":"success"},"patches":{"result":"success"},"plan":{"result":"%s","outputs":{"build":"%s"}},"build":{"result":"%s"}}' \
        "$1" "$3" "$4" "$2"
}
ci_results() { NEEDS=$(needs "$@") "$root/tools/check-ci-results.sh"; }
expect_pass "CI results: every job succeeded" ci_results success success success true
expect_pass "CI results: a push skips commit hygiene" ci_results skipped success success true
expect_pass "CI results: a skipped build passes when the planner said false" ci_results success skipped success false
expect_fail "CI results: a skipped build fails when the planner said true" "." ci_results success skipped success true
expect_fail "CI results: a failed build fails" "." ci_results success failure success true
expect_fail "CI results: a failed build fails even when the planner said false" "." ci_results success failure success false
expect_fail "CI results: a failed planner fails" "." ci_results success skipped failure false
expect_fail "CI results: a skipped planner fails" "." ci_results success success skipped ""
expect_fail "CI results: a skipped build without a verdict fails" "." env NEEDS='{"commit-hygiene":{"result":"success"},"quality":{"result":"success"},"patches":{"result":"success"},"plan":{"result":"success"},"build":{"result":"skipped"}}' "$root/tools/check-ci-results.sh"
expect_fail "CI results: a missing job fails" "." env NEEDS='{"commit-hygiene":{"result":"success"},"quality":{"result":"success"},"patches":{"result":"success"},"build":{"result":"success"}}' "$root/tools/check-ci-results.sh"

# --- scripts/package-deb.sh ---------------------------------------------------------------------
# The package of a fake toolchain tree: its fields, links and scripts, its determinism, and the archives
# it must refuse. dpkg-deb and ar are Debian tools: without them (a Mac) the probes are skipped, and the
# CI quality job runs them.
if command -v dpkg-deb >/dev/null 2>&1 && command -v ar >/dev/null 2>&1; then
    deb_work=$tmp/deb
    mkdir -p "$deb_work/tree/morphos-cross/bin" "$deb_work/tree/morphos-cross/share/doc/morphos-cross"
    printf '#!/bin/sh\n' > "$deb_work/tree/morphos-cross/bin/ppc-morphos-gcc"
    printf '#!/bin/sh\n' > "$deb_work/tree/morphos-cross/bin/morphos-cross-sdk"
    printf 'licence\n' > "$deb_work/tree/morphos-cross/share/doc/morphos-cross/LICENSE"
    chmod +x "$deb_work/tree/morphos-cross/bin/"*
    fake_archive=$deb_work/morphos-cross-20000101-r1-linux-x86_64.tar.xz
    tar -C "$deb_work/tree" -cJf "$fake_archive" morphos-cross
    export SOURCE_DATE_EPOCH=946684800
    expect_pass "deb: a Linux archive becomes a package" "$root/scripts/package-deb.sh" "$fake_archive" "$deb_work/out1"
    deb=$deb_work/out1/morphos-cross_20000101-r1_amd64.deb
    if [[ -f $deb && $(dpkg-deb --field "$deb" Package) == morphos-cross && $(dpkg-deb --field "$deb" Version) == 20000101-r1 &&
          $(dpkg-deb --field "$deb" Architecture) == amd64 && $(dpkg-deb --field "$deb" Depends) == "libc6 (>= 2.36)" ]]; then
        pass "deb: canonical file name, package, version, architecture and the glibc baseline"
    else fail "deb: the fields or the file name are wrong"; fi
    contents=$(dpkg-deb --contents "$deb")
    if grep -q 'usr/bin/ppc-morphos-gcc -> ../lib/morphos-cross/bin/ppc-morphos-gcc' <<<"$contents" &&
       grep -q 'usr/bin/morphos-cross-sdk -> ../lib/morphos-cross/bin/morphos-cross-sdk' <<<"$contents" &&
       grep -q 'usr/share/doc/morphos-cross/copyright' <<<"$contents" && ! grep -q 'os-include/' <<<"$contents"; then
        pass "deb: the tools are linked into /usr/bin, the copyright is there and no SDK file is"
    else fail "deb: unexpected contents"; fi
    scripts_in_deb=$(dpkg-deb --ctrl-tarfile "$deb" | tar -t | sed 's|^\./||' | grep -v '^$' | sort | tr '\n' ' ')
    if [[ $scripts_in_deb == "control postinst postrm prerm " ]]; then pass "deb: the maintainer scripts are in the package"
    else fail "deb: the control member holds [$scripts_in_deb]"; fi
    "$root/scripts/package-deb.sh" "$fake_archive" "$deb_work/out2" >/dev/null
    if cmp -s "$deb" "$deb_work/out2/morphos-cross_20000101-r1_amd64.deb"; then pass "deb: building twice gives the same bytes"
    else fail "deb: two builds differ"; fi
    members=$(ar t "$deb" | tr '\n' ' ')
    if [[ $members == "debian-binary control.tar.gz data.tar.xz " ]]; then pass "deb: the control member is gzip, the data member xz"
    else fail "deb: members are [$members]"; fi
    mkdir -p "$deb_work/sdktree/morphos-cross/os-include" "$deb_work/sdk"
    cp -R "$deb_work/tree/morphos-cross/bin" "$deb_work/sdktree/morphos-cross/"
    tar -C "$deb_work/sdktree" -cJf "$deb_work/sdk/morphos-cross-20000101-r1-linux-x86_64.tar.xz" morphos-cross
    expect_fail "deb: an archive that contains the SDK is refused" "contains the MorphOS SDK" \
        "$root/scripts/package-deb.sh" "$deb_work/sdk/morphos-cross-20000101-r1-linux-x86_64.tar.xz" "$deb_work/out3"
    cp "$fake_archive" "$deb_work/morphos-cross-20000101-r1-macos-arm64.tar.xz"
    expect_fail "deb: the archive of a Mac has no package" "not the archive of a Linux host" \
        "$root/scripts/package-deb.sh" "$deb_work/morphos-cross-20000101-r1-macos-arm64.tar.xz" "$deb_work/out4"
    unset SOURCE_DATE_EPOCH
else
    printf 'skip: dpkg-deb and ar are not installed; the package probes run in the CI quality job\n'
fi
glibc_deb=$(sed -n 's/^glibc_min=//p' "$root/scripts/package-deb.sh")
# shellcheck disable=SC2016  # the pattern is literal text of the script under test
glibc_linkage=$(sed -n 's/^max_glibc=\${MAX_GLIBC:-\(.*\)}$/\1/p' "$root/scripts/check-linkage.sh")
if [[ -n $glibc_deb && $glibc_deb == "$glibc_linkage" ]]; then pass "deb: the Depends baseline is the glibc baseline of the linkage check ($glibc_deb)"
else fail "deb: glibc baseline [$glibc_deb] differs from the linkage check [$glibc_linkage]"; fi

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
needed=$(grep -E 'keys ==' "$root/tools/check-ci-results.sh" | grep -oE '"[a-z-]+"' | tr -d '"' | sort | tr '\n' ' ')
if [[ $ci_jobs == "$needed" ]]; then pass "CI: the result check demands exactly the jobs of ci.yml"
else fail "CI: ci.yml has [$ci_jobs] but check-ci-results.sh demands [$needed]"; fi
waited_for=$(sed -nE 's/^    needs: \[(commit-hygiene.*)\]$/\1/p' "$root/.github/workflows/ci.yml" | tr -d ' ' | tr ',' '\n' | sort | tr '\n' ' ')
if [[ $ci_jobs == "$waited_for" ]]; then pass "CI: CI Success waits for exactly the jobs of ci.yml"
else fail "CI: ci.yml has [$ci_jobs] but CI Success waits for [$waited_for]"; fi
if grep -qF "if: needs.plan.outputs.build == 'true'" "$root/.github/workflows/ci.yml"; then pass "CI: the builds run on the planner's verdict"
else fail "CI: the builds do not depend on the planner's verdict"; fi

if grep -qE '^    paths: \[pins\.env\]$' "$root/.github/workflows/release.yml"; then pass "release: the push trigger is limited to pins.env"
else fail "release: the push trigger is not limited to pins.env"; fi

# The channels: Homebrew and AUR before the promotion, APT after it (the archive reads stable releases only),
# each skipped when unconfigured.
release=$root/.github/workflows/release.yml
if grep -qF 'needs: [identity, stage, homebrew, aur]' "$release"; then pass "release: the promotion waits for Homebrew and AUR"
else fail "release: the promotion does not wait for Homebrew and AUR"; fi
if awk '/^  apt:$/ { in_apt = 1; next } in_apt && /^  [a-z-]+:$/ { in_apt = 0 } in_apt && /needs: \[identity, channels, promote\]/ { found = 1 } END { exit !found }' "$release"; then
    pass "release: APT is asked after the promotion"
else fail "release: APT is not asked after the promotion"; fi
for channel in homebrew aur apt; do
    if grep -qF "needs.channels.outputs.$channel == 'true'" "$release"; then pass "release: the $channel channel is skipped when unconfigured"
    else fail "release: the $channel channel does not depend on the preflight"; fi
done

[[ $failures -eq 0 ]] || { printf '%s gate probe(s) failed\n' "$failures" >&2; exit 1; }
printf 'All gate probes passed.\n'
