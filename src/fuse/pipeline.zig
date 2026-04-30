const std = @import("std");
const core = @import("align_stack_core");
const gray = core.gray;
const image_io = core.image_io;
const profiler = core.profiler;
const blend = @import("blend.zig");
const config = @import("config.zig");
const contrast = @import("contrast.zig");
const io = @import("io.zig");

pub const RunError = io.LoadError || image_io.SaveError || std.mem.Allocator.Error || std.Thread.SpawnError;

pub fn run(allocator: std.mem.Allocator, cfg: *const config.Config) RunError!void {
    const prof = profiler.scope("fuse.pipeline.run");
    defer prof.end();

    const jobs = resolveJobs(cfg.jobs);
    var best_weights = std.ArrayListUnmanaged(f32){};
    defer best_weights.deinit(allocator);

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
            output = try blend.allocateOutput(allocator, image.info);
            const count = @as(usize, image.info.width) * @as(usize, image.info.height);
            try best_weights.resize(allocator, count);
            @memset(best_weights.items, -std.math.inf(f32));
        }

        var gray_image = try gray.fromLoaded(allocator, &image);
        defer gray_image.deinit(allocator);

        var weights = try contrast.computeLocalContrastWeights(allocator, &gray_image, cfg.contrast_window_size, jobs);
        defer weights.deinit(allocator);

        if (cfg.verbose > 1) {
            const stats = weightStats(&weights);
            std.debug.print("  local contrast: mean={d:.4} max={d:.4}\n", .{ stats.mean, stats.max });
        }

        try blend.updateWinners(allocator, &image, &weights, best_weights.items, &output.?, jobs);
    }

    if (cfg.verbose > 0) {
        std.debug.print("focus fuse: writing {s}\n", .{cfg.output_path.?});
    }
    try image_io.writeTiff(cfg.output_path.?, &output.?);
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
