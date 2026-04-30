const std = @import("std");
const core = @import("align_stack_core");
const image_io = core.image_io;
const profiler = core.profiler;

pub const LoadError = image_io.LoadError || error{
    MismatchedImageSizes,
    MismatchedImageFormats,
};

pub const StackInfo = struct {
    width: u32,
    height: u32,
    color_model: image_io.ColorModel,
    sample_type: image_io.SampleType,
    color_channels: u8,
    extra_channels: u8,
};

pub fn loadAndValidateImage(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: ?StackInfo,
) (LoadError || std.mem.Allocator.Error)!image_io.Image {
    const prof = profiler.scope("fuse.io.loadAndValidateImage");
    defer prof.end();

    var image = try image_io.loadImage(allocator, path);
    errdefer image.deinit(allocator);

    if (expected) |info| {
        if (image.info.width != info.width or image.info.height != info.height) {
            return error.MismatchedImageSizes;
        }
        if (image.info.color_model != info.color_model or
            image.info.sample_type != info.sample_type or
            image.info.color_channels != info.color_channels or
            image.info.extra_channels != info.extra_channels)
        {
            return error.MismatchedImageFormats;
        }
    }

    return image;
}

pub fn stackInfoFromImage(image: *const image_io.Image) StackInfo {
    return .{
        .width = image.info.width,
        .height = image.info.height,
        .color_model = image.info.color_model,
        .sample_type = image.info.sample_type,
        .color_channels = image.info.color_channels,
        .extra_channels = image.info.extra_channels,
    };
}
