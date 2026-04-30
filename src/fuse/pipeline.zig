const std = @import("std");
const core = @import("align_stack_core");
const gray = core.gray;
const image_io = core.image_io;
const profiler = core.profiler;
const blend = @import("blend.zig");
const config = @import("config.zig");
const contrast = @import("contrast.zig");
const io = @import("io.zig");
const masks = @import("masks.zig");
const pyramid = @import("pyramid.zig");

pub const RunError = io.LoadError || image_io.SaveError || std.mem.Allocator.Error || std.Thread.SpawnError;
const max_cached_pyramid_bytes: usize = 2 * 1024 * 1024 * 1024;
const max_cached_pyramid_total_bytes: usize = 4 * 1024 * 1024 * 1024;

pub fn run(allocator: std.mem.Allocator, cfg: *const config.Config) RunError!void {
    const prof = profiler.scope("fuse.pipeline.run");
    defer prof.end();

    const jobs = resolveJobs(cfg.jobs);
    var best_weights = std.ArrayListUnmanaged(f32){};
    defer best_weights.deinit(allocator);
    var gray_buffer = std.ArrayListUnmanaged(f32){};
    defer gray_buffer.deinit(allocator);
    var weight_buffer = std.ArrayListUnmanaged(f32){};
    defer weight_buffer.deinit(allocator);
    var smoothed_weight_buffer = std.ArrayListUnmanaged(f32){};
    defer smoothed_weight_buffer.deinit(allocator);
    var soft_blend: ?blend.SoftBlendState = null;
    defer if (soft_blend) |*state| state.deinit(allocator);
    var norm_weight_sums = std.ArrayListUnmanaged(f32){};
    defer norm_weight_sums.deinit(allocator);
    var pyramid_accumulator: ?pyramid.Accumulator = null;
    defer if (pyramid_accumulator) |*value| value.deinit(allocator);

    var output: ?image_io.Image = null;
    defer if (output) |*image| image.deinit(allocator);

    switch (cfg.method) {
        .hardmask_contrast, .softmask_contrast => {
            try runSinglePass(
                allocator,
                cfg,
                jobs,
                &best_weights,
                &gray_buffer,
                &weight_buffer,
                &smoothed_weight_buffer,
                &soft_blend,
                &output,
            );
            switch (cfg.method) {
                .hardmask_contrast => {},
                .softmask_contrast => blend.finalizeSoft(&soft_blend.?, &output.?),
                .pyramid_contrast => unreachable,
            }
        },
        .pyramid_contrast => {
            try runPyramidPass(
                allocator,
                cfg,
                jobs,
                &gray_buffer,
                &weight_buffer,
                &norm_weight_sums,
                &output,
                &pyramid_accumulator,
            );
            const collapsed_info = fusedOutputInfo(output.?.info);
            output.?.deinit(allocator);
            output = try pyramid.collapseToImage(allocator, collapsed_info, &pyramid_accumulator.?);
        },
    }

    if (cfg.verbose > 0) {
        std.debug.print("focus fuse: writing {s}\n", .{cfg.output_path.?});
    }
    try image_io.writeTiff(cfg.output_path.?, &output.?);
}

fn runSinglePass(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    jobs: usize,
    best_weights: *std.ArrayListUnmanaged(f32),
    gray_buffer: *std.ArrayListUnmanaged(f32),
    weight_buffer: *std.ArrayListUnmanaged(f32),
    smoothed_weight_buffer: *std.ArrayListUnmanaged(f32),
    soft_blend: *?blend.SoftBlendState,
    output: *?image_io.Image,
) RunError!void {
    var expected: ?io.StackInfo = null;
    const input_count = cfg.input_files.items.len;
    for (cfg.input_files.items, 0..) |path, index| {
        if (cfg.verbose > 0) {
            std.debug.print("focus fuse: [{d}/{d}] loading {s}\n", .{ index + 1, input_count, path });
        }
        var image = try io.loadAndValidateImage(allocator, path, expected);
        defer image.deinit(allocator);

        if (expected == null) {
            expected = io.stackInfoFromImage(&image);
            output.* = try blend.allocateOutput(allocator, fusedOutputInfo(image.info));
            const count = @as(usize, image.info.width) * @as(usize, image.info.height);
            try gray_buffer.resize(allocator, count);
            try weight_buffer.resize(allocator, count);
            switch (cfg.method) {
                .hardmask_contrast => {
                    try best_weights.resize(allocator, count);
                    @memset(best_weights.items, -std.math.inf(f32));
                },
                .softmask_contrast => {
                    try smoothed_weight_buffer.resize(allocator, count);
                    soft_blend.* = try blend.SoftBlendState.init(allocator, output.*.?.info);
                },
                .pyramid_contrast => unreachable,
            }
        }

        try computeWeightMapForImage(cfg, jobs, &image, gray_buffer.items, weight_buffer.items);
        var weights = contrast.WeightMap{
            .width = image.info.width,
            .height = image.info.height,
            .pixels = weight_buffer.items,
        };
        if (cfg.verbose > 1) {
            const stats = weightStats(&weights);
            std.debug.print("  local contrast: mean={d:.4} max={d:.4}\n", .{ stats.mean, stats.max });
        }
        switch (cfg.method) {
            .hardmask_contrast => try blend.updateWinners(allocator, &image, &weights, best_weights.items, &output.*.?, jobs),
            .softmask_contrast => {
                masks.applySupportInto(&image, weight_buffer.items);
                try masks.blurFiveTapInto(allocator, image.info.width, image.info.height, jobs, weight_buffer.items, smoothed_weight_buffer.items, weight_buffer.items);
                try blend.accumulateSoft(allocator, &image, weight_buffer.items, &soft_blend.*.?, jobs);
            },
            .pyramid_contrast => unreachable,
        }
    }
}

fn runPyramidPass(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    jobs: usize,
    gray_buffer: *std.ArrayListUnmanaged(f32),
    weight_buffer: *std.ArrayListUnmanaged(f32),
    norm_weight_sums: *std.ArrayListUnmanaged(f32),
    output: *?image_io.Image,
    accumulator: *?pyramid.Accumulator,
) RunError!void {
    const prof = profiler.scope("fuse.pipeline.runPyramidPass");
    defer prof.end();

    var expected: ?io.StackInfo = null;
    const input_count = cfg.input_files.items.len;
    var cached_images = std.ArrayListUnmanaged(image_io.Image){};
    defer {
        for (cached_images.items) |*image| image.deinit(allocator);
        cached_images.deinit(allocator);
    }
    var cached_weights = std.ArrayListUnmanaged([]f32){};
    defer {
        for (cached_weights.items) |weights| allocator.free(weights);
        cached_weights.deinit(allocator);
    }
    var workspace: ?pyramid.Workspace = null;
    defer if (workspace) |*value| value.deinit(allocator);
    var cache_images = false;
    var cache_weights = false;

    for (cfg.input_files.items, 0..) |path, index| {
        if (cfg.verbose > 0) {
            std.debug.print("focus fuse: [{d}/{d}] loading {s} for weight normalization\n", .{ index + 1, input_count, path });
        }
        var image = try io.loadAndValidateImage(allocator, path, expected);
        var keep_image = false;
        errdefer if (!keep_image) image.deinit(allocator);
        if (expected == null) {
            expected = io.stackInfoFromImage(&image);
            output.* = try blend.allocateOutput(allocator, fusedOutputInfo(image.info));
            const count = @as(usize, image.info.width) * @as(usize, image.info.height);
            try gray_buffer.resize(allocator, count);
            try weight_buffer.resize(allocator, count);
            try norm_weight_sums.resize(allocator, count);
            @memset(norm_weight_sums.items, 0);
            accumulator.* = try pyramid.Accumulator.init(allocator, image.info.width, image.info.height);
            workspace = try pyramid.Workspace.init(allocator, image.info.width, image.info.height);
            cache_images = estimatedCacheBytes(image.info, input_count) <= max_cached_pyramid_bytes;
            cache_weights = cache_images and estimatedCacheBytes(image.info, input_count) + estimatedWeightCacheBytes(image.info.width, image.info.height, input_count) <= max_cached_pyramid_total_bytes;
            if (cfg.verbose > 0 and cache_images) {
                std.debug.print("focus fuse: caching aligned inputs in memory for pyramid blend\n", .{});
                if (cache_weights) {
                    std.debug.print("focus fuse: caching weight maps in memory for pyramid blend\n", .{});
                }
            }
        }
        try computeWeightMapForImage(cfg, jobs, &image, gray_buffer.items, weight_buffer.items);
        masks.applySupportInto(&image, weight_buffer.items);
        for (norm_weight_sums.items, weight_buffer.items) |*sum, weight| sum.* += weight;
        if (cache_images) {
            try cached_images.append(allocator, image);
            if (cache_weights) {
                try cached_weights.append(allocator, try allocator.dupe(f32, weight_buffer.items));
            }
            keep_image = true;
        }
    }

    try gray_buffer.resize(allocator, norm_weight_sums.items.len);

    if (cache_images) {
        for (cached_images.items, 0..) |*image, index| {
            if (cfg.verbose > 0) {
                std.debug.print("focus fuse: [{d}/{d}] pyramid blend from cached image\n", .{ index + 1, input_count });
            }
            if (cache_weights) {
                @memcpy(weight_buffer.items, cached_weights.items[index]);
            } else {
                try computeWeightMapForImage(cfg, jobs, image, gray_buffer.items, weight_buffer.items);
                masks.applySupportInto(image, weight_buffer.items);
            }
            pyramid.normalizeWeightsInto(weight_buffer.items, norm_weight_sums.items, input_count, gray_buffer.items);
            try pyramid.accumulateImageWithWorkspace(allocator, image, gray_buffer.items, &accumulator.*.?, &workspace.?);
        }
    } else {
        for (cfg.input_files.items, 0..) |path, index| {
            if (cfg.verbose > 0) {
                std.debug.print("focus fuse: [{d}/{d}] loading {s} for pyramid blend\n", .{ index + 1, input_count, path });
            }
            var image = try io.loadAndValidateImage(allocator, path, expected);
            defer image.deinit(allocator);
            try computeWeightMapForImage(cfg, jobs, &image, gray_buffer.items, weight_buffer.items);
            masks.applySupportInto(&image, weight_buffer.items);
            pyramid.normalizeWeightsInto(weight_buffer.items, norm_weight_sums.items, input_count, gray_buffer.items);
            try pyramid.accumulateImageWithWorkspace(allocator, &image, gray_buffer.items, &accumulator.*.?, &workspace.?);
        }
    }
}

fn estimatedCacheBytes(info: image_io.ImageInfo, image_count: usize) usize {
    const sample_bytes: usize = switch (info.sample_type) {
        .u8 => 1,
        .u16 => 2,
    };
    const pixel_bytes = @as(usize, info.width) * @as(usize, info.height) * @as(usize, info.color_channels + info.extra_channels) * sample_bytes;
    return pixel_bytes * image_count;
}

fn estimatedWeightCacheBytes(width: u32, height: u32, image_count: usize) usize {
    return @as(usize, width) * @as(usize, height) * @sizeOf(f32) * image_count;
}

fn computeWeightMapForImage(
    cfg: *const config.Config,
    jobs: usize,
    image: *const image_io.Image,
    gray_pixels: []f32,
    weights: []f32,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    gray.fillFromLoaded(gray_pixels, image);
    var gray_image = gray.GrayImage{
        .width = image.info.width,
        .height = image.info.height,
        .pixels = gray_pixels,
        .sample_scale = switch (image.info.sample_type) {
            .u8 => 255.0,
            .u16 => 65535.0,
        },
    };
    try contrast.computeLocalContrastWeightsInto(&gray_image, cfg.contrast_window_size, jobs, weights);
}

fn fusedOutputInfo(info: image_io.ImageInfo) image_io.ImageInfo {
    var out = info;
    out.extra_channels = 0;
    return out;
}

pub fn resolveJobs(requested: ?u32) usize {
    if (requested) |value| return @max(@as(usize, value), 1);
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return if (cpu_count > 2) cpu_count - 2 else 1;
}

fn weightStats(weights: *const contrast.WeightMap) struct { mean: f64, max: f32 } {
    var sum: f64 = 0;
    var max_value: f32 = 0;
    for (weights.pixels) |value| {
        sum += value;
        max_value = @max(max_value, value);
    }
    return .{
        .mean = sum / @as(f64, @floatFromInt(weights.pixels.len)),
        .max = max_value,
    };
}
