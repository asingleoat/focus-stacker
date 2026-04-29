const std = @import("std");
const profiler = @import("profiler.zig");
const smooth_numbers = @import("smooth_numbers");

const c = @cImport({
    @cInclude("pffft.h");
});

pub const Backend = enum {
    cpu_pffft,
    gpu_vkfft,
};

pub const Complex = extern struct {
    re: f32 = 0,
    im: f32 = 0,

    pub fn mulConj(self: Complex, other: Complex) Complex {
        return .{
            .re = self.re * other.re + self.im * other.im,
            .im = self.im * other.re - self.re * other.im,
        };
    }
};

pub const ComplexPlan2D = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    row_setup: *c.PFFFT_Setup,
    col_setup: *c.PFFFT_Setup,
    row_in: []f32,
    row_out: []f32,
    row_work: []f32,
    col_in: []f32,
    col_out: []f32,
    col_work: []f32,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !ComplexPlan2D {
        const row_setup = c.pffft_new_setup(@as(c_int, @intCast(width)), c.PFFFT_COMPLEX) orelse return error.UnsupportedFftLength;
        errdefer c.pffft_destroy_setup(row_setup);
        const col_setup = c.pffft_new_setup(@as(c_int, @intCast(height)), c.PFFFT_COMPLEX) orelse return error.UnsupportedFftLength;
        errdefer c.pffft_destroy_setup(col_setup);

        const row_len = 2 * @as(usize, width);
        const col_len = 2 * @as(usize, height);

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .row_setup = row_setup,
            .col_setup = col_setup,
            .row_in = try allocAlignedFloatBuffer(row_len),
            .row_out = try allocAlignedFloatBuffer(row_len),
            .row_work = try allocAlignedFloatBuffer(row_len),
            .col_in = try allocAlignedFloatBuffer(col_len),
            .col_out = try allocAlignedFloatBuffer(col_len),
            .col_work = try allocAlignedFloatBuffer(col_len),
        };
    }

    pub fn deinit(self: *ComplexPlan2D) void {
        freeAlignedFloatBuffer(self.row_in);
        freeAlignedFloatBuffer(self.row_out);
        freeAlignedFloatBuffer(self.row_work);
        freeAlignedFloatBuffer(self.col_in);
        freeAlignedFloatBuffer(self.col_out);
        freeAlignedFloatBuffer(self.col_work);
        c.pffft_destroy_setup(self.row_setup);
        c.pffft_destroy_setup(self.col_setup);
        self.* = undefined;
    }

    pub fn transformInPlace(self: *ComplexPlan2D, data: []Complex, inverse: bool) void {
        const prof = profiler.scope("fft_backend.pffftTransform2d");
        defer prof.end();

        const direction: c.pffft_direction_t = if (inverse) c.PFFFT_BACKWARD else c.PFFFT_FORWARD;
        const row_stride = @as(usize, self.width);
        const col_stride = @as(usize, self.height);

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const row = data[@as(usize, y) * row_stride ..][0..row_stride];
            loadComplexRow(row, self.row_in);
            c.pffft_transform_ordered(self.row_setup, self.row_in.ptr, self.row_out.ptr, self.row_work.ptr, direction);
            storeComplexRow(self.row_out, row);
        }

        var x: u32 = 0;
        while (x < self.width) : (x += 1) {
            var row: u32 = 0;
            while (row < self.height) : (row += 1) {
                const value = data[@as(usize, row) * row_stride + @as(usize, x)];
                const base = 2 * @as(usize, row);
                self.col_in[base] = value.re;
                self.col_in[base + 1] = value.im;
            }
            c.pffft_transform_ordered(self.col_setup, self.col_in.ptr, self.col_out.ptr, self.col_work.ptr, direction);
            row = 0;
            while (row < self.height) : (row += 1) {
                const base = 2 * @as(usize, row);
                data[@as(usize, row) * row_stride + @as(usize, x)] = .{
                    .re = self.col_out[base],
                    .im = self.col_out[base + 1],
                };
            }
        }

        if (inverse) {
            const scale = @as(f32, @floatFromInt(self.width * self.height));
            for (data) |*value| {
                value.re /= scale;
                value.im /= scale;
            }
        }

        _ = col_stride;
    }
};

pub fn preferredBackend() Backend {
    return .cpu_pffft;
}

pub fn largestSmoothLengthAtMost(k: u32) u32 {
    if (k <= 1) return k;
    return @as(u32, @intCast(smooth_numbers.largestNSmoothLessThanK(std.heap.page_allocator, 11, k) catch return k));
}

pub fn largestUsableTruncatedComplexLength(requested: u32) u32 {
    if (requested == 0) return 0;

    const trimmed = largestSmoothLengthAtMost(requested);
    if (c.pffft_is_valid_size(@as(c_int, @intCast(trimmed)), c.PFFFT_COMPLEX) != 0) {
        return trimmed;
    }

    const lower = c.pffft_nearest_transform_size(@as(c_int, @intCast(trimmed)), c.PFFFT_COMPLEX, 0);
    if (lower > 0 and lower <= @as(c_int, @intCast(requested))) {
        return @as(u32, @intCast(lower));
    }

    if (c.pffft_is_valid_size(@as(c_int, @intCast(requested)), c.PFFFT_COMPLEX) != 0) {
        return requested;
    }

    return @as(u32, @intCast(c.pffft_nearest_transform_size(@as(c_int, @intCast(requested)), c.PFFFT_COMPLEX, 1)));
}

pub fn nearestValidComplexLength(requested: u32) u32 {
    if (requested == 0) return 0;
    if (c.pffft_is_valid_size(@as(c_int, @intCast(requested)), c.PFFFT_COMPLEX) != 0) {
        return requested;
    }
    return @as(u32, @intCast(c.pffft_nearest_transform_size(@as(c_int, @intCast(requested)), c.PFFFT_COMPLEX, 1)));
}

fn allocAlignedFloatBuffer(len: usize) ![]f32 {
    const ptr = c.pffft_aligned_malloc(len * @sizeOf(f32)) orelse return error.OutOfMemory;
    const typed: [*]f32 = @ptrCast(@alignCast(ptr));
    return typed[0..len];
}

fn freeAlignedFloatBuffer(buffer: []f32) void {
    c.pffft_aligned_free(buffer.ptr);
}

fn loadComplexRow(src: []const Complex, dst: []f32) void {
    std.debug.assert(dst.len >= 2 * src.len);
    for (src, 0..) |value, idx| {
        dst[2 * idx] = value.re;
        dst[2 * idx + 1] = value.im;
    }
}

fn storeComplexRow(src: []const f32, dst: []Complex) void {
    std.debug.assert(src.len >= 2 * dst.len);
    for (dst, 0..) |*value, idx| {
        value.* = .{
            .re = src[2 * idx],
            .im = src[2 * idx + 1],
        };
    }
}

test "largestSmoothLengthAtMost uses vendored 11-smooth selector" {
    try std.testing.expectEqual(@as(u32, 100), largestSmoothLengthAtMost(105));
    try std.testing.expectEqual(@as(u32, 126), largestSmoothLengthAtMost(128));
}

test "largest usable truncated complex length follows smooth truncation policy" {
    try std.testing.expectEqual(@as(u32, 96), largestUsableTruncatedComplexLength(105));
    try std.testing.expectEqual(@as(u32, 96), largestUsableTruncatedComplexLength(128));
}

test "nearest valid complex length preserves current non-truncating matcher behavior" {
    try std.testing.expectEqual(@as(u32, 128), nearestValidComplexLength(105));
    try std.testing.expectEqual(@as(u32, 128), nearestValidComplexLength(128));
}
