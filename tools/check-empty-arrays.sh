#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# macOS ships bash 3.2, where expanding an empty array as "${name[@]}" under set -u fails with
# "unbound variable". A script that works in the newer bash from Homebrew then breaks on a
# machine that only has the system shell (a GitHub macOS runner, for one). This gate finds the
# unguarded expansions of arrays that a script declares empty; write ${name[@]+"${name[@]}"}.
# Usage: tools/check-empty-arrays.sh [FILE...]   (default: every tracked shell script)
# shellcheck disable=SC2016  # the messages quote shell syntax
set -euo pipefail

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
    while IFS= read -r file; do files+=("$file"); done < <(git ls-files '*.sh' scripts/morphos-cross-sdk)
fi

status=0
for file in "${files[@]}"; do
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        # An expansion counts as guarded when the quote is preceded by "+", as in ${name[@]+"${name[@]}"}.
        if grep -nE "(^|[^+])\"\\$\{$name\[@\]\}\"" "$file" > /dev/null; then
            printf 'ERROR: %s expands the possibly empty array %s unguarded; use ${%s[@]+"${%s[@]}"}\n' \
                "$file" "$name" "$name" "$name" >&2
            status=1
        fi
    done < <(grep -oE '^[[:space:]]*[a-z_]+=\(\)' "$file" | sed -E 's/^[[:space:]]*//; s/=\(\)//' | sort -u)
done
[[ $status -eq 0 ]] || exit 1
printf 'No unguarded expansion of an empty array in %s files.\n' "${#files[@]}"
