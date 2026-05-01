const std = @import("std");
const core = @import("align_stack_core");
const gray = core.gray;
const profiler = core.profiler;

pub const WeightMap = struct {
    width: u32,
    height: u32,
    pixels: []f32,

    pub fn deinit(self: *WeightMap, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

const ScratchPad = struct {
    sum: f64 = 0,
    sum_sqr: f64 = 0,
};

pub fn computeLocalContrastWeights(
    allocator: std.mem.Allocator,
    image: *const gray.GrayImage,
    window_size: u32,
    jobs: usize,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!WeightMap {
    const prof = profiler.scope("fuse.contrast.computeLocalContrastWeights");
    defer prof.end();

    const count = @as(usize, image.width) * @as(usize, image.height);
    const weights = try allocator.alloc(f32, count);
    errdefer allocator.free(weights);
    try computeLocalContrastWeightsInto(image, window_size, jobs, weights);

    return .{
        .width = image.width,
        .height = image.height,
        .pixels = weights,
    };
}

pub fn computeLocalContrastWeightsInto(
    image: *const gray.GrayImage,
    window_size: u32,
    jobs: usize,
    weights: []f32,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    const prof = profiler.scope("fuse.contrast.computeLocalContrastWeightsInto");
    defer prof.end();

    const count = @as(usize, image.width) * @as(usize, image.height);
    std.debug.assert(weights.len >= count);
    @memset(weights[0..count], 0);

    if (window_size < 3 or image.width < window_size or image.height < window_size) {
        return;
    }

    const worker_count = @min(@max(jobs, 1), @as(usize, @intCast(image.height)));
    if (worker_count <= 1) {
        try computeRange(image, window_size, weights[0..count], 0, image.height);
    } else {
        var threads = try std.heap.page_allocator.alloc(std.Thread, worker_count - 1);
        defer std.heap.page_allocator.free(threads);

        const rows_per_worker = std.math.divCeil(usize, image.height, worker_count) catch unreachable;
        var started_threads: usize = 0;
        errdefer {
            for (threads[0..started_threads]) |thread| thread.join();
        }

        for (threads, 0..) |*thread, i| {
            const worker_start = @as(u32, @intCast((i + 1) * rows_per_worker));
            const worker_end = @as(u32, @intCast(@min((i + 2) * rows_per_worker, image.height)));
            thread.* = try std.Thread.spawn(.{}, computeRangeThread, .{ image, window_size, weights[0..count], worker_start, worker_end });
            started_threads += 1;
        }

        const main_end = @as(u32, @intCast(@min(rows_per_worker, image.height)));
        try computeRange(image, window_size, weights[0..count], 0, main_end);
        for (threads) |thread| thread.join();
    }
}

fn computeRangeThread(
    image: *const gray.GrayImage,
    window_size: u32,
    weights: []f32,
    start_row: u32,
    end_row: u32,
) void {
    computeRange(image, window_size, weights, start_row, end_row) catch @panic("OOM");
}

fn computeRange(
    image: *const gray.GrayImage,
    window_size: u32,
    weights: []f32,
    start_row: u32,
    end_row: u32,
) std.mem.Allocator.Error!void {
    const prof = profiler.scope("fuse.contrast.computeRange");
    defer prof.end();

    if (start_row >= end_row) return;

    const border = window_size / 2;
    const first_row = @max(start_row, border);
    const last_row_exclusive = @min(end_row, image.height - border);
    if (first_row >= last_row_exclusive) return;

    const scratch = try std.heap.page_allocator.alloc(ScratchPad, @as(usize, image.width));
    defer std.heap.page_allocator.free(scratch);

    const width = @as(i32, @intCast(image.width));
    const width_usize = @as(usize, image.width);
    const border_i = @as(i32, @intCast(border));
    const window_size_i = @as(i32, @intCast(window_size));
    const full_window_samples = window_size * window_size;
    const pixels = image.pixels;

    {
        var column_usize: usize = 0;
        while (column_usize < width_usize) : (column_usize += 1) {
            var col_sum: f64 = 0;
            var col_sum_sqr: f64 = 0;
            var yy = first_row - border;
            const yy_end = first_row + border;
            while (yy <= yy_end) : (yy += 1) {
                const value = pixels[@as(usize, yy) * width_usize + column_usize];
                col_sum += value;
                col_sum_sqr += value * value;
            }
            scratch[column_usize] = .{
                .sum = col_sum,
                .sum_sqr = col_sum_sqr,
            };
        }
    }

    var row: i32 = @as(i32, @intCast(first_row));
    while (row < @as(i32, @intCast(last_row_exclusive))) : (row += 1) {
        var sum: f64 = 0;
        var sum_sqr: f64 = 0;

        var column: i32 = 0;
        while (column < window_size_i) : (column += 1) {
            const slot = scratch[@as(usize, @intCast(column))];
            sum += slot.sum;
            sum_sqr += slot.sum_sqr;
        }

        var x: i32 = border_i;
        while (true) {
            const out_index = @as(usize, @intCast(row)) * @as(usize, image.width) + @as(usize, @intCast(x));
            weights[out_index] = sampleStdDev(sum, sum_sqr, full_window_samples);
            if (x == width - border_i - 1) break;

            const next_column = x + border_i + 1;
            const old_slot = &scratch[@as(usize, @intCast(x - border_i))];
            const next_slot = scratch[@as(usize, @intCast(next_column))];
            sum += next_slot.sum - old_slot.sum;
            sum_sqr += next_slot.sum_sqr - old_slot.sum_sqr;

            x += 1;
        }

        if (row + 1 >= @as(i32, @intCast(last_row_exclusive))) continue;

        const remove_y = row - border_i;
        const add_y = row + border_i + 1;
        const remove_row_base = @as(usize, @intCast(remove_y)) * width_usize;
        const add_row_base = @as(usize, @intCast(add_y)) * width_usize;
        var column_update: usize = 0;
        while (column_update < width_usize) : (column_update += 1) {
            const slot = &scratch[column_update];
            const removed = pixels[remove_row_base + column_update];
            const added = pixels[add_row_base + column_update];
            slot.sum += added - removed;
            slot.sum_sqr += added * added - removed * removed;
        }
    }
}

fn sampleStdDev(sum: f64, sum_sqr: f64, n: u32) f32 {
    if (n <= 1) return 0;
    const denom = @as(f64, @floatFromInt(n - 1));
    const n_f = @as(f64, @floatFromInt(n));
    const variance = @max((sum_sqr - ((sum * sum) / n_f)) / denom, 0.0);
    return @floatCast(std.math.sqrt(variance));
}

test "sample stddev matches expected simple window" {
    const values = [_]f64{ 0, 1, 1, 2 };
    var sum: f64 = 0;
    var sum_sqr: f64 = 0;
    for (values) |value| {
        sum += value;
        sum_sqr += value * value;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.8164966), sampleStdDev(sum, sum_sqr, 4), 1e-6);
}
