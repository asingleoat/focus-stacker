const std = @import("std");
const gray = @import("gray.zig");

pub fn cornerResponse(
    allocator: std.mem.Allocator,
    src: *const gray.GrayImage,
    scale: f64,
) std.mem.Allocator.Error!gray.GrayImage {
    var gx = try allocImage(allocator, src.width, src.height);
    errdefer gx.deinit(allocator);
    var gy = try allocImage(allocator, src.width, src.height);
    errdefer gy.deinit(allocator);

    try gaussianGradient(allocator, src, scale, &gx, &gy);

    var tmp = try allocImage(allocator, src.width, src.height);
    errdefer tmp.deinit(allocator);
    var st_xx = try allocImage(allocator, src.width, src.height);
    errdefer st_xx.deinit(allocator);
    var st_xy = try allocImage(allocator, src.width, src.height);
    errdefer st_xy.deinit(allocator);
    var st_yy = try allocImage(allocator, src.width, src.height);
    errdefer st_yy.deinit(allocator);

    multiplyInto(&gx, &gx, &tmp);
    try gaussianSmoothing(allocator, &tmp, scale, &st_xx);
    multiplyInto(&gy, &gy, &tmp);
    try gaussianSmoothing(allocator, &tmp, scale, &st_yy);
    multiplyInto(&gx, &gy, &tmp);
    try gaussianSmoothing(allocator, &tmp, scale, &st_xy);

    gx.deinit(allocator);
    gy.deinit(allocator);
    tmp.deinit(allocator);

    var response = try allocImage(allocator, src.width, src.height);
    errdefer response.deinit(allocator);

    for (response.pixels, st_xx.pixels, st_yy.pixels, st_xy.pixels) |*out, xx, yy, xy| {
        const xx64 = @as(f64, xx);
        const yy64 = @as(f64, yy);
        const xy64 = @as(f64, xy);
        const trace = xx64 + yy64;
        out.* = @as(f32, @floatCast((xx64 * yy64 - xy64 * xy64) - 0.04 * trace * trace));
    }

    st_xx.deinit(allocator);
    st_xy.deinit(allocator);
    st_yy.deinit(allocator);

    return response;
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
