**Goal**
Port `enfuse` into this repository as a cleanly separated Zig fusion subsystem that:
- can be called from the focus-stack workflow for end-to-end benchmarking
- stays modular enough to become a small standalone `enfuse`-like tool later
- follows upstream `enfuse` semantics closely before we diverge for performance

**Current Why**
On the practical 10-frame full-resolution `S004_0020..0029` workflow:
- align/remap: about `9290 ms`
- `enfuse`: about `27774 ms`
- preview JPEG: about `1716 ms`

`enfuse` is now the dominant wall-clock cost.

**Current Port Status**
Implemented in-tree:
- [src/fuse/main.zig](/home/tim/code/focus_stack/src/fuse/main.zig)
- [src/fuse/pipeline.zig](/home/tim/code/focus_stack/src/fuse/pipeline.zig)
- [src/fuse/contrast.zig](/home/tim/code/focus_stack/src/fuse/contrast.zig)
- [src/fuse/blend.zig](/home/tim/code/focus_stack/src/fuse/blend.zig)
- [scripts/stack_zig.sh](/home/tim/code/focus_stack/scripts/stack_zig.sh) `--fuse-method`

Current Zig fusion method:
- `hardmask-contrast`
- ports the upstream local-contrast weight idea from `enfuse.h`
- uses hard-mask winner selection
- does not yet port the Gaussian/Laplacian pyramid path

Current alternate Zig fusion method:
- `softmask-contrast`
- keeps the same local-contrast weighting
- multiplies in the remap support mask
- applies a separable 5-tap Burt-Adelson-style blur to the masks before blending
- still stops short of a full Gaussian-mask / Laplacian-image pyramid port

On the same clean aligned 10-frame full-resolution `S004_0020..0029` stack:
- external `enfuse`: about `27849 ms`
- `focus_fuse_zig --method hardmask-contrast --threads 32`: about `2611 ms`
- normalized RMSE vs external `enfuse` output: about `0.02305`
- `focus_fuse_zig --method softmask-contrast --threads 32`: about `3601 ms`
- normalized RMSE vs external `enfuse` output: about `0.00589`

**Upstream Snapshot**
Vendored reference source:
- [upstream/enblend-enfuse-4.3-8243911d8684/src/enfuse.cc](/home/tim/code/focus_stack/upstream/enblend-enfuse-4.3-8243911d8684/src/enfuse.cc)
- [upstream/enblend-enfuse-4.3-8243911d8684/src/enfuse.h](/home/tim/code/focus_stack/upstream/enblend-enfuse-4.3-8243911d8684/src/enfuse.h)
- [upstream/enblend-enfuse-4.3-8243911d8684/src/blend.h](/home/tim/code/focus_stack/upstream/enblend-enfuse-4.3-8243911d8684/src/blend.h)
- [upstream/enblend-enfuse-4.3-8243911d8684/src/pyramid.h](/home/tim/code/focus_stack/upstream/enblend-enfuse-4.3-8243911d8684/src/pyramid.h)
- [upstream/enblend-enfuse-4.3-8243911d8684/src/assemble.h](/home/tim/code/focus_stack/upstream/enblend-enfuse-4.3-8243911d8684/src/assemble.h)
- [upstream/enblend-enfuse-4.3-8243911d8684/src/exposure_weight.h](/home/tim/code/focus_stack/upstream/enblend-enfuse-4.3-8243911d8684/src/exposure_weight.h)
- [upstream/enblend-enfuse-4.3-8243911d8684/src/exposure_weight.cc](/home/tim/code/focus_stack/upstream/enblend-enfuse-4.3-8243911d8684/src/exposure_weight.cc)

Reference docs:
- [upstream/enblend-enfuse-4.3-8243911d8684/doc/enfuse-overview.tex](/home/tim/code/focus_stack/upstream/enblend-enfuse-4.3-8243911d8684/doc/enfuse-overview.tex)
- [upstream/enblend-enfuse-4.3-8243911d8684/doc/focus-stack-decision-tree.dot](/home/tim/code/focus_stack/upstream/enblend-enfuse-4.3-8243911d8684/doc/focus-stack-decision-tree.dot)

Observed binary in this environment:
- `enfuse 4.3-8243911d8684`

**What Upstream Actually Does**
High level:
1. parse CLI and global weighting configuration in `enfuse.cc`
2. load and optionally assemble non-overlapping inputs in `assemble.h`
3. compute per-image weight maps from one or more criteria:
   - exposure
   - saturation
   - local contrast
   - local entropy
4. optionally save/load soft and hard masks
5. build Gaussian mask pyramids and Laplacian image pyramids via `pyramid.h`
6. blend pyramid levels via `blend.h`
7. collapse the result pyramid and write output

Focus-stack relevant defaults in this environment:
- exposure weight default upstream is `1.0`
- saturation default upstream is `0.0`
- contrast default upstream is `0.0`
- our script explicitly uses:
  - exposure weight `0`
  - saturation weight `0`
  - contrast weight `1`
  - `--hard-mask`
  - contrast window size `5`

That means our practical focus-stack path is much narrower than general `enfuse`.

**Most Relevant Upstream Pieces For Focus Stacking**
- `enfuse.cc`
  - CLI/options
  - top-level pipeline orchestration
  - layer ordering / selection hooks
- `enfuse.h`
  - local contrast / entropy machinery
  - exposure, saturation, contrast, entropy functors
  - focus-stack-relevant weight-map generation logic
  - hard/soft mask handling
- `pyramid.h`
  - Gaussian pyramid construction
  - Laplacian pyramid construction
  - collapse path
- `blend.h`
  - per-level pyramid blending against mask pyramids
- `assemble.h`
  - pre-fusion coalescing of non-overlapping images

For a first Zig focus-stack port, `assemble.h` is optional.
Our aligned stack outputs overlap strongly and are already consistently ordered.

**Recommended Zig Module Split**
Proposed new subtree:
- `src/fuse/config.zig`
  - fusion options and defaults
- `src/fuse/io.zig`
  - stack input loading and metadata checks
- `src/fuse/contrast.zig`
  - local contrast path from `enfuse.h`
- `src/fuse/blend.zig`
  - initial hard-mask winner application and later per-level blending from `blend.h`
- `src/fuse/entropy.zig`
  - local entropy path from `enfuse.h`
- `src/fuse/exposure.zig`
  - exposure weight functions from `exposure_weight.*`
- `src/fuse/masks.zig`
  - hard/soft mask generation and normalization
- `src/fuse/pyramid.zig`
  - Gaussian/Laplacian pyramid construction and collapse
- `src/fuse/pipeline.zig`
  - end-to-end fusion orchestration
- `src/fuse/main.zig`
  - standalone lite `enfuse` entrypoint later

Integration points in existing app:
- `scripts/stack_zig.sh`
  - switchable fuse method
- future `src/fuse_probe.zig`
  - benchmark harness like `remap_probe`

**Implementation Order**
1. Build a switchable fusion surface
   - keep external `enfuse` baseline
   - add placeholder `zig-focus`

2. Implement the narrow real-world path first
   - aligned TIFF inputs only
   - same size / same crop
   - weight recipe equivalent to current script:
     - exposure `0`
     - saturation `0`
     - contrast `1`
     - hard-mask mode

3. Port upstream local contrast weighting
   - start from the `ContrastFunctor` and local-contrast path in `enfuse.h`
   - match `--contrast-window-size=5`

4. Port upstream hard-mask selection semantics
   - this matters for focus stacking quality and seam behavior

5. Port the pyramid path
   - Gaussian mask pyramid
   - Laplacian image pyramid
   - blend and collapse

6. Benchmark against external `enfuse`
   - same aligned TIFF stack
   - compare wall time
   - compare visual output

**Important Constraint**
Do not start with a generic “exposure fusion engine.”
Start with the exact focus-stack path we actually use today.

That means first target parity with:
```text
enfuse
  --exposure-weight=0
  --saturation-weight=0
  --contrast-weight=1
  --contrast-window-size=5
  --hard-mask
```

**Immediate Next Slice**
Implement:
- `src/fuse/config.zig`
- `src/fuse/weights.zig`
- `src/fuse/contrast.zig`
- `src/fuse/pyramid.zig`
- `src/fuse/blend.zig`

And wire a benchmark-only CLI surface:
- `zig build run -- --fuse-method=zig-focus ...`
or
- `zig build probe-fuse -- <aligned stack>`

The first goal was not standalone polish.
The first goal was to reproduce the current focus-stack fusion recipe in-tree with a measurable A/B against external `enfuse`.

That first goal is now partially met:
- there is a fast standalone Zig fusion binary
- it is already wired into the practical stack script
- the soft-mask checkpoint confirms that mask softness is a major part of the remaining visual delta
- the next fidelity target is still the pyramid path, not more CLI work
