const std = @import("std");
const core = @import("align_stack_core");

pub fn fillAverageFromLoaded(dst: []f32, image: *const core.image_io.Image) void {
    const count = @as(usize, image.info.width) * @as(usize, image.info.height);
    std.debug.assert(dst.len >= count);

    switch (image.pixels) {
        .u8 => |src| fillAverageU8(dst[0..count], image, src),
        .u16 => |src| fillAverageU16(dst[0..count], image, src),
    }
}

pub fn sampleScaleForType(sample_type: core.image_io.SampleType) f32 {
    return switch (sample_type) {
        .u8 => 255.0,
        .u16 => 65535.0,
    };
}

fn fillAverageU8(dst: []f32, image: *const core.image_io.Image, src: []const u8) void {
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
                const sum: u32 = @as(u32, src[base]) + @as(u32, src[base + 1]) + @as(u32, src[base + 2]);
                dst[i] = @as(f32, @floatFromInt(sum)) / (3.0 * 255.0);
            }
        },
    }
}

fn fillAverageU16(dst: []f32, image: *const core.image_io.Image, src: []const u16) void {
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
                const sum: u32 = @as(u32, src[base]) + @as(u32, src[base + 1]) + @as(u32, src[base + 2]);
                dst[i] = @as(f32, @floatFromInt(sum)) / (3.0 * 65535.0);
            }
        },
    }
}

test "fillAverageFromLoaded averages RGB channels" {
    var pixels = [_]u8{ 0, 255, 255 };
    const image = core.image_io.Image{
        .info = .{
            .format = .tiff,
            .width = 1,
            .height = 1,
            .color_model = .rgb,
            .sample_type = .u8,
            .color_channels = 3,
            .extra_channels = 0,
            .exposure_value = null,
        },
        .pixels = .{ .u8 = pixels[0..] },
    };
    var gray = [_]f32{0};
    fillAverageFromLoaded(gray[0..], &image);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), gray[0], 1e-6);
}
