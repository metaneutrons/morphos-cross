#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if ! command -v file >/dev/null 2>&1; then
    printf 'ERROR: the file utility is required for the repository asset audit.\n' >&2
    exit 2
fi

status=0

check_file() {
    local path="$1"
    local mime encoding

    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        printf 'ERROR: tracked path is missing: %s\n' "$path" >&2
        status=1
        return
    fi

    mime="$(file --brief --mime-type -- "$path")"
    mime="${mime%%$'\n'*}"
    case "$mime" in
        application/x-empty|inode/x-empty|inode/symlink) return ;;
    esac
    # Soft magic can mistake source text at a fixed offset for a ROM, or label
    # a binary-padded shebang as text. Classify bytes independently of that magic.
    encoding="$(file --brief --mime-encoding --exclude=soft -- "$path")"
    case "$encoding" in
        us-ascii|utf-8) return ;;
    esac
    printf 'ERROR: tracked binary artifact: %s (%s, %s)\n' "$path" "$mime" "$encoding" >&2
    status=1
}

if [ "$#" -gt 0 ]; then
    for path in "$@"; do
        check_file "$path"
    done
else
    while IFS= read -r -d '' path; do
        check_file "$path"
    done < <(git ls-files -z)
fi

if [ "$status" -ne 0 ]; then
    printf 'Tracked binaries are forbidden; build or download them at run time.\n' >&2
    exit "$status"
fi

printf 'Repository asset audit passed: no tracked binaries.\n'
