# Security Policy

## Supported versions

Only the latest release of morphos-cross is supported. Every release is built from the pinned
sources of one MorphOS SDK, see [README.md](README.md#versions).

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's
[private vulnerability reporting](https://github.com/metaneutrons/morphos-cross/security/advisories/new)
to send the report and reproduction details privately.

We aim to acknowledge reports within three business days and provide an initial assessment
within ten business days.

## What to verify

Every release asset is covered by `SHA256SUMS`, carries a keyless Sigstore signature and a GitHub
build provenance attestation. [README.md](README.md#verify-a-download) shows how to check them.
Report an asset whose signature or attestation does not verify as a vulnerability.
