#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

# commit-hygiene runs on pull requests only and may be skipped on a push. The builds may be skipped
# only when the planner decided that the change cannot affect them: a skip is a scope decision, not
# a success, and a skip without that decision fails.
jq -e '
    keys == ["build", "commit-hygiene", "patches", "plan", "quality"] and
    all(.[]; .result == "success" or .result == "skipped") and
    (.plan.result == "success") and (.quality.result == "success") and (.patches.result == "success") and
    (.build.result == "success" or (.build.result == "skipped" and .plan.outputs.build == "false"))
' <<< "${NEEDS:?NEEDS must contain the complete GitHub job result object}"
