# Align Image Stack Port Plan

## Scope

The target is a clean Zig port of Hugin's `align_image_stack`, using `hugin-2025.0.1` as the pinned behavioral reference when the optional local upstream snapshot is fetched.

## Why a fetched release snapshot

The official source distribution that `nixpkgs` consumes is a SourceForge release tarball, not a Git repository. Vendoring the same upstream snapshot gives us a deterministic reference without inventing a fake Git submodule workflow around Hugin's upstream release process.

In the current repo layout, that reference tree is fetched on demand with:

```sh
./scripts/fetch_upstream_refs.sh
```

## Reference decomposition

When the optional local upstream tree is present, the implementation in `upstream/hugin-2025.0.1/src/tools/align_image_stack.cpp` naturally breaks into these stages:

1. CLI parsing and configuration validation.
2. Input metadata loading and optional EV-based ordering.
3. Pyramid image reduction and per-pair image decode.
4. Interest point detection over a grid.
5. Correlation-based point refinement and control point generation.
6. Panorama variable setup and geometric optimization.
7. Control point pruning, stereo window handling, and optional autocrop.
8. Remap and output writing for aligned TIFFs, HDR, and PTO.

## Intended Zig module split

- `src/config.zig`: CLI parity and validated runtime configuration.
- `src/pipeline.zig`: high-level orchestration and stable stage boundaries.
- `src/image_io.zig`: C-backed file decode and metadata extraction.
- `src/gray.zig`: pure-Zig grayscale conversion and pyramid reduction.
- `src/features.zig`: pure-Zig grid-local interest point detection.
- `src/match.zig`: pure-Zig coarse correlation matching and control point generation.
- `src/optimize.zig`: iterative pose/lens solve and residual pruning.
- `src/remap.zig` / `src/pto.zig`: remap, crop, and TIFF/PTO emission.

## Immediate next steps

1. Improve optimizer fidelity and stability, especially fuller upstream translation semantics, better parameter scaling/regularization, and broader projection-model parity beyond the current rectilinear-focused camera warp.
2. Implement HDR output and its alignment/remap path.
3. Add a repeatable benchmark corpus and timing harness before any optimization pass.
