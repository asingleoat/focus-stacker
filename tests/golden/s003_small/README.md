Source: `S003/S003_0001.jpg` through `S003/S003_0003.jpg`

Derivation:
- Downsampled with `magick ... -resize 768x -strip`
- `upstream_pair_m.pto` generated with `align_image_stack -m -p ... 0001.jpg 0002.jpg`
- `port_pair_m.pto` generated with `zig build -Doptimize=ReleaseFast run -- -m -p ... 0001.jpg 0002.jpg`
- `port3_000{0,1,2}.tif` generated with `zig build -Doptimize=ReleaseFast run -- -m -a ... 0001.jpg 0002.jpg 0003.jpg`

Purpose:
- `port_pair_m.pto` is the strict matcher/optimizer golden for the two-frame magnification-aware path.
- `upstream_pair_m.pto` is the looser parity reference against upstream Hugin behavior.
- `port3_000*.tif` are the end-to-end remap goldens for regression testing.
