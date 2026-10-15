#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Decide from the changed paths (one per line on stdin) whether the toolchain builds have to run.
# Prints build=true or build=false for $GITHUB_OUTPUT and the verdict for every path on stderr.
# Only paths that cannot change the toolchain, its archive or its tests may skip the builds. Every
# other path, an empty list and anything unforeseen select the full scope.
set -euo pipefail

skips_build() {
    case $1 in
        README.md | CONTRIBUTING.md | SECURITY.md | docs/*) return 0 ;;
        # Checked by the quality job (tests/install.sh) and, on the exact candidate, by the clean-room test.
        install.sh) return 0 ;;
        tools/* | tests/gates.sh | tests/install.sh | tests/release_tools.py) return 0 ;;
        Makefile | lefthook.yml | scripts/hooks/*) return 0 ;;
        .github/CODEOWNERS | .github/dependabot.yml | .github/pull_request_template.md) return 0 ;;
        .github/ISSUE_TEMPLATE/*) return 0 ;;
        .github/workflows/release.yml | .github/workflows/dependabot-auto-merge.yml) return 0 ;;
    esac
    return 1
}

count=0
full=0
while IFS= read -r path || [[ -n $path ]]; do
    [[ -n $path ]] || continue
    count=$((count + 1))
    if skips_build "$path"; then
        printf 'no build   %s\n' "$path" >&2
    else
        printf 'build      %s\n' "$path" >&2
        full=1
    fi
done

if [[ $count -eq 0 ]]; then
    printf 'No changed path was given; selecting the full scope.\n' >&2
    full=1
fi

if [[ $full -eq 1 ]]; then printf 'build=true\n'; else printf 'build=false\n'; fi
