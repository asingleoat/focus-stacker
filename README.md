# focus_stack

This repository now includes:

- A vendored upstream reference snapshot of Hugin `align_image_stack` at `upstream/hugin-2025.0.1/`
- A Zig scaffold for the port in `src/`
- A short porting plan in `docs/port-plan.md`
- Ported planning stages for sequence ordering, pair generation, remap-reference handling, and optimizer-variable selection
- Pure-Zig coarse feature detection and coarse control-point matching over reduced grayscale image pairs
- A second-pass pure-Zig full-resolution refinement stage for coarse matches
- A pure-Zig iterative camera-model pose solve with residual-threshold pruning
- Pure-Zig remap/PTO output for rigid and first-pass lens-term warps, including a basic overlap crop path for `-C`
- A switchable in-tree Zig fusion subsystem for focus stacking:
  - `hardmask-contrast`: fast contrast-weight winner selection
  - `softmask-contrast`: soft-mask blend using a 5-tap Burt-Adelson-style blur on contrast masks
  - `pyramid-contrast`: first-pass multiresolution blend with Gaussian mask pyramids and Laplacian image pyramids
  - `hybrid-pyramid-contrast`: opt-in sharpened pyramid variant with tunable extra sharpness

Current practical defaults:

- `focus_stack_zig` / `focus_fuse_zig` keep a conservative internal default of `hardmask-contrast`
- `scripts/stack_zig.sh` defaults to external `enfuse`
- the best current in-tree quality baseline is `pyramid-contrast`
- `hybrid-pyramid-contrast` is experimental and intentionally opt-in

Useful commands:

```sh
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run -- -h
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run-fuse -- --help
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run-stack -- --help
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-zig -- lm-params /tmp/example.pto
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-upstream -- fvec /tmp/example.pto 1
```

Useful docs:

- [docs/fusion-modes.md](docs/fusion-modes.md): current fusion modes, tradeoffs, and recommended usage
- [docs/probes.md](docs/probes.md): current probe/oracle/debug tooling and when to use each tool
- [docs/enfuse-port-map.md](docs/enfuse-port-map.md): upstream `enfuse` implementation map used during the Zig fusion port

Committed fixtures:

- `tests/golden/s003_small/`: fast 2-frame/3-frame regression fixtures used by `zig build test`
- `tests/perf/s003_stack10_768/`: a 10-frame downsampled stack reserved for profiling, optimizer throughput work, and future parallelism experiments

Focused parity tools:

- `probe-zig`: evaluates the port's optimizer state and residual functions from a PTO file.
- `probe-upstream`: evaluates pano13's `SetLMParams`, `SetAlignParams`, `EvaluateControlPointErrorAndComponents`, and `fcnPano` from the same PTO file.
- Use them to compare `lm-params`, `image-vars`, `cp-error`, and `fvec` directly instead of diffing only final aligned outputs.

Current status: CLI validation and pre-alignment planning are implemented. Real image metadata loading is in place, JPEG/PNG/TIFF decode is available through `libjpeg-turbo`, `libpng`, `libtiff`, and `libexif`, and the current pure-Zig pipeline now covers grayscale conversion, pyramid reduction, Harris-style interest point detection, coarse normalized-correlation matching, a full-resolution refinement pass, an iterative camera-model solve with residual pruning, EXIF-derived initial HFOV inference, first-pass HFOV/radial/center-shift optimization terms with regularization, PTO writing, aligned TIFF remap output, and in-tree focus-stack fusion. This is still narrower than upstream's full Panotools-based optimizer and full `enfuse` pyramid stack, and HDR output is still pending.

For practical focus-stack workflows:
- `focus_fuse_zig` fuses an already aligned TIFF stack
- `focus_stack_zig` aligns, remaps, and fuses in-process without aligned-TIFF round-tripping
- `scripts/stack_zig.sh` is the easiest end-to-end driver for real stacks and lets you switch between external `enfuse` and in-tree Zig fusion modes

If Zig's shared global cache becomes noisy in your environment, use `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache` for reproducible local builds.
