# Build environment for the Linux toolchains. Debian 12 (glibc 2.36) is the
# oldest Linux baseline the release archives run on.
# The base image is pinned by digest (multi-arch index: amd64 and arm64).
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

RUN apt-get update \
 && apt-get install --yes --no-install-recommends \
        build-essential ca-certificates curl file libarchive-tools m4 patch perl python3 xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
