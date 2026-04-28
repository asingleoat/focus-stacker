const std = @import("std");
const image_io = @import("image_io.zig");

pub const GrayImage = struct {
    width: u32,
    height: u32,
    pixels: []f32,

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
        };
    }
};

pub fn fromLoaded(allocator: std.mem.Allocator, image: *const image_io.Image) std.mem.Allocator.Error!GrayImage {
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
    };
}

pub fn reduceByHalf(allocator: std.mem.Allocator, src: *const GrayImage) std.mem.Allocator.Error!GrayImage {
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
    };
}

pub fn reduceNTimes(
    allocator: std.mem.Allocator,
    src: *const GrayImage,
    levels: u8,
) std.mem.Allocator.Error!GrayImage {
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
    switch (image.info.color_model) {
        .grayscale => {
            for (dst, src[0..count]) |*out, value| {
                out.* = @as(f32, @floatFromInt(value)) / 255.0;
            }
        },
        .rgb => {
            for (0..count) |i| {
                const base = i * 3;
                const r = @as(f32, @floatFromInt(src[base])) / 255.0;
                const g = @as(f32, @floatFromInt(src[base + 1])) / 255.0;
                const b = @as(f32, @floatFromInt(src[base + 2])) / 255.0;
                dst[i] = 0.3 * r + 0.59 * g + 0.11 * b;
            }
        },
    }
}

fn convertU16(dst: []f32, image: *const image_io.Image, src: []const u16) void {
    const count = @as(usize, image.info.width) * @as(usize, image.info.height);
    switch (image.info.color_model) {
        .grayscale => {
            for (dst, src[0..count]) |*out, value| {
                out.* = @as(f32, @floatFromInt(value)) / 65535.0;
            }
        },
        .rgb => {
            for (0..count) |i| {
                const base = i * 3;
                const r = @as(f32, @floatFromInt(src[base])) / 65535.0;
                const g = @as(f32, @floatFromInt(src[base + 1])) / 65535.0;
                const b = @as(f32, @floatFromInt(src[base + 2])) / 65535.0;
                dst[i] = 0.3 * r + 0.59 * g + 0.11 * b;
            }
        },
    }
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

    try std.testing.expectApproxEqAbs(@as(f32, 0.3), gray.pixels[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.59), gray.pixels[1], 0.0001);
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
    const fixture = @embedFile("../upstream/hugin-2025.0.1/src/hugin1/hugin/xrc/data/help_en_EN/100px-PC_img04.jpg");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "fixture.jpg", .data = fixture });
    const path = try tmp.dir.realpathAlloc(allocator, "fixture.jpg");
    defer allocator.free(path);

    var loaded = try image_io.loadImage(allocator, path);
    defer loaded.deinit(allocator);

    var gray = try fromLoaded(allocator, &loaded);
    defer gray.deinit(allocator);

    var reduced = try reduceNTimes(allocator, &gray, 1);
    defer reduced.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 100), gray.width);
    try std.testing.expectEqual(@as(u32, 78), gray.height);
    try std.testing.expectEqual(@as(u32, 50), reduced.width);
    try std.testing.expectEqual(@as(u32, 39), reduced.height);
}
