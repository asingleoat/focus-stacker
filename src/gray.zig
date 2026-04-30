const std = @import("std");
const image_io = @import("image_io.zig");
const profiler = @import("profiler.zig");

pub const GrayImage = struct {
    width: u32,
    height: u32,
    pixels: []f32,
    sample_scale: f32 = 1.0,

    pub fn pixel(self: *const GrayImage, x: u32, y: u32) f32 {
        return self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    pub fn deinit(self: *GrayImage, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn clone(self: *const GrayImage, allocator: std.mem.Allocator) std.mem.Allocator.Error!GrayImage {
        const pixels = try allocator.dupe(f32, self.pixels);
        return .{
            .width = self.width,
            .height = self.height,
            .pixels = pixels,
            .sample_scale = self.sample_scale,
        };
    }
};

pub fn quantizeInPlace(image: *GrayImage, sample_type: image_io.SampleType) void {
    const max_value: f32 = switch (sample_type) {
        .u8 => 255.0,
        .u16 => 65535.0,
    };

    for (image.pixels) |*pixel| {
        const clamped = @max(@as(f32, 0), @min(@as(f32, 1), pixel.*));
        pixel.* = @round(clamped * max_value) / max_value;
    }
}

pub fn fromLoaded(allocator: std.mem.Allocator, image: *const image_io.Image) std.mem.Allocator.Error!GrayImage {
    const prof = profiler.scope("gray.fromLoaded");
    defer prof.end();

    const count = @as(usize, image.info.width) * @as(usize, image.info.height);
    const pixels = try allocator.alloc(f32, count);
    errdefer allocator.free(pixels);

    switch (image.pixels) {
        .u8 => |src| convertU8(pixels, image, src),
        .u16 => |src| convertU16(pixels, image, src),
    }

    return .{
        .width = image.info.width,
        .height = image.info.height,
        .pixels = pixels,
        .sample_scale = sampleScaleForType(image.info.sample_type),
    };
}

pub fn fromLoadedReducedLikeHugin(
    allocator: std.mem.Allocator,
    image: *const image_io.Image,
    levels: u8,
) std.mem.Allocator.Error!GrayImage {
    const prof = profiler.scope("gray.fromLoadedReducedLikeHugin");
    defer prof.end();

    return switch (image.pixels) {
        .u8 => |src| reduceAndConvert(u8, allocator, image.info, src, levels),
        .u16 => |src| reduceAndConvert(u16, allocator, image.info, src, levels),
    };
}

pub fn reduceByHalf(allocator: std.mem.Allocator, src: *const GrayImage) std.mem.Allocator.Error!GrayImage {
    const prof = profiler.scope("gray.reduceByHalf");
    defer prof.end();

    const dst_width = (src.width + 1) / 2;
    const dst_height = (src.height + 1) / 2;
    const dst_pixels = try allocator.alloc(f32, @as(usize, dst_width) * @as(usize, dst_height));
    errdefer allocator.free(dst_pixels);

    const weights = [_]f32{ 1, 4, 6, 4, 1 };
    const out_width = @as(usize, dst_width);
    const out_height = @as(usize, dst_height);

    for (0..out_height) |dy| {
        const src_center_y = @as(i32, @intCast(dy * 2));
        for (0..out_width) |dx| {
            const src_center_x = @as(i32, @intCast(dx * 2));

            var weighted_sum: f64 = 0;
            var total_weight: f64 = 0;

            for (0..weights.len) |ky| {
                const sy = src_center_y + @as(i32, @intCast(ky)) - 2;
                if (sy < 0 or sy >= @as(i32, @intCast(src.height))) continue;

                for (0..weights.len) |kx| {
                    const sx = src_center_x + @as(i32, @intCast(kx)) - 2;
                    if (sx < 0 or sx >= @as(i32, @intCast(src.width))) continue;

                    const weight = @as(f64, weights[ky] * weights[kx]);
                    weighted_sum += weight * @as(f64, src.pixel(@as(u32, @intCast(sx)), @as(u32, @intCast(sy))));
                    total_weight += weight;
                }
            }

            dst_pixels[dy * out_width + dx] = @as(f32, @floatCast(weighted_sum / total_weight));
        }
    }

    return .{
        .width = dst_width,
        .height = dst_height,
        .pixels = dst_pixels,
        .sample_scale = src.sample_scale,
    };
}

pub fn reduceNTimes(
    allocator: std.mem.Allocator,
    src: *const GrayImage,
    levels: u8,
) std.mem.Allocator.Error!GrayImage {
    const prof = profiler.scope("gray.reduceNTimes");
    defer prof.end();

    var current = try src.clone(allocator);
    errdefer current.deinit(allocator);

    var level: u8 = 0;
    while (level < levels) : (level += 1) {
        const next = try reduceByHalf(allocator, &current);
        current.deinit(allocator);
        current = next;
    }

    return current;
}

fn convertU8(dst: []f32, image: *const image_io.Image, src: []const u8) void {
    const count = @as(usize, image.info.width) * @as(usize, image.info.height);
    const stride = @as(usize, image.info.color_channels + image.info.extra_channels);
    switch (image.info.color_model) {
        .grayscale => {
            for (0..count) |i| {
                dst[i] = @as(f32, @floatFromInt(src[i * stride])) / 255.0;
            }
        },
        .rgb => {
            for (0..count) |i| {
                const base = i * stride;
                const gray = rgbToGrayRoundedU8(src[base], src[base + 1], src[base + 2]);
                dst[i] = @as(f32, @floatFromInt(gray)) / 255.0;
            }
        },
    }
}

fn convertU16(dst: []f32, image: *const image_io.Image, src: []const u16) void {
    const count = @as(usize, image.info.width) * @as(usize, image.info.height);
    const stride = @as(usize, image.info.color_channels + image.info.extra_channels);
    switch (image.info.color_model) {
        .grayscale => {
            for (0..count) |i| {
                dst[i] = @as(f32, @floatFromInt(src[i * stride])) / 65535.0;
            }
        },
        .rgb => {
            for (0..count) |i| {
                const base = i * stride;
                const gray = rgbToGrayRoundedU16(src[base], src[base + 1], src[base + 2]);
                dst[i] = @as(f32, @floatFromInt(gray)) / 65535.0;
            }
        },
    }
}

fn reduceAndConvert(
    comptime T: type,
    allocator: std.mem.Allocator,
    info: image_io.ImageInfo,
    src: []const T,
    levels: u8,
) std.mem.Allocator.Error!GrayImage {
    const prof = profiler.scope("gray.reduceAndConvert");
    defer prof.end();

    const channels = @as(usize, info.color_channels + info.extra_channels);
    var width = info.width;
    var height = info.height;
    var current_owned: ?[]T = null;
    defer if (current_owned) |buffer| allocator.free(buffer);
    var current: []const T = src;

    var level: u8 = 0;
    while (level < levels) : (level += 1) {
        const next_width = (width + 1) / 2;
        const next_height = (height + 1) / 2;
        const next = try allocator.alloc(T, @as(usize, next_width) * @as(usize, next_height) * channels);
        reduceTypedByHalf(T, current, width, height, channels, next, next_width, next_height);
        if (current_owned) |buffer| allocator.free(buffer);
        current_owned = next;
        current = next;
        width = next_width;
        height = next_height;
    }

    const out_pixels = try allocator.alloc(f32, @as(usize, width) * @as(usize, height));
    errdefer allocator.free(out_pixels);

    switch (T) {
        u8 => convertReducedU8(out_pixels, info.color_model, width, height, channels, current),
        u16 => convertReducedU16(out_pixels, info.color_model, width, height, channels, current),
        else => unreachable,
    }

    return .{
        .width = width,
        .height = height,
        .pixels = out_pixels,
        .sample_scale = sampleScaleForType(info.sample_type),
    };
}

fn sampleScaleForType(sample_type: image_io.SampleType) f32 {
    return switch (sample_type) {
        .u8 => 255.0,
        .u16 => 65535.0,
    };
}

fn reduceTypedByHalf(
    comptime T: type,
    src: []const T,
    src_width: u32,
    src_height: u32,
    channels: usize,
    dst: []T,
    dst_width: u32,
    dst_height: u32,
) void {
    const prof = profiler.scope("gray.reduceTypedByHalf");
    defer prof.end();

    std.debug.assert(src_width > 1 and src_height > 1);
    std.debug.assert(dst_width == (src_width + 1) / 2);
    std.debug.assert(dst_height == (src_height + 1) / 2);

    const Promote = i64;
    const state_len = @as(usize, dst_width) + 1;

    for (0..channels) |channel| {
        var isc0_buf: [4096]Promote = undefined;
        var isc1_buf: [4096]Promote = undefined;
        var iscp_buf: [4096]Promote = undefined;

        var isc0 = if (state_len <= isc0_buf.len) isc0_buf[0..state_len] else unreachable;
        var isc1 = if (state_len <= isc1_buf.len) isc1_buf[0..state_len] else unreachable;
        var iscp = if (state_len <= iscp_buf.len) iscp_buf[0..state_len] else unreachable;
        @memset(isc0, 0);
        @memset(isc1, 0);
        @memset(iscp, 0);

        var isr0: Promote = sourceComponent(T, src, src_width, channels, 0, 0, channel);
        var isr1: Promote = 0;
        var isrp: Promote = isr0 * 4;

        // First row.
        {
            var even_x = true;
            var dstx: usize = 0;
            var srcx: u32 = 0;
            while (srcx < src_width) : (srcx += 1) {
                const current = sourceComponent(T, src, src_width, channels, srcx, 0, channel);
                if (even_x) {
                    isc0[dstx] = isr1 + 6 * isr0 + isrp + current;
                    isc1[dstx] = 5 * isc0[dstx];
                    isr1 = isr0 + isrp;
                    isr0 = current;
                } else {
                    isrp = current * 4;
                    dstx += 1;
                }
                even_x = !even_x;
            }

            if (!even_x) {
                dstx += 1;
                isc0[dstx] = isr1 + 11 * isr0;
                isc1[dstx] = 5 * isc0[dstx];
            } else {
                isc0[dstx] = isr1 + 6 * isr0 + isrp + @divTrunc(isrp, 4);
                isc1[dstx] = 5 * isc0[dstx];
            }
        }

        var dy: u32 = 0;
        var even_y = false;
        var srcy: u32 = 1;
        while (srcy < src_height) : (srcy += 1) {
            isr0 = sourceComponent(T, src, src_width, channels, 0, srcy, channel);
            isr1 = 0;
            isrp = isr0 * 4;

            if (even_y) {
                isr1 = isr0 + isrp;
                isr0 = sourceComponent(T, src, src_width, channels, 0, srcy, channel);

                var dstx: usize = 0;
                var dx: u32 = 0;
                var even_x = false;
                var srcx: u32 = 1;
                while (srcx < src_width) : (srcx += 1) {
                    const current = sourceComponent(T, src, src_width, channels, srcx, srcy, channel);
                    if (even_x) {
                        var ip = isc1[dstx] + 6 * isc0[dstx] + iscp[dstx];
                        isc1[dstx] = isc0[dstx] + iscp[dstx];
                        isc0[dstx] = isr1 + 6 * isr0 + isrp + current;
                        isr1 = isr0 + isrp;
                        isr0 = current;
                        ip += isc0[dstx];
                        setReducedComponent(T, dst, dst_width, channels, dx, dy, channel, reducedOutputValue(T, channels, ip));
                        dx += 1;
                    } else {
                        isrp = current * 4;
                        dstx += 1;
                    }
                    even_x = !even_x;
                }

                if (!even_x) {
                    dstx += 1;
                    var ip = isc1[dstx] + 6 * isc0[dstx] + iscp[dstx];
                    isc1[dstx] = isc0[dstx] + iscp[dstx];
                    isc0[dstx] = isr1 + 11 * isr0;
                    ip += isc0[dstx];
                    setReducedComponent(T, dst, dst_width, channels, dx, dy, channel, reducedOutputValue(T, channels, ip));
                } else {
                    var ip = isc1[dstx] + 6 * isc0[dstx] + iscp[dstx];
                    isc1[dstx] = isc0[dstx] + iscp[dstx];
                    isc0[dstx] = isr1 + 6 * isr0 + isrp + @divTrunc(isrp, 4);
                    ip += isc0[dstx];
                    setReducedComponent(T, dst, dst_width, channels, dx, dy, channel, reducedOutputValue(T, channels, ip));
                }

                dy += 1;
            } else {
                isr1 = isr0 + isrp;
                isr0 = sourceComponent(T, src, src_width, channels, 0, srcy, channel);

                var dstx: usize = 0;
                var even_x = false;
                var srcx: u32 = 1;
                while (srcx < src_width) : (srcx += 1) {
                    const current = sourceComponent(T, src, src_width, channels, srcx, srcy, channel);
                    if (even_x) {
                        iscp[dstx] = (isr1 + 6 * isr0 + isrp + current) * 4;
                        isr1 = isr0 + isrp;
                        isr0 = current;
                    } else {
                        isrp = current * 4;
                        dstx += 1;
                    }
                    even_x = !even_x;
                }

                if (!even_x) {
                    dstx += 1;
                    iscp[dstx] = (isr1 + 11 * isr0) * 4;
                } else {
                    iscp[dstx] = (isr1 + 6 * isr0 + isrp + @divTrunc(isrp, 4)) * 4;
                }
            }

            even_y = !even_y;
        }

        if (!even_y) {
            var dstx: usize = 1;
            var dx: u32 = 0;
            while (dstx < state_len) : (dstx += 1) {
                const ip = reducedOutputValue(T, channels, isc1[dstx] + 11 * isc0[dstx]);
                setReducedComponent(T, dst, dst_width, channels, dx, dy, channel, ip);
                dx += 1;
            }
        } else {
            var dstx: usize = 1;
            var dx: u32 = 0;
            while (dstx < state_len) : (dstx += 1) {
                const ip = reducedOutputValue(T, channels, isc1[dstx] + 6 * isc0[dstx] + iscp[dstx] + @divTrunc(iscp[dstx], 4));
                setReducedComponent(T, dst, dst_width, channels, dx, dy, channel, ip);
                dx += 1;
            }
        }
    }
}

fn sourceComponent(
    comptime T: type,
    src: []const T,
    width: u32,
    channels: usize,
    x: u32,
    y: u32,
    channel: usize,
) i64 {
    const index = ((@as(usize, y) * @as(usize, width)) + @as(usize, x)) * channels + channel;
    return @as(i64, src[index]);
}

fn setReducedComponent(
    comptime T: type,
    dst: []T,
    width: u32,
    channels: usize,
    x: u32,
    y: u32,
    channel: usize,
    value: i64,
) void {
    const index = ((@as(usize, y) * @as(usize, width)) + @as(usize, x)) * channels + channel;
    dst[index] = @as(T, @intCast(value));
}

fn reducedOutputValue(comptime T: type, channels: usize, numerator: i64) i64 {
    if (channels == 1) {
        return @divTrunc(numerator, 256);
    }

    const value = @as(f64, @floatFromInt(numerator)) / 256.0;
    const rounded = value + 0.5;
    const max_value: f64 = switch (T) {
        u8 => 255.0,
        u16 => 65535.0,
        else => unreachable,
    };
    return @as(i64, @intFromFloat(@min(max_value, rounded)));
}

fn convertReducedU8(dst: []f32, color_model: image_io.ColorModel, width: u32, height: u32, stride: usize, src: []const u8) void {
    const count = @as(usize, width) * @as(usize, height);
    switch (color_model) {
        .grayscale => {
            for (0..count) |i| {
                dst[i] = @as(f32, @floatFromInt(src[i * stride])) / 255.0;
            }
        },
        .rgb => {
            for (0..count) |i| {
                const base = i * stride;
                const gray = rgbToGrayRoundedU8(src[base], src[base + 1], src[base + 2]);
                dst[i] = @as(f32, @floatFromInt(gray)) / 255.0;
            }
        },
    }
}

fn convertReducedU16(dst: []f32, color_model: image_io.ColorModel, width: u32, height: u32, stride: usize, src: []const u16) void {
    const count = @as(usize, width) * @as(usize, height);
    switch (color_model) {
        .grayscale => {
            for (0..count) |i| {
                dst[i] = @as(f32, @floatFromInt(src[i * stride])) / 65535.0;
            }
        },
        .rgb => {
            for (0..count) |i| {
                const base = i * stride;
                const gray = rgbToGrayRoundedU16(src[base], src[base + 1], src[base + 2]);
                dst[i] = @as(f32, @floatFromInt(gray)) / 65535.0;
            }
        },
    }
}

fn rgbToGrayRoundedU8(r: u8, g: u8, b: u8) u8 {
    const gray = 0.3 * @as(f64, @floatFromInt(r)) +
        0.59 * @as(f64, @floatFromInt(g)) +
        0.11 * @as(f64, @floatFromInt(b));
    return @as(u8, @intFromFloat(@min(@as(f64, 255.0), gray + 0.5)));
}

fn rgbToGrayRoundedU16(r: u16, g: u16, b: u16) u16 {
    const gray = 0.3 * @as(f64, @floatFromInt(r)) +
        0.59 * @as(f64, @floatFromInt(g)) +
        0.11 * @as(f64, @floatFromInt(b));
    return @as(u16, @intFromFloat(@min(@as(f64, 65535.0), gray + 0.5)));
}

test "rgb u8 converts to grayscale luminance" {
    const allocator = std.testing.allocator;

    const src_pixels = try allocator.dupe(u8, &[_]u8{
        255, 0, 0,
        0, 255, 0,
    });
    defer allocator.free(src_pixels);

    const image = image_io.Image{
        .info = .{
            .format = .jpeg,
            .width = 2,
            .height = 1,
            .color_model = .rgb,
            .sample_type = .u8,
            .color_channels = 3,
            .extra_channels = 0,
            .exposure_value = null,
        },
        .pixels = .{ .u8 = src_pixels },
    };

    var gray = try fromLoaded(allocator, &image);
    defer gray.deinit(allocator);

    try std.testing.expectApproxEqAbs(@as(f32, 77.0 / 255.0), gray.pixels[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 150.0 / 255.0), gray.pixels[1], 0.0001);
}

test "reduce by half matches Burt-Adelson weights" {
    const allocator = std.testing.allocator;
    const src_pixels = try allocator.dupe(f32, &[_]f32{
        1, 2, 3, 4,
        5, 6, 7, 8,
        9, 10, 11, 12,
        13, 14, 15, 16,
    });
    defer allocator.free(src_pixels);

    var src = GrayImage{
        .width = 4,
        .height = 4,
        .pixels = src_pixels,
    };

    var reduced = try reduceByHalf(allocator, &src);
    defer reduced.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), reduced.width);
    try std.testing.expectEqual(@as(u32, 2), reduced.height);
    try std.testing.expectApproxEqAbs(@as(f32, 3.7272727), reduced.pixels[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.048485), reduced.pixels[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.012121), reduced.pixels[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.333333), reduced.pixels[3], 0.0001);
}

test "fixture jpeg converts and reduces" {
    const allocator = std.testing.allocator;
    var loaded = try image_io.loadImage(allocator, "tests/golden/s003_small/0001.jpg");
    defer loaded.deinit(allocator);

    var gray = try fromLoaded(allocator, &loaded);
    defer gray.deinit(allocator);

    var reduced = try reduceNTimes(allocator, &gray, 1);
    defer reduced.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 768), gray.width);
    try std.testing.expectEqual(@as(u32, 512), gray.height);
    try std.testing.expectEqual(@as(u32, 384), reduced.width);
    try std.testing.expectEqual(@as(u32, 256), reduced.height);
}

test "quantize in place follows source sample grid" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.dupe(f32, &[_]f32{ 0.0, 0.5, 0.5008, 1.0 });
    defer allocator.free(pixels);

    var image = GrayImage{
        .width = 4,
        .height = 1,
        .pixels = pixels,
    };

    quantizeInPlace(&image, .u8);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), image.pixels[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), image.pixels[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), image.pixels[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), image.pixels[3], 1e-6);
}

test "typed reduce matches upstream tiny grayscale pgm" {
    const allocator = std.testing.allocator;
    const src_pixels = try allocator.dupe(u8, &[_]u8{
        1, 2, 3, 4, 5,
        6, 7, 8, 9, 10,
        11, 12, 13, 14, 15,
        16, 17, 18, 19, 20,
        21, 22, 23, 24, 25,
    });
    defer allocator.free(src_pixels);

    const image = image_io.Image{
        .info = .{
            .format = .png,
            .width = 5,
            .height = 5,
            .color_model = .grayscale,
            .sample_type = .u8,
            .color_channels = 1,
            .extra_channels = 0,
            .exposure_value = null,
        },
        .pixels = .{ .u8 = src_pixels },
    };

    var reduced = try fromLoadedReducedLikeHugin(allocator, &image, 1);
    defer reduced.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 3), reduced.width);
    try std.testing.expectEqual(@as(u32, 3), reduced.height);

    const expected = [_]u8{
        3, 4, 6,
        11, 13, 14,
        19, 21, 22,
    };
    for (expected, reduced.pixels) |want, got| {
        try std.testing.expectEqual(@as(u8, want), @as(u8, @intFromFloat(@round(got * 255.0))));
    }
}

test "typed reduce matches upstream tiny rgb ppm" {
    const allocator = std.testing.allocator;
    const src_pixels = try allocator.alloc(u8, 5 * 5 * 3);
    defer allocator.free(src_pixels);

    for (0..25) |p| {
        const base = p * 3;
        src_pixels[base] = @as(u8, @intCast(p + 1));
        src_pixels[base + 1] = @as(u8, @intCast(p + 101));
        src_pixels[base + 2] = @as(u8, @intCast(p + 201));
    }

    const image = image_io.Image{
        .info = .{
            .format = .png,
            .width = 5,
            .height = 5,
            .color_model = .rgb,
            .sample_type = .u8,
            .color_channels = 3,
            .extra_channels = 0,
            .exposure_value = null,
        },
        .pixels = .{ .u8 = src_pixels },
    };

    var reduced = try fromLoadedReducedLikeHugin(allocator, &image, 1);
    defer reduced.deinit(allocator);

    const expected = [_]u8{
        84, 86, 88,
        92, 94, 96,
        101, 102, 104,
    };
    for (expected, reduced.pixels) |want, got| {
        try std.testing.expectEqual(@as(u8, want), @as(u8, @intFromFloat(@round(got * 255.0))));
    }
}
