#!/usr/bin/env bash
set -euo pipefail

file=${1:?file is required}
expected=${2:?expected SHA-256 is required}

if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum -- "$file" | awk '{print $1}')
else
    actual=$(shasum -a 256 -- "$file" | awk '{print $1}')
fi

if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'ERROR: expected SHA-256 is not a lowercase 64-character digest.\n' >&2
    exit 2
fi

if [[ "$actual" != "$expected" ]]; then
    printf 'ERROR: SHA-256 mismatch for %s.\n' "$file" >&2
    printf 'Expected: %s\nActual:   %s\n' "$expected" "$actual" >&2
    exit 1
fi

printf 'Verified SHA-256: %s\n' "$file"
