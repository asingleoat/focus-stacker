# Third-Party And Upstream Licensing

This repository includes bundled reference material and upstream source
snapshots. Those files do not inherit the main project-authored license grant
just because they live in the same repository.

## Upstream Hugin snapshot

- Path: `upstream/hugin-2025.0.1/`
- Role: reference implementation and documentation for the Zig aligner port
- License file in tree: `upstream/hugin-2025.0.1/COPYING.txt`

## Upstream Enblend/Enfuse snapshot

- Path: `upstream/enblend-enfuse-4.3-8243911d8684/`
- Role: reference implementation for the Zig fusion port
- License file in tree: `upstream/enblend-enfuse-4.3-8243911d8684/COPYING`

## Upstream libpano13 snapshot

- Path: `upstream/libpano13-2.9.23/libpano13-2.9.23/`
- Role: transform and optimizer reference material
- License file in tree: `upstream/libpano13-2.9.23/libpano13-2.9.23/COPYING`

## Partial VIGRA header snapshot

- Path: `upstream/vigra-1.12.3/include/`
- Role: small set of vendored upstream headers used by oracle/debug tooling
- License notice location: in-file header notices inside the vendored VIGRA
  headers, for example `upstream/vigra-1.12.3/include/vigra/convolution.hxx`

## Oracle / reference helper tools

- Path: `tools/`
- Role: upstream-facing comparison and oracle helpers, not product-path code
- Local policy: treated as a separate GPL-3.0-only bucket; see `tools/README.md`

## Vendored smooth-numbers submodule

- Path: `vendor/smooth-numbers/`
- Role: project-authored helper used by FFT truncation sizing
- Repository status in this checkout: treated as project-authored code and
  covered by the repository-level GPL-3.0-only bucket described in `LICENSE`
- Follow-up recommended: add an explicit license file to the standalone
  `smooth-numbers` repository as well, so the submodule remains self-describing
  outside this monorepo
