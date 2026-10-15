#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install the morphos-cross toolchain from a GitHub release.
#
#   curl -fsSL https://github.com/metaneutrons/morphos-cross/releases/latest/download/install.sh | sh
#   sh install.sh [--version TAG] [--prefix DIR] [--no-sdk] [--require-signature] [--force]
#
# The script downloads the archive for this machine and SHA256SUMS from the release, checks the
# checksum, verifies the Sigstore signature when cosign is installed, unpacks into
# PREFIX/<version> and points PREFIX/current at it. Then it fetches the pinned MorphOS SDK from
# morphos-team.net and installs its headers and libraries into the toolchain. The SDK is not part
# of the release archives; it belongs to the MorphOS Team.
set -eu

repository=metaneutrons/morphos-cross
# The release workflow replaces this in the copy it attaches to a release; a copy taken from the
# repository resolves the latest release instead.
default_version=@VERSION@
base_url=${MORPHOS_CROSS_BASE_URL:-https://github.com/$repository/releases/download}
prefix=${MORPHOS_CROSS_HOME:-$HOME/.morphos-cross}
version=''
install_sdk=1
require_signature=0
force=0

die() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit "${1:-2}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) [ $# -ge 2 ] || usage; version=$2; shift 2 ;;
        --prefix) [ $# -ge 2 ] || usage; prefix=$2; shift 2 ;;
        --no-sdk) install_sdk=0; shift ;;
        --require-signature) require_signature=1; shift ;;
        --force) force=1; shift ;;
        -h | --help) usage 0 ;;
        *) usage ;;
    esac
done

# --- host -------------------------------------------------------------------------------------
host=${MORPHOS_CROSS_HOST:-}
if [ -z "$host" ]; then
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) host=linux-x86_64 ;;
        Linux-aarch64 | Linux-arm64) host=linux-arm64 ;;
        Darwin-arm64) host=macos-arm64 ;;
        *) die "unsupported host $(uname -s)-$(uname -m); supported: linux-x86_64, linux-arm64, macos-arm64" ;;
    esac
fi
case "$host" in
    linux-x86_64 | linux-arm64 | macos-arm64) ;;
    *) die "unsupported host $host; supported: linux-x86_64, linux-arm64, macos-arm64" ;;
esac

# --- version ----------------------------------------------------------------------------------
if [ -z "$version" ]; then
    case "$default_version" in
        @*) ;;
        *) version=$default_version ;;
    esac
fi
if [ -z "$version" ]; then
    final=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repository/releases/latest") ||
        die "cannot resolve the latest release"
    version=${final##*/}
fi
case "$version" in
    v[0-9]*-r[0-9]*) ;;
    *) die "unexpected release tag '$version' (expected vYYYYMMDD-rN)" ;;
esac

asset=morphos-cross-${version#v}-$host.tar.xz
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch() {
    curl -fsSL --retry 3 --output "$tmp/$1" "$base_url/$version/$1" || die "cannot download $1 from release $version"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

target=$prefix/$version
if [ -e "$target" ] && [ "$force" -ne 1 ]; then
    printf 'Release %s is already installed in %s (use --force to replace it).\n' "$version" "$target"
else
    printf 'Downloading %s\n' "$asset"
    fetch SHA256SUMS
    fetch "$asset"

    expected=$(awk -v name="$asset" '$2 == name { print $1 }' "$tmp/SHA256SUMS")
    [ -n "$expected" ] || die "$asset is not listed in SHA256SUMS"
    actual=$(sha256_of "$tmp/$asset")
    [ "$expected" = "$actual" ] || die "checksum mismatch for $asset (expected $expected, got $actual)"
    printf 'Checksum verified.\n'

    if command -v cosign >/dev/null 2>&1; then
        fetch "$asset.sigstore.json"
        cosign verify-blob \
            --bundle "$tmp/$asset.sigstore.json" \
            --certificate-oidc-issuer https://token.actions.githubusercontent.com \
            --certificate-identity-regexp "^https://github\.com/$repository/\.github/workflows/release\.yml@refs/heads/main\$" \
            "$tmp/$asset" || die "signature verification failed for $asset"
        printf 'Signature verified.\n'
    elif [ "$require_signature" -eq 1 ]; then
        die "cosign is required for --require-signature but is not installed"
    else
        printf 'Note: cosign is not installed, so the Sigstore signature was not checked.\n'
        printf '      The checksum only proves that the download is intact. See the README.\n'
    fi

    mkdir -p "$prefix"
    mkdir "$tmp/unpack"
    tar -xJf "$tmp/$asset" -C "$tmp/unpack"
    [ -d "$tmp/unpack/morphos-cross" ] || die "the archive does not contain morphos-cross/"
    rm -rf "$target"
    mv "$tmp/unpack/morphos-cross" "$target"
fi
ln -sfn "$version" "$prefix/current"

if [ "$install_sdk" -eq 1 ]; then
    "$target/bin/morphos-cross-sdk" install
else
    printf 'Skipping the SDK. Install it later with: %s/bin/morphos-cross-sdk install\n' "$target"
fi

cat <<EOF

morphos-cross $version is installed in $target

Add it to your PATH:

    export PATH="$prefix/current/bin:\$PATH"

Then:

    ppc-morphos-gcc --version
EOF
