#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install the Debian package in clean containers without a network and check what a user gets:
# a failed SDK download that never fails the installation, an install from a file, a cached download,
# the skip switch, a reinstall, remove and purge. The prerequisites the package recommends are put
# into a throwaway image first, because the scenarios themselves run offline.
# Usage: scripts/test-deb.sh DEB CACHE_DIR IMAGE
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
deb=$(cd "$(dirname "${1:?usage: test-deb.sh DEB CACHE_DIR IMAGE}")" && pwd)/$(basename "$1")
cache=$(cd "${2:?usage: test-deb.sh DEB CACHE_DIR IMAGE}" && pwd)
image=${3:?usage: test-deb.sh DEB CACHE_DIR IMAGE}

tag=morphos-cross-deb-test:$(printf '%s' "$image" | tr ':/' '--')
docker build --quiet --tag "$tag" - >/dev/null <<DOCKERFILE
FROM $image
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        ca-certificates curl xz-utils libarchive-tools \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE

for scenario in offline cached skip; do
    printf '== %s on %s\n' "$scenario" "$image"
    docker run --rm --network none \
        --volume "$root:/src:ro" --volume "$(dirname "$deb"):/deb:ro" --volume "$cache:/cache:ro" \
        "$tag" bash /src/scripts/clean-room-deb.sh "$scenario"
done
