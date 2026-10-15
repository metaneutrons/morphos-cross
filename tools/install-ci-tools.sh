#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s):$(uname -m)" != Linux:x86_64 ]]; then
    printf 'ERROR: CI tool binaries are pinned only for Linux x86_64.\n' >&2
    exit 2
fi

destination=${1:-"${HOME}/.local/bin"}
mkdir -p "$destination"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

download() {
    local url=$1
    local output=$2
    local sha256=$3

    curl --fail --silent --show-error --location --retry 3 --output "$output" "$url"
    tools/verify-sha256.sh "$output" "$sha256"
}

lefthook_version=2.1.12
download \
    "https://github.com/evilmartians/lefthook/releases/download/v${lefthook_version}/lefthook_${lefthook_version}_Linux_x86_64.gz" \
    "$tmp/lefthook.gz" \
    dad908593c859d139b886c14913a44401d95288aa7642d9bdf6f3bd36bd788ff
gzip -dc "$tmp/lefthook.gz" > "$destination/lefthook"
chmod 0755 "$destination/lefthook"

actionlint_version=1.7.12
download \
    "https://github.com/rhysd/actionlint/releases/download/v${actionlint_version}/actionlint_${actionlint_version}_linux_amd64.tar.gz" \
    "$tmp/actionlint.tar.gz" \
    8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
tar -xzf "$tmp/actionlint.tar.gz" -C "$tmp" actionlint
install -m 0755 "$tmp/actionlint" "$destination/actionlint"

gitleaks_version=8.30.1
download \
    "https://github.com/gitleaks/gitleaks/releases/download/v${gitleaks_version}/gitleaks_${gitleaks_version}_linux_x64.tar.gz" \
    "$tmp/gitleaks.tar.gz" \
    551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
tar -xzf "$tmp/gitleaks.tar.gz" -C "$tmp" gitleaks
install -m 0755 "$tmp/gitleaks" "$destination/gitleaks"

"$destination/lefthook" version
"$destination/actionlint" -version
"$destination/gitleaks" version
