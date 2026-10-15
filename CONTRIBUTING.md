# Contributing to morphos-cross

## Development workflow

Create a focused branch from `main`. Use descriptive branch names such as `fix/linux-linkage` or
`feat/macos-universal`. Direct commits to `main` are blocked by the local hooks and by GitHub's
repository rules.

Install the local hooks and run the repository checks:

```sh
make setup
make check
```

`make check` needs `shellcheck`, `actionlint`, `gitleaks`, `lefthook` and ripgrep. Building the
toolchain is a separate, long job:

```sh
scripts/ci-build.sh          # build, package and test for this machine
scripts/docker-build.sh      # the same for Linux, inside the pinned build container
make patches-check           # one minute: do the patches still fit the pinned sources?
```

## Commits and pull requests

Commit messages and pull request titles must follow Conventional Commits. Accepted types are
`feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, and `revert`.
Use a lowercase optional scope and keep the subject at or below 100 characters. Everything written
into the repository is English.

Pull requests explain the reason for the change, describe validation, and disclose remaining risk.
The repository uses squash merges, so the pull request title becomes the commit subject on `main`.
One pull request carries changes of one kind.

Do not commit build output, downloaded archives, or any file of the MorphOS SDK. The SDK belongs to
the MorphOS Team; the release archives deliberately do not contain it.

## Patches

Our patches to the MorphOS sources live in `patches/<SDK date>/<component>/`. They are applied after
the patches of the MorphOS Team, in name order and without fuzz, and each starts with a comment that
says why it exists. Prefer a configure option or a step after installation to a patch: a patch breaks
when the compiler source moves.

## Versions and releases

There is no release pull request. The version comes from `pins.env`: the SDK date plus a revision,
tag `v<SDK date>-r<revision>`. A merge to `main` that changes `pins.env` starts the release pipeline
when that tag does not exist yet.

- A new SDK: run `scripts/pin-sdk.sh`, which fetches both archives, computes their SHA-256 and
  rewrites the pins. Check `make patches-check`; fix a patch that no longer fits.
- A rebuild of the same SDK (a fix in the scripts or patches): raise `REVISION` in `pins.env`.

A change to scripts, patches or the build container without a change to `pins.env` produces no
release. CI builds and tests it on every pull request that changes a path the builds read. A pull
request that touches only documentation, repository tooling or the release and Dependabot workflows
skips the three builds, because `tools/plan-ci.sh` classifies the changed paths and selects the
full scope for every path it does not know. Pushes to `main` always build.

### Package channels

Every release also carries the Debian packages (`morphos-cross_<version>_amd64.deb` and `_arm64.deb`),
the Homebrew formula (`morphos-cross.rb`) and the AUR recipe (`PKGBUILD`, `morphos-cross-bin.SRCINFO`),
produced from the archives of the same run, signed and attested like the archives. The MorphOS SDK is in
none of them: the Debian maintainer scripts fetch it with `morphos-cross-sdk install --best-effort`, which
never fails the installation, the formula takes it as a resource and the PKGBUILD as a source.

Homebrew and AUR publish before the promotion and block it when they fail, the AUR after the tap, so
that nothing reaches it that the tap's qualification has refused; APT is asked after the promotion,
because the archive reads stable releases only. A channel runs when all of its values are set in
the environment `release` and is skipped when none is; a partly configured channel stops the run before
anything public changes.

| Channel | Values in the environment `release` | Target |
| --- | --- | --- |
| Homebrew | variable `HOMEBREW_APP_CLIENT_ID`, secret `HOMEBREW_APP_PRIVATE_KEY` | pull request in `metaneutrons/homebrew-tap` |
| AUR | variable `AUR_SSH_KNOWN_HOSTS`, secret `AUR_SSH_PRIVATE_KEY` | `morphos-cross-bin` |
| APT | variable `ARCHIVE_DISPATCH_CLIENT_ID`, secret `ARCHIVE_DISPATCH_PRIVATE_KEY` | project `morphos-cross` in `metaneutrons/apt-archive` |

`make check` runs the probes of the packaging scripts. The Debian package is built and installed in clean
containers by `scripts/test-deb.sh`, and `tools/release/aur.sh verify` builds the AUR recipe in an Arch
container.

If a release run fails after it created the draft release, delete the draft
(`gh release delete v<version> --yes`, the tag stays and is reused) and re-run the Release workflow
from `main`. A published release is final: fix forward with the next revision.
