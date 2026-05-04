# Third-Party And Upstream Licensing

This repository does not currently redistribute upstream source snapshots in
git. Instead, it can optionally recreate local upstream reference trees under
`upstream/` via `scripts/fetch_upstream_refs.sh`.

Those fetched trees:

- remain under their own upstream licenses and notices
- do not inherit the main project-authored license grant
- are local developer reference material, not part of the normal product-path
  build/test/run surface

## Upstream Hugin reference snapshot

- Path: `upstream/hugin-2025.0.1/`
- Role: reference implementation and documentation for the Zig aligner port
- License file in tree: `upstream/hugin-2025.0.1/COPYING.txt`

## Upstream Enblend/Enfuse reference snapshot

- Path: `upstream/enblend-enfuse-4.3-8243911d8684/`
- Role: reference implementation for the Zig fusion port
- License file in tree: `upstream/enblend-enfuse-4.3-8243911d8684/COPYING`

## Upstream libpano13 reference snapshot

- Path: `upstream/libpano13-2.9.23/libpano13-2.9.23/`
- Role: transform and optimizer reference material
- License file in tree: `upstream/libpano13-2.9.23/libpano13-2.9.23/COPYING`

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
