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

pub const SoftBlendState = struct {
    weight_sums: []f32,
    pixel_sums: []f32,
    pixel_channels: usize,

    pub fn init(allocator: std.mem.Allocator, info: image_io.ImageInfo) std.mem.Allocator.Error!SoftBlendState {
        const count = @as(usize, info.width) * @as(usize, info.height);
        const pixel_channels = @as(usize, info.color_channels);
        const weight_sums = try allocator.alloc(f32, count);
        errdefer allocator.free(weight_sums);
        const pixel_sums = try allocator.alloc(f32, count * pixel_channels);
        errdefer allocator.free(pixel_sums);
        @memset(weight_sums, 0);
        @memset(pixel_sums, 0);
        return .{
            .weight_sums = weight_sums,
            .pixel_sums = pixel_sums,
            .pixel_channels = pixel_channels,
        };
    }

    pub fn deinit(self: *SoftBlendState, allocator: std.mem.Allocator) void {
        allocator.free(self.weight_sums);
        allocator.free(self.pixel_sums);
    }
};

pub fn accumulateSoft(
    allocator: std.mem.Allocator,
    image: *const image_io.Image,
    weights: []const f32,
    state: *SoftBlendState,
    jobs: usize,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    const prof = profiler.scope("fuse.blend.accumulateSoft");
    defer prof.end();

    const worker_count = @min(@max(jobs, 1), @as(usize, @intCast(image.info.height)));
    if (worker_count <= 1) {
        accumulateRange(image, weights, state, 0, image.info.height);
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
        thread.* = try std.Thread.spawn(.{}, accumulateRangeThread, .{ image, weights, state, start_row, end_row });
        started_threads += 1;
    }

    const main_end = @as(u32, @intCast(@min(rows_per_worker, image.info.height)));
    accumulateRange(image, weights, state, 0, main_end);
    for (threads) |thread| thread.join();
}

fn accumulateRangeThread(
    image: *const image_io.Image,
    weights: []const f32,
    state: *SoftBlendState,
    start_row: u32,
    end_row: u32,
) void {
    accumulateRange(image, weights, state, start_row, end_row);
}

fn accumulateRange(
    image: *const image_io.Image,
    weights: []const f32,
    state: *SoftBlendState,
    start_row: u32,
    end_row: u32,
) void {
    const prof = profiler.scope("fuse.blend.accumulateRange");
    defer prof.end();

    const src_pixel_channels = @as(usize, image.info.color_channels + image.info.extra_channels);
    const width = @as(usize, image.info.width);
    const dst_channels = state.pixel_channels;

    switch (image.pixels) {
        .u8 => |src| {
            for (start_row..end_row) |row| {
                const row_base = @as(usize, row) * width;
                for (0..width) |x| {
                    const pixel_index = row_base + x;
                    const weight = weights[pixel_index];
                    if (weight <= 0) continue;
                    state.weight_sums[pixel_index] += weight;
                    const src_base = pixel_index * src_pixel_channels;
                    const dst_base = pixel_index * dst_channels;
                    for (0..dst_channels) |channel| {
                        state.pixel_sums[dst_base + channel] += weight * @as(f32, @floatFromInt(src[src_base + channel]));
                    }
                }
            }
        },
        .u16 => |src| {
            for (start_row..end_row) |row| {
                const row_base = @as(usize, row) * width;
                for (0..width) |x| {
                    const pixel_index = row_base + x;
                    const weight = weights[pixel_index];
                    if (weight <= 0) continue;
                    state.weight_sums[pixel_index] += weight;
                    const src_base = pixel_index * src_pixel_channels;
                    const dst_base = pixel_index * dst_channels;
                    for (0..dst_channels) |channel| {
                        state.pixel_sums[dst_base + channel] += weight * @as(f32, @floatFromInt(src[src_base + channel]));
                    }
                }
            }
        },
    }
}

pub fn finalizeSoft(state: *const SoftBlendState, output: *image_io.Image) void {
    const prof = profiler.scope("fuse.blend.finalizeSoft");
    defer prof.end();

    const pixel_count = @as(usize, output.info.width) * @as(usize, output.info.height);
    const pixel_channels = state.pixel_channels;
    switch (output.pixels) {
        .u8 => |dst| {
            for (0..pixel_count) |pixel_index| {
                const dst_base = pixel_index * pixel_channels;
                const weight = state.weight_sums[pixel_index];
                if (weight <= 1e-12) {
                    @memset(dst[dst_base .. dst_base + pixel_channels], 0);
                    continue;
                }
                const inv = 1.0 / weight;
                for (0..pixel_channels) |channel| {
                    const value = state.pixel_sums[dst_base + channel] * inv;
                    dst[dst_base + channel] = @intFromFloat(std.math.clamp(value + 0.5, 0.0, 255.0));
                }
            }
        },
        .u16 => |dst| {
            for (0..pixel_count) |pixel_index| {
                const dst_base = pixel_index * pixel_channels;
                const weight = state.weight_sums[pixel_index];
                if (weight <= 1e-12) {
                    @memset(dst[dst_base .. dst_base + pixel_channels], 0);
                    continue;
                }
                const inv = 1.0 / weight;
                for (0..pixel_channels) |channel| {
                    const value = state.pixel_sums[dst_base + channel] * inv;
                    dst[dst_base + channel] = @intFromFloat(std.math.clamp(value + 0.5, 0.0, 65535.0));
                }
            }
        },
    }
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

    const src_pixel_channels = @as(usize, image.info.color_channels + image.info.extra_channels);
    const dst_pixel_channels = @as(usize, output.info.color_channels + output.info.extra_channels);
    const width = @as(usize, image.info.width);

    switch (image.pixels) {
        .u8 => |src| switch (output.pixels) {
            .u8 => |dst| {
                for (start_row..end_row) |row| {
                    const row_base = @as(usize, row) * width;
                    for (0..width) |x| {
                        const pixel_index = row_base + x;
                        const weight = effectiveWeightU8(image.info, src, weights.pixels[pixel_index], pixel_index, src_pixel_channels);
                        if (weight <= best_weights[pixel_index]) continue;
                        best_weights[pixel_index] = weight;
                        const src_base = pixel_index * src_pixel_channels;
                        const dst_base = pixel_index * dst_pixel_channels;
                        @memcpy(dst[dst_base .. dst_base + dst_pixel_channels], src[src_base .. src_base + dst_pixel_channels]);
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
                        const weight = effectiveWeightU16(image.info, src, weights.pixels[pixel_index], pixel_index, src_pixel_channels);
                        if (weight <= best_weights[pixel_index]) continue;
                        best_weights[pixel_index] = weight;
                        const src_base = pixel_index * src_pixel_channels;
                        const dst_base = pixel_index * dst_pixel_channels;
                        @memcpy(dst[dst_base .. dst_base + dst_pixel_channels], src[src_base .. src_base + dst_pixel_channels]);
                    }
                }
            },
            else => unreachable,
        },
    }
}

fn effectiveWeightU8(
    info: image_io.ImageInfo,
    src: []const u8,
    base_weight: f32,
    pixel_index: usize,
    pixel_channels: usize,
) f32 {
    if (info.extra_channels == 0) return base_weight;
    const alpha_index = pixel_index * pixel_channels + @as(usize, info.color_channels);
    const support = @as(f32, @floatFromInt(src[alpha_index])) / 255.0;
    return base_weight * support;
}

fn effectiveWeightU16(
    info: image_io.ImageInfo,
    src: []const u16,
    base_weight: f32,
    pixel_index: usize,
    pixel_channels: usize,
) f32 {
    if (info.extra_channels == 0) return base_weight;
    const alpha_index = pixel_index * pixel_channels + @as(usize, info.color_channels);
    const support = @as(f32, @floatFromInt(src[alpha_index])) / 65535.0;
    return base_weight * support;
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

test "winner update discounts low-support alpha" {
    const allocator = std.testing.allocator;
    var output = try allocateOutput(allocator, .{
        .format = .tiff,
        .width = 1,
        .height = 1,
        .color_model = .rgb,
        .sample_type = .u8,
        .color_channels = 3,
        .extra_channels = 0,
        .exposure_value = null,
    });
    defer output.deinit(allocator);

    const best = try allocator.alloc(f32, 1);
    defer allocator.free(best);
    @memset(best, -std.math.inf(f32));

    var weights = contrast.WeightMap{
        .width = 1,
        .height = 1,
        .pixels = try allocator.dupe(f32, &[_]f32{1.0}),
    };
    defer weights.deinit(allocator);

    var low_support = image_io.Image{
        .info = .{
            .format = .tiff,
            .width = 1,
            .height = 1,
            .color_model = .rgb,
            .sample_type = .u8,
            .color_channels = 3,
            .extra_channels = 1,
            .exposure_value = null,
        },
        .pixels = .{ .u8 = try allocator.dupe(u8, &[_]u8{ 200, 10, 10, 32 }) },
    };
    defer low_support.deinit(allocator);

    var full_support = image_io.Image{
        .info = low_support.info,
        .pixels = .{ .u8 = try allocator.dupe(u8, &[_]u8{ 10, 200, 10, 255 }) },
    };
    defer full_support.deinit(allocator);

    try updateWinners(allocator, &low_support, &weights, best, &output, 1);
    weights.pixels[0] = 0.2;
    try updateWinners(allocator, &full_support, &weights, best, &output, 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 200, 10 }, output.pixels.u8);
}

test "soft blend averages weighted inputs" {
    const allocator = std.testing.allocator;
    var output = try allocateOutput(allocator, .{
        .format = .tiff,
        .width = 1,
        .height = 1,
        .color_model = .rgb,
        .sample_type = .u8,
        .color_channels = 3,
        .extra_channels = 0,
        .exposure_value = null,
    });
    defer output.deinit(allocator);

    var state = try SoftBlendState.init(allocator, output.info);
    defer state.deinit(allocator);

    var image_a = image_io.Image{
        .info = output.info,
        .pixels = .{ .u8 = try allocator.dupe(u8, &[_]u8{ 10, 20, 30 }) },
    };
    defer image_a.deinit(allocator);
    var image_b = image_io.Image{
        .info = output.info,
        .pixels = .{ .u8 = try allocator.dupe(u8, &[_]u8{ 110, 120, 130 }) },
    };
    defer image_b.deinit(allocator);

    try accumulateSoft(allocator, &image_a, &[_]f32{1.0}, &state, 1);
    try accumulateSoft(allocator, &image_b, &[_]f32{3.0}, &state, 1);
    finalizeSoft(&state, &output);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 85, 95, 105 }, output.pixels.u8);
}
