const std = @import("std");
const gray = @import("gray.zig");

pub const CornerWorkspace = struct {
    allocator: std.mem.Allocator,
    gx: []f32 = &.{},
    gy: []f32 = &.{},
    tmp: []f32 = &.{},
    blur_tmp: []f32 = &.{},
    st_xx: []f32 = &.{},
    st_xy: []f32 = &.{},
    st_yy: []f32 = &.{},
    smooth_kernel: []f64 = &.{},
    grad_kernel: []f64 = &.{},
    kernel_scale: ?f64 = null,

    pub fn init(allocator: std.mem.Allocator) CornerWorkspace {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CornerWorkspace) void {
        freeSlice(self.allocator, &self.gx);
        freeSlice(self.allocator, &self.gy);
        freeSlice(self.allocator, &self.tmp);
        freeSlice(self.allocator, &self.blur_tmp);
        freeSlice(self.allocator, &self.st_xx);
        freeSlice(self.allocator, &self.st_xy);
        freeSlice(self.allocator, &self.st_yy);
        freeSliceF64(self.allocator, &self.smooth_kernel);
        freeSliceF64(self.allocator, &self.grad_kernel);
        self.* = undefined;
    }

    pub fn cornerResponseInto(
        self: *CornerWorkspace,
        src: *const gray.GrayImage,
        scale: f64,
        response_pixels: []f32,
    ) std.mem.Allocator.Error!gray.GrayImage {
        const pixel_count = @as(usize, src.width) * @as(usize, src.height);
        std.debug.assert(response_pixels.len >= pixel_count);

        try self.ensureImageCapacity(pixel_count);
        try self.ensureKernels(scale);

        var gx = imageView(src.width, src.height, self.gx[0..pixel_count]);
        var gy = imageView(src.width, src.height, self.gy[0..pixel_count]);
        var tmp = imageView(src.width, src.height, self.tmp[0..pixel_count]);
        var blur_tmp = imageView(src.width, src.height, self.blur_tmp[0..pixel_count]);
        var st_xx = imageView(src.width, src.height, self.st_xx[0..pixel_count]);
        var st_xy = imageView(src.width, src.height, self.st_xy[0..pixel_count]);
        var st_yy = imageView(src.width, src.height, self.st_yy[0..pixel_count]);
        const response = imageView(src.width, src.height, response_pixels[0..pixel_count]);

        gaussianGradientWithKernels(src, self.smooth_kernel, self.grad_kernel, &tmp, &gx, &gy);

        multiplyInto(&gx, &gx, &tmp);
        gaussianSmoothingWithKernel(&tmp, self.smooth_kernel, &blur_tmp, &st_xx);
        multiplyInto(&gy, &gy, &tmp);
        gaussianSmoothingWithKernel(&tmp, self.smooth_kernel, &blur_tmp, &st_yy);
        multiplyInto(&gx, &gy, &tmp);
        gaussianSmoothingWithKernel(&tmp, self.smooth_kernel, &blur_tmp, &st_xy);

        for (response.pixels, st_xx.pixels, st_yy.pixels, st_xy.pixels) |*out, xx, yy, xy| {
            const xx64 = @as(f64, xx);
            const yy64 = @as(f64, yy);
            const xy64 = @as(f64, xy);
            const trace = xx64 + yy64;
            out.* = @as(f32, @floatCast((xx64 * yy64 - xy64 * xy64) - 0.04 * trace * trace));
        }

        return response;
    }

    fn ensureImageCapacity(self: *CornerWorkspace, needed: usize) !void {
        try ensureSliceCapacity(self.allocator, &self.gx, needed);
        try ensureSliceCapacity(self.allocator, &self.gy, needed);
        try ensureSliceCapacity(self.allocator, &self.tmp, needed);
        try ensureSliceCapacity(self.allocator, &self.blur_tmp, needed);
        try ensureSliceCapacity(self.allocator, &self.st_xx, needed);
        try ensureSliceCapacity(self.allocator, &self.st_xy, needed);
        try ensureSliceCapacity(self.allocator, &self.st_yy, needed);
    }

    fn ensureKernels(self: *CornerWorkspace, scale: f64) !void {
        if (self.kernel_scale != null and self.kernel_scale.? == scale) return;

        if (self.smooth_kernel.len != 0) {
            self.allocator.free(self.smooth_kernel);
            self.smooth_kernel = &.{};
        }
        if (self.grad_kernel.len != 0) {
            self.allocator.free(self.grad_kernel);
            self.grad_kernel = &.{};
        }

        self.smooth_kernel = try makeGaussianKernel(self.allocator, scale);
        errdefer {
            self.allocator.free(self.smooth_kernel);
            self.smooth_kernel = &.{};
        }
        self.grad_kernel = try makeGaussianDerivativeKernel(self.allocator, scale, 1);
        self.kernel_scale = scale;
    }
};

pub fn cornerResponse(
    allocator: std.mem.Allocator,
    src: *const gray.GrayImage,
    scale: f64,
) std.mem.Allocator.Error!gray.GrayImage {
    const pixel_count = @as(usize, src.width) * @as(usize, src.height);
    const pixels = try allocator.alloc(f32, pixel_count);
    errdefer allocator.free(pixels);

    var workspace = CornerWorkspace.init(allocator);
    defer workspace.deinit();
    _ = try workspace.cornerResponseInto(src, scale, pixels);

    return .{
        .width = src.width,
        .height = src.height,
        .pixels = pixels,
    };
}

pub fn isStrictLocalMaximum(
    response: *const gray.GrayImage,
    x: u32,
    y: u32,
    threshold: f32,
) bool {
    const center = response.pixel(x, y);
    if (!(center > threshold)) return false;

    var ny = @as(i32, @intCast(y)) - 1;
    while (ny <= @as(i32, @intCast(y)) + 1) : (ny += 1) {
        var nx = @as(i32, @intCast(x)) - 1;
        while (nx <= @as(i32, @intCast(x)) + 1) : (nx += 1) {
            if (nx == @as(i32, @intCast(x)) and ny == @as(i32, @intCast(y))) {
                continue;
            }
            if (!(center > response.pixel(@as(u32, @intCast(nx)), @as(u32, @intCast(ny))))) {
                return false;
            }
        }
    }
    return true;
}

fn gaussianGradient(
    allocator: std.mem.Allocator,
    src: *const gray.GrayImage,
    scale: f64,
    gx: *gray.GrayImage,
    gy: *gray.GrayImage,
) std.mem.Allocator.Error!void {
    const smooth = try makeGaussianKernel(allocator, scale);
    defer allocator.free(smooth);
    const grad = try makeGaussianDerivativeKernel(allocator, scale, 1);
    defer allocator.free(grad);

    var tmp = try allocImage(allocator, src.width, src.height);
    defer tmp.deinit(allocator);

    convolveX(src, grad, &tmp);
    convolveY(&tmp, smooth, gx);
    convolveX(src, smooth, &tmp);
    convolveY(&tmp, grad, gy);
}

fn gaussianGradientWithKernels(
    src: *const gray.GrayImage,
    smooth: []const f64,
    grad: []const f64,
    tmp: *gray.GrayImage,
    gx: *gray.GrayImage,
    gy: *gray.GrayImage,
) void {
    convolveX(src, grad, tmp);
    convolveY(tmp, smooth, gx);
    convolveX(src, smooth, tmp);
    convolveY(tmp, grad, gy);
}

fn gaussianSmoothing(
    allocator: std.mem.Allocator,
    src: *const gray.GrayImage,
    scale: f64,
    dest: *gray.GrayImage,
) std.mem.Allocator.Error!void {
    const kernel = try makeGaussianKernel(allocator, scale);
    defer allocator.free(kernel);

    var tmp = try allocImage(allocator, src.width, src.height);
    defer tmp.deinit(allocator);

    convolveX(src, kernel, &tmp);
    convolveY(&tmp, kernel, dest);
}

fn gaussianSmoothingWithKernel(
    src: *const gray.GrayImage,
    kernel: []const f64,
    tmp: *gray.GrayImage,
    dest: *gray.GrayImage,
) void {
    convolveX(src, kernel, tmp);
    convolveY(tmp, kernel, dest);
}

fn multiplyInto(a: *const gray.GrayImage, b: *const gray.GrayImage, dest: *gray.GrayImage) void {
    for (dest.pixels, a.pixels, b.pixels) |*out, av, bv| {
        out.* = av * bv;
    }
}

fn allocImage(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
) std.mem.Allocator.Error!gray.GrayImage {
    return .{
        .width = width,
        .height = height,
        .pixels = try allocator.alloc(f32, @as(usize, width) * @as(usize, height)),
    };
}

fn imageView(width: u32, height: u32, pixels: []f32) gray.GrayImage {
    return .{
        .width = width,
        .height = height,
        .pixels = pixels,
    };
}

fn ensureSliceCapacity(allocator: std.mem.Allocator, slice: *[]f32, needed: usize) !void {
    if (slice.len >= needed) return;
    if (slice.len == 0) {
        slice.* = try allocator.alloc(f32, needed);
    } else {
        slice.* = try allocator.realloc(slice.*, needed);
    }
}

fn freeSlice(allocator: std.mem.Allocator, slice: *[]f32) void {
    if (slice.len != 0) allocator.free(slice.*);
    slice.* = &.{};
}

fn freeSliceF64(allocator: std.mem.Allocator, slice: *[]f64) void {
    if (slice.len != 0) allocator.free(slice.*);
    slice.* = &.{};
}

fn convolveX(src: *const gray.GrayImage, kernel: []const f64, dest: *gray.GrayImage) void {
    const radius = @as(i32, @intCast(kernel.len / 2));
    for (0..src.height) |y| {
        for (0..src.width) |x| {
            var sum: f64 = 0;
            var kx: i32 = -radius;
            while (kx <= radius) : (kx += 1) {
                const sx = reflectIndex(@as(i32, @intCast(x)) + kx, src.width);
                sum += kernel[@as(usize, @intCast(kx + radius))] * @as(f64, src.pixel(sx, @as(u32, @intCast(y))));
            }
            dest.pixels[y * src.width + x] = @as(f32, @floatCast(sum));
        }
    }
}

fn convolveY(src: *const gray.GrayImage, kernel: []const f64, dest: *gray.GrayImage) void {
    const radius = @as(i32, @intCast(kernel.len / 2));
    for (0..src.height) |y| {
        for (0..src.width) |x| {
            var sum: f64 = 0;
            var ky: i32 = -radius;
            while (ky <= radius) : (ky += 1) {
                const sy = reflectIndex(@as(i32, @intCast(y)) + ky, src.height);
                sum += kernel[@as(usize, @intCast(ky + radius))] * @as(f64, src.pixel(@as(u32, @intCast(x)), sy));
            }
            dest.pixels[y * src.width + x] = @as(f32, @floatCast(sum));
        }
    }
}

fn reflectIndex(index: i32, len: u32) u32 {
    if (len <= 1) return 0;

    const max = @as(i32, @intCast(len - 1));
    var value = index;
    while (value < 0 or value > max) {
        if (value < 0) {
            value = -value;
        } else {
            value = 2 * max - value;
        }
    }
    return @as(u32, @intCast(value));
}

fn makeGaussianKernel(
    allocator: std.mem.Allocator,
    stddev: f64,
) std.mem.Allocator.Error![]f64 {
    if (stddev <= 0.0) {
        const kernel = try allocator.alloc(f64, 1);
        kernel[0] = 1.0;
        return kernel;
    }

    var radius = @as(i32, @intFromFloat(@floor(3.0 * stddev + 0.5)));
    if (radius == 0) radius = 1;

    const size = @as(usize, @intCast(radius * 2 + 1));
    const kernel = try allocator.alloc(f64, size);
    errdefer allocator.free(kernel);

    const sigma_sq = stddev * stddev;
    const norm = 1.0 / (@sqrt(2.0 * std.math.pi) * stddev);
    var sum: f64 = 0;
    for (0..size) |i| {
        const x = @as(f64, @floatFromInt(@as(i32, @intCast(i)) - radius));
        const value = norm * @exp(-(x * x) / (2.0 * sigma_sq));
        kernel[i] = value;
        sum += value;
    }
    for (kernel) |*value| {
        value.* /= sum;
    }
    return kernel;
}

fn makeGaussianDerivativeKernel(
    allocator: std.mem.Allocator,
    stddev: f64,
    order: u32,
) std.mem.Allocator.Error![]f64 {
    if (order == 0) return makeGaussianKernel(allocator, stddev);
    std.debug.assert(order == 1);
    std.debug.assert(stddev > 0.0);

    var radius = @as(i32, @intFromFloat(@floor((3.0 + 0.5 * @as(f64, @floatFromInt(order))) * stddev + 0.5)));
    if (radius == 0) radius = 1;

    const size = @as(usize, @intCast(radius * 2 + 1));
    const kernel = try allocator.alloc(f64, size);
    errdefer allocator.free(kernel);

    const sigma_sq = stddev * stddev;
    const norm = 1.0 / (@sqrt(2.0 * std.math.pi) * stddev);
    var dc: f64 = 0;
    for (0..size) |i| {
        const x = @as(f64, @floatFromInt(@as(i32, @intCast(i)) - radius));
        const gaussian = norm * @exp(-(x * x) / (2.0 * sigma_sq));
        const value = -(x / sigma_sq) * gaussian;
        kernel[i] = value;
        dc += value;
    }
    dc /= @as(f64, @floatFromInt(size));
    for (kernel) |*value| {
        value.* -= dc;
    }

    var moment: f64 = 0;
    for (0..size) |i| {
        const x = @as(f64, @floatFromInt(@as(i32, @intCast(i)) - radius));
        moment += kernel[i] * (-x);
    }
    const scale_factor = 1.0 / moment;
    for (kernel) |*value| {
        value.* *= scale_factor;
    }
    return kernel;
}

test "strict local maxima rejects equal neighbors" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.dupe(f32, &[_]f32{
        0, 0, 0,
        0, 1, 1,
        0, 0, 0,
    });
    defer allocator.free(pixels);

    const image = gray.GrayImage{
        .width = 3,
        .height = 3,
        .pixels = pixels,
    };

    try std.testing.expect(!isStrictLocalMaximum(&image, 1, 1, 0));
}
