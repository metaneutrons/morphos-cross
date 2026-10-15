#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the Debian package from the release archive of a Linux host. The package carries the toolchain
# tree under /usr/lib/morphos-cross with links in /usr/bin and never the MorphOS SDK: the maintainer
# scripts fetch it with morphos-cross-sdk and cannot fail the installation.
#
# The file name is the canonical Debian one, morphos-cross_<version>_<arch>.deb, which the APT archive
# reads as package, version and architecture. The version is the release version, 20260529-r2.
#
# Usage: scripts/package-deb.sh ARCHIVE OUTPUT_DIR     SOURCE_DATE_EPOCH selects the timestamps
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
archive=${1:?usage: package-deb.sh ARCHIVE OUTPUT_DIR}
outdir=${2:?usage: package-deb.sh ARCHIVE OUTPUT_DIR}
epoch=${SOURCE_DATE_EPOCH:-$(git -C "$root" show -s --format=%ct HEAD)}
# The baseline of scripts/check-linkage.sh.
glibc_min=2.36

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for tool in dpkg-deb tar ar find du; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
[[ -f $archive && ! -L $archive ]] || fail "the archive must be a regular file: $archive"
[[ $epoch =~ ^[1-9][0-9]*$ ]] || fail "SOURCE_DATE_EPOCH must be a positive integer"

name=$(basename "$archive")
if [[ $name =~ ^morphos-cross-([0-9]{8}-r[1-9][0-9]*)-(linux-x86_64|linux-arm64)\.tar\.xz$ ]]; then
    version=${BASH_REMATCH[1]}
    case ${BASH_REMATCH[2]} in
        linux-x86_64) arch=amd64 ;;
        linux-arm64) arch=arm64 ;;
    esac
else
    fail "not the archive of a Linux host: $name"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xJf "$archive" -C "$work"
tree=$work/morphos-cross
[[ -x $tree/bin/ppc-morphos-gcc && -x $tree/bin/morphos-cross-sdk ]] || fail "$name is not a toolchain archive"
[[ ! -e $tree/os-include ]] || fail "$name contains the MorphOS SDK"

pkg=$work/pkg
install -d "$pkg/DEBIAN" "$pkg/usr/lib" "$pkg/usr/bin" "$pkg/usr/share/doc/morphos-cross"
mv "$tree" "$pkg/usr/lib/morphos-cross"
# Relative links: the compiler and the SDK helper both follow them back to the tree.
for tool in "$pkg/usr/lib/morphos-cross/bin/"*; do
    ln -s "../lib/morphos-cross/bin/$(basename "$tool")" "$pkg/usr/bin/$(basename "$tool")"
done
install -m 0644 "$root/packaging/debian/copyright" "$pkg/usr/share/doc/morphos-cross/copyright"
for script in postinst prerm postrm; do
    install -m 0755 "$root/packaging/debian/$script" "$pkg/DEBIAN/$script"
done

# Modes and times that do not depend on the build machine.
find "$pkg" -type d -exec chmod 0755 {} +
find "$pkg" -type f -perm -u+x -not -path "$pkg/DEBIAN/*" -exec chmod 0755 {} +
find "$pkg" -type f ! -perm -u+x -exec chmod 0644 {} +
# GNU touch reads @EPOCH; the BSD touch of a Mac wants a time in UTC.
if touch -d "@$epoch" "$work/probe" 2>/dev/null; then
    stamp=(-d "@$epoch")
else
    stamp=(-t "$(TZ=UTC date -r "$epoch" +%Y%m%d%H%M.%S)")
fi
find "$pkg" -exec env TZ=UTC touch -h "${stamp[@]}" {} +

installed_size=$(du -ks "$pkg/usr" | cut -f1)
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: morphos-cross
Version: $version
Section: devel
Priority: optional
Architecture: $arch
Maintainer: Fabian Schmieder <fabian@schmieder.eu>
Installed-Size: $installed_size
Depends: libc6 (>= $glibc_min)
Recommends: ca-certificates, curl, xz-utils, libarchive-tools | lhasa
Homepage: https://github.com/metaneutrons/morphos-cross
Description: GCC 15 cross-compiler toolchain for MorphOS (PowerPC)
 ppc-morphos-gcc, ppc-morphos-g++ and the matching binutils, built from the
 sources and patches of the MorphOS Team's SDK. The tree is relocatable.
 .
 The MorphOS SDK belongs to the MorphOS Team and is not part of this package.
 The installation fetches the pinned SDK from morphos-team.net and installs it
 into the toolchain. If that fails, for example without a network, the package
 is installed all the same: run "morphos-cross-sdk install" later, or
 "morphos-cross-sdk install SDK.lha" with an archive downloaded elsewhere.
 Set MORPHOS_CROSS_SKIP_SDK=1 to skip the download during installation.
CONTROL
chmod 0644 "$pkg/DEBIAN/control"
TZ=UTC touch "${stamp[@]}" "$pkg/DEBIAN/control"

install -d "$outdir"
output=$outdir/morphos-cross_${version}_${arch}.deb
# --no-uniform-compression keeps the control member gzip, which every consumer reads; the APT archive
# refused control.tar.zst. -Zxz -z9 applies to the data member only and matches the archive's size.
SOURCE_DATE_EPOCH=$epoch dpkg-deb --root-owner-group --no-uniform-compression -Zxz -z9 --build "$pkg" "$output" >/dev/null

[[ $(dpkg-deb --field "$output" Version) == "$version" ]] || fail "the package carries the wrong version"
[[ $(dpkg-deb --field "$output" Architecture) == "$arch" ]] || fail "the package carries the wrong architecture"
members=$(ar t "$output")
grep -qx 'control.tar.gz' <<<"$members" || fail "the control member is not gzip: $(tr '\n' ' ' <<<"$members")"
grep -qxE 'data\.tar\.(xz|gz)' <<<"$members" || fail "unexpected data member: $(tr '\n' ' ' <<<"$members")"
if dpkg-deb --contents "$output" | grep -q 'os-include/'; then fail "the package contains MorphOS SDK files"; fi

printf '%s\n' "$output"
