# Third-party software

morphos-cross builds the following components and ships them in its release archives. The versions
are pinned in [`pins.env`](pins.env); the exact sources are in the source archive that accompanies
every release.

| Component | Licence | Notes |
| --- | --- | --- |
| GCC | GPL-3.0-or-later | With the MorphOS Team's patches. `libgcc`, `libstdc++` and the other runtime libraries are covered by the GCC Runtime Library Exception 3.1. |
| GNU binutils | GPL-3.0-or-later | With the MorphOS Team's patches. |
| GMP | LGPL-3.0-or-later OR GPL-2.0-or-later | Linked into the compiler. |
| MPFR | LGPL-3.0-or-later | Linked into the compiler. |
| MPC | LGPL-3.0-or-later | Linked into the compiler. |

The sources and the MorphOS patches come from the SDK sources published by the MorphOS Team at
<https://morphos-team.net/sources>. The licence texts are in the source archive (`COPYING3`,
`COPYING.RUNTIME` and the files of the individual components).

## The MorphOS SDK

The SDK (headers, libraries, documentation) is © the MorphOS Team and is **not** part of any release
archive. The installer downloads it from morphos-team.net and installs the parts a compiler needs
into the toolchain on your machine. Its own terms apply to it; the SDK readme states that the system
includes may not be distributed separately without the MorphOS Team's permission.

## Build and test tooling

CI runs gitleaks, actionlint, shellcheck and the SPDX tools validator from their published releases
or hash-locked packages; none of them is part of a release archive.
