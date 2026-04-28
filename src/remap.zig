const std = @import("std");
const image_io = @import("image_io.zig");
const optimize = @import("optimize.zig");
const sequence = @import("sequence.zig");

pub fn writeAlignedImages(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    ordered_indices: []const usize,
    remap_active: []const bool,
    images: []const sequence.InputImage,
    poses: []const optimize.ImagePose,
    roi: ?Rect,
) !void {
    var output_index: usize = 0;
    for (ordered_indices) |image_index| {
        if (!remap_active[image_index]) continue;

        var src = try image_io.loadImage(allocator, images[image_index].path);
        defer src.deinit(allocator);

        var remapped = try remapRigidImage(allocator, &src, poses[image_index], roi);
        defer remapped.deinit(allocator);

        const path = try std.fmt.allocPrint(allocator, "{s}_{d:0>4}.tif", .{ prefix, output_index });
        defer allocator.free(path);
        try image_io.writeTiff(path, &remapped);
        output_index += 1;
    }
}

pub fn remapRigidImage(
    allocator: std.mem.Allocator,
    src: *const image_io.Image,
    pose: optimize.ImagePose,
    roi: ?Rect,
) std.mem.Allocator.Error!image_io.Image {
    const out_rect = roi orelse Rect{
        .left = 0,
        .top = 0,
        .right = @intCast(src.info.width),
        .bottom = @intCast(src.info.height),
    };
    const info = image_io.ImageInfo{
        .format = .tiff,
        .width = @intCast(out_rect.right - out_rect.left),
        .height = @intCast(out_rect.bottom - out_rect.top),
        .color_model = src.info.color_model,
        .sample_type = src.info.sample_type,
        .color_channels = src.info.color_channels,
        .extra_channels = 0,
        .exposure_value = src.info.exposure_value,
        .exif_focal_length_mm = src.info.exif_focal_length_mm,
        .exif_focal_length_35mm = src.info.exif_focal_length_35mm,
        .exif_crop_factor = src.info.exif_crop_factor,
    };

    return switch (src.pixels) {
        .u8 => blk: {
            const pixels = try allocator.alloc(u8, pixelCount(info));
            errdefer allocator.free(pixels);
            remapU8(pixels, src, pose, out_rect);
            break :blk .{
                .info = info,
                .pixels = .{ .u8 = pixels },
            };
        },
        .u16 => blk: {
            const pixels = try allocator.alloc(u16, pixelCount(info));
            errdefer allocator.free(pixels);
            remapU16(pixels, src, pose, out_rect);
            break :blk .{
                .info = info,
                .pixels = .{ .u16 = pixels },
            };
        },
    };
}

fn remapU8(dst: []u8, src: *const image_io.Image, pose: optimize.ImagePose, roi: Rect) void {
    const width = src.info.width;
    const height = src.info.height;
    const out_width = @as(u32, @intCast(roi.right - roi.left));
    const out_height = @as(u32, @intCast(roi.bottom - roi.top));
    const channels = @as(usize, src.info.color_channels);
    const src_pixels = src.pixels.u8;

    for (0..out_height) |y| {
        for (0..out_width) |x| {
            const world_x = @as(f64, @floatFromInt(roi.left)) + @as(f64, @floatFromInt(x));
            const world_y = @as(f64, @floatFromInt(roi.top)) + @as(f64, @floatFromInt(y));
            const sample = optimize.inverseTransformPoint(pose, world_x, world_y, width, height);
            const dst_base = (@as(usize, y) * @as(usize, out_width) + @as(usize, x)) * channels;
            for (0..channels) |channel| {
                dst[dst_base + channel] = bilinearSampleU8(src_pixels, width, height, channels, sample.x, sample.y, channel);
            }
        }
    }
}

fn remapU16(dst: []u16, src: *const image_io.Image, pose: optimize.ImagePose, roi: Rect) void {
    const width = src.info.width;
    const height = src.info.height;
    const out_width = @as(u32, @intCast(roi.right - roi.left));
    const out_height = @as(u32, @intCast(roi.bottom - roi.top));
    const channels = @as(usize, src.info.color_channels);
    const src_pixels = src.pixels.u16;

    for (0..out_height) |y| {
        for (0..out_width) |x| {
            const world_x = @as(f64, @floatFromInt(roi.left)) + @as(f64, @floatFromInt(x));
            const world_y = @as(f64, @floatFromInt(roi.top)) + @as(f64, @floatFromInt(y));
            const sample = optimize.inverseTransformPoint(pose, world_x, world_y, width, height);
            const dst_base = (@as(usize, y) * @as(usize, out_width) + @as(usize, x)) * channels;
            for (0..channels) |channel| {
                dst[dst_base + channel] = bilinearSampleU16(src_pixels, width, height, channels, sample.x, sample.y, channel);
            }
        }
    }
}

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

const Vec2 = struct {
    x: f64,
    y: f64,
};

pub fn computeCommonOverlapRoi(
    allocator: std.mem.Allocator,
    remap_active: []const bool,
    images: []const sequence.InputImage,
    poses: []const optimize.ImagePose,
) std.mem.Allocator.Error!?Rect {
    var polygon: std.ArrayList(Vec2) = .empty;
    defer polygon.deinit(allocator);

    var first = true;
    for (images, 0..) |image, image_index| {
        if (!remap_active[image_index]) continue;

        var quad = try transformedQuad(allocator, image.width, image.height, poses[image_index]);
        defer quad.deinit(allocator);

        if (first) {
            try polygon.appendSlice(allocator, quad.items);
            first = false;
        } else {
            const clipped = try clipPolygonToConvex(allocator, polygon.items, quad.items);
            polygon.deinit(allocator);
            polygon = clipped;
            if (polygon.items.len == 0) return null;
        }
    }

    if (polygon.items.len == 0) return null;

    var min_x = polygon.items[0].x;
    var max_x = polygon.items[0].x;
    var min_y = polygon.items[0].y;
    var max_y = polygon.items[0].y;
    for (polygon.items[1..]) |point| {
        min_x = @min(min_x, point.x);
        max_x = @max(max_x, point.x);
        min_y = @min(min_y, point.y);
        max_y = @max(max_y, point.y);
    }

    const roi = Rect{
        .left = @intFromFloat(@ceil(min_x)),
        .top = @intFromFloat(@ceil(min_y)),
        .right = @as(i32, @intFromFloat(@floor(max_x))) + 1,
        .bottom = @as(i32, @intFromFloat(@floor(max_y))) + 1,
    };
    if (roi.right <= roi.left or roi.bottom <= roi.top) return null;
    return roi;
}

fn transformedQuad(allocator: std.mem.Allocator, width: u32, height: u32, pose: optimize.ImagePose) std.mem.Allocator.Error!std.ArrayList(Vec2) {
    var points: std.ArrayList(Vec2) = .empty;
    try points.appendSlice(allocator, &[_]Vec2{
        forwardMappedPoint(0, 0, width, height, pose),
        forwardMappedPoint(@floatFromInt(width - 1), 0, width, height, pose),
        forwardMappedPoint(@floatFromInt(width - 1), @floatFromInt(height - 1), width, height, pose),
        forwardMappedPoint(0, @floatFromInt(height - 1), width, height, pose),
    });
    return points;
}

fn forwardMappedPoint(x: f64, y: f64, width: u32, height: u32, pose: optimize.ImagePose) Vec2 {
    const mapped = optimize.transformPoint(pose, x, y, width, height);
    return .{ .x = mapped.x, .y = mapped.y };
}

fn clipPolygonToConvex(
    allocator: std.mem.Allocator,
    subject: []const Vec2,
    clipper: []const Vec2,
) std.mem.Allocator.Error!std.ArrayList(Vec2) {
    var current: std.ArrayList(Vec2) = .empty;
    try current.appendSlice(allocator, subject);

    for (clipper, 0..) |a, i| {
        const b = clipper[(i + 1) % clipper.len];
        var next: std.ArrayList(Vec2) = .empty;

        if (current.items.len == 0) {
            current.deinit(allocator);
            return next;
        }

        var prev = current.items[current.items.len - 1];
        var prev_inside = isInsideEdge(prev, a, b);
        for (current.items) |curr| {
            const curr_inside = isInsideEdge(curr, a, b);
            if (curr_inside != prev_inside) {
                try next.append(allocator, lineIntersection(prev, curr, a, b));
            }
            if (curr_inside) {
                try next.append(allocator, curr);
            }
            prev = curr;
            prev_inside = curr_inside;
        }

        current.deinit(allocator);
        current = next;
    }

    return current;
}

fn isInsideEdge(point: Vec2, a: Vec2, b: Vec2) bool {
    return ((b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)) >= -1e-6;
}

fn lineIntersection(p1: Vec2, p2: Vec2, q1: Vec2, q2: Vec2) Vec2 {
    const a1 = p2.y - p1.y;
    const b1 = p1.x - p2.x;
    const c1 = a1 * p1.x + b1 * p1.y;

    const a2 = q2.y - q1.y;
    const b2 = q1.x - q2.x;
    const c2 = a2 * q1.x + b2 * q1.y;

    const det = a1 * b2 - a2 * b1;
    if (@abs(det) < 1e-9) return p2;
    return .{
        .x = (b2 * c1 - b1 * c2) / det,
        .y = (a1 * c2 - a2 * c1) / det,
    };
}

fn bilinearSampleU8(
    pixels: []const u8,
    width: u32,
    height: u32,
    channels: usize,
    x: f64,
    y: f64,
    channel: usize,
) u8 {
    if (x < 0 or y < 0 or x > @as(f64, @floatFromInt(width - 1)) or y > @as(f64, @floatFromInt(height - 1))) {
        return 0;
    }
    const x0 = @as(u32, @intFromFloat(@floor(x)));
    const y0 = @as(u32, @intFromFloat(@floor(y)));
    const x1 = @min(x0 + 1, width - 1);
    const y1 = @min(y0 + 1, height - 1);
    const fx = x - @as(f64, @floatFromInt(x0));
    const fy = y - @as(f64, @floatFromInt(y0));

    const p00 = sampleU8(pixels, width, channels, x0, y0, channel);
    const p10 = sampleU8(pixels, width, channels, x1, y0, channel);
    const p01 = sampleU8(pixels, width, channels, x0, y1, channel);
    const p11 = sampleU8(pixels, width, channels, x1, y1, channel);

    const top = lerp(@floatFromInt(p00), @floatFromInt(p10), fx);
    const bottom = lerp(@floatFromInt(p01), @floatFromInt(p11), fx);
    return @as(u8, @intFromFloat(@round(lerp(top, bottom, fy))));
}

fn bilinearSampleU16(
    pixels: []const u16,
    width: u32,
    height: u32,
    channels: usize,
    x: f64,
    y: f64,
    channel: usize,
) u16 {
    if (x < 0 or y < 0 or x > @as(f64, @floatFromInt(width - 1)) or y > @as(f64, @floatFromInt(height - 1))) {
        return 0;
    }
    const x0 = @as(u32, @intFromFloat(@floor(x)));
    const y0 = @as(u32, @intFromFloat(@floor(y)));
    const x1 = @min(x0 + 1, width - 1);
    const y1 = @min(y0 + 1, height - 1);
    const fx = x - @as(f64, @floatFromInt(x0));
    const fy = y - @as(f64, @floatFromInt(y0));

    const p00 = sampleU16(pixels, width, channels, x0, y0, channel);
    const p10 = sampleU16(pixels, width, channels, x1, y0, channel);
    const p01 = sampleU16(pixels, width, channels, x0, y1, channel);
    const p11 = sampleU16(pixels, width, channels, x1, y1, channel);

    const top = lerp(@floatFromInt(p00), @floatFromInt(p10), fx);
    const bottom = lerp(@floatFromInt(p01), @floatFromInt(p11), fx);
    return @as(u16, @intFromFloat(@round(lerp(top, bottom, fy))));
}

fn sampleU8(pixels: []const u8, width: u32, channels: usize, x: u32, y: u32, channel: usize) u8 {
    const index = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * channels + channel;
    return pixels[index];
}

fn sampleU16(pixels: []const u16, width: u32, channels: usize, x: u32, y: u32, channel: usize) u16 {
    const index = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * channels + channel;
    return pixels[index];
}

fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}

fn pixelCount(info: image_io.ImageInfo) usize {
    return @as(usize, info.width) * @as(usize, info.height) * @as(usize, info.color_channels);
}

test "identity remap preserves interior grayscale pixels" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.dupe(u8, &[_]u8{
        1, 2, 3, 4, 5,
        6, 7, 8, 9, 10,
        11, 12, 13, 14, 15,
        16, 17, 18, 19, 20,
        21, 22, 23, 24, 25,
    });
    defer allocator.free(pixels);

    const src = image_io.Image{
        .info = .{
            .format = .jpeg,
            .width = 5,
            .height = 5,
            .color_model = .grayscale,
            .sample_type = .u8,
            .color_channels = 1,
            .extra_channels = 0,
            .exposure_value = null,
        },
        .pixels = .{ .u8 = pixels },
    };

    var remapped = try remapRigidImage(allocator, &src, .{}, null);
    defer remapped.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 5), remapped.info.width);
    try std.testing.expectEqual(@as(u32, 5), remapped.info.height);
    try std.testing.expectEqual(@as(u8, 13), remapped.pixels.u8[2 * 5 + 2]);
    try std.testing.expectEqual(@as(u8, 18), remapped.pixels.u8[3 * 5 + 2]);
    try std.testing.expectEqual(@as(u8, 14), remapped.pixels.u8[2 * 5 + 3]);
}

test "common overlap roi for identical images is non-empty and bounded" {
    const allocator = std.testing.allocator;
    const images = [_]sequence.InputImage{
        .{ .pano_index = 0, .path = "a", .format = .jpeg, .width = 10, .height = 8, .color_model = .grayscale, .sample_type = .u8 },
        .{ .pano_index = 1, .path = "b", .format = .jpeg, .width = 10, .height = 8, .color_model = .grayscale, .sample_type = .u8 },
    };
    const remap_active = [_]bool{ true, true };
    const poses = [_]optimize.ImagePose{
        .{},
        .{},
    };

    const roi = (try computeCommonOverlapRoi(allocator, &remap_active, &images, &poses)).?;
    try std.testing.expect(roi.left >= 0);
    try std.testing.expect(roi.top >= 0);
    try std.testing.expect(roi.right <= 10);
    try std.testing.expect(roi.bottom <= 8);
    try std.testing.expect(roi.right > roi.left);
    try std.testing.expect(roi.bottom > roi.top);
}

test "scaled remap yields a non-empty roi" {
    const allocator = std.testing.allocator;
    const images = [_]sequence.InputImage{
        .{ .pano_index = 0, .path = "a", .format = .jpeg, .width = 10, .height = 8, .color_model = .grayscale, .sample_type = .u8 },
    };
    const remap_active = [_]bool{true};
    const poses = [_]optimize.ImagePose{
        .{ .trans_z = -0.1 },
    };

    const roi = (try computeCommonOverlapRoi(allocator, &remap_active, &images, &poses)).?;
    try std.testing.expect(roi.right > roi.left);
    try std.testing.expect(roi.bottom > roi.top);
}
