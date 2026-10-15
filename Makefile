# Checks of the repository itself. Building the toolchain is scripts/ci-build.sh.
SHELL := /bin/bash

SHELL_SCRIPTS = $(shell git ls-files '*.sh' scripts/morphos-cross-sdk packaging/debian/postinst packaging/debian/prerm packaging/debian/postrm)

.PHONY: setup check repository-audit quality-gates shellcheck actionlint secrets-scan patches-check

setup:
	lefthook install

repository-audit:
	@tools/check-no-binaries.sh
	@tools/check-actions-pinned.sh

quality-gates:
	@tests/gates.sh
	@tests/install.sh
	@tests/sdk-helper.sh
	@python3 -m unittest tests/release_tools.py
	@lefthook validate

shellcheck:
	@shellcheck -x -P SCRIPTDIR $(SHELL_SCRIPTS)

actionlint:
	@actionlint

secrets-scan:
	@gitleaks git --redact --verbose .

# Unpack the pinned sources into a scratch directory and apply every patch:
# the quick answer to "does this still fit the pinned SDK?".
patches-check:
	@work=$$(mktemp -d) && trap 'rm -rf "$$work"' EXIT && \
		MORPHOS_CROSS_WORK=$$work scripts/fetch.sh source && \
		MORPHOS_CROSS_WORK=$$work scripts/build.sh unpack

check: repository-audit quality-gates shellcheck actionlint secrets-scan
