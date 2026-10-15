#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Read-only checks before the release pipeline changes anything public: the repository identity,
# write access, the state of the release and the tag. Changes nothing.
# Usage: tools/release/preflight.sh TAG   (needs GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA)
set -euo pipefail

tag=${1:?release tag is required}
repository=${GITHUB_REPOSITORY:?}
sha=${GITHUB_SHA:?}
token=${GH_TOKEN:?}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $repository == metaneutrons/morphos-cross ]] || fail "unexpected repository identity: $repository"
[[ $tag =~ ^v[0-9]{8}-r[1-9][0-9]*$ ]] || fail "invalid release tag: $tag"
[[ $(gh api "repos/$repository" --jq .archived) == false ]] || fail "the repository is archived"

# Write access to contents: the receive-pack advertisement is a GET that changes nothing.
credential=$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')
status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --header "Authorization: Basic $credential" \
    "https://github.com/$repository.git/info/refs?service=git-receive-pack")
[[ $status == 200 ]] || fail "no write access to the repository contents (HTTP $status)"

# A published release is final; a draft is the state a failed earlier run leaves behind.
if state=$(gh release view "$tag" --json isDraft --jq .isDraft 2>/dev/null); then
    [[ $state == true ]] || fail "release $tag is already published"
    assets=$(gh release view "$tag" --json assets --jq '.assets | length')
    [[ $assets -eq 0 ]] || fail "the draft of $tag already has $assets assets"
fi

# The tag may exist only if it points at the commit this run releases.
if tag_sha=$(gh api "repos/$repository/git/ref/tags/$tag" --jq .object.sha 2>/dev/null); then
    tag_type=$(gh api "repos/$repository/git/ref/tags/$tag" --jq .object.type)
    if [[ $tag_type == tag ]]; then
        tag_sha=$(gh api "repos/$repository/git/tags/$tag_sha" --jq .object.sha)
    fi
    [[ $tag_sha == "$sha" ]] || fail "tag $tag exists and points at $tag_sha, not at $sha"
fi

printf 'Release preflight passed for %s.\n' "$tag"
