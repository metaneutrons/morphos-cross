#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Arch side of the AUR channel, in the digest-pinned Arch container (makepkg does not run as root).
#
#   aur.sh srcinfo PKGBUILD OUTPUT            .SRCINFO of the PKGBUILD, from makepkg --printsrcinfo
#   aur.sh verify PKGBUILD SEED_DIR ARCHIVE   build the package from the PKGBUILD, install it with pacman,
#                                             compile with it, compare its compiler with the release
#                                             archive of the x86_64 host, and remove it again
#
# makepkg fetches the sources named in the PKGBUILD. Files of SEED_DIR with the same name are used instead
# of a download, which keeps the 370 MiB SDK out of the network while the PKGBUILD keeps the URL users get.
set -euo pipefail

image=archlinux:base-devel@sha256:a26046b7363dad8e2614858f4313949ae9b05c9c5f31de343a54864b9e20806f
command=${1:?usage: aur.sh srcinfo|verify ...}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
absolute() { printf '%s/%s' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }

# An explicit template: macOS mktemp ignores TMPDIR without one, and the container needs a shared path.
work=$(mktemp -d "${TMPDIR:-/tmp}/morphos-cross-aur.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/in" "$work/out"

case "$command" in
    srcinfo)
        pkgbuild=$(absolute "${2:?usage: aur.sh srcinfo PKGBUILD OUTPUT}")
        output=$(absolute "${3:?usage: aur.sh srcinfo PKGBUILD OUTPUT}")
        install -m 0644 "$pkgbuild" "$work/in/PKGBUILD"
        docker run --rm --platform linux/amd64 --user root --volume "$work/in:/in:ro" --volume "$work/out:/out" "$image" \
            bash -euo pipefail -c '
                useradd -m builder
                install -d -o builder -g builder /home/builder/pkg
                install -m 0644 -o builder -g builder /in/PKGBUILD /home/builder/pkg/PKGBUILD
                su builder -c "cd /home/builder/pkg && makepkg --printsrcinfo > /home/builder/pkg/.SRCINFO"
                install -m 0644 /home/builder/pkg/.SRCINFO /out/SRCINFO
            '
        [[ -s $work/out/SRCINFO ]] || fail ".SRCINFO is empty"
        install -m 0644 "$work/out/SRCINFO" "$output"
        ;;
    verify)
        pkgbuild=$(absolute "${2:?usage: aur.sh verify PKGBUILD SEED_DIR ARCHIVE}")
        seed=$(cd "${3:?usage: aur.sh verify PKGBUILD SEED_DIR ARCHIVE}" && pwd)
        archive=$(absolute "${4:?usage: aur.sh verify PKGBUILD SEED_DIR ARCHIVE}")
        install -m 0644 "$pkgbuild" "$work/in/PKGBUILD"
        for file in "$seed"/*; do
            [[ -f $file ]] || continue
            cp "$file" "$work/in/"
        done
        # A directory of the container's own, not the mount: makepkg needs to chmod what it builds.
        docker run --rm --platform linux/amd64 --user root --volume "$work/in:/in:ro" --volume "$archive:/archive.tar.xz:ro" "$image" \
            bash -euo pipefail -c '
                useradd -m builder
                install -d -o builder -g builder /home/builder/pkg
                cp /in/* /home/builder/pkg/
                chown -R builder:builder /home/builder/pkg
                su builder -c "cd /home/builder/pkg && makepkg --cleanbuild --noconfirm --nocheck"
                package=$(ls /home/builder/pkg/*.pkg.tar.zst)

                mkdir /tmp/archive /tmp/package
                tar -xJf /archive.tar.xz -C /tmp/archive
                bsdtar -xf "$package" -C /tmp/package
                cmp /tmp/archive/morphos-cross/bin/ppc-morphos-gcc-15 /tmp/package/opt/morphos-cross/bin/ppc-morphos-gcc-15
                echo "ok: the packaged compiler is byte-identical to the one of the release archive"

                pacman -U --noconfirm "$package" >/dev/null
                printf "#include <stdio.h>\nint main(void){puts(\"hi\");return 0;}\n" > /tmp/hello.c
                ppc-morphos-gcc -O2 -o /tmp/hello /tmp/hello.c
                ppc-morphos-readelf -h /tmp/hello | grep -q PowerPC
                morphos-cross-sdk status
                echo "ok: installed with pacman, the compiler works through /usr/bin and the SDK is the pinned one"

                pacman -R --noconfirm morphos-cross-bin >/dev/null
                [[ ! -e /usr/bin/ppc-morphos-gcc && ! -e /opt/morphos-cross ]]
                echo "ok: pacman -R removes the tree and the links"
            '
        ;;
    *)
        fail "unknown command: $command"
        ;;
esac
