# Upstream Reference

This directory contains the vendored upstream Hugin release snapshot used as the reference for the Zig port.

- Upstream project: `Hugin`
- Source release: `hugin-2025.0.1`
- Release date: `2025-12-13`
- Source tarball: `https://downloads.sourceforge.net/project/hugin/hugin/hugin-2025.0/hugin-2025.0.1.tar.bz2`
- Tarball SHA-256: `7cf8eb33a6a8848cc7f816faf4bc88389228883d5513136dccb5cb243912ab79`
- Primary implementation reference: `upstream/hugin-2025.0.1/src/tools/align_image_stack.cpp`
- CLI documentation reference: `upstream/hugin-2025.0.1/doc/align_image_stack.pod`

Treat `upstream/hugin-2025.0.1/` as reference material, not as a target for local edits.

This directory also contains the vendored `libpano13` source that the active Nix flake resolves for `panotools`.

- Transitive dependency: `libpano13`
- Nix package: `panotools`
- Source release: `libpano13-2.9.23`
- Source URL: `mirror://sourceforge/panotools/libpano13-2.9.23.tar.gz`
- Primary transform references:
  - `upstream/libpano13-2.9.23/libpano13-2.9.23/adjust.c`
  - `upstream/libpano13-2.9.23/libpano13-2.9.23/math.c`

Treat `upstream/libpano13-2.9.23/` as reference material, not as a target for local edits.
