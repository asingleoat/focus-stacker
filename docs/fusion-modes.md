# Fusion Modes

This repository currently has two end-to-end focus-stack fusion families:

- external `enfuse`
- in-tree Zig fusion modes under `focus_fuse_zig` and `focus_stack_zig`

The current recommendation is:

- use `enfuse` when you want the most established baseline
- use `pyramid-contrast` when you want the best current in-tree quality baseline
- use `hybrid-pyramid-contrast` only when you are explicitly exploring a sharper variant

## CLI Surface

Direct Zig binaries:

- `focus_fuse_zig --method hardmask-contrast`
- `focus_fuse_zig --method softmask-contrast`
- `focus_fuse_zig --method pyramid-contrast`
- `focus_fuse_zig --method hybrid-pyramid-contrast --hybrid-sharpness 0.35`

- `focus_stack_zig --fuse-method hardmask-contrast`
- `focus_stack_zig --fuse-method softmask-contrast`
- `focus_stack_zig --fuse-method pyramid-contrast`
- `focus_stack_zig --fuse-method hybrid-pyramid-contrast --hybrid-sharpness 0.35`

Script wrapper:

- `./scripts/stack_zig.sh --fuse-method enfuse`
- `./scripts/stack_zig.sh --fuse-method zig-hardmask-contrast`
- `./scripts/stack_zig.sh --fuse-method zig-softmask-contrast`
- `./scripts/stack_zig.sh --fuse-method zig-pyramid-contrast`
- `./scripts/stack_zig.sh --fuse-method zig-hybrid-pyramid-contrast --hybrid-sharpness 0.35`

Environment overrides:

- `ALIGN_FUSE_METHOD`
- `ALIGN_HYBRID_SHARPNESS`

## Modes

### `hardmask-contrast`

Behavior:

- pure contrast-weight winner selection
- no multiresolution blending

Strengths:

- fastest in-tree mode
- tends to preserve very crisp local detail
- avoids some soft halo behavior because each pixel comes from one frame

Weaknesses:

- more prone to seam-like and winner-selection artifacts
- can look unnatural on difficult subjects

When to use:

- quick sharpness-biased experiments
- subjects where hard transitions are acceptable

### `softmask-contrast`

Behavior:

- contrast weights with a blurred support-aware mask
- single-scale weighted blend

Strengths:

- simple and robust
- useful as an intermediate reference

Weaknesses:

- generally dominated by `pyramid-contrast` for serious quality work
- can introduce translucent ghosting

When to use:

- debugging or comparison
- not the primary recommended mode

### `pyramid-contrast`

Behavior:

- multiresolution Gaussian-mask / Laplacian-image blend
- current in-tree quality baseline
- includes the no-wrap expand fix that removed the earlier horizontal banding artifact

Strengths:

- best current in-tree visual baseline
- close to `enfuse` behavior on real stacks
- artifact-resistant relative to hardmask

Weaknesses:

- can still look slightly softer or bloomier than desirable on some subjects
- slower than hardmask

When to use:

- default in-tree quality mode
- quality benchmarking against `enfuse`

### `hybrid-pyramid-contrast`

Behavior:

- starts from the pyramid baseline
- injects some hardmask contribution into a band of mid pyramid levels
- controlled by `--hybrid-sharpness` in `[0, 1]`

Current implementation:

- hard contribution begins at mid pyramid levels, not the finest or coarsest levels
- default sharpness is `0.35`

Strengths:

- can reduce some broad low-frequency bloom relative to pure pyramid
- offers a useful quality/sharpness exploration knob

Weaknesses:

- still experimental
- can reintroduce some hardmask-style artifacts if pushed too far
- there is no single known-best sharpness value yet

When to use:

- exploratory real-world comparisons
- subject-specific tuning where `pyramid-contrast` feels too soft but `hardmask-contrast` is too harsh

Recommended starting points:

- `0.20`: subtle
- `0.35`: current tuned default
- `0.50`: stronger effect, more risk of hardmask artifacts

## Current Default Story

There are intentionally different defaults in different entrypoints:

- `scripts/stack_zig.sh` defaults to `enfuse`
- direct Zig binaries still default to `hardmask-contrast`
- `pyramid-contrast` is the best current in-tree quality recommendation

This is deliberate but easy to forget. If you care about quality comparisons inside Zig, pass the fusion mode explicitly.

## Quality Checkpoints

Reference quality checkpoints currently used in the repo workflow:

- `reference-checkpoint`: fixed the earlier pyramid horizontal banding issue
- `visually-inspected-checkpoint`: earlier visually verified full-stack checkpoint

Representative reviewed outputs are typically written under local `review_outputs/`, which is intentionally ignored by Git.
