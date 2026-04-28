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

Useful commands:

```sh
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run -- -h
```

Current status: CLI validation and pre-alignment planning are implemented. Real image metadata loading is in place, JPEG/PNG/TIFF decode is available through `libjpeg-turbo`, `libpng`, `libtiff`, and `libexif`, and the current pure-Zig pipeline now covers grayscale conversion, pyramid reduction, Harris-style interest point detection, coarse normalized-correlation matching, a full-resolution refinement pass, an iterative camera-model solve with residual pruning, first-pass HFOV/radial/center-shift optimization terms with regularization, PTO writing, and aligned TIFF remap output. This is still narrower than upstream's full Panotools-based optimizer, and HDR output is still pending.

If Zig's shared global cache becomes noisy in your environment, use `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache` for reproducible local builds.
