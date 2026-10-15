#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

# commit-hygiene runs on pull requests only and may be skipped on a push.
jq -e '
    keys == ["build", "commit-hygiene", "patches", "quality"] and
    all(.[]; .result == "success" or .result == "skipped") and
    (.quality.result == "success") and (.patches.result == "success") and
    (.build.result == "success")
' <<< "${NEEDS:?NEEDS must contain the complete GitHub job result object}"
