# Probes And Oracles

This repo now has a fairly rich probe/debug surface. This document is the short map for what still matters and when to use it.

## Philosophy

There are three classes of diagnostic tools here:

- Zig probes: inspect or benchmark the port directly
- upstream probes/oracles: compare against fetched upstream behavior
- local debug dumps: inspect masks, pyramid levels, or remap output visually

Use the smallest tool that answers the question you actually have.

## Build Targets

Common commands:

```sh
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-zig -- <args...>
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-upstream -- <args...>
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-match -- <args...>
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-live -- <args...>
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-remap -- <args...>
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-fuse-masks -- <args...>
```

Some upstream-facing probes and oracle tools assume the optional local
`upstream/` reference tree has been populated first:

```sh
./scripts/fetch_upstream_refs.sh
```

## Active Zig Probes

### `probe-zig`

Purpose:

- inspect optimizer state from PTO files
- compare objective vectors, LM parameters, and sparsity information

Use it for:

- `lm-params`
- `image-vars`
- `cp-error`
- `fvec`
- Jacobian/sparsity diagnostics

Primary file:

- [src/parity_probe.zig](/home/tim/code/focus_stack/src/parity_probe.zig)

### `probe-upstream`

Purpose:

- evaluate the fetched upstream optimizer path from the same PTO data

Use it for:

- parity checks against pano13 semantics
- confirming whether a mismatch is in the Zig port or already in the chosen upstream reference path

Requirement:

- local upstream references fetched via `scripts/fetch_upstream_refs.sh`

Primary file:

- [src/upstream_probe.zig](/home/tim/code/focus_stack/src/upstream_probe.zig)

### `probe-match`

Purpose:

- compare and benchmark pair-matching behavior

Use it for:

- control-point count checks
- grid/correlation threshold comparisons
- pair-alignment method experiments

Primary file:

- [src/match_probe.zig](/home/tim/code/focus_stack/src/match_probe.zig)

### `probe-live`

Purpose:

- compare in-process solves and PTO-roundtrip solves on live image data

Use it for:

- separating “solver logic” from “pipeline/plumbing” regressions
- confirming whether a discrepancy survives PTO serialization

Primary file:

- [src/live_probe.zig](/home/tim/code/focus_stack/src/live_probe.zig)

### `probe-remap`

Purpose:

- benchmark remap/output from a solved PTO without rerunning matching and optimization

Use it for:

- remap kernel timing
- TIFF output timing
- row-parallel output experiments

Primary file:

- [src/remap_probe.zig](/home/tim/code/focus_stack/src/remap_probe.zig)

### `probe-fuse-masks`

Purpose:

- dump raw and normalized focus-fusion masks

Use it for:

- diagnosing support alpha behavior
- comparing raw mask generation with `enfuse`
- debugging mask normalization

Primary file:

- [src/fuse_mask_probe.zig](/home/tim/code/focus_stack/src/fuse_mask_probe.zig)

## Temporary Oracle Tools

These are useful, but they are not product-path code.

### `tools/enfuse_pyramid_oracle.cpp`

Purpose:

- dump real upstream `enfuse` Gaussian/Laplacian pyramid levels

Why it exists:

- it was the decisive oracle for fixing the coarse no-wrap expand mismatch that caused the earlier horizontal banding

Status:

- keep it around as a reference/oracle tool
- do not treat it as product code

### `tools/vigra_oracle.cpp`

Purpose:

- compare reduced-image import, interest-point selection, and matching behavior against the upstream Vigra-based path

Status:

- still useful for matcher investigations
- also oracle/debug-only, not production code

## Debug Dump Plumbing

There is also debug-only dumping wired into the live stacker/fuser through:

- `--dump-masks-dir`

This can emit:

- raw masks
- normalized masks
- union-support images
- mask sums
- weighted contributions
- and, in some debug builds/branches, pyramid-level intermediates

Use it sparingly:

- it is very useful for visual diagnosis
- it is also very expensive on large stacks
- output belongs in local scratch space, not in Git

## What Still Matters Most

For current maintenance work, the most important probes are:

- `probe-live`
- `probe-remap`
- `probe-fuse-masks`
- `probe-zig`
- `probe-upstream`

Those are the ones most tied to the current align/remap/fusion parity and performance story.

## Local Output Hygiene

Probe and review artifacts are intentionally treated as local outputs. Common scratch roots are:

- `review_outputs/`
- `bench_outputs*/`
- `tmp_mask_probe_out/`

These are ignored in Git so the repo can stay clean while still supporting heavy visual/perf iteration.
