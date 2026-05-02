const std = @import("std");
const core = @import("align_stack_core");
const pyramid = @import("pyramid.zig");

pub fn writeScalarMapU16Unit(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    filename: []const u8,
    width: u32,
    height: u32,
    values: []const f32,
) !void {
    const count = @as(usize, width) * @as(usize, height);
    const pixels = try allocator.alloc(u16, count);
    defer allocator.free(pixels);

    for (values[0..count], 0..) |value, i| {
        pixels[i] = @intFromFloat(std.math.clamp(value * 65535.0 + 0.5, 0.0, 65535.0));
    }
    try writePixelsU16(allocator, output_dir, filename, width, height, pixels);
}

pub fn writeScalarMapU16Auto(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    filename: []const u8,
    width: u32,
    height: u32,
    values: []const f32,
) !void {
    const count = @as(usize, width) * @as(usize, height);
    const pixels = try allocator.alloc(u16, count);
    defer allocator.free(pixels);

    var max_value: f32 = 0.0;
    for (values[0..count]) |value| max_value = @max(max_value, value);
    const scale: f32 = if (max_value > 0.0) 65535.0 / max_value else 0.0;
    for (values[0..count], 0..) |value, i| {
        pixels[i] = if (scale > 0.0) @intFromFloat(std.math.clamp(value * scale + 0.5, 0.0, 65535.0)) else 0;
    }
    try writePixelsU16(allocator, output_dir, filename, width, height, pixels);
}

pub fn dumpPyramidScalars(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    width: u32,
    height: u32,
    norm_weight_sums: []const f32,
    union_support: []const f32,
) !void {
    try std.fs.cwd().makePath(output_dir);
    try writeScalarMapU16Auto(allocator, output_dir, "norm_sum.tif", width, height, norm_weight_sums);
    try writeScalarMapU16Unit(allocator, output_dir, "union_support.tif", width, height, union_support);
}

pub fn dumpRawMask(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    width: u32,
    height: u32,
    image_index: usize,
    weights: []const f32,
    sample_scale: f32,
) !void {
    const count = @as(usize, width) * @as(usize, height);
    const scaled = try allocator.alloc(f32, count);
    defer allocator.free(scaled);

    if (sample_scale > 0.0) {
        for (weights[0..count], 0..) |value, i| scaled[i] = value / sample_scale;
    } else {
        @memcpy(scaled, weights[0..count]);
    }

    var filename_buf: [64]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filename_buf, "rawmask_{d:0>4}.tif", .{image_index});
    try writeScalarMapU16Unit(allocator, output_dir, filename, width, height, scaled);
}

pub fn dumpNormalizedMask(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    width: u32,
    height: u32,
    image_index: usize,
    normalized_mask: []const f32,
) !void {
    var filename_buf: [64]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filename_buf, "mask_{d:0>4}.tif", .{image_index});
    try writeScalarMapU16Unit(allocator, output_dir, filename, width, height, normalized_mask);
}

pub fn dumpWorkspaceLevels(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    image_index: usize,
    workspace: *const pyramid.Workspace,
) !void {
    var dir_buf: [64]u8 = undefined;
    const dirname = try std.fmt.bufPrint(&dir_buf, "frame_{d:0>4}", .{image_index});
    const frame_dir = try std.fs.path.join(allocator, &.{ output_dir, dirname });
    defer allocator.free(frame_dir);
    try std.fs.cwd().makePath(frame_dir);

    for (workspace.mask_levels, 0..) |level, level_index| {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "mask_g_{d:0>2}.tif", .{level_index});
        try writeScalarMapU16Unit(allocator, frame_dir, name, level.width, level.height, level.pixels);
    }
    for (workspace.gaussian_levels, 0..) |level, level_index| {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "gauss_{d:0>2}.tif", .{level_index});
        try writeRgbMapU16Auto(allocator, frame_dir, name, level.width, level.height, level.pixels);
    }
    for (workspace.expanded_levels, 0..) |level, level_index| {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "expand_{d:0>2}.tif", .{level_index});
        try writeRgbMapU16Auto(allocator, frame_dir, name, level.width, level.height, level.pixels);

        const current = workspace.gaussian_levels[level_index];
        const count = @as(usize, current.width) * @as(usize, current.height) * 3;
        const lap = try allocator.alloc(f32, count);
        defer allocator.free(lap);
        for (0..count) |i| lap[i] = current.pixels[i] - level.pixels[i];

        var lap_name_buf: [64]u8 = undefined;
        const lap_name = try std.fmt.bufPrint(&lap_name_buf, "lap_{d:0>2}.tif", .{level_index});
        try writeRgbMapU16SignedAuto(allocator, frame_dir, lap_name, current.width, current.height, lap);
    }
}

pub fn dumpAccumulatorLevels(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    accumulator: *const pyramid.Accumulator,
) !void {
    const accum_dir = try std.fs.path.join(allocator, &.{ output_dir, "accumulator" });
    defer allocator.free(accum_dir);
    try std.fs.cwd().makePath(accum_dir);

    for (accumulator.levels, 0..) |level, level_index| {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "accum_{d:0>2}.tif", .{level_index});
        try writeRgbMapU16SignedAuto(allocator, accum_dir, name, level.width, level.height, level.pixels);
    }
}

pub fn dumpCollapsedBase(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    collapse_step: usize,
    level: *const pyramid.RgbLevel,
) !void {
    const collapse_dir = try std.fs.path.join(allocator, &.{ output_dir, "collapse" });
    defer allocator.free(collapse_dir);
    try std.fs.cwd().makePath(collapse_dir);

    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "base_after_{d:0>2}.tif", .{collapse_step});
    try writeRgbMapU16Auto(allocator, collapse_dir, name, level.width, level.height, level.pixels);
}

pub fn dumpScalarLevels(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    subdir_name: []const u8,
    prefix: []const u8,
    levels: []const pyramid.ScalarLevel,
) !void {
    const dir = try std.fs.path.join(allocator, &.{ output_dir, subdir_name });
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    for (levels, 0..) |level, level_index| {
        var name_buf: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_{d:0>2}.tif", .{ prefix, level_index });
        try writeScalarMapU16Unit(allocator, dir, name, level.width, level.height, level.pixels);
    }
}

pub fn writeRgbMapU16Auto(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    filename: []const u8,
    width: u32,
    height: u32,
    values: []const f32,
) !void {
    const count = @as(usize, width) * @as(usize, height) * 3;
    const pixels = try allocator.alloc(u16, count);
    defer allocator.free(pixels);

    var max_value: f32 = 0.0;
    for (values[0..count]) |value| max_value = @max(max_value, value);
    const scale: f32 = if (max_value > 0.0) 65535.0 / max_value else 0.0;
    for (values[0..count], 0..) |value, i| {
        pixels[i] = if (scale > 0.0) @intFromFloat(std.math.clamp(value * scale + 0.5, 0.0, 65535.0)) else 0;
    }
    try writePixelsRgbU16(allocator, output_dir, filename, width, height, pixels);
}

pub fn writeRgbMapU16SignedAuto(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    filename: []const u8,
    width: u32,
    height: u32,
    values: []const f32,
) !void {
    const count = @as(usize, width) * @as(usize, height) * 3;
    const pixels = try allocator.alloc(u16, count);
    defer allocator.free(pixels);

    var max_abs: f32 = 0.0;
    for (values[0..count]) |value| max_abs = @max(max_abs, @abs(value));
    const scale: f32 = if (max_abs > 0.0) 32767.0 / max_abs else 0.0;
    for (values[0..count], 0..) |value, i| {
        const centered = 32768.0 + value * scale;
        pixels[i] = @intFromFloat(std.math.clamp(centered + 0.5, 0.0, 65535.0));
    }
    try writePixelsRgbU16(allocator, output_dir, filename, width, height, pixels);
}

fn writePixelsU16(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    filename: []const u8,
    width: u32,
    height: u32,
    pixels: []u16,
) !void {
    const path = try std.fs.path.join(allocator, &.{ output_dir, filename });
    defer allocator.free(path);
    var image = core.image_io.Image{
        .info = .{
            .format = .tiff,
            .width = width,
            .height = height,
            .color_model = .grayscale,
            .sample_type = .u16,
            .color_channels = 1,
            .extra_channels = 0,
            .exposure_value = null,
        },
        .pixels = .{ .u16 = pixels },
    };
    try core.image_io.writeTiff(path, &image);
}

fn writePixelsRgbU16(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    filename: []const u8,
    width: u32,
    height: u32,
    pixels: []u16,
) !void {
    const path = try std.fs.path.join(allocator, &.{ output_dir, filename });
    defer allocator.free(path);
    var image = core.image_io.Image{
        .info = .{
            .format = .tiff,
            .width = width,
            .height = height,
            .color_model = .rgb,
            .sample_type = .u16,
            .color_channels = 3,
            .extra_channels = 0,
            .exposure_value = null,
        },
        .pixels = .{ .u16 = pixels },
    };
    try core.image_io.writeTiff(path, &image);
}
