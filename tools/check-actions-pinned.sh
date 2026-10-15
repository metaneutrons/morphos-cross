#!/usr/bin/env bash
set -euo pipefail

workflow_dir=${1:-.github/workflows}
status=0
[[ -d "$workflow_dir" ]] || { printf 'ERROR: workflow directory is missing.\n' >&2; exit 2; }
command -v rg >/dev/null || { printf 'ERROR: ripgrep is required.\n' >&2; exit 2; }
matches=$(mktemp)
trap 'rm -f "$matches"' EXIT
if rg --no-heading --line-number '^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*' "$workflow_dir" > "$matches"; then
    :
else
    rc=$?
    [[ "$rc" -eq 1 ]] || exit "$rc"
fi

while IFS=: read -r file line content; do
    spec=$(sed -E 's/.*uses:[[:space:]]*([^[:space:]#]+).*/\1/' <<<"$content")
    case "$spec" in
        ./*) continue ;;
    esac

    ref=${spec##*@}
    if [[ "$spec" != *@* ]] || [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'ERROR: %s:%s action is not pinned to a full commit SHA: %s\n' \
            "$file" "$line" "$spec" >&2
        status=1
    fi
    if ! grep -Eq '#[[:space:]]*v?[0-9]' <<<"$content"; then
        printf 'ERROR: %s:%s action pin has no version comment.\n' "$file" "$line" >&2
        status=1
    fi
done < "$matches"

exit "$status"
