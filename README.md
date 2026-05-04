# focus_stack

`focus_stack` is a Zig-based focus stacking pipeline with:

- pair alignment and global solve in Zig
- remap and aligned output in Zig
- multiple in-tree fusion modes in Zig
- optional fallback to external `enfuse`
- optional fetched upstream reference/oracle code for parity and debugging work

The practical end-to-end entrypoint is [scripts/stack_zig.sh](scripts/stack_zig.sh). The fastest full in-tree path is `focus_stack_zig`.

## Current State

This is no longer just a scaffold or partial port. The current codebase supports real-world focus-stack runs with:

- reduced-image feature detection and pair matching
- alternative pair-alignment strategies:
  - `hugin-ncc`
  - `phasecorr-seeded`
  - `phasecorr-locked`
- global pose optimization with a chain-structured large-stack path
- aligned remap output with support alpha
- in-tree focus fusion modes:
  - `hardmask-contrast`
  - `softmask-contrast`
  - `pyramid-contrast`
  - `hybrid-pyramid-contrast`
- memory-aware worker and cache limiting via `--memory-fraction`

The current in-tree quality baseline is `pyramid-contrast`. The hybrid mode is intentionally opt-in and exists for subject-specific sharpness experiments.

## Practical Entry Points

### `focus_stack_zig`

Align, remap, and fuse in-process without aligned-TIFF round-tripping.

Useful for:

- fastest full Zig workflow
- real benchmark runs
- in-tree fusion experiments

### `focus_fuse_zig`

Fuse an already aligned stack.

Useful for:

- fusion-only iteration
- comparing Zig fusion modes on the same aligned inputs

### `align_image_stack_zig`

Alignment/remap-oriented CLI analogous to the upstream aligner workflow.

Useful for:

- parity work
- PTO/remap investigation
- external `enfuse` workflows

### `scripts/stack_zig.sh`

The easiest real-world driver.

It can:

- accept image lists or manifest JSON files
- run the full Zig stacker
- or run Zig alignment plus external `enfuse`
- emit TIFF and JPEG outputs

## Optional Upstream References

Normal Zig build, test, and run workflows do not require a local `upstream/`
tree.

Populate the optional upstream reference snapshots only when you need:

- `probe-upstream`
- the upstream oracle tools in `tools/`
- source archaeology against the pinned Hugin / Enblend / libpano13 snapshots

Fetch them with:

```sh
./scripts/fetch_upstream_refs.sh
```

The pinned source definitions live in:

- `third_party/upstream-snapshots.lock`

## Quick Start

Build and test:

```sh
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build -Doptimize=ReleaseFast
```

Show CLI help:

```sh
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run -- -h
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run-fuse -- --help
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run-stack -- --help
```

Run the practical wrapper:

```sh
./scripts/stack_zig.sh --threads 32 --memory-fraction 0.5 path/to/images/*.jpg
```

Run the full in-tree stacker directly:

```sh
./zig-out/bin/focus_stack_zig \
  --threads 32 \
  --memory-fraction 0.5 \
  --pair-align phasecorr-locked \
  --fuse-method pyramid-contrast \
  -c 24 -g 4 -t 5 \
  -o out.tif \
  path/to/images/*.jpg
```

Use the sharpened hybrid fusion mode explicitly:

```sh
./scripts/stack_zig.sh \
  --fuse-method zig-hybrid-pyramid-contrast \
  --hybrid-sharpness 0.35 \
  path/to/images/*.jpg
```

## Defaults And Recommendations

Current defaults:

- `scripts/stack_zig.sh` defaults to `zig-pyramid-contrast`
- direct Zig binaries default to `pyramid-contrast`
- `enfuse` remains available as the external reference path
- `hybrid-pyramid-contrast` is experimental and should be selected explicitly

Recommended starting points:

- full Zig quality run:
  - `--pair-align phasecorr-locked --fuse-method pyramid-contrast`
- external reference-quality comparison:
  - `scripts/stack_zig.sh --fuse-method enfuse`
- hybrid sharpness exploration:
  - `--fuse-method hybrid-pyramid-contrast --hybrid-sharpness 0.20`
  - `--fuse-method hybrid-pyramid-contrast --hybrid-sharpness 0.35`

## Performance Snapshot

Representative recent results on a real full-resolution focus-stack corpus:

- full 143-image stack of `7952x5304` JPEGs, full Zig path:
  - about `162s`
- same full 143-image `7952x5304` stack, upstream align + `enfuse`:
  - upstream aligner did not finish within `16+` minutes on the same configuration
- 30-image slice from the same `7952x5304` corpus:
  - full Zig path: about `29.6s`
  - full upstream path: about `121.7s`

These numbers are not a formal benchmark suite, but they reflect the current practical state of the codebase well: the Zig path is already competitive on medium stacks and dramatically faster on large stacks because of the chain-structured optimizer path.

## Fusion Modes

See [docs/fusion-modes.md](docs/fusion-modes.md) for the full current fusion-mode map.

Short version:

- `hardmask-contrast`
  - fastest
  - sharp
  - more seam/winner artifacts
- `softmask-contrast`
  - mostly a comparison/debug mode now
- `pyramid-contrast`
  - best current in-tree quality baseline
  - visually reviewed against `enfuse`
- `hybrid-pyramid-contrast`
  - opt-in tuning mode
  - tries to trade some pyramid softness for added sharpness

## Probes And Oracles

This repo has an intentionally rich parity/debug surface.

Useful build targets:

```sh
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-zig -- <args...>
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-upstream -- <args...>
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-match -- <args...>
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-live -- <args...>
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-remap -- <args...>
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build probe-fuse-masks -- <args...>
```

Use [docs/probes.md](docs/probes.md) for the short “which tool is for what” map.

## Reference Checkpoints

Two tags are especially useful when checking regressions:

- `reference-checkpoint`
  - visually reviewed checkpoint after the upstream-style no-wrap pyramid expand fix
- `visually-inspected-checkpoint`
  - earlier full-stack visual checkpoint

Local review artifacts are typically written under `review_outputs/`, which is intentionally ignored by Git.

## Repository Layout

- `src/`
  - main Zig implementation
- `scripts/`
  - practical workflow wrappers
- `docs/`
  - fusion, probe, and port/reference notes
- `tools/`
  - oracle/reference tooling, not product-path code
- `upstream/`
  - optional fetched upstream reference snapshots, not committed product code
- `vendor/smooth-numbers/`
  - separately versioned helper submodule, now pinned to its public GitHub remote
- `tests/golden/`
  - small correctness fixtures
- `tests/perf/`
  - profiling fixtures

## Licensing

This is a mixed-license repo.

See:

- [LICENSE](LICENSE)
- [COPYING](COPYING)
- [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)

Current structure:

- project-authored Zig/product/support code: GPL-3.0-only
- oracle/reference tooling under `tools/`: separate GPL-3.0-only bucket
- fetched third-party code under `upstream/`: retains upstream licensing

## Notes

- If Zig’s shared cache is noisy in your environment, use `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache`.
- Probe and review outputs are treated as local scratch data and are ignored by Git.
- `smooth-numbers` is a real submodule, so fresh clones should use:

```sh
git clone --recurse-submodules <repo-url>
```
