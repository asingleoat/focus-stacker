const std = @import("std");
const core = @import("align_stack_core");
const image_io = core.image_io;
const profiler = core.profiler;

pub const ScalarLevel = struct {
    width: u32,
    height: u32,
    pixels: []f32,

    pub fn deinit(self: *ScalarLevel, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const RgbLevel = struct {
    width: u32,
    height: u32,
    pixels: []f32,

    pub fn deinit(self: *RgbLevel, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const Accumulator = struct {
    levels: []RgbLevel,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) std.mem.Allocator.Error!Accumulator {
        const level_count = computeLevelCount(width, height);
        const levels = try allocator.alloc(RgbLevel, level_count);
        errdefer allocator.free(levels);

        var w = width;
        var h = height;
        var initialized: usize = 0;
        errdefer {
            for (levels[0..initialized]) |*level| level.deinit(allocator);
        }
        for (levels, 0..) |*level, i| {
            const count = @as(usize, w) * @as(usize, h) * 3;
            level.* = .{
                .width = w,
                .height = h,
                .pixels = try allocator.alloc(f32, count),
            };
            @memset(level.pixels, 0);
            initialized = i + 1;
            if (w == 1 and h == 1) break;
            w = nextLevelSize(w);
            h = nextLevelSize(h);
        }
        return .{ .levels = levels };
    }

    pub fn deinit(self: *Accumulator, allocator: std.mem.Allocator) void {
        for (self.levels) |*level| level.deinit(allocator);
        allocator.free(self.levels);
    }
};

pub fn computeLevelCount(width: u32, height: u32) usize {
    var levels: usize = 1;
    var w = width;
    var h = height;
    while (w > 1 or h > 1) : (levels += 1) {
        w = nextLevelSize(w);
        h = nextLevelSize(h);
    }
    return levels;
}

pub fn nextLevelSize(value: u32) u32 {
    return if (value > 1) (value + 1) / 2 else 1;
}

pub fn accumulateImage(
    allocator: std.mem.Allocator,
    image: *const image_io.Image,
    normalized_mask: []const f32,
    result: *Accumulator,
) std.mem.Allocator.Error!void {
    const prof = profiler.scope("fuse.pyramid.accumulateImage");
    defer prof.end();

    const mask_levels = try buildMaskGaussianPyramid(allocator, image.info.width, image.info.height, normalized_mask, result.levels.len);
    defer deinitScalarLevels(allocator, mask_levels);

    const image_levels = try buildImageLaplacianPyramid(allocator, image, result.levels.len);
    defer deinitRgbLevels(allocator, image_levels);

    for (result.levels, image_levels, mask_levels) |*dst, src_level, mask_level| {
        const pixel_count = @as(usize, dst.width) * @as(usize, dst.height);
        for (0..pixel_count) |pixel_index| {
            const weight = mask_level.pixels[pixel_index];
            const base = pixel_index * 3;
            dst.pixels[base + 0] += src_level.pixels[base + 0] * weight;
            dst.pixels[base + 1] += src_level.pixels[base + 1] * weight;
            dst.pixels[base + 2] += src_level.pixels[base + 2] * weight;
        }
    }
}

pub fn collapseToImage(
    allocator: std.mem.Allocator,
    info: image_io.ImageInfo,
    result: *const Accumulator,
) std.mem.Allocator.Error!image_io.Image {
    const prof = profiler.scope("fuse.pyramid.collapseToImage");
    defer prof.end();

    var collapsed = try cloneRgbLevels(allocator, result.levels);
    defer deinitRgbLevels(allocator, collapsed);

    var level_index = collapsed.len;
    while (level_index > 1) {
        level_index -= 1;
        const child = collapsed[level_index];
        const parent = &collapsed[level_index - 1];
        const expanded = try allocator.alloc(f32, @as(usize, parent.width) * @as(usize, parent.height) * 3);
        defer allocator.free(expanded);
        expandRgb(parent.width, parent.height, child.width, child.height, child.pixels, expanded);
        for (parent.pixels, expanded) |*dst, value| {
            dst.* += value;
        }
    }

    var out_info = info;
    out_info.extra_channels = 0;
    const output = try allocateRgbOutput(allocator, out_info);
    const base = collapsed[0];
    switch (output.pixels) {
        .u8 => |dst| {
            for (base.pixels, 0..) |value, index| {
                dst[index] = @intFromFloat(std.math.clamp(value + 0.5, 0.0, 255.0));
            }
        },
        .u16 => |dst| {
            for (base.pixels, 0..) |value, index| {
                dst[index] = @intFromFloat(std.math.clamp(value + 0.5, 0.0, 65535.0));
            }
        },
    }
    return output;
}

pub fn normalizeWeightsInto(
    input_weights: []const f32,
    norm_weights: []const f32,
    total_images: usize,
    output: []f32,
) void {
    const prof = profiler.scope("fuse.pyramid.normalizeWeightsInto");
    defer prof.end();

    const default_weight = 1.0 / @as(f32, @floatFromInt(total_images));
    for (input_weights, norm_weights, output) |weight, norm, *dst| {
        dst.* = if (norm > 1e-12) weight / norm else default_weight;
    }
}

pub fn buildMaskGaussianPyramid(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    base_mask: []const f32,
    level_count: usize,
) std.mem.Allocator.Error![]ScalarLevel {
    const prof = profiler.scope("fuse.pyramid.buildMaskGaussianPyramid");
    defer prof.end();

    var levels = try allocator.alloc(ScalarLevel, level_count);
    errdefer allocator.free(levels);

    levels[0] = .{
        .width = width,
        .height = height,
        .pixels = try allocator.dupe(f32, base_mask),
    };
    errdefer levels[0].deinit(allocator);

    var built: usize = 1;
    errdefer {
        for (levels[1..built]) |*level| level.deinit(allocator);
    }

    while (built < level_count) : (built += 1) {
        const prev = levels[built - 1];
        const next_w = nextLevelSize(prev.width);
        const next_h = nextLevelSize(prev.height);
        const next_pixels = try allocator.alloc(f32, @as(usize, next_w) * @as(usize, next_h));
        reduceScalar(prev.width, prev.height, prev.pixels, next_w, next_h, next_pixels);
        levels[built] = .{ .width = next_w, .height = next_h, .pixels = next_pixels };
    }
    return levels;
}

pub fn buildImageLaplacianPyramid(
    allocator: std.mem.Allocator,
    image: *const image_io.Image,
    level_count: usize,
) std.mem.Allocator.Error![]RgbLevel {
    const prof = profiler.scope("fuse.pyramid.buildImageLaplacianPyramid");
    defer prof.end();

    var gaussians = try allocator.alloc(RgbLevel, level_count);
    errdefer allocator.free(gaussians);

    gaussians[0] = .{
        .width = image.info.width,
        .height = image.info.height,
        .pixels = try allocator.alloc(f32, @as(usize, image.info.width) * @as(usize, image.info.height) * 3),
    };
    errdefer gaussians[0].deinit(allocator);
    fillRgbBase(image, gaussians[0].pixels);

    var built: usize = 1;
    errdefer {
        for (gaussians[1..built]) |*level| level.deinit(allocator);
    }
    while (built < level_count) : (built += 1) {
        const prev = gaussians[built - 1];
        const next_w = nextLevelSize(prev.width);
        const next_h = nextLevelSize(prev.height);
        const next_pixels = try allocator.alloc(f32, @as(usize, next_w) * @as(usize, next_h) * 3);
        reduceRgb(prev.width, prev.height, prev.pixels, next_w, next_h, next_pixels);
        gaussians[built] = .{ .width = next_w, .height = next_h, .pixels = next_pixels };
    }

    var laps = try allocator.alloc(RgbLevel, level_count);
    errdefer allocator.free(laps);
    for (gaussians, 0..) |level, i| {
        laps[i] = .{
            .width = level.width,
            .height = level.height,
            .pixels = try allocator.alloc(f32, level.pixels.len),
        };
        @memcpy(laps[i].pixels, level.pixels);
    }
    errdefer {
        for (laps) |*level| level.deinit(allocator);
    }

    for (0..level_count - 1) |i| {
        const next = gaussians[i + 1];
        const current = gaussians[i];
        const expanded = try allocator.alloc(f32, current.pixels.len);
        defer allocator.free(expanded);
        expandRgb(current.width, current.height, next.width, next.height, next.pixels, expanded);
        for (laps[i].pixels, expanded) |*dst, value| {
            dst.* -= value;
        }
    }

    for (gaussians) |*level| level.deinit(allocator);
    allocator.free(gaussians);
    return laps;
}

fn deinitScalarLevels(allocator: std.mem.Allocator, levels: []ScalarLevel) void {
    for (levels) |*level| level.deinit(allocator);
    allocator.free(levels);
}

fn deinitRgbLevels(allocator: std.mem.Allocator, levels: []RgbLevel) void {
    for (levels) |*level| level.deinit(allocator);
    allocator.free(levels);
}

fn cloneRgbLevels(allocator: std.mem.Allocator, levels: []const RgbLevel) std.mem.Allocator.Error![]RgbLevel {
    const cloned = try allocator.alloc(RgbLevel, levels.len);
    errdefer allocator.free(cloned);
    var built: usize = 0;
    errdefer {
        for (cloned[0..built]) |*level| level.deinit(allocator);
    }
    for (levels, 0..) |level, i| {
        cloned[i] = .{
            .width = level.width,
            .height = level.height,
            .pixels = try allocator.dupe(f32, level.pixels),
        };
        built += 1;
    }
    return cloned;
}

fn fillRgbBase(image: *const image_io.Image, dst: []f32) void {
    const src_channels = @as(usize, image.info.color_channels + image.info.extra_channels);
    const pixel_count = @as(usize, image.info.width) * @as(usize, image.info.height);
    switch (image.pixels) {
        .u8 => |src| {
            for (0..pixel_count) |pixel_index| {
                const src_base = pixel_index * src_channels;
                const dst_base = pixel_index * 3;
                dst[dst_base + 0] = @as(f32, @floatFromInt(src[src_base + 0]));
                dst[dst_base + 1] = @as(f32, @floatFromInt(src[src_base + 1]));
                dst[dst_base + 2] = @as(f32, @floatFromInt(src[src_base + 2]));
            }
        },
        .u16 => |src| {
            for (0..pixel_count) |pixel_index| {
                const src_base = pixel_index * src_channels;
                const dst_base = pixel_index * 3;
                dst[dst_base + 0] = @as(f32, @floatFromInt(src[src_base + 0]));
                dst[dst_base + 1] = @as(f32, @floatFromInt(src[src_base + 1]));
                dst[dst_base + 2] = @as(f32, @floatFromInt(src[src_base + 2]));
            }
        },
    }
}

fn reduceScalar(src_w: u32, src_h: u32, src: []const f32, dst_w: u32, dst_h: u32, dst: []f32) void {
    for (0..dst_h) |dy| {
        for (0..dst_w) |dx| {
            const sx = @as(i32, @intCast(dx * 2));
            const sy = @as(i32, @intCast(dy * 2));
            dst[@as(usize, dy) * @as(usize, dst_w) + @as(usize, dx)] = sampleScalarFiveTap(src_w, src_h, src, sx, sy);
        }
    }
}

fn reduceRgb(src_w: u32, src_h: u32, src: []const f32, dst_w: u32, dst_h: u32, dst: []f32) void {
    for (0..dst_h) |dy| {
        for (0..dst_w) |dx| {
            const sx = @as(i32, @intCast(dx * 2));
            const sy = @as(i32, @intCast(dy * 2));
            const dst_base = (@as(usize, dy) * @as(usize, dst_w) + @as(usize, dx)) * 3;
            sampleRgbFiveTap(src_w, src_h, src, sx, sy, dst[dst_base .. dst_base + 3]);
        }
    }
}

fn expandRgb(dst_w: u32, dst_h: u32, src_w: u32, src_h: u32, src: []const f32, dst: []f32) void {
    const dst_width = @as(usize, dst_w);
    for (0..dst_h) |dy| {
        for (0..dst_w) |dx| {
            const dst_base = (@as(usize, dy) * dst_width + @as(usize, dx)) * 3;
            sampleExpandedRgb(src_w, src_h, src, @as(i32, @intCast(dx)), @as(i32, @intCast(dy)), dst[dst_base .. dst_base + 3]);
        }
    }
}

fn sampleScalarFiveTap(width: u32, height: u32, pixels: []const f32, center_x: i32, center_y: i32) f32 {
    var sum: f32 = 0;
    const kernel = [_]f32{ 1, 4, 6, 4, 1 };
    var ky: usize = 0;
    while (ky < 5) : (ky += 1) {
        const y = clampCoord(center_y + @as(i32, @intCast(ky)) - 2, height);
        var kx: usize = 0;
        while (kx < 5) : (kx += 1) {
            const x = clampCoord(center_x + @as(i32, @intCast(kx)) - 2, width);
            const weight = kernel[ky] * kernel[kx] / 256.0;
            sum += pixels[@as(usize, y) * @as(usize, width) + @as(usize, x)] * weight;
        }
    }
    return sum;
}

fn sampleRgbFiveTap(width: u32, height: u32, pixels: []const f32, center_x: i32, center_y: i32, out: []f32) void {
    out[0] = 0;
    out[1] = 0;
    out[2] = 0;
    const kernel = [_]f32{ 1, 4, 6, 4, 1 };
    var ky: usize = 0;
    while (ky < 5) : (ky += 1) {
        const y = clampCoord(center_y + @as(i32, @intCast(ky)) - 2, height);
        var kx: usize = 0;
        while (kx < 5) : (kx += 1) {
            const x = clampCoord(center_x + @as(i32, @intCast(kx)) - 2, width);
            const weight = kernel[ky] * kernel[kx] / 256.0;
            const base = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 3;
            out[0] += pixels[base + 0] * weight;
            out[1] += pixels[base + 1] * weight;
            out[2] += pixels[base + 2] * weight;
        }
    }
}

fn sampleExpandedRgb(src_w: u32, src_h: u32, src: []const f32, dst_x: i32, dst_y: i32, out: []f32) void {
    out[0] = 0;
    out[1] = 0;
    out[2] = 0;
    const kernel = [_]f32{ 1, 4, 6, 4, 1 };
    var ky: usize = 0;
    while (ky < 5) : (ky += 1) {
        const sample_y = dst_y + @as(i32, @intCast(ky)) - 2;
        if ((sample_y & 1) != 0) continue;
        const src_y = clampCoord(@divTrunc(sample_y, 2), src_h);
        var kx: usize = 0;
        while (kx < 5) : (kx += 1) {
            const sample_x = dst_x + @as(i32, @intCast(kx)) - 2;
            if ((sample_x & 1) != 0) continue;
            const src_x = clampCoord(@divTrunc(sample_x, 2), src_w);
            const weight = kernel[ky] * kernel[kx] / 64.0;
            const base = (@as(usize, src_y) * @as(usize, src_w) + @as(usize, src_x)) * 3;
            out[0] += src[base + 0] * weight;
            out[1] += src[base + 1] * weight;
            out[2] += src[base + 2] * weight;
        }
    }
}

fn clampCoord(coord: i32, limit: u32) u32 {
    if (coord <= 0) return 0;
    const max = @as(i32, @intCast(limit - 1));
    if (coord >= max) return @as(u32, @intCast(max));
    return @as(u32, @intCast(coord));
}

fn allocateRgbOutput(allocator: std.mem.Allocator, info: image_io.ImageInfo) std.mem.Allocator.Error!image_io.Image {
    const count = @as(usize, info.width) * @as(usize, info.height) * @as(usize, info.color_channels + info.extra_channels);
    return switch (info.sample_type) {
        .u8 => .{
            .info = info,
            .pixels = .{ .u8 = try allocator.alloc(u8, count) },
        },
        .u16 => .{
            .info = info,
            .pixels = .{ .u16 = try allocator.alloc(u16, count) },
        },
    };
}

test "normalize weights falls back when norm is zero" {
    var out = [_]f32{ 0, 0 };
    normalizeWeightsInto(&[_]f32{ 1, 2 }, &[_]f32{ 2, 0 }, 4, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), out[1], 1e-6);
}

test "five tap reduce and expand preserve uniform rgb image" {
    const allocator = std.testing.allocator;
    const src = try allocator.dupe(f32, &[_]f32{
        10, 20, 30, 10, 20, 30, 10, 20, 30, 10, 20, 30,
        10, 20, 30, 10, 20, 30, 10, 20, 30, 10, 20, 30,
        10, 20, 30, 10, 20, 30, 10, 20, 30, 10, 20, 30,
        10, 20, 30, 10, 20, 30, 10, 20, 30, 10, 20, 30,
    });
    defer allocator.free(src);
    const reduced = try allocator.alloc(f32, 2 * 2 * 3);
    defer allocator.free(reduced);
    const expanded = try allocator.alloc(f32, 4 * 4 * 3);
    defer allocator.free(expanded);
    reduceRgb(4, 4, src, 2, 2, reduced);
    expandRgb(4, 4, 2, 2, reduced, expanded);
    for (expanded, 0..) |value, index| {
        const expected = src[index];
        try std.testing.expectApproxEqAbs(expected, value, 1e-5);
    }
}
