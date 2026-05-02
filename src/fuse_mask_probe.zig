const std = @import("std");
const fuse = @import("focus_fuse_core");
const gray = fuse.image_io;
const core = @import("align_stack_core");

fn usage(exe_name: []const u8) []const u8 {
    _ = exe_name;
    return
        \\Usage: fuse_mask_probe <output_dir> <aligned_input_1> <aligned_input_2> ...
        \\
        \\Writes:
        \\  - norm_sum.tif
        \\  - union_support.tif
        \\  - mask_0000.tif, mask_0001.tif, ...
        \\
    ;
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 4) {
        try std.fs.File.stderr().writeAll(usage(args[0]));
        return error.InvalidArgs;
    }

    const output_dir = args[1];
    const input_files = args[2..];
    try std.fs.cwd().makePath(output_dir);

    var expected: ?fuse.io.StackInfo = null;
    var gray_buffer = std.ArrayListUnmanaged(f32){};
    defer gray_buffer.deinit(allocator);
    var support_buffer = std.ArrayListUnmanaged(f32){};
    defer support_buffer.deinit(allocator);
    var weight_buffer = std.ArrayListUnmanaged(f32){};
    defer weight_buffer.deinit(allocator);
    var norm_weight_sums = std.ArrayListUnmanaged(f32){};
    defer norm_weight_sums.deinit(allocator);
    var contrast_workspace: ?fuse.contrast.Workspace = null;
    defer if (contrast_workspace) |*value| value.deinit(allocator);

    var cached_images = std.ArrayListUnmanaged(core.image_io.Image){};
    defer {
        for (cached_images.items) |*image| image.deinit(allocator);
        cached_images.deinit(allocator);
    }

    for (input_files) |path| {
        var image = try fuse.io.loadAndValidateImage(allocator, path, expected);
        if (expected == null) {
            expected = fuse.io.stackInfoFromImage(&image);
            const count = @as(usize, image.info.width) * @as(usize, image.info.height);
            try gray_buffer.resize(allocator, count);
            try support_buffer.resize(allocator, count);
            try weight_buffer.resize(allocator, count);
            try norm_weight_sums.resize(allocator, count);
            @memset(norm_weight_sums.items, 0);
            contrast_workspace = try fuse.contrast.Workspace.init(allocator, image.info.width, 1);
        }
        try computeWeightMap(&image, gray_buffer.items, support_buffer.items, weight_buffer.items, &(contrast_workspace.?));
        fuse.masks.applySupportInto(&image, weight_buffer.items);
        fuse.masks.accumulateBinarySupportMax(&image, support_buffer.items);
        for (norm_weight_sums.items, weight_buffer.items) |*sum, weight| sum.* += weight;
        try cached_images.append(allocator, image);
    }

    const info = cached_images.items[0].info;
    try writeScalarMapU16Auto(allocator, output_dir, "norm_sum.tif", info.width, info.height, norm_weight_sums.items);
    try writeScalarMapU16Unit(allocator, output_dir, "union_support.tif", info.width, info.height, support_buffer.items);

    for (cached_images.items, 0..) |*image, index| {
        try computeWeightMap(image, gray_buffer.items, support_buffer.items, weight_buffer.items, &(contrast_workspace.?));
        fuse.masks.applySupportInto(image, weight_buffer.items);
        var raw_filename_buf: [64]u8 = undefined;
        const raw_filename = try std.fmt.bufPrint(&raw_filename_buf, "rawmask_{d:0>4}.tif", .{index});
        const sample_scale: f32 = switch (image.info.sample_type) {
            .u8 => 255.0,
            .u16 => 65535.0,
        };
        for (weight_buffer.items) |*value| value.* /= sample_scale;
        try writeScalarMapU16Unit(allocator, output_dir, raw_filename, info.width, info.height, weight_buffer.items);
        fuse.pyramid.normalizeWeightsInto(weight_buffer.items, norm_weight_sums.items, cached_images.items.len, gray_buffer.items);
        var filename_buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "mask_{d:0>4}.tif", .{index});
        try writeScalarMapU16Unit(allocator, output_dir, filename, info.width, info.height, gray_buffer.items);
    }
}

fn computeWeightMap(
    image: *const core.image_io.Image,
    gray_pixels: []f32,
    support_pixels: []f32,
    weights: []f32,
    workspace: *fuse.contrast.Workspace,
) !void {
    fuse.grayscale.fillAverageFromLoaded(gray_pixels, image);
    fuse.masks.fillBinarySupport(image, support_pixels);
    var gray_image = core.gray.GrayImage{
        .width = image.info.width,
        .height = image.info.height,
        .pixels = gray_pixels,
        .sample_scale = fuse.grayscale.sampleScaleForType(image.info.sample_type),
    };
    try fuse.contrast.computeLocalContrastWeightsWithWorkspace(&gray_image, support_pixels, 5, 1, weights, workspace);
}

fn writeScalarMapU16Unit(
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

fn writeScalarMapU16Auto(
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
