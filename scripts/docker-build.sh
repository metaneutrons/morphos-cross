#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build and test the Linux toolchain for the architecture of the Docker engine.
# The work tree lives in a named volume (fast, not a bind mount); the finished
# tree is copied to dist/.
# Usage: scripts/docker-build.sh [DOCKER_CONTEXT]
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
docker_cmd=(docker)
[[ -n ${1:-} ]] && docker_cmd=(docker --context "$1")
image=morphos-cross-build
volume=${MORPHOS_CROSS_VOLUME:-morphos-cross-work}

mkdir -p "$root/dist" "$root/cache"
"$root/scripts/fetch.sh" all
"${docker_cmd[@]}" build --tag "$image" --file "$root/docker/linux.Dockerfile" "$root/docker"
"${docker_cmd[@]}" run --rm \
    --volume "$root:/src:ro" \
    --volume "$root/cache:/cache:ro" \
    --volume "$volume:/work" \
    --volume "$root/dist:/out" \
    --env JOBS="${JOBS:-}" \
    --env MORPHOS_CROSS_CACHE=/cache \
    --env MORPHOS_CROSS_WORK=/work \
    --env MORPHOS_CROSS_OUT=/out \
    "$image" bash /src/scripts/ci-build.sh
