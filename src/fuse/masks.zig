const std = @import("std");
const core = @import("align_stack_core");
const image_io = core.image_io;
const profiler = core.profiler;

pub fn applySupportInto(image: *const image_io.Image, weights: []f32) void {
    const prof = profiler.scope("fuse.masks.applySupportInto");
    defer prof.end();

    if (image.info.extra_channels == 0) return;
    const pixel_channels = @as(usize, image.info.color_channels + image.info.extra_channels);
    const alpha_offset = @as(usize, image.info.color_channels);

    switch (image.pixels) {
        .u8 => |src| {
            for (weights, 0..) |*weight, index| {
                const alpha_index = index * pixel_channels + alpha_offset;
                const support = @as(f32, @floatFromInt(src[alpha_index])) / 255.0;
                weight.* *= support;
            }
        },
        .u16 => |src| {
            for (weights, 0..) |*weight, index| {
                const alpha_index = index * pixel_channels + alpha_offset;
                const support = @as(f32, @floatFromInt(src[alpha_index])) / 65535.0;
                weight.* *= support;
            }
        },
    }
}

pub fn fillBinarySupport(image: *const image_io.Image, output: []f32) void {
    const count = @as(usize, image.info.width) * @as(usize, image.info.height);
    std.debug.assert(output.len >= count);

    if (image.info.extra_channels == 0) {
        @memset(output[0..count], 1.0);
        return;
    }

    const pixel_channels = @as(usize, image.info.color_channels + image.info.extra_channels);
    const alpha_offset = @as(usize, image.info.color_channels);
    switch (image.pixels) {
        .u8 => |src| {
            for (0..count) |index| {
                const alpha_index = index * pixel_channels + alpha_offset;
                output[index] = if (src[alpha_index] > 0) 1.0 else 0.0;
            }
        },
        .u16 => |src| {
            for (0..count) |index| {
                const alpha_index = index * pixel_channels + alpha_offset;
                output[index] = if (src[alpha_index] > 0) 1.0 else 0.0;
            }
        },
    }
}

pub fn accumulateBinarySupportMax(image: *const image_io.Image, output: []f32) void {
    const count = @as(usize, image.info.width) * @as(usize, image.info.height);
    std.debug.assert(output.len >= count);

    if (image.info.extra_channels == 0) {
        @memset(output[0..count], 1.0);
        return;
    }

    const pixel_channels = @as(usize, image.info.color_channels + image.info.extra_channels);
    const alpha_offset = @as(usize, image.info.color_channels);
    switch (image.pixels) {
        .u8 => |src| {
            for (0..count) |index| {
                const alpha_index = index * pixel_channels + alpha_offset;
                if (src[alpha_index] > 0) output[index] = 1.0;
            }
        },
        .u16 => |src| {
            for (0..count) |index| {
                const alpha_index = index * pixel_channels + alpha_offset;
                if (src[alpha_index] > 0) output[index] = 1.0;
            }
        },
    }
}

pub fn blurFiveTapInto(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    jobs: usize,
    input: []const f32,
    scratch: []f32,
    output: []f32,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    const prof = profiler.scope("fuse.masks.blurFiveTapInto");
    defer prof.end();

    const count = @as(usize, width) * @as(usize, height);
    std.debug.assert(input.len >= count);
    std.debug.assert(scratch.len >= count);
    std.debug.assert(output.len >= count);

    try parallelRows(allocator, width, height, jobs, input, scratch, horizontalPassRange);
    try parallelRows(allocator, width, height, jobs, scratch, output, verticalPassRange);
}

fn parallelRows(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    jobs: usize,
    input: []const f32,
    output: []f32,
    comptime passFn: fn (u32, u32, u32, u32, []const f32, []f32) void,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    const worker_count = @min(@max(jobs, 1), @as(usize, @intCast(height)));
    if (worker_count <= 1) {
        passFn(width, height, 0, height, input, output);
        return;
    }

    var threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);

    const rows_per_worker = std.math.divCeil(usize, height, worker_count) catch unreachable;
    var started_threads: usize = 0;
    errdefer {
        for (threads[0..started_threads]) |thread| thread.join();
    }

    for (threads, 0..) |*thread, i| {
        const start_row = @as(u32, @intCast((i + 1) * rows_per_worker));
        const end_row = @as(u32, @intCast(@min((i + 2) * rows_per_worker, height)));
        thread.* = try std.Thread.spawn(.{}, passThread, .{ width, height, start_row, end_row, input, output, passFn });
        started_threads += 1;
    }

    const main_end = @as(u32, @intCast(@min(rows_per_worker, height)));
    passFn(width, height, 0, main_end, input, output);
    for (threads) |thread| thread.join();
}

fn passThread(
    width: u32,
    height: u32,
    start_row: u32,
    end_row: u32,
    input: []const f32,
    output: []f32,
    comptime passFn: fn (u32, u32, u32, u32, []const f32, []f32) void,
) void {
    passFn(width, height, start_row, end_row, input, output);
}

fn horizontalPassRange(
    width: u32,
    height: u32,
    start_row: u32,
    end_row: u32,
    input: []const f32,
    output: []f32,
) void {
    _ = height;
    const w = @as(usize, width);
    for (start_row..end_row) |row| {
        const row_base = @as(usize, row) * w;
        for (0..w) |x| {
            const xm2 = if (x >= 2) x - 2 else 0;
            const xm1 = if (x >= 1) x - 1 else 0;
            const xp1 = @min(x + 1, w - 1);
            const xp2 = @min(x + 2, w - 1);
            output[row_base + x] =
                (input[row_base + xm2] +
                4.0 * input[row_base + xm1] +
                6.0 * input[row_base + x] +
                4.0 * input[row_base + xp1] +
                input[row_base + xp2]) / 16.0;
        }
    }
}

fn verticalPassRange(
    width: u32,
    height: u32,
    start_row: u32,
    end_row: u32,
    input: []const f32,
    output: []f32,
) void {
    const w = @as(usize, width);
    const h = @as(usize, height);
    for (start_row..end_row) |row| {
        const y = @as(usize, row);
        const ym2 = if (y >= 2) y - 2 else 0;
        const ym1 = if (y >= 1) y - 1 else 0;
        const yp1 = @min(y + 1, h - 1);
        const yp2 = @min(y + 2, h - 1);
        for (0..w) |x| {
            output[y * w + x] =
                (input[ym2 * w + x] +
                4.0 * input[ym1 * w + x] +
                6.0 * input[y * w + x] +
                4.0 * input[yp1 * w + x] +
                input[yp2 * w + x]) / 16.0;
        }
    }
}

test "five tap blur keeps uniform weights unchanged" {
    const allocator = std.testing.allocator;
    const input = try allocator.dupe(f32, &[_]f32{
        1, 1, 1,
        1, 1, 1,
        1, 1, 1,
    });
    defer allocator.free(input);
    const scratch = try allocator.alloc(f32, input.len);
    defer allocator.free(scratch);
    const output = try allocator.alloc(f32, input.len);
    defer allocator.free(output);

    try blurFiveTapInto(allocator, 3, 3, 1, input, scratch, output);
    for (output) |value| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), value, 1e-6);
    }
}
