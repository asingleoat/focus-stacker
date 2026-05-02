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

        var lap_summary_buf: [64]u8 = undefined;
        const lap_summary = try std.fmt.bufPrint(&lap_summary_buf, "lap_{d:0>2}_profile.txt", .{level_index});
        try writeRgbAbsProfileSummary(frame_dir, lap_summary, current.width, current.height, lap);
    }
}

pub fn dumpWeightedWorkspaceLevels(
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

    for (workspace.expanded_levels, 0..) |level, level_index| {
        const current = workspace.gaussian_levels[level_index];
        const mask = workspace.mask_levels[level_index];
        const count = @as(usize, current.width) * @as(usize, current.height) * 3;
        const weighted = try allocator.alloc(f32, count);
        defer allocator.free(weighted);
        for (0..count / 3) |pixel_index| {
            const base = pixel_index * 3;
            const weight = mask.pixels[pixel_index];
            weighted[base + 0] = (current.pixels[base + 0] - level.pixels[base + 0]) * weight;
            weighted[base + 1] = (current.pixels[base + 1] - level.pixels[base + 1]) * weight;
            weighted[base + 2] = (current.pixels[base + 2] - level.pixels[base + 2]) * weight;
        }
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "weighted_{d:0>2}.tif", .{level_index});
        try writeRgbMapU16SignedAuto(allocator, frame_dir, name, current.width, current.height, weighted);

        var summary_buf: [96]u8 = undefined;
        const summary_name = try std.fmt.bufPrint(&summary_buf, "weighted_{d:0>2}_profile.txt", .{level_index});
        try writeRgbAbsProfileSummary(frame_dir, summary_name, current.width, current.height, weighted);
    }

    const last_index = workspace.mask_levels.len - 1;
    const gaussian = workspace.gaussian_levels[last_index];
    const mask = workspace.mask_levels[last_index];
    const count = @as(usize, gaussian.width) * @as(usize, gaussian.height) * 3;
    const weighted = try allocator.alloc(f32, count);
    defer allocator.free(weighted);
    for (0..count / 3) |pixel_index| {
        const base = pixel_index * 3;
        const weight = mask.pixels[pixel_index];
        weighted[base + 0] = gaussian.pixels[base + 0] * weight;
        weighted[base + 1] = gaussian.pixels[base + 1] * weight;
        weighted[base + 2] = gaussian.pixels[base + 2] * weight;
    }
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "weighted_{d:0>2}.tif", .{last_index});
    try writeRgbMapU16SignedAuto(allocator, frame_dir, name, gaussian.width, gaussian.height, weighted);

    var summary_buf: [96]u8 = undefined;
    const summary_name = try std.fmt.bufPrint(&summary_buf, "weighted_{d:0>2}_profile.txt", .{last_index});
    try writeRgbAbsProfileSummary(frame_dir, summary_name, gaussian.width, gaussian.height, weighted);
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

fn writeRgbAbsProfileSummary(
    output_dir: []const u8,
    filename: []const u8,
    width: u32,
    height: u32,
    values: []const f32,
) !void {
    const row_count = @as(usize, height);
    const col_count = @as(usize, width);
    var row_means = try std.heap.page_allocator.alloc(f64, row_count);
    defer std.heap.page_allocator.free(row_means);
    var col_means = try std.heap.page_allocator.alloc(f64, col_count);
    defer std.heap.page_allocator.free(col_means);
    @memset(row_means, 0);
    @memset(col_means, 0);

    var global_sum: f64 = 0.0;
    for (0..row_count) |row| {
        const row_base = row * col_count * 3;
        for (0..col_count) |col| {
            const base = row_base + col * 3;
            const magnitude = (@abs(values[base + 0]) + @abs(values[base + 1]) + @abs(values[base + 2])) / 3.0;
            const mag64 = @as(f64, magnitude);
            row_means[row] += mag64;
            col_means[col] += mag64;
            global_sum += mag64;
        }
    }
    const pixel_count = @as(f64, @floatFromInt(row_count * col_count));
    for (row_means) |*value| value.* /= @as(f64, @floatFromInt(col_count));
    for (col_means) |*value| value.* /= @as(f64, @floatFromInt(row_count));
    const global_mean = if (pixel_count > 0.0) global_sum / pixel_count else 0.0;

    const row_stddev = stddev(row_means, global_mean);
    const col_stddev = stddev(col_means, global_mean);
    const row_neighbor_rms = neighborRms(row_means);
    const col_neighbor_rms = neighborRms(col_means);

    const path = try std.fs.path.join(std.heap.page_allocator, &.{ output_dir, filename });
    defer std.heap.page_allocator.free(path);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buf: [1024]u8 = undefined;
    var writer = file.writer(&buf);
    const w = &writer.interface;
    try w.print("width={d}\n", .{width});
    try w.print("height={d}\n", .{height});
    try w.print("global_mean_abs={d:.8}\n", .{global_mean});
    try w.print("row_mean_stddev={d:.8}\n", .{row_stddev});
    try w.print("col_mean_stddev={d:.8}\n", .{col_stddev});
    try w.print("row_neighbor_rms={d:.8}\n", .{row_neighbor_rms});
    try w.print("col_neighbor_rms={d:.8}\n", .{col_neighbor_rms});
    try w.print("stddev_ratio_row_over_col={d:.8}\n", .{if (col_stddev > 0.0) row_stddev / col_stddev else 0.0});
    try w.print("neighbor_rms_ratio_row_over_col={d:.8}\n", .{if (col_neighbor_rms > 0.0) row_neighbor_rms / col_neighbor_rms else 0.0});
    try w.flush();
}

fn stddev(values: []const f64, mean: f64) f64 {
    if (values.len == 0) return 0.0;
    var sum_sq: f64 = 0.0;
    for (values) |value| {
        const diff = value - mean;
        sum_sq += diff * diff;
    }
    return @sqrt(sum_sq / @as(f64, @floatFromInt(values.len)));
}

fn neighborRms(values: []const f64) f64 {
    if (values.len <= 1) return 0.0;
    var sum_sq: f64 = 0.0;
    for (values[1..], values[0 .. values.len - 1]) |current, prev| {
        const diff = current - prev;
        sum_sq += diff * diff;
    }
    return @sqrt(sum_sq / @as(f64, @floatFromInt(values.len - 1)));
}
