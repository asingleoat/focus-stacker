Source: `S003/S003_0001.jpg` through `S003/S003_0010.jpg`

Derivation:
- Downsampled with `magick ... -resize 768x -strip`

Purpose:
- This fixture is for profiling and throughput work, especially around multi-frame matching, optimization, and future parallelism.
- It is intentionally separate from the `tests/golden/` suite so routine `zig build test` stays fast.

Representative commands:

```sh
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build -Doptimize=ReleaseFast -Dfunction-timing=true run -- \
  -m -p /tmp/s003_stack10_768.pto \
  tests/perf/s003_stack10_768/0001.jpg \
  tests/perf/s003_stack10_768/0002.jpg \
  tests/perf/s003_stack10_768/0003.jpg \
  tests/perf/s003_stack10_768/0004.jpg \
  tests/perf/s003_stack10_768/0005.jpg \
  tests/perf/s003_stack10_768/0006.jpg \
  tests/perf/s003_stack10_768/0007.jpg \
  tests/perf/s003_stack10_768/0008.jpg \
  tests/perf/s003_stack10_768/0009.jpg \
  tests/perf/s003_stack10_768/0010.jpg
```

Current baseline:
- the current port runs through sequence planning and full pairwise matching cleanly on this fixture
- a PTO-only `-m` run is still optimizer-bound enough to hit a `300s` timeout in the current implementation
- that makes this fixture a good target for future solver and parallelism work
