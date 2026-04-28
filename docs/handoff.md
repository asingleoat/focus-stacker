# Focus Stack Port Handoff

## Project Intent

This repository is intended to become a faithful Zig port of Hugin's `align_image_stack`, using the vendored `hugin-2025.0.1` release as the behavioral reference.

The goal is not just feature overlap. The goal is semantic parity:

- same CLI surface and output modes where practical
- same high-level processing stages
- increasingly similar optimizer behavior and variable meaning
- a codebase that is easy to profile, benchmark, and optimize once parity is credible

Two constraints define the implementation direction:

- image file I/O may use standard C libraries
- all internal image processing, matching, optimization, remap logic, and future performance work should be pure Zig

## Reference Material

Primary upstream references in this repo:

- `upstream/hugin-2025.0.1/src/tools/align_image_stack.cpp`
- `upstream/hugin-2025.0.1/doc/align_image_stack.pod`
- `upstream/hugin-2025.0.1/src/hugin_base/panotools/PanoToolsInterface.cpp`
- `upstream/hugin-2025.0.1/src/hugin_base/nona/SpaceTransform.cpp`
- `upstream/hugin-2025.0.1/src/hugin_base/panodata/SrcPanoImage.cpp`

These matter for different reasons:

- `align_image_stack.cpp` defines tool-level behavior, control flow, and failure conditions
- `PanoToolsInterface.cpp` and `SpaceTransform.cpp` define what variables like `y/p/r/v/a/b/c/d/e/TrX/TrY/TrZ` mean in practice
- `SrcPanoImage.cpp` contains HFOV and focal-length conversion math used by the camera model

## Current Repository Structure

- `src/config.zig`: CLI parsing and validated configuration
- `src/pipeline.zig`: top-level orchestration
- `src/image_io.zig`: JPEG/PNG/TIFF decode, TIFF write, EXIF EV extraction
- `src/gray.zig`: grayscale conversion and pyramid reduction
- `src/features.zig`: feature detection on reduced images
- `src/match.zig`: coarse matching and full-resolution refinement
- `src/sequence.zig`: EV ordering, pair planning, remap activation
- `src/optimize.zig`: iterative camera/lens solver and pruning
- `src/remap.zig`: aligned TIFF remap and overlap crop
- `src/pto.zig`: PTO export
- `docs/port-plan.md`: compact roadmap
- `docs/handoff.md`: this document

## Build And Run Notes

Recommended commands:

```sh
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run -- -h
```

The repo uses the flake for dependency management. Re-enter the shell with `nix develop` if the environment drifts.

The Zig shared global cache at `/home/tim/.cache/zig` has been unreliable in this environment. Use the repo-local `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache` setting consistently.

## Current Functional State

Implemented and working:

- CLI parsing for the current ported option surface
- input metadata loading
- EXIF-derived initial HFOV inference from focal-length metadata when available
- JPEG/PNG/TIFF decode via `libjpeg-turbo`, `libpng`, `libtiff`, and `libexif`
- EV-based input ordering with the upstream `0.05` spread cutoff behavior
- pair planning for consecutive matching and `--align-to-first`
- `--dont-remap-ref` handling
- pure-Zig grayscale conversion and pyramid reduction
- pure-Zig feature detection on reduced images
- coarse normalized-correlation matching
- full-resolution control-point refinement
- control-point pruning by residual threshold
- iterative camera/lens optimization
- PTO output
- aligned TIFF output
- overlap crop path for `-C`

Implemented, but still only a first-pass approximation of upstream:

- optimizer semantics for `y/p/r/v`
- optimizer semantics for `a/b/c/d/e`
- optimizer semantics for `TrX/TrY/TrZ`
- remap model for the currently supported camera/lens variables

Not implemented:

- HDR output (`-o`)
- stereo-window-specific behavior
- GPU remap path
- lens database distortion loading behavior beyond current scaffolding
- true PTOptimizer-equivalent semantics and conditioning

## What "Current Optimizer" Means

The optimizer is no longer a rigid 2D fallback. It now has three layers:

1. A linear seed step to initialize active parameters.
2. An iterative nonlinear least-squares refinement loop using numerical derivatives.
3. Soft priors to keep poorly constrained variables from drifting into nonsense.

The current variable meanings are:

- `y/p/r`: rectilinear camera rotation parameters in the warp
- `v`: HFOV delta from a per-image base HFOV
- `a/b/c`: radial lens terms in a polynomial image-space distortion model
- `d/e`: center-shift terms
- `TrX/TrY/TrZ`: first-pass translated-camera terms against the reference plane

This is directionally closer to upstream than the earlier image-plane approximation, but it is still not semantically identical to Panotools/PTOptimizer.

## Verified Runtime Behavior

Recent real-sequence checks used `S003/S003_0001.jpg` and `S003/S003_0002.jpg`.

Observed baseline behavior:

- with default `y/p/r`, the solve converges to small rotations rather than fake pixel shifts
- with EXIF focal/crop metadata present, the port now initializes the baseline HFOV from metadata instead of falling back to `50`
- with `-m -d -i`, the solve emits nonzero HFOV/radial/center-shift terms and writes them into PTO
- with `-x -y -z`, the solve emits small camera-translation values and writes them into PTO
- aligned TIFF outputs complete successfully for the current default, camera, and exercised translation paths

Recent example commands:

```sh
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run -- -v -p verify.pto S003/S003_0001.jpg S003/S003_0002.jpg
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run -- -v -m -d -i -p verify_mdi.pto S003/S003_0001.jpg S003/S003_0002.jpg
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run -- -v -x -y -z -p verify_xyz.pto S003/S003_0001.jpg S003/S003_0002.jpg
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run -- -v -a verifyalign_cam S003/S003_0001.jpg S003/S003_0002.jpg
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run -- -v -x -y -z -a verifyalign_xyz S003/S003_0001.jpg S003/S003_0002.jpg
```

Representative outcomes at handoff time:

- default `y/p/r`: post-prune RMS about `0.9819 px`
- `-m -d -i`: on the `S003` pair now fails after pruning away all reference-image control points, which is closer to the upstream tool's behavior on this sample
- `-x -y -z`: post-prune RMS about `1.6066 px`

These numbers are useful for regression tracking, not as final quality targets.

## Known Gaps To Semantic Parity

### 1. Translation semantics are still incomplete

This is the most important remaining semantic gap.

Current state:

- `TrX/TrY/TrZ` are now modeled as camera-position terms against a reference plane
- `align_image_stack` itself does not add `Tpy/Tpp` to its default optimize vector when `-x/-y/-z` are enabled
- the port now matches that optimize-vector surface again: `Tpy/Tpp` remain serialized image variables, but they are not auto-optimized

Still missing:

- upstream translation-plane orientation semantics (`Tpy` / `Tpp`)
- closer equivalence to how Panotools couples translation with projection and camera orientation
- confidence that the current normalization/scaling matches upstream well enough

### 2. Projection/model fidelity is still narrower than upstream

Current warp is rectilinear-focused.

Still missing:

- broader projection parity
- more faithful reuse of upstream projection-specific scale and transform relationships
- exact handling of fisheye and related cases

### 3. Optimizer conditioning is still hand-tuned

Current priors and parameter scaling are practical engineering controls, not a reproduction of PTOptimizer behavior.

Still missing:

- more principled variable scaling
- better coupling/decoupling rules between camera and lens terms
- closer reproduction of upstream optimizer convergence behavior and failure behavior

### 4. Tool-level parity is incomplete

Still missing:

- HDR output
- stereo-specific alignment behavior
- remaining option-surface fidelity

## Recommended Next Steps

The rest of the work should be done in phases. Do not jump straight into micro-optimizing the current code. Semantic parity first, then performance work.

### Phase 1: Finish translation semantics

Objective:

- make `TrX/TrY/TrZ` behave much closer to upstream
- add translation-plane orientation semantics (`Tpy` / `Tpp`)

Concrete plan:

1. Keep `Tpy/Tpp` out of the default `align_image_stack` optimize vector, but preserve them in the camera model and PTO serialization for future explicit support.
2. Read the upstream translation handling in `PanoToolsInterface.cpp`, `SpaceTransform.cpp`, and the remap/fitting path until the meaning of `TrX/TrY/TrZ/Tpy/Tpp` is explicit enough to mirror.
3. Tighten the common panorama-space mapping so translated cameras are solved in the same frame that upstream uses.
4. Add focused tests:
   - translation-only synthetic pair
   - translation plus rotation synthetic pair
   - round-trip transform/inverse-transform with translation-plane orientation active
5. Re-run the `-x -y -z` real-pair case against the upstream binary and compare residuals, surviving control-point count, and PTO output.

Success criteria:

- no runaway `Tr*` values on the real pair
- consistent aligned TIFF output
- synthetic tests prove parameter meaning is stable

### Phase 2: Tighten camera/lens parameter scaling

Objective:

- reduce overfitting and improve stability when `-m -d -i` are enabled

Concrete plan:

1. Review the current priors in `src/optimize.zig`.
2. Separate:
   - absolute-value regularization
   - step-size damping
   - parameter normalization
3. Normalize derivatives/updates by parameter scale instead of only adding diagonal penalties.
4. Add regression snapshots for:
   - default `y/p/r`
   - `-m -d -i`
   - `-x -y -z`
5. Compare before/after residuals and exported parameter magnitudes.

Success criteria:

- `v/a/b/c/d/e` remain moderate without having to clamp them aggressively
- residual quality does not regress

### Phase 3: Broaden projection fidelity

Objective:

- move beyond the current rectilinear-centered assumptions

Concrete plan:

1. Re-read the scale and projection handling in:
   - `SrcPanoImage.cpp`
   - `SpaceTransform.cpp`
2. Split the current warp into:
   - projection-independent camera pose logic
   - projection-specific image/ray mapping
3. Implement at least:
   - rectilinear
   - current fisheye mode needed by CLI `-e`
4. Update PTO output to reflect the improved model consistently.
5. Add synthetic tests that exercise projection-specific round trips.

Success criteria:

- `-e` meaningfully changes camera-model behavior, not just the PTO flag

### Phase 4: Implement HDR output

Objective:

- support `-o` and complete the major output surface

Concrete plan:

1. Inspect `align_image_stack.cpp` output path and identify the minimal parity target.
2. Decide the internal handoff format after remap.
3. Implement the alignment/remap-to-HDR path with the current pure-Zig internals.
4. Add at least one end-to-end command that verifies `-o`.

Success criteria:

- `-o` works end to end
- no regression in `-p` and `-a`

### Phase 5: Build a benchmark and regression harness

Objective:

- avoid blind optimization

Concrete plan:

1. Pick a fixed corpus:
   - the existing `S003` pair
   - at least one longer stack
   - at least one case with broader motion or lens variation
2. Record:
   - coarse CP count
   - refined CP count
   - post-prune CP count
   - RMS/max residual
   - runtime per stage
3. Put the benchmark entrypoint under version control.
4. Use it before any performance refactor.

Success criteria:

- every optimization change has a measurement baseline

## Suggested Engineering Discipline For The Next Person

- Keep using upstream code as the semantic reference, especially for variable meaning.
- Prefer small semantic increments over broad rewrites.
- After every optimizer-model change:
  - run `zig build test`
  - run a real-pair PTO export
  - run a real-pair aligned TIFF export
- Treat large residual improvements with suspicion if parameter magnitudes explode.
- Do not start algorithmic speed work until the variable semantics are credible.

## Short Status Summary

If someone needs the shortest possible summary:

- the project is a Zig port of `align_image_stack`
- matching and remap/output work today
- the optimizer is now a real iterative camera/lens solver, not a rigid placeholder
- `y/p/r/v/a/b/c/d/e/TrX/TrY/TrZ` are partially meaningful, but translation semantics and full PTOptimizer parity are still incomplete
- the next correct task is finishing translation-plane semantics and tightening optimizer conditioning
