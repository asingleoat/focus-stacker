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

pub const Workspace = struct {
    width: u32,
    worker_count: usize,
    sums_storage: []f64,
    sums_sqr_storage: []f64,
    counts_storage: []u32,

    pub fn init(allocator: std.mem.Allocator, width: u32, worker_count: usize) std.mem.Allocator.Error!Workspace {
        const worker_slots = @max(worker_count, 1);
        const per_worker = @as(usize, width);
        return .{
            .width = width,
            .worker_count = worker_slots,
            .sums_storage = try allocator.alloc(f64, per_worker * worker_slots),
            .sums_sqr_storage = try allocator.alloc(f64, per_worker * worker_slots),
            .counts_storage = try allocator.alloc(u32, per_worker * worker_slots),
        };
    }

    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        allocator.free(self.sums_storage);
        allocator.free(self.sums_sqr_storage);
        allocator.free(self.counts_storage);
    }

    fn sumsFor(self: *Workspace, worker_index: usize) []f64 {
        const width_usize = @as(usize, self.width);
        const start = worker_index * width_usize;
        return self.sums_storage[start .. start + width_usize];
    }

    fn sumsSqrFor(self: *Workspace, worker_index: usize) []f64 {
        const width_usize = @as(usize, self.width);
        const start = worker_index * width_usize;
        return self.sums_sqr_storage[start .. start + width_usize];
    }

    fn countsFor(self: *Workspace, worker_index: usize) []u32 {
        const width_usize = @as(usize, self.width);
        const start = worker_index * width_usize;
        return self.counts_storage[start .. start + width_usize];
    }
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
    const support = try allocator.alloc(f32, count);
    defer allocator.free(support);
    @memset(support, 1.0);
    try computeLocalContrastWeightsInto(image, support, window_size, jobs, weights);

    return .{
        .width = image.width,
        .height = image.height,
        .pixels = weights,
    };
}

pub fn computeLocalContrastWeightsInto(
    image: *const gray.GrayImage,
    support: []const f32,
    window_size: u32,
    jobs: usize,
    weights: []f32,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    var workspace = try Workspace.init(std.heap.page_allocator, image.width, @min(@max(jobs, 1), @as(usize, @intCast(image.height))));
    defer workspace.deinit(std.heap.page_allocator);
    return computeLocalContrastWeightsWithWorkspace(image, support, window_size, jobs, weights, &workspace);
}

pub fn computeLocalContrastWeightsWithWorkspace(
    image: *const gray.GrayImage,
    support: []const f32,
    window_size: u32,
    jobs: usize,
    weights: []f32,
    workspace: *Workspace,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    const prof = profiler.scope("fuse.contrast.computeLocalContrastWeightsInto");
    defer prof.end();

    const count = @as(usize, image.width) * @as(usize, image.height);
    std.debug.assert(weights.len >= count);
    std.debug.assert(support.len >= count);
    std.debug.assert(workspace.width == image.width);
    @memset(weights[0..count], 0);

    if (window_size < 3 or image.width < window_size or image.height < window_size) {
        return;
    }

    const worker_count = @min(@max(jobs, 1), @as(usize, @intCast(image.height)));
    if (worker_count <= 1) {
        try computeRange(image, support, window_size, weights[0..count], 0, image.height, workspace.sumsFor(0), workspace.sumsSqrFor(0), workspace.countsFor(0));
    } else {
        var threads = try std.heap.page_allocator.alloc(std.Thread, worker_count - 1);
        defer std.heap.page_allocator.free(threads);
        var tasks = try std.heap.page_allocator.alloc(ComputeRangeTask, worker_count - 1);
        defer std.heap.page_allocator.free(tasks);

        const rows_per_worker = std.math.divCeil(usize, image.height, worker_count) catch unreachable;
        var started_threads: usize = 0;
        errdefer {
            for (threads[0..started_threads]) |thread| thread.join();
        }

        for (threads, 0..) |*thread, i| {
            const worker_start = @as(u32, @intCast((i + 1) * rows_per_worker));
            const worker_end = @as(u32, @intCast(@min((i + 2) * rows_per_worker, image.height)));
            tasks[i] = .{
                .image = image,
                .support = support,
                .window_size = window_size,
                .weights = weights[0..count],
                .start_row = worker_start,
                .end_row = worker_end,
                .sums = workspace.sumsFor(i + 1),
                .sums_sqr = workspace.sumsSqrFor(i + 1),
                .counts = workspace.countsFor(i + 1),
            };
            thread.* = try std.Thread.spawn(.{}, computeRangeThread, .{&tasks[i]});
            started_threads += 1;
        }

        const main_end = @as(u32, @intCast(@min(rows_per_worker, image.height)));
        try computeRange(image, support, window_size, weights[0..count], 0, main_end, workspace.sumsFor(0), workspace.sumsSqrFor(0), workspace.countsFor(0));
        for (threads) |thread| thread.join();
    }
}

const ComputeRangeTask = struct {
    image: *const gray.GrayImage,
    support: []const f32,
    window_size: u32,
    weights: []f32,
    start_row: u32,
    end_row: u32,
    sums: []f64,
    sums_sqr: []f64,
    counts: []u32,
};

fn computeRangeThread(task: *const ComputeRangeTask) void {
    computeRange(task.image, task.support, task.window_size, task.weights, task.start_row, task.end_row, task.sums, task.sums_sqr, task.counts) catch @panic("OOM");
}

fn computeRange(
    image: *const gray.GrayImage,
    support: []const f32,
    window_size: u32,
    weights: []f32,
    start_row: u32,
    end_row: u32,
    sums: []f64,
    sums_sqr: []f64,
    counts: []u32,
) std.mem.Allocator.Error!void {
    const prof = profiler.scope("fuse.contrast.computeRange");
    defer prof.end();

    if (start_row >= end_row) return;

    const border = window_size / 2;
    const first_row = @max(start_row, border);
    const last_row_exclusive = @min(end_row, image.height - border);
    if (first_row >= last_row_exclusive) return;

    const width = @as(i32, @intCast(image.width));
    const width_usize = @as(usize, image.width);
    std.debug.assert(sums.len >= width_usize);
    std.debug.assert(sums_sqr.len >= width_usize);
    std.debug.assert(counts.len >= width_usize);
    const border_i = @as(i32, @intCast(border));
    const window_size_i = @as(i32, @intCast(window_size));
    const pixels = image.pixels;

    {
        var column_usize: usize = 0;
        while (column_usize < width_usize) : (column_usize += 1) {
            var col_sum: f64 = 0;
            var col_sum_sqr: f64 = 0;
            counts[column_usize] = 0;
            var yy = first_row - border;
            const yy_end = first_row + border;
            while (yy <= yy_end) : (yy += 1) {
                const index = @as(usize, yy) * width_usize + column_usize;
                if (support[index] <= 0.0) continue;
                const value = pixels[index];
                col_sum += value;
                col_sum_sqr += value * value;
                counts[column_usize] += 1;
            }
            sums[column_usize] = col_sum;
            sums_sqr[column_usize] = col_sum_sqr;
        }
    }

    var row: i32 = @as(i32, @intCast(first_row));
    while (row < @as(i32, @intCast(last_row_exclusive))) : (row += 1) {
        var sum: f64 = 0;
        var sum_sqr: f64 = 0;
        var n: u32 = 0;

        var column: i32 = 0;
        while (column < window_size_i) : (column += 1) {
            const idx = @as(usize, @intCast(column));
            sum += sums[idx];
            sum_sqr += sums_sqr[idx];
            n += counts[idx];
        }

        var x: i32 = border_i;
        var out_index = @as(usize, @intCast(row)) * width_usize + @as(usize, @intCast(border_i));
        while (true) {
            if (support[out_index] > 0.0) {
                weights[out_index] = sampleStdDev(sum, sum_sqr, n);
            } else {
                weights[out_index] = 0.0;
            }
            if (x == width - border_i - 1) break;

            const next_column = x + border_i + 1;
            const old_idx = @as(usize, @intCast(x - border_i));
            const next_idx = @as(usize, @intCast(next_column));
            sum += sums[next_idx] - sums[old_idx];
            sum_sqr += sums_sqr[next_idx] - sums_sqr[old_idx];
            n += counts[next_idx] - counts[old_idx];

            x += 1;
            out_index += 1;
        }

        if (row + 1 >= @as(i32, @intCast(last_row_exclusive))) continue;

        const remove_y = row - border_i;
        const add_y = row + border_i + 1;
        const remove_row_base = @as(usize, @intCast(remove_y)) * width_usize;
        const add_row_base = @as(usize, @intCast(add_y)) * width_usize;
        var column_update: usize = 0;
        while (column_update < width_usize) : (column_update += 1) {
            const remove_index = remove_row_base + column_update;
            const add_index = add_row_base + column_update;
            if (support[remove_index] > 0.0) {
                const removed = pixels[remove_index];
                sums[column_update] -= removed;
                sums_sqr[column_update] -= removed * removed;
                counts[column_update] -= 1;
            }
            if (support[add_index] > 0.0) {
                const added = pixels[add_index];
                sums[column_update] += added;
                sums_sqr[column_update] += added * added;
                counts[column_update] += 1;
            }
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

fn sampleStdDev5x5(sum: f64, sum_sqr: f64) f32 {
    const variance = @max((sum_sqr - ((sum * sum) / 25.0)) / 24.0, 0.0);
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
