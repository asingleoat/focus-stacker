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
    n: u32 = 0,
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
    @memset(weights, 0);

    if (window_size < 3 or image.width < window_size or image.height < window_size) {
        return .{
            .width = image.width,
            .height = image.height,
            .pixels = weights,
        };
    }

    const worker_count = @min(@max(jobs, 1), @as(usize, @intCast(image.height)));
    if (worker_count <= 1) {
        try computeRange(image, window_size, weights, 0, image.height);
    } else {
        var threads = try allocator.alloc(std.Thread, worker_count - 1);
        defer allocator.free(threads);

        const rows_per_worker = std.math.divCeil(usize, image.height, worker_count) catch unreachable;
        var started_threads: usize = 0;
        errdefer {
            for (threads[0..started_threads]) |thread| thread.join();
        }

        for (threads, 0..) |*thread, i| {
            const worker_start = @as(u32, @intCast((i + 1) * rows_per_worker));
            const worker_end = @as(u32, @intCast(@min((i + 2) * rows_per_worker, image.height)));
            thread.* = try std.Thread.spawn(.{}, computeRangeThread, .{ image, window_size, weights, worker_start, worker_end });
            started_threads += 1;
        }

        const main_end = @as(u32, @intCast(@min(rows_per_worker, image.height)));
        try computeRange(image, window_size, weights, 0, main_end);
        for (threads) |thread| thread.join();
    }

    return .{
        .width = image.width,
        .height = image.height,
        .pixels = weights,
    };
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

    const scratch = try std.heap.page_allocator.alloc(ScratchPad, @as(usize, image.width) + 1);
    defer std.heap.page_allocator.free(scratch);

    const width = @as(i32, @intCast(image.width));
    const border_i = @as(i32, @intCast(border));
    const window_size_i = @as(i32, @intCast(window_size));

    var row: i32 = @as(i32, @intCast(first_row));
    while (row < @as(i32, @intCast(last_row_exclusive))) : (row += 1) {
        var sum: f64 = 0;
        var sum_sqr: f64 = 0;
        var n: u32 = 0;

        var column: i32 = 0;
        while (column < window_size_i) : (column += 1) {
            var col_sum: f64 = 0;
            var col_sum_sqr: f64 = 0;
            var col_n: u32 = 0;

            var yy = row - border_i;
            while (yy <= row + border_i) : (yy += 1) {
                const value = image.pixel(@intCast(column), @intCast(yy));
                col_sum += value;
                col_sum_sqr += value * value;
                col_n += 1;
            }

            const slot = &scratch[@as(usize, @intCast(column))];
            slot.sum = col_sum;
            slot.sum_sqr = col_sum_sqr;
            slot.n = col_n;
            sum += col_sum;
            sum_sqr += col_sum_sqr;
            n += col_n;
        }

        var x: i32 = border_i;
        while (true) {
            const out_index = @as(usize, @intCast(row)) * @as(usize, image.width) + @as(usize, @intCast(x));
            weights[out_index] = sampleStdDev(sum, sum_sqr, n);
            if (x == width - border_i - 1) break;

            const next_column = x + border_i + 1;
            var next_sum: f64 = 0;
            var next_sum_sqr: f64 = 0;
            var next_n: u32 = 0;
            var yy = row - border_i;
            while (yy <= row + border_i) : (yy += 1) {
                const value = image.pixel(@intCast(next_column), @intCast(yy));
                next_sum += value;
                next_sum_sqr += value * value;
                next_n += 1;
            }

            const old_slot = &scratch[@as(usize, @intCast(x - border_i))];
            sum += next_sum - old_slot.sum;
            sum_sqr += next_sum_sqr - old_slot.sum_sqr;
            n += next_n - old_slot.n;
            old_slot.* = .{
                .sum = next_sum,
                .sum_sqr = next_sum_sqr,
                .n = next_n,
            };

            x += 1;
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
