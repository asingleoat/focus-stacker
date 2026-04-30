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

pub const RunError = io.LoadError || image_io.SaveError || std.mem.Allocator.Error || std.Thread.SpawnError;

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

    var output: ?image_io.Image = null;
    defer if (output) |*image| image.deinit(allocator);

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
            output = try blend.allocateOutput(allocator, fusedOutputInfo(image.info));
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
                    soft_blend = try blend.SoftBlendState.init(allocator, output.?.info);
                },
            }
        }

        gray.fillFromLoaded(gray_buffer.items, &image);
        var gray_image = gray.GrayImage{
            .width = image.info.width,
            .height = image.info.height,
            .pixels = gray_buffer.items,
            .sample_scale = switch (image.info.sample_type) {
                .u8 => 255.0,
                .u16 => 65535.0,
            },
        };
        try contrast.computeLocalContrastWeightsInto(&gray_image, cfg.contrast_window_size, jobs, weight_buffer.items);
        var weights = contrast.WeightMap{
            .width = gray_image.width,
            .height = gray_image.height,
            .pixels = weight_buffer.items,
        };

        if (cfg.verbose > 1) {
            const stats = weightStats(&weights);
            std.debug.print("  local contrast: mean={d:.4} max={d:.4}\n", .{ stats.mean, stats.max });
        }

        switch (cfg.method) {
            .hardmask_contrast => {
                try blend.updateWinners(allocator, &image, &weights, best_weights.items, &output.?, jobs);
            },
            .softmask_contrast => {
                masks.applySupportInto(&image, weight_buffer.items);
                try masks.blurFiveTapInto(
                    allocator,
                    image.info.width,
                    image.info.height,
                    jobs,
                    weight_buffer.items,
                    smoothed_weight_buffer.items,
                    weight_buffer.items,
                );
                try blend.accumulateSoft(allocator, &image, weight_buffer.items, &soft_blend.?, jobs);
            },
        }
    }

    switch (cfg.method) {
        .hardmask_contrast => {},
        .softmask_contrast => blend.finalizeSoft(&soft_blend.?, &output.?),
    }

    if (cfg.verbose > 0) {
        std.debug.print("focus fuse: writing {s}\n", .{cfg.output_path.?});
    }
    try image_io.writeTiff(cfg.output_path.?, &output.?);
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
