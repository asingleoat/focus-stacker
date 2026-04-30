const std = @import("std");
const core = @import("align_stack_core");
const image_io = core.image_io;
const profiler = core.profiler;
const contrast = @import("contrast.zig");

pub fn allocateOutput(
    allocator: std.mem.Allocator,
    info: image_io.ImageInfo,
) std.mem.Allocator.Error!image_io.Image {
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

pub fn updateWinners(
    allocator: std.mem.Allocator,
    image: *const image_io.Image,
    weights: *const contrast.WeightMap,
    best_weights: []f32,
    output: *image_io.Image,
    jobs: usize,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    const prof = profiler.scope("fuse.blend.updateWinners");
    defer prof.end();

    const worker_count = @min(@max(jobs, 1), @as(usize, @intCast(image.info.height)));
    if (worker_count <= 1) {
        updateRange(image, weights, best_weights, output, 0, image.info.height);
        return;
    }

    var threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);

    const rows_per_worker = std.math.divCeil(usize, image.info.height, worker_count) catch unreachable;
    var started_threads: usize = 0;
    errdefer {
        for (threads[0..started_threads]) |thread| thread.join();
    }

    for (threads, 0..) |*thread, i| {
        const start_row = @as(u32, @intCast((i + 1) * rows_per_worker));
        const end_row = @as(u32, @intCast(@min((i + 2) * rows_per_worker, image.info.height)));
        thread.* = try std.Thread.spawn(.{}, updateRangeThread, .{ image, weights, best_weights, output, start_row, end_row });
        started_threads += 1;
    }

    const main_end = @as(u32, @intCast(@min(rows_per_worker, image.info.height)));
    updateRange(image, weights, best_weights, output, 0, main_end);
    for (threads) |thread| thread.join();
}

fn updateRangeThread(
    image: *const image_io.Image,
    weights: *const contrast.WeightMap,
    best_weights: []f32,
    output: *image_io.Image,
    start_row: u32,
    end_row: u32,
) void {
    updateRange(image, weights, best_weights, output, start_row, end_row);
}

fn updateRange(
    image: *const image_io.Image,
    weights: *const contrast.WeightMap,
    best_weights: []f32,
    output: *image_io.Image,
    start_row: u32,
    end_row: u32,
) void {
    const prof = profiler.scope("fuse.blend.updateRange");
    defer prof.end();

    const pixel_channels = @as(usize, image.info.color_channels + image.info.extra_channels);
    const width = @as(usize, image.info.width);

    switch (image.pixels) {
        .u8 => |src| switch (output.pixels) {
            .u8 => |dst| {
                for (start_row..end_row) |row| {
                    const row_base = @as(usize, row) * width;
                    for (0..width) |x| {
                        const pixel_index = row_base + x;
                        const weight = weights.pixels[pixel_index];
                        if (weight <= best_weights[pixel_index]) continue;
                        best_weights[pixel_index] = weight;
                        const src_base = pixel_index * pixel_channels;
                        const dst_base = pixel_index * pixel_channels;
                        @memcpy(dst[dst_base .. dst_base + pixel_channels], src[src_base .. src_base + pixel_channels]);
                    }
                }
            },
            else => unreachable,
        },
        .u16 => |src| switch (output.pixels) {
            .u16 => |dst| {
                for (start_row..end_row) |row| {
                    const row_base = @as(usize, row) * width;
                    for (0..width) |x| {
                        const pixel_index = row_base + x;
                        const weight = weights.pixels[pixel_index];
                        if (weight <= best_weights[pixel_index]) continue;
                        best_weights[pixel_index] = weight;
                        const src_base = pixel_index * pixel_channels;
                        const dst_base = pixel_index * pixel_channels;
                        @memcpy(dst[dst_base .. dst_base + pixel_channels], src[src_base .. src_base + pixel_channels]);
                    }
                }
            },
            else => unreachable,
        },
    }
}

test "winner update prefers higher weight" {
    const allocator = std.testing.allocator;
    var output = try allocateOutput(allocator, .{
        .format = .tiff,
        .width = 2,
        .height = 1,
        .color_model = .rgb,
        .sample_type = .u8,
        .color_channels = 3,
        .extra_channels = 0,
        .exposure_value = null,
    });
    defer output.deinit(allocator);

    const best = try allocator.alloc(f32, 2);
    defer allocator.free(best);
    @memset(best, -std.math.inf(f32));

    var weights = contrast.WeightMap{
        .width = 2,
        .height = 1,
        .pixels = try allocator.dupe(f32, &[_]f32{ 0.1, 0.2 }),
    };
    defer weights.deinit(allocator);

    var image = image_io.Image{
        .info = output.info,
        .pixels = .{ .u8 = try allocator.dupe(u8, &[_]u8{ 1, 2, 3, 4, 5, 6 }) },
    };
    defer image.deinit(allocator);

    try updateWinners(allocator, &image, &weights, best, &output, 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6 }, output.pixels.u8);
}
