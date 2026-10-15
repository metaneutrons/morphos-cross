#!/usr/bin/env bash
set -euo pipefail

event_name=${GITHUB_EVENT_NAME:-${1:-}}
event_path=${GITHUB_EVENT_PATH:-${2:-}}

if [[ -z "$event_name" || -z "$event_path" || ! -f "$event_path" ]]; then
    printf 'ERROR: GitHub event name and event payload are required.\n' >&2
    exit 2
fi

check_attribution() {
    local commit=$1
    local identities message

    identities=$(git show -s --format='%an <%ae>%n%cn <%ce>' "$commit")
    message=$(git show -s --format='%B' "$commit")
    if grep -Eiq 'noreply@anthropic\.com|claude|anthropic|codex' <<<"$identities"; then
        printf 'ERROR: commit %s has a forbidden AI author or committer identity.\n' "$commit" >&2
        return 1
    fi
    if grep -Eiq '^[[:space:]]*co-authored-by:.*(claude|anthropic|codex|openai)' \
        <<<"$message"; then
        printf 'ERROR: commit %s has a forbidden AI attribution trailer.\n' "$commit" >&2
        return 1
    fi
    if grep -Eiq 'generated with .*(claude code|codex)' <<<"$message"; then
        printf 'ERROR: commit %s has a forbidden AI generation line.\n' "$commit" >&2
        return 1
    fi
}

case "$event_name" in
    pull_request)
        base=$(jq -er '.pull_request.base.sha' "$event_path")
        head=$(jq -er '.pull_request.head.sha' "$event_path")
        title=$(jq -er '.pull_request.title' "$event_path")
        body=$(jq -r '.pull_request.body // ""' "$event_path")

        message_file=$(mktemp)
        trap 'rm -f "$message_file"' EXIT
        printf '%s\n\n%s\n' "$title" "$body" > "$message_file"
        sh scripts/hooks/check-commit-message.sh "$message_file"
        ;;
    push)
        base=$(jq -er '.before' "$event_path")
        head=$(jq -er '.after' "$event_path")
        ;;
    *)
        printf 'Commit hygiene does not apply to event %s.\n' "$event_name"
        exit 0
        ;;
esac

git cat-file -e "${head}^{commit}"

status=0
if [[ "$base" =~ ^0+$ ]]; then
    commits=$head
else
    git cat-file -e "${base}^{commit}"
    commits=$(git rev-list "${base}..${head}")
fi

while IFS= read -r commit; do
    check_attribution "$commit" || status=1
done <<<"$commits"

exit "$status"
