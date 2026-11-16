# Build environment for the Linux toolchains. Debian 12 (glibc 2.36) is the
# oldest Linux baseline the release archives run on.
# The base image is pinned by digest (multi-arch index: amd64 and arm64).
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

RUN apt-get update \
 && apt-get install --yes --no-install-recommends \
        build-essential ca-certificates curl file libarchive-tools m4 patch perl python3 xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
