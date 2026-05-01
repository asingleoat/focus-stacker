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

pub const Workspace = struct {
    mask_levels: []ScalarLevel,
    gaussian_levels: []RgbLevel,
    expanded_levels: []RgbLevel,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) std.mem.Allocator.Error!Workspace {
        const level_count = computeLevelCount(width, height);
        const mask_levels = try allocator.alloc(ScalarLevel, level_count);
        errdefer allocator.free(mask_levels);
        const gaussian_levels = try allocator.alloc(RgbLevel, level_count);
        errdefer allocator.free(gaussian_levels);
        const expanded_levels = try allocator.alloc(RgbLevel, level_count - 1);
        errdefer allocator.free(expanded_levels);

        var w = width;
        var h = height;
        var built_masks: usize = 0;
        var built_gaussians: usize = 0;
        var built_expanded: usize = 0;
        errdefer {
            for (mask_levels[0..built_masks]) |*level| level.deinit(allocator);
            for (gaussian_levels[0..built_gaussians]) |*level| level.deinit(allocator);
            for (expanded_levels[0..built_expanded]) |*level| level.deinit(allocator);
        }

        for (0..level_count) |i| {
            const mask_count = @as(usize, w) * @as(usize, h);
            const rgb_count = mask_count * 3;
            mask_levels[i] = .{
                .width = w,
                .height = h,
                .pixels = try allocator.alloc(f32, mask_count),
            };
            built_masks += 1;
            gaussian_levels[i] = .{
                .width = w,
                .height = h,
                .pixels = try allocator.alloc(f32, rgb_count),
            };
            built_gaussians += 1;
            if (i + 1 < level_count) {
                expanded_levels[i] = .{
                    .width = w,
                    .height = h,
                    .pixels = try allocator.alloc(f32, rgb_count),
                };
                built_expanded += 1;
            }
            if (w == 1 and h == 1) break;
            w = nextLevelSize(w);
            h = nextLevelSize(h);
        }

        return .{
            .mask_levels = mask_levels,
            .gaussian_levels = gaussian_levels,
            .expanded_levels = expanded_levels,
        };
    }

    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        deinitScalarLevels(allocator, self.mask_levels);
        deinitRgbLevels(allocator, self.gaussian_levels);
        deinitRgbLevels(allocator, self.expanded_levels);
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
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    var workspace = try Workspace.init(allocator, image.info.width, image.info.height);
    defer workspace.deinit(allocator);
    return accumulateImageWithWorkspace(allocator, image, normalized_mask, result, &workspace, 1);
}

pub fn accumulateImageWithWorkspace(
    allocator: std.mem.Allocator,
    image: *const image_io.Image,
    normalized_mask: []const f32,
    result: *Accumulator,
    workspace: *Workspace,
    jobs: usize,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    const prof = profiler.scope("fuse.pyramid.accumulateImage");
    defer prof.end();

    try buildMaskGaussianPyramidInto(allocator, normalized_mask, workspace.mask_levels, jobs);
    try buildAndAccumulateImagePyramidInto(allocator, image, workspace.gaussian_levels, workspace.expanded_levels, workspace.mask_levels, result.levels, jobs);
}

pub fn collapseToImage(
    allocator: std.mem.Allocator,
    info: image_io.ImageInfo,
    result: *const Accumulator,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!image_io.Image {
    return collapseToImageWithJobs(allocator, info, result, 1);
}

pub fn collapseToImageWithJobs(
    allocator: std.mem.Allocator,
    info: image_io.ImageInfo,
    result: *const Accumulator,
    jobs: usize,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!image_io.Image {
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
        try expandRgb(allocator, parent.width, parent.height, child.width, child.height, child.pixels, expanded, jobs);
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
) (std.mem.Allocator.Error || std.Thread.SpawnError)![]ScalarLevel {
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
        try reduceScalar(allocator, prev.width, prev.height, prev.pixels, next_w, next_h, next_pixels, 1);
        levels[built] = .{ .width = next_w, .height = next_h, .pixels = next_pixels };
    }
    return levels;
}

fn buildMaskGaussianPyramidInto(
    allocator: std.mem.Allocator,
    base_mask: []const f32,
    levels: []ScalarLevel,
    jobs: usize,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    const prof = profiler.scope("fuse.pyramid.buildMaskGaussianPyramidInto");
    defer prof.end();

    @memcpy(levels[0].pixels, base_mask);
    var built: usize = 1;
    while (built < levels.len) : (built += 1) {
        const prev = levels[built - 1];
        const next = levels[built];
        try reduceScalar(allocator, prev.width, prev.height, prev.pixels, next.width, next.height, next.pixels, jobs);
    }
}

pub fn buildImageLaplacianPyramid(
    allocator: std.mem.Allocator,
    image: *const image_io.Image,
    level_count: usize,
) (std.mem.Allocator.Error || std.Thread.SpawnError)![]RgbLevel {
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
        try reduceRgb(allocator, prev.width, prev.height, prev.pixels, next_w, next_h, next_pixels, 1);
        gaussians[built] = .{ .width = next_w, .height = next_h, .pixels = next_pixels };
    }

    var laps = try allocator.alloc(RgbLevel, level_count);
    errdefer allocator.free(laps);
    var lap_built: usize = 0;
    errdefer {
        for (laps[0..lap_built]) |*level| level.deinit(allocator);
    }

    for (0..level_count - 1) |i| {
        const current = gaussians[i];
        const next = gaussians[i + 1];
        const lap_pixels = try allocator.alloc(f32, current.pixels.len);
        errdefer allocator.free(lap_pixels);
        const expanded = try allocator.alloc(f32, current.pixels.len);
        defer allocator.free(expanded);
        try expandRgb(allocator, current.width, current.height, next.width, next.height, next.pixels, expanded, 1);
        for (lap_pixels, current.pixels, expanded) |*dst, base_value, expanded_value| {
            dst.* = base_value - expanded_value;
        }
        laps[i] = .{
            .width = current.width,
            .height = current.height,
            .pixels = lap_pixels,
        };
        lap_built += 1;
    }

    const last = gaussians[level_count - 1];
    laps[level_count - 1] = .{
        .width = last.width,
        .height = last.height,
        .pixels = try allocator.dupe(f32, last.pixels),
    };
    lap_built += 1;

    for (gaussians) |*level| level.deinit(allocator);
    allocator.free(gaussians);
    return laps;
}

fn buildAndAccumulateImagePyramidInto(
    allocator: std.mem.Allocator,
    image: *const image_io.Image,
    gaussians: []RgbLevel,
    expanded_levels: []RgbLevel,
    masks: []const ScalarLevel,
    dst_levels: []RgbLevel,
    jobs: usize,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    const prof = profiler.scope("fuse.pyramid.buildImageLaplacianPyramidInto");
    defer prof.end();

    fillRgbBase(image, gaussians[0].pixels);
    var built: usize = 1;
    while (built < gaussians.len) : (built += 1) {
        const prev = gaussians[built - 1];
        const next = gaussians[built];
        try reduceRgb(allocator, prev.width, prev.height, prev.pixels, next.width, next.height, next.pixels, jobs);
    }

    const blend_prof = profiler.scope("fuse.pyramid.accumulateLevels");
    defer blend_prof.end();

    for (0..gaussians.len - 1) |i| {
        const current = gaussians[i];
        const next = gaussians[i + 1];
        const expanded = expanded_levels[i];
        const mask_level = masks[i];
        const dst_level = &dst_levels[i];
        try expandRgb(allocator, current.width, current.height, next.width, next.height, next.pixels, expanded.pixels, jobs);
        const pixel_count = @as(usize, current.width) * @as(usize, current.height);
        for (0..pixel_count) |pixel_index| {
            const weight = mask_level.pixels[pixel_index];
            const base = pixel_index * 3;
            const lap0: f32 = current.pixels[base + 0] - expanded.pixels[base + 0];
            const lap1: f32 = current.pixels[base + 1] - expanded.pixels[base + 1];
            const lap2: f32 = current.pixels[base + 2] - expanded.pixels[base + 2];
            dst_level.pixels[base + 0] += lap0 * weight;
            dst_level.pixels[base + 1] += lap1 * weight;
            dst_level.pixels[base + 2] += lap2 * weight;
        }
    }

    const last_index = gaussians.len - 1;
    const last_gaussian = gaussians[last_index];
    const last_mask = masks[last_index];
    const last_dst = &dst_levels[last_index];
    const last_pixel_count = @as(usize, last_gaussian.width) * @as(usize, last_gaussian.height);
    for (0..last_pixel_count) |pixel_index| {
        const weight = last_mask.pixels[pixel_index];
        const base = pixel_index * 3;
        last_dst.pixels[base + 0] += last_gaussian.pixels[base + 0] * weight;
        last_dst.pixels[base + 1] += last_gaussian.pixels[base + 1] * weight;
        last_dst.pixels[base + 2] += last_gaussian.pixels[base + 2] * weight;
    }
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

fn reduceScalar(
    allocator: std.mem.Allocator,
    src_w: u32,
    src_h: u32,
    src: []const f32,
    dst_w: u32,
    dst_h: u32,
    dst: []f32,
    jobs: usize,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    const worker_count = effectiveWorkerCount(jobs, dst_h);
    if (worker_count == 1) {
        const storage = try allocator.alloc(f32, 5 * @as(usize, dst_w));
        defer allocator.free(storage);
        reduceScalarRowsSequential(src_w, src_h, src, dst_w, dst_h, dst, 0, dst_h, storage);
        return;
    }
    const row_storage_len = 5 * @as(usize, dst_w);
    const storage = try allocator.alloc(f32, row_storage_len * worker_count);
    defer allocator.free(storage);
    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);
    var tasks = try allocator.alloc(ReduceScalarTask, worker_count - 1);
    defer allocator.free(tasks);
    const rows_per_worker = std.math.divCeil(usize, @as(usize, dst_h), worker_count) catch unreachable;
    var started_threads: usize = 0;
    errdefer for (threads[0..started_threads]) |thread| thread.join();
    for (threads, 0..) |*thread, i| {
        const start_row = @min((i + 1) * rows_per_worker, @as(usize, dst_h));
        const end_row = @min((i + 2) * rows_per_worker, @as(usize, dst_h));
        tasks[i] = .{
            .src_w = src_w,
            .src_h = src_h,
            .src = src,
            .dst_w = dst_w,
            .dst_h = dst_h,
            .dst = dst,
            .start_row = @as(u32, @intCast(start_row)),
            .end_row = @as(u32, @intCast(end_row)),
            .storage = storage[(i + 1) * row_storage_len .. (i + 2) * row_storage_len],
        };
        thread.* = try std.Thread.spawn(.{}, reduceScalarThread, .{&tasks[i]});
        started_threads += 1;
    }
    reduceScalarRowsSequential(
        src_w,
        src_h,
        src,
        dst_w,
        dst_h,
        dst,
        0,
        @as(u32, @intCast(@min(rows_per_worker, @as(usize, dst_h)))),
        storage[0..row_storage_len],
    );
    for (threads) |thread| thread.join();
}

fn reduceRgb(
    allocator: std.mem.Allocator,
    src_w: u32,
    src_h: u32,
    src: []const f32,
    dst_w: u32,
    dst_h: u32,
    dst: []f32,
    jobs: usize,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    const worker_count = effectiveWorkerCount(jobs, dst_h);
    if (worker_count == 1) {
        const storage = try allocator.alloc(f32, 5 * @as(usize, dst_w) * 3);
        defer allocator.free(storage);
        reduceRgbRowsSequential(src_w, src_h, src, dst_w, dst_h, dst, 0, dst_h, storage);
        return;
    }
    const row_storage_len = 5 * @as(usize, dst_w) * 3;
    const storage = try allocator.alloc(f32, row_storage_len * worker_count);
    defer allocator.free(storage);
    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);
    var tasks = try allocator.alloc(ReduceRgbTask, worker_count - 1);
    defer allocator.free(tasks);
    const rows_per_worker = std.math.divCeil(usize, @as(usize, dst_h), worker_count) catch unreachable;
    var started_threads: usize = 0;
    errdefer for (threads[0..started_threads]) |thread| thread.join();
    for (threads, 0..) |*thread, i| {
        const start_row = @min((i + 1) * rows_per_worker, @as(usize, dst_h));
        const end_row = @min((i + 2) * rows_per_worker, @as(usize, dst_h));
        tasks[i] = .{
            .src_w = src_w,
            .src_h = src_h,
            .src = src,
            .dst_w = dst_w,
            .dst_h = dst_h,
            .dst = dst,
            .start_row = @as(u32, @intCast(start_row)),
            .end_row = @as(u32, @intCast(end_row)),
            .storage = storage[(i + 1) * row_storage_len .. (i + 2) * row_storage_len],
        };
        thread.* = try std.Thread.spawn(.{}, reduceRgbThread, .{&tasks[i]});
        started_threads += 1;
    }
    reduceRgbRowsSequential(
        src_w,
        src_h,
        src,
        dst_w,
        dst_h,
        dst,
        0,
        @as(u32, @intCast(@min(rows_per_worker, @as(usize, dst_h)))),
        storage[0..row_storage_len],
    );
    for (threads) |thread| thread.join();
}

fn expandRgb(
    allocator: std.mem.Allocator,
    dst_w: u32,
    dst_h: u32,
    src_w: u32,
    src_h: u32,
    src: []const f32,
    dst: []f32,
    jobs: usize,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    const worker_count = effectiveWorkerCount(jobs, dst_h);
    if (worker_count == 1) {
        const storage = try allocator.alloc(f32, 4 * @as(usize, dst_w) * 3);
        defer allocator.free(storage);
        expandRgbRowsSequential(dst_w, dst_h, src_w, src_h, src, dst, 0, dst_h, storage);
        return;
    }
    const row_storage_len = 4 * @as(usize, dst_w) * 3;
    const storage = try allocator.alloc(f32, row_storage_len * worker_count);
    defer allocator.free(storage);
    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);
    var tasks = try allocator.alloc(ExpandRgbTask, worker_count - 1);
    defer allocator.free(tasks);
    const rows_per_worker = std.math.divCeil(usize, @as(usize, dst_h), worker_count) catch unreachable;
    var started_threads: usize = 0;
    errdefer for (threads[0..started_threads]) |thread| thread.join();
    for (threads, 0..) |*thread, i| {
        const start_row = @min((i + 1) * rows_per_worker, @as(usize, dst_h));
        const end_row = @min((i + 2) * rows_per_worker, @as(usize, dst_h));
        tasks[i] = .{
            .dst_w = dst_w,
            .dst_h = dst_h,
            .src_w = src_w,
            .src_h = src_h,
            .src = src,
            .dst = dst,
            .start_row = @as(u32, @intCast(start_row)),
            .end_row = @as(u32, @intCast(end_row)),
            .storage = storage[(i + 1) * row_storage_len .. (i + 2) * row_storage_len],
        };
        thread.* = try std.Thread.spawn(.{}, expandRgbThread, .{&tasks[i]});
        started_threads += 1;
    }
    expandRgbRowsSequential(
        dst_w,
        dst_h,
        src_w,
        src_h,
        src,
        dst,
        0,
        @as(u32, @intCast(@min(rows_per_worker, @as(usize, dst_h)))),
        storage[0..row_storage_len],
    );
    for (threads) |thread| thread.join();
}

fn reduceScalarRowsSequential(
    src_w: u32,
    src_h: u32,
    src: []const f32,
    dst_w: u32,
    dst_h: u32,
    dst: []f32,
    start_row: u32,
    end_row: u32,
    storage: []f32,
) void {
    _ = dst_h;
    const invalid_y = std.math.maxInt(u32);
    var cache_y = [_]u32{ invalid_y, invalid_y, invalid_y, invalid_y, invalid_y };
    var cache_rows: [5][]f32 = undefined;
    std.debug.assert(storage.len >= 5 * @as(usize, dst_w));
    for (0..5) |i| {
        cache_rows[i] = storage[i * @as(usize, dst_w) .. (i + 1) * @as(usize, dst_w)];
    }
    var replace_index: usize = 0;

    var dy: u32 = start_row;
    while (dy < end_row) : (dy += 1) {
        const center_y = @as(i32, @intCast(dy * 2));
        var needed_slots: [5]usize = undefined;
        for (0..5) |ky| {
            const y = clampCoord(center_y + @as(i32, @intCast(ky)) - 2, src_h);
            needed_slots[ky] = ensureReducedScalarRow(src_w, src, dst_w, y, &cache_y, &cache_rows, &replace_index);
        }
        const row0 = cache_rows[needed_slots[0]];
        const row1 = cache_rows[needed_slots[1]];
        const row2 = cache_rows[needed_slots[2]];
        const row3 = cache_rows[needed_slots[3]];
        const row4 = cache_rows[needed_slots[4]];
        for (0..dst_w) |dx| {
            dst[@as(usize, dy) * @as(usize, dst_w) + @as(usize, dx)] =
                (row0[dx] + 4.0 * row1[dx] + 6.0 * row2[dx] + 4.0 * row3[dx] + row4[dx]) * (1.0 / 16.0);
        }
    }
}

fn reduceRgbRowsSequential(
    src_w: u32,
    src_h: u32,
    src: []const f32,
    dst_w: u32,
    dst_h: u32,
    dst: []f32,
    start_row: u32,
    end_row: u32,
    storage: []f32,
) void {
    _ = dst_h;
    const invalid_y = std.math.maxInt(u32);
    var cache_y = [_]u32{ invalid_y, invalid_y, invalid_y, invalid_y, invalid_y };
    var cache_rows: [5][]f32 = undefined;
    const row_len = @as(usize, dst_w) * 3;
    std.debug.assert(storage.len >= 5 * row_len);
    for (0..5) |i| {
        cache_rows[i] = storage[i * row_len .. (i + 1) * row_len];
    }
    var replace_index: usize = 0;

    var dy: u32 = start_row;
    while (dy < end_row) : (dy += 1) {
        const center_y = @as(i32, @intCast(dy * 2));
        var needed_slots: [5]usize = undefined;
        for (0..5) |ky| {
            const y = clampCoord(center_y + @as(i32, @intCast(ky)) - 2, src_h);
            needed_slots[ky] = ensureReducedRgbRow(src_w, src, dst_w, y, &cache_y, &cache_rows, &replace_index);
        }
        const row0 = cache_rows[needed_slots[0]];
        const row1 = cache_rows[needed_slots[1]];
        const row2 = cache_rows[needed_slots[2]];
        const row3 = cache_rows[needed_slots[3]];
        const row4 = cache_rows[needed_slots[4]];
        for (0..dst_w) |dx| {
            const dst_base = (@as(usize, dy) * @as(usize, dst_w) + @as(usize, dx)) * 3;
            const src_base = @as(usize, dx) * 3;
            dst[dst_base + 0] = (row0[src_base + 0] + 4.0 * row1[src_base + 0] + 6.0 * row2[src_base + 0] + 4.0 * row3[src_base + 0] + row4[src_base + 0]) * (1.0 / 16.0);
            dst[dst_base + 1] = (row0[src_base + 1] + 4.0 * row1[src_base + 1] + 6.0 * row2[src_base + 1] + 4.0 * row3[src_base + 1] + row4[src_base + 1]) * (1.0 / 16.0);
            dst[dst_base + 2] = (row0[src_base + 2] + 4.0 * row1[src_base + 2] + 6.0 * row2[src_base + 2] + 4.0 * row3[src_base + 2] + row4[src_base + 2]) * (1.0 / 16.0);
        }
    }
}

fn expandRgbRowsSequential(
    dst_w: u32,
    dst_h: u32,
    src_w: u32,
    src_h: u32,
    src: []const f32,
    dst: []f32,
    start_row: u32,
    end_row: u32,
    storage: []f32,
) void {
    _ = dst_h;
    const invalid_y = std.math.maxInt(u32);
    var cache_y = [_]u32{ invalid_y, invalid_y, invalid_y, invalid_y };
    var cache_rows: [4][]f32 = undefined;
    const row_len = @as(usize, dst_w) * 3;
    std.debug.assert(storage.len >= 4 * row_len);
    for (0..4) |i| {
        cache_rows[i] = storage[i * row_len .. (i + 1) * row_len];
    }
    var replace_index: usize = 0;
    const dst_width = @as(usize, dst_w);
    var dy: u32 = start_row;
    while (dy < end_row) : (dy += 1) {
        const even_y = (dy & 1) == 0;
        const base_y = @as(u32, @intCast(dy / 2));
        const y0 = if (even_y) clampCoord(@as(i32, @intCast(base_y)) - 1, src_h) else clampCoord(@as(i32, @intCast(base_y)), src_h);
        const y1 = clampCoord(@as(i32, @intCast(base_y)), src_h);
        const y2 = if (even_y) clampCoord(@as(i32, @intCast(base_y)) + 1, src_h) else clampCoord(@as(i32, @intCast(base_y + 1)), src_h);
        const slot0 = ensureExpandedRgbRow(src_w, src, dst_w, y0, &cache_y, &cache_rows, &replace_index);
        const slot1 = ensureExpandedRgbRow(src_w, src, dst_w, y1, &cache_y, &cache_rows, &replace_index);
        const row0 = cache_rows[slot0];
        const row1 = cache_rows[slot1];
        const row2 = if (even_y) cache_rows[ensureExpandedRgbRow(src_w, src, dst_w, y2, &cache_y, &cache_rows, &replace_index)] else row1;
        for (0..dst_w) |dx| {
            const dst_base = (@as(usize, dy) * dst_width + @as(usize, dx)) * 3;
            const src_base = @as(usize, dx) * 3;
            if (even_y) {
                dst[dst_base + 0] = (row0[src_base + 0] + 6.0 * row1[src_base + 0] + row2[src_base + 0]) * (1.0 / 8.0);
                dst[dst_base + 1] = (row0[src_base + 1] + 6.0 * row1[src_base + 1] + row2[src_base + 1]) * (1.0 / 8.0);
                dst[dst_base + 2] = (row0[src_base + 2] + 6.0 * row1[src_base + 2] + row2[src_base + 2]) * (1.0 / 8.0);
            } else {
                dst[dst_base + 0] = (row0[src_base + 0] + row1[src_base + 0]) * 0.5;
                dst[dst_base + 1] = (row0[src_base + 1] + row1[src_base + 1]) * 0.5;
                dst[dst_base + 2] = (row0[src_base + 2] + row1[src_base + 2]) * 0.5;
            }
        }
    }
}

const ReduceScalarTask = struct {
    src_w: u32,
    src_h: u32,
    src: []const f32,
    dst_w: u32,
    dst_h: u32,
    dst: []f32,
    start_row: u32,
    end_row: u32,
    storage: []f32,
};

const ReduceRgbTask = struct {
    src_w: u32,
    src_h: u32,
    src: []const f32,
    dst_w: u32,
    dst_h: u32,
    dst: []f32,
    start_row: u32,
    end_row: u32,
    storage: []f32,
};

const ExpandRgbTask = struct {
    dst_w: u32,
    dst_h: u32,
    src_w: u32,
    src_h: u32,
    src: []const f32,
    dst: []f32,
    start_row: u32,
    end_row: u32,
    storage: []f32,
};

fn reduceScalarThread(task: *const ReduceScalarTask) void {
    reduceScalarRowsSequential(task.src_w, task.src_h, task.src, task.dst_w, task.dst_h, task.dst, task.start_row, task.end_row, task.storage);
}

fn reduceRgbThread(task: *const ReduceRgbTask) void {
    reduceRgbRowsSequential(task.src_w, task.src_h, task.src, task.dst_w, task.dst_h, task.dst, task.start_row, task.end_row, task.storage);
}

fn expandRgbThread(task: *const ExpandRgbTask) void {
    expandRgbRowsSequential(task.dst_w, task.dst_h, task.src_w, task.src_h, task.src, task.dst, task.start_row, task.end_row, task.storage);
}

fn effectiveWorkerCount(jobs: usize, rows: u32) usize {
    return @min(@max(jobs, 1), @as(usize, rows));
}

fn ensureReducedScalarRow(
    src_w: u32,
    src: []const f32,
    dst_w: u32,
    src_y: u32,
    cache_y: *[5]u32,
    cache_rows: *[5][]f32,
    replace_index: *usize,
) usize {
    for (cache_y, 0..) |cached_y, i| {
        if (cached_y == src_y) return i;
    }
    const slot = replace_index.*;
    replace_index.* = (replace_index.* + 1) % cache_rows.len;
    cache_y[slot] = src_y;
    horizontalReduceScalarRow(src_w, src, src_y, dst_w, cache_rows[slot]);
    return slot;
}

fn ensureReducedRgbRow(
    src_w: u32,
    src: []const f32,
    dst_w: u32,
    src_y: u32,
    cache_y: *[5]u32,
    cache_rows: *[5][]f32,
    replace_index: *usize,
) usize {
    for (cache_y, 0..) |cached_y, i| {
        if (cached_y == src_y) return i;
    }
    const slot = replace_index.*;
    replace_index.* = (replace_index.* + 1) % cache_rows.len;
    cache_y[slot] = src_y;
    horizontalReduceRgbRow(src_w, src, src_y, dst_w, cache_rows[slot]);
    return slot;
}

fn ensureExpandedRgbRow(
    src_w: u32,
    src: []const f32,
    dst_w: u32,
    src_y: u32,
    cache_y: *[4]u32,
    cache_rows: *[4][]f32,
    replace_index: *usize,
) usize {
    for (cache_y, 0..) |cached_y, i| {
        if (cached_y == src_y) return i;
    }
    const slot = replace_index.*;
    replace_index.* = (replace_index.* + 1) % cache_rows.len;
    cache_y[slot] = src_y;
    horizontalExpandRgbRow(src_w, src, src_y, dst_w, cache_rows[slot]);
    return slot;
}

fn horizontalReduceScalarRow(src_w: u32, src: []const f32, src_y: u32, dst_w: u32, dst_row: []f32) void {
    const src_base = @as(usize, src_y) * @as(usize, src_w);
    for (0..dst_w) |dx| {
        const sx = @as(i32, @intCast(dx * 2));
        const x0 = clampCoord(sx - 2, src_w);
        const x1 = clampCoord(sx - 1, src_w);
        const x2 = clampCoord(sx, src_w);
        const x3 = clampCoord(sx + 1, src_w);
        const x4 = clampCoord(sx + 2, src_w);
        dst_row[dx] =
            (src[src_base + @as(usize, x0)] +
            4.0 * src[src_base + @as(usize, x1)] +
            6.0 * src[src_base + @as(usize, x2)] +
            4.0 * src[src_base + @as(usize, x3)] +
            src[src_base + @as(usize, x4)]) * (1.0 / 16.0);
    }
}

fn horizontalReduceRgbRow(src_w: u32, src: []const f32, src_y: u32, dst_w: u32, dst_row: []f32) void {
    const src_width = @as(usize, src_w);
    const src_row_base = @as(usize, src_y) * src_width * 3;
    for (0..dst_w) |dx| {
        const sx = @as(i32, @intCast(dx * 2));
        const x0 = @as(usize, clampCoord(sx - 2, src_w));
        const x1 = @as(usize, clampCoord(sx - 1, src_w));
        const x2 = @as(usize, clampCoord(sx, src_w));
        const x3 = @as(usize, clampCoord(sx + 1, src_w));
        const x4 = @as(usize, clampCoord(sx + 2, src_w));
        const dst_base = @as(usize, dx) * 3;
        const b0 = src_row_base + x0 * 3;
        const b1 = src_row_base + x1 * 3;
        const b2 = src_row_base + x2 * 3;
        const b3 = src_row_base + x3 * 3;
        const b4 = src_row_base + x4 * 3;
        dst_row[dst_base + 0] = (src[b0 + 0] + 4.0 * src[b1 + 0] + 6.0 * src[b2 + 0] + 4.0 * src[b3 + 0] + src[b4 + 0]) * (1.0 / 16.0);
        dst_row[dst_base + 1] = (src[b0 + 1] + 4.0 * src[b1 + 1] + 6.0 * src[b2 + 1] + 4.0 * src[b3 + 1] + src[b4 + 1]) * (1.0 / 16.0);
        dst_row[dst_base + 2] = (src[b0 + 2] + 4.0 * src[b1 + 2] + 6.0 * src[b2 + 2] + 4.0 * src[b3 + 2] + src[b4 + 2]) * (1.0 / 16.0);
    }
}

fn horizontalExpandRgbRow(src_w: u32, src: []const f32, src_y: u32, dst_w: u32, dst_row: []f32) void {
    const src_width = @as(usize, src_w);
    const src_row_base = @as(usize, src_y) * src_width * 3;
    for (0..dst_w) |dx| {
        const dst_base = @as(usize, dx) * 3;
        if ((dx & 1) == 0) {
            const sx = @as(i32, @intCast(dx / 2));
            const x0 = @as(usize, clampCoord(sx - 1, src_w));
            const x1 = @as(usize, clampCoord(sx, src_w));
            const x2 = @as(usize, clampCoord(sx + 1, src_w));
            const b0 = src_row_base + x0 * 3;
            const b1 = src_row_base + x1 * 3;
            const b2 = src_row_base + x2 * 3;
            dst_row[dst_base + 0] = (src[b0 + 0] + 6.0 * src[b1 + 0] + src[b2 + 0]) * (1.0 / 8.0);
            dst_row[dst_base + 1] = (src[b0 + 1] + 6.0 * src[b1 + 1] + src[b2 + 1]) * (1.0 / 8.0);
            dst_row[dst_base + 2] = (src[b0 + 2] + 6.0 * src[b1 + 2] + src[b2 + 2]) * (1.0 / 8.0);
        } else {
            const sx = @as(i32, @intCast(dx / 2));
            const x0 = @as(usize, clampCoord(sx, src_w));
            const x1 = @as(usize, clampCoord(sx + 1, src_w));
            const b0 = src_row_base + x0 * 3;
            const b1 = src_row_base + x1 * 3;
            dst_row[dst_base + 0] = (src[b0 + 0] + src[b1 + 0]) * 0.5;
            dst_row[dst_base + 1] = (src[b0 + 1] + src[b1 + 1]) * 0.5;
            dst_row[dst_base + 2] = (src[b0 + 2] + src[b1 + 2]) * 0.5;
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
    try reduceRgb(allocator, 4, 4, src, 2, 2, reduced, 1);
    try expandRgb(allocator, 4, 4, 2, 2, reduced, expanded, 1);
    for (expanded, 0..) |value, index| {
        const expected = src[index];
        try std.testing.expectApproxEqAbs(expected, value, 1e-5);
    }
}
