const std = @import("std");
const core = @import("align_stack_core");
const gray = core.gray;
const image_io = core.image_io;
const profiler = core.profiler;
const blend = @import("blend.zig");
const config = @import("config.zig");
const contrast = @import("contrast.zig");
const debug = @import("debug.zig");
const grayscale = @import("grayscale.zig");
const io = @import("io.zig");
const masks = @import("masks.zig");
const memory_budget = core.memory_budget;
const pyramid = @import("pyramid.zig");

pub const RunError = anyerror;
const max_cached_pyramid_bytes: u64 = 2 * 1024 * 1024 * 1024;
const max_cached_pyramid_total_bytes: u64 = 4 * 1024 * 1024 * 1024;

pub fn run(allocator: std.mem.Allocator, cfg: *const config.Config) RunError!void {
    const prof = profiler.scope("fuse.pipeline.run");
    defer prof.end();

    const jobs = resolveJobs(cfg.jobs);
    var best_weights = std.ArrayListUnmanaged(f32){};
    defer best_weights.deinit(allocator);
    var gray_buffer = std.ArrayListUnmanaged(f32){};
    defer gray_buffer.deinit(allocator);
    var support_buffer = std.ArrayListUnmanaged(f32){};
    defer support_buffer.deinit(allocator);
    var weight_buffer = std.ArrayListUnmanaged(f32){};
    defer weight_buffer.deinit(allocator);
    var smoothed_weight_buffer = std.ArrayListUnmanaged(f32){};
    defer smoothed_weight_buffer.deinit(allocator);
    var soft_blend: ?blend.SoftBlendState = null;
    defer if (soft_blend) |*state| state.deinit(allocator);
    var contrast_workspace: ?contrast.Workspace = null;
    defer if (contrast_workspace) |*value| value.deinit(allocator);
    var norm_weight_sums = std.ArrayListUnmanaged(f32){};
    defer norm_weight_sums.deinit(allocator);
    var powered_weight_sums = std.ArrayListUnmanaged(f32){};
    defer powered_weight_sums.deinit(allocator);
    var union_support = std.ArrayListUnmanaged(f32){};
    defer union_support.deinit(allocator);
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
                &support_buffer,
                &weight_buffer,
                &smoothed_weight_buffer,
                &soft_blend,
                &contrast_workspace,
                &output,
            );
            switch (cfg.method) {
                .hardmask_contrast => {},
                .softmask_contrast => blend.finalizeSoft(&soft_blend.?, &output.?),
                .pyramid_contrast, .hybrid_pyramid_contrast => unreachable,
            }
        },
        .pyramid_contrast => {
            output = try runCollapsedPyramidPass(
                allocator,
                cfg,
                jobs,
                &gray_buffer,
                &support_buffer,
                &weight_buffer,
                &contrast_workspace,
                &norm_weight_sums,
                &powered_weight_sums,
                &union_support,
                &pyramid_accumulator,
            );
        },
        .hybrid_pyramid_contrast => {
            var pyramid_cfg = cfg.*;
            pyramid_cfg.method = .pyramid_contrast;
            output = try runCollapsedPyramidPass(
                allocator,
                &pyramid_cfg,
                jobs,
                &gray_buffer,
                &support_buffer,
                &weight_buffer,
                &contrast_workspace,
                &norm_weight_sums,
                &powered_weight_sums,
                &union_support,
                &pyramid_accumulator,
            );

            var soft_output = output.?;
            defer soft_output.deinit(allocator);
            output = null;
            if (contrast_workspace) |*value| {
                value.deinit(allocator);
                contrast_workspace = null;
            }

            var hardmask_cfg = cfg.*;
            hardmask_cfg.method = .hardmask_contrast;
            try runSinglePass(
                allocator,
                &hardmask_cfg,
                jobs,
                &best_weights,
                &gray_buffer,
                &support_buffer,
                &weight_buffer,
                &smoothed_weight_buffer,
                &soft_blend,
                &contrast_workspace,
                &output,
            );

            const merged = try pyramid.mergeHybridImages(
                allocator,
                &soft_output,
                &output.?,
                pyramid.hybrid_hard_level_start,
                pyramid.hybrid_hard_level_count,
                cfg.hybrid_sharpness,
                jobs,
            );
            output.?.deinit(allocator);
            output = merged;
        },
    }

    if (cfg.verbose > 0) {
        std.debug.print("focus fuse: writing {s}\n", .{cfg.output_path.?});
    }
    try image_io.writeTiff(cfg.output_path.?, &output.?);
}

fn runCollapsedPyramidPass(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    jobs: usize,
    gray_buffer: *std.ArrayListUnmanaged(f32),
    support_buffer: *std.ArrayListUnmanaged(f32),
    weight_buffer: *std.ArrayListUnmanaged(f32),
    contrast_workspace: *?contrast.Workspace,
    norm_weight_sums: *std.ArrayListUnmanaged(f32),
    powered_weight_sums: *std.ArrayListUnmanaged(f32),
    union_support: *std.ArrayListUnmanaged(f32),
    pyramid_accumulator: *?pyramid.Accumulator,
) RunError!image_io.Image {
    var output: ?image_io.Image = null;
    errdefer if (output) |*image| image.deinit(allocator);

    try runPyramidPass(
        allocator,
        cfg,
        jobs,
        gray_buffer,
        support_buffer,
        weight_buffer,
        contrast_workspace,
        norm_weight_sums,
        powered_weight_sums,
        union_support,
        &output,
        pyramid_accumulator,
    );
    const collapsed_info = fusedOutputInfo(output.?.info);
    output.?.deinit(allocator);
    return try pyramid.collapseToImageWithJobsAndDebug(
        allocator,
        collapsed_info,
        &pyramid_accumulator.*.?,
        jobs,
        cfg.dump_masks_dir,
    );
}

fn runSinglePass(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    jobs: usize,
    best_weights: *std.ArrayListUnmanaged(f32),
    gray_buffer: *std.ArrayListUnmanaged(f32),
    support_buffer: *std.ArrayListUnmanaged(f32),
    weight_buffer: *std.ArrayListUnmanaged(f32),
    smoothed_weight_buffer: *std.ArrayListUnmanaged(f32),
    soft_blend: *?blend.SoftBlendState,
    contrast_workspace: *?contrast.Workspace,
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
            try support_buffer.resize(allocator, count);
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
                .pyramid_contrast, .hybrid_pyramid_contrast => unreachable,
            }
            contrast_workspace.* = try contrast.Workspace.init(allocator, image.info.width, jobs);
        }

        try computeWeightMapForImage(cfg, jobs, &image, gray_buffer.items, support_buffer.items, weight_buffer.items, &(contrast_workspace.*.?));
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
            .pyramid_contrast, .hybrid_pyramid_contrast => unreachable,
        }
    }
}

fn runPyramidPass(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    jobs: usize,
    gray_buffer: *std.ArrayListUnmanaged(f32),
    support_buffer: *std.ArrayListUnmanaged(f32),
    weight_buffer: *std.ArrayListUnmanaged(f32),
    contrast_workspace: *?contrast.Workspace,
    norm_weight_sums: *std.ArrayListUnmanaged(f32),
    powered_weight_sums: *std.ArrayListUnmanaged(f32),
    union_support: *std.ArrayListUnmanaged(f32),
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
    const debug_level_index = input_count / 2;

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
            try support_buffer.resize(allocator, count);
            try weight_buffer.resize(allocator, count);
            try norm_weight_sums.resize(allocator, count);
            if (cfg.method == .hybrid_pyramid_contrast) {
                try powered_weight_sums.resize(allocator, count);
                @memset(powered_weight_sums.items, 0);
            }
            try union_support.resize(allocator, count);
            @memset(norm_weight_sums.items, 0);
            @memset(union_support.items, 0);
            accumulator.* = try pyramid.Accumulator.init(allocator, image.info.width, image.info.height);
            workspace = try pyramid.Workspace.init(allocator, image.info.width, image.info.height);
            contrast_workspace.* = try contrast.Workspace.init(allocator, image.info.width, jobs);
            const image_cache_budget = memory_budget.cacheAllowanceBytes(cfg.memory_fraction, max_cached_pyramid_bytes);
            const total_cache_budget = memory_budget.cacheAllowanceBytes(cfg.memory_fraction, max_cached_pyramid_total_bytes);
            cache_images = estimatedCacheBytes(image.info, input_count) <= image_cache_budget;
            cache_weights = cache_images and estimatedCacheBytes(image.info, input_count) + estimatedWeightCacheBytes(image.info.width, image.info.height, input_count) <= total_cache_budget;
            if (cfg.verbose > 0 and cache_images) {
                std.debug.print("focus fuse: caching aligned inputs in memory for pyramid blend\n", .{});
                if (cache_weights) {
                    std.debug.print("focus fuse: caching weight maps in memory for pyramid blend\n", .{});
                }
            }
        }
        try computeWeightMapForImage(cfg, jobs, &image, gray_buffer.items, support_buffer.items, weight_buffer.items, &(contrast_workspace.*.?));
        masks.applySupportInto(&image, weight_buffer.items);
        masks.accumulateBinarySupportMax(&image, union_support.items);
        for (norm_weight_sums.items, weight_buffer.items) |*sum, weight| sum.* += weight;
        if (cache_images) {
            try cached_images.append(allocator, image);
            if (cache_weights) {
                try cached_weights.append(allocator, try allocator.dupe(f32, weight_buffer.items));
            }
            keep_image = true;
        }
    }

    if (cfg.dump_masks_dir) |dump_dir| {
        try debug.dumpPyramidScalars(
            allocator,
            dump_dir,
            output.*.?.info.width,
            output.*.?.info.height,
            norm_weight_sums.items,
            union_support.items,
        );
    }

    try gray_buffer.resize(allocator, norm_weight_sums.items.len);
    if (cfg.method == .hybrid_pyramid_contrast) {
        if (cache_images) {
            for (cached_images.items, 0..) |*image, index| {
                if (cache_weights) {
                    @memcpy(weight_buffer.items, cached_weights.items[index]);
                } else {
                    try computeWeightMapForImage(cfg, jobs, image, gray_buffer.items, support_buffer.items, weight_buffer.items, &(contrast_workspace.*.?));
                    masks.applySupportInto(image, weight_buffer.items);
                }
                pyramid.accumulateNormalizedWeightPowers(
                    weight_buffer.items,
                    norm_weight_sums.items,
                    input_count,
                    pyramid.hybrid_mask_power,
                    powered_weight_sums.items,
                );
            }
        } else {
            for (cfg.input_files.items) |path| {
                var image = try io.loadAndValidateImage(allocator, path, expected);
                defer image.deinit(allocator);
                try computeWeightMapForImage(cfg, jobs, &image, gray_buffer.items, support_buffer.items, weight_buffer.items, &(contrast_workspace.*.?));
                masks.applySupportInto(&image, weight_buffer.items);
                pyramid.accumulateNormalizedWeightPowers(
                    weight_buffer.items,
                    norm_weight_sums.items,
                    input_count,
                    pyramid.hybrid_mask_power,
                    powered_weight_sums.items,
                );
            }
        }
    }

    if (cache_images) {
        for (cached_images.items, 0..) |*image, index| {
            if (cfg.verbose > 0) {
                std.debug.print("focus fuse: [{d}/{d}] pyramid blend from cached image\n", .{ index + 1, input_count });
            }
            if (cache_weights) {
                @memcpy(weight_buffer.items, cached_weights.items[index]);
            } else {
                try computeWeightMapForImage(cfg, jobs, image, gray_buffer.items, support_buffer.items, weight_buffer.items, &(contrast_workspace.*.?));
                masks.applySupportInto(image, weight_buffer.items);
            }
            try dumpAndNormalizeCurrentWeights(
                allocator,
                cfg,
                image.info,
                index,
                input_count,
                weight_buffer.items,
                norm_weight_sums.items,
                powered_weight_sums.items,
                gray_buffer.items,
            );
            try pyramid.accumulateImageWithWorkspace(allocator, image, gray_buffer.items, union_support.items, &accumulator.*.?, &workspace.?, jobs);
            if (cfg.dump_masks_dir) |dump_dir| {
                if (index == debug_level_index) {
                    try debug.dumpWorkspaceLevels(allocator, dump_dir, index, &workspace.?);
                }
            }
        }
    } else {
        for (cfg.input_files.items, 0..) |path, index| {
            if (cfg.verbose > 0) {
                std.debug.print("focus fuse: [{d}/{d}] loading {s} for pyramid blend\n", .{ index + 1, input_count, path });
            }
            var image = try io.loadAndValidateImage(allocator, path, expected);
            defer image.deinit(allocator);
            try computeWeightMapForImage(cfg, jobs, &image, gray_buffer.items, support_buffer.items, weight_buffer.items, &(contrast_workspace.*.?));
            masks.applySupportInto(&image, weight_buffer.items);
            try dumpAndNormalizeCurrentWeights(
                allocator,
                cfg,
                image.info,
                index,
                input_count,
                weight_buffer.items,
                norm_weight_sums.items,
                powered_weight_sums.items,
                gray_buffer.items,
            );
            try pyramid.accumulateImageWithWorkspace(allocator, &image, gray_buffer.items, union_support.items, &accumulator.*.?, &workspace.?, jobs);
            if (cfg.dump_masks_dir) |dump_dir| {
                if (index == debug_level_index) {
                    try debug.dumpWorkspaceLevels(allocator, dump_dir, index, &workspace.?);
                }
            }
        }
    }

    if (cfg.dump_masks_dir) |dump_dir| {
        try debug.dumpAccumulatorLevels(allocator, dump_dir, &accumulator.*.?);
    }
}

fn estimatedCacheBytes(info: image_io.ImageInfo, image_count: usize) u64 {
    const sample_bytes: u64 = switch (info.sample_type) {
        .u8 => 1,
        .u16 => 2,
    };
    const pixel_bytes = @as(u64, info.width) * @as(u64, info.height) * @as(u64, info.color_channels + info.extra_channels) * sample_bytes;
    return pixel_bytes * @as(u64, @intCast(image_count));
}

fn estimatedWeightCacheBytes(width: u32, height: u32, image_count: usize) u64 {
    return @as(u64, width) * @as(u64, height) * @sizeOf(f32) * @as(u64, @intCast(image_count));
}

fn dumpAndNormalizeCurrentWeights(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    info: image_io.ImageInfo,
    index: usize,
    input_count: usize,
    weight_pixels: []const f32,
    norm_weight_sums: []const f32,
    powered_weight_sums: []const f32,
    normalized_out: []f32,
) RunError!void {
    if (cfg.dump_masks_dir) |dump_dir| {
        try debug.dumpRawMask(
            allocator,
            dump_dir,
            info.width,
            info.height,
            index,
            weight_pixels,
            grayscale.sampleScaleForType(info.sample_type),
        );
    }
    if (cfg.method == .hybrid_pyramid_contrast) {
        pyramid.normalizeWeightsPoweredInto(
            weight_pixels,
            norm_weight_sums,
            powered_weight_sums,
            input_count,
            pyramid.hybrid_mask_power,
            normalized_out,
        );
    } else {
        pyramid.normalizeWeightsInto(weight_pixels, norm_weight_sums, input_count, normalized_out);
    }
    if (cfg.dump_masks_dir) |dump_dir| {
        try debug.dumpNormalizedMask(
            allocator,
            dump_dir,
            info.width,
            info.height,
            index,
            normalized_out,
        );
    }
}

fn computeWeightMapForImage(
    cfg: *const config.Config,
    jobs: usize,
    image: *const image_io.Image,
    gray_pixels: []f32,
    support_pixels: []f32,
    weights: []f32,
    workspace: *contrast.Workspace,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    grayscale.fillAverageFromLoaded(gray_pixels, image);
    masks.fillBinarySupport(image, support_pixels);
    var gray_image = gray.GrayImage{
        .width = image.info.width,
        .height = image.info.height,
        .pixels = gray_pixels,
        .sample_scale = grayscale.sampleScaleForType(image.info.sample_type),
    };
    try contrast.computeLocalContrastWeightsWithWorkspace(&gray_image, support_pixels, cfg.contrast_window_size, jobs, weights, workspace);
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
