#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The metadata of the package channels, generated from the release candidate.

    channels.py formula  PINS TAG CANDIDATE OUTPUT    Homebrew formula
    channels.py pkgbuild PINS TAG CANDIDATE OUTPUT    PKGBUILD of the AUR package morphos-cross-bin

Every checksum is computed from the archive in CANDIDATE, never typed in. The MorphOS SDK is not part of
a release: the formula takes it as a resource and the PKGBUILD as a source, so that the user's own
download from morphos-team.net fetches it, and no package repository ever holds a copy.
"""

import hashlib
from pathlib import Path
import re
import sys

REPOSITORY = "metaneutrons/morphos-cross"
HOMEPAGE = f"https://github.com/{REPOSITORY}"
MAINTAINER = "Fabian Schmieder <fabian@schmieder.eu>"
DESCRIPTION = "GCC 15 cross-compiler toolchain for MorphOS (PowerPC)"
HOSTS = ("linux-x86_64", "linux-arm64", "macos-arm64")
AUR_PACKAGE = "morphos-cross-bin"


def read_pins(path):
    pins = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            pins[key] = value.strip().strip('"')
    pins["VERSION"] = f"{pins['SDK_DATE']}-r{pins['REVISION']}"
    return pins


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def release_url(tag, name):
    return f"{HOMEPAGE}/releases/download/{tag}/{name}"


def archive_name(version, host):
    return f"morphos-cross-{version}-{host}.tar.xz"


def check_identity(pins, tag):
    version = pins["VERSION"]
    if tag != f"v{version}":
        raise ValueError(f"the tag {tag} is not the release of pins.env, v{version}")
    if not re.fullmatch(r"v\d{8}-r[1-9]\d*", tag):
        raise ValueError(f"invalid release tag {tag}")
    return version


def formula(pins, tag, candidate):
    version = check_identity(pins, tag)
    digest = {host: sha256(Path(candidate) / archive_name(version, host)) for host in HOSTS}
    url = {host: release_url(tag, archive_name(version, host)) for host in HOSTS}
    sdk_name = pins["SDK_URL"].rsplit("/", 1)[1]
    return f'''class MorphosCross < Formula
  desc "{DESCRIPTION}"
  homepage "{HOMEPAGE}"
  version "{version}"
  license "GPL-3.0-or-later"

  depends_on "libarchive"
  depends_on "xz"

  on_macos do
    depends_on arch: :arm64

    on_arm do
      url "{url['macos-arm64']}"
      sha256 "{digest['macos-arm64']}"
    end
  end

  on_linux do
    on_arm do
      url "{url['linux-arm64']}"
      sha256 "{digest['linux-arm64']}"
    end

    on_intel do
      url "{url['linux-x86_64']}"
      sha256 "{digest['linux-x86_64']}"
    end
  end

  # The MorphOS SDK belongs to the MorphOS Team. brew fetches it from their site for the user and checks
  # the checksum; this tap never carries a copy.
  resource "sdk" do
    url "{pins['SDK_URL']}", using: :nounzip
    sha256 "{pins['SDK_SHA256']}"
  end

  def install
    libexec.install Dir["*"]
    bin.install_symlink Dir[libexec/"bin/*"]
    # The helper reads the SDK archive with bsdtar, which libarchive provides without linking it.
    with_env(PATH: "#{{formula_opt_bin("libarchive")}}:#{{ENV["PATH"]}}") do
      system libexec/"bin/morphos-cross-sdk", "install", resource("sdk").cached_download
    end
  end

  def caveats
    <<~EOS
      The MorphOS SDK ({sdk_name}) was installed into the toolchain from the MorphOS Team's site.
      If a newer release of this formula pins a newer SDK, "brew upgrade" installs that one as well.
    EOS
  end

  test do
    (testpath/"hello.c").write <<~C
      #include <stdio.h>
      int main(void) {{ puts("hello"); return 0; }}
    C
    system bin/"ppc-morphos-gcc", "-O2", "-o", "hello", "hello.c"
    assert_match "PowerPC", shell_output("#{{bin}}/ppc-morphos-readelf -h hello")
    assert_match "is installed", shell_output("#{{bin}}/morphos-cross-sdk status")
  end
end
'''


def pkgbuild(pins, tag, candidate):
    version = check_identity(pins, tag)
    pkgver, pkgrel = version.split("-r")
    sdk_name = pins["SDK_URL"].rsplit("/", 1)[1]
    sources = {}
    for host, arch in (("linux-x86_64", "x86_64"), ("linux-arm64", "aarch64")):
        name = archive_name(version, host)
        sources[arch] = (f"{name}::{release_url(tag, name)}", sha256(Path(candidate) / name))
    return f'''# Maintainer: {MAINTAINER}
pkgname={AUR_PACKAGE}
pkgver={pkgver}
pkgrel={pkgrel}
pkgdesc="{DESCRIPTION}, with the MorphOS SDK"
arch=('x86_64' 'aarch64')
url="{HOMEPAGE}"
license=('GPL-3.0-or-later' 'LicenseRef-MorphOS-SDK')
depends=('glibc')
makedepends=('libarchive')
provides=('morphos-cross')
conflicts=('morphos-cross')
# The toolchain is a tree that must stay as built, and its target files are PowerPC code: makepkg would
# run the host's strip over them.
options=('!strip' '!debug' '!lto' 'staticlibs')
source=("{sdk_name}::{pins['SDK_URL']}")
source_x86_64=("{sources['x86_64'][0]}")
source_aarch64=("{sources['aarch64'][0]}")
noextract=("{sdk_name}")
sha256sums=('{pins['SDK_SHA256']}')
sha256sums_x86_64=('{sources['x86_64'][1]}')
sha256sums_aarch64=('{sources['aarch64'][1]}')

# The MorphOS SDK belongs to the MorphOS Team. makepkg downloads it from their site for the user, so that
# this recipe never distributes it, and the toolchain's own helper installs it into the package.
package() {{
    local tree="$pkgdir/opt/morphos-cross" tool
    install -d "$pkgdir/opt" "$pkgdir/usr/bin"
    cp -a "$srcdir/morphos-cross" "$tree"
    "$tree/bin/morphos-cross-sdk" install "$srcdir/{sdk_name}"
    for tool in "$tree/bin/"*; do
        ln -s "/opt/morphos-cross/bin/${{tool##*/}}" "$pkgdir/usr/bin/${{tool##*/}}"
    done
    install -Dm644 "$tree/share/doc/morphos-cross/LICENSE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
    install -Dm644 "$tree/share/doc/morphos-cross/THIRD-PARTY.md" "$pkgdir/usr/share/licenses/$pkgname/THIRD-PARTY.md"
    bsdtar -xOf "$srcdir/{sdk_name}" morphossdk/Readme.txt > "$pkgdir/usr/share/licenses/$pkgname/MorphOS-SDK-Readme.txt"
}}
'''


def main():
    if len(sys.argv) != 6 or sys.argv[1] not in ("formula", "pkgbuild"):
        sys.exit(__doc__)
    kind, pins_path, tag, candidate, output = sys.argv[1:]
    generate = formula if kind == "formula" else pkgbuild
    try:
        text = generate(read_pins(pins_path), tag, candidate)
    except (ValueError, OSError, KeyError) as error:
        sys.exit(f"ERROR: {error}")
    Path(output).write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
