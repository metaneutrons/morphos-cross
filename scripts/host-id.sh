#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Print the host id of this machine: linux-x86_64, linux-arm64 or macos-arm64.
set -euo pipefail
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) echo linux-x86_64 ;;
    Linux-aarch64 | Linux-arm64) echo linux-arm64 ;;
    Darwin-arm64) echo macos-arm64 ;;
    *) printf 'ERROR: unsupported host %s-%s\n' "$(uname -s)" "$(uname -m)" >&2; exit 1 ;;
esac
