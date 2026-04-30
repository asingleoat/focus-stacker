const std = @import("std");
const profiler = @import("profiler.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("setjmp.h");
    @cInclude("jpeglib.h");
    @cInclude("png.h");
    @cInclude("tiffio.h");
    @cInclude("libexif/exif-data.h");
    @cInclude("libexif/exif-tag.h");
    @cInclude("libexif/exif-utils.h");
});

pub const Format = enum {
    jpeg,
    png,
    tiff,
};

pub const ColorModel = enum {
    grayscale,
    rgb,
};

pub const SampleType = enum {
    u8,
    u16,
};

pub const ImageInfo = struct {
    format: Format,
    width: u32,
    height: u32,
    color_model: ColorModel,
    sample_type: SampleType,
    color_channels: u8,
    extra_channels: u8,
    exposure_value: ?f64,
    exif_focal_length_mm: ?f64 = null,
    exif_focal_length_35mm: ?f64 = null,
    exif_crop_factor: ?f64 = null,
};

pub const PixelStorage = union(enum) {
    u8: []u8,
    u16: []u16,
};

pub const Image = struct {
    info: ImageInfo,
    pixels: PixelStorage,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        switch (self.pixels) {
            .u8 => |pixels| allocator.free(pixels),
            .u16 => |pixels| allocator.free(pixels),
        }
    }
};

pub const LoadError = error{
    UnsupportedFormat,
    InvalidImage,
    UnsupportedPixelFormat,
    OpenFailed,
    DecodeFailed,
};

pub const SaveError = error{
    OpenFailed,
    EncodeFailed,
    UnsupportedPixelFormat,
};

pub const TiffWriter = struct {
    tiff: *c.TIFF,

    pub fn deinit(self: *TiffWriter) void {
        c.TIFFClose(self.tiff);
    }

    pub fn writeScanlineU8(self: *TiffWriter, row_index: u32, scanline: []const u8) SaveError!void {
        const prof = profiler.scope("image_io.tiffWriter.writeScanlineU8");
        defer prof.end();
        if (c.TIFFWriteScanline(self.tiff, @ptrCast(@constCast(scanline.ptr)), @as(c.uint32, @intCast(row_index)), 0) == -1) {
            return error.EncodeFailed;
        }
    }

    pub fn writeScanlineU16(self: *TiffWriter, row_index: u32, scanline: []const u16) SaveError!void {
        const prof = profiler.scope("image_io.tiffWriter.writeScanlineU16");
        defer prof.end();
        if (c.TIFFWriteScanline(self.tiff, @ptrCast(@constCast(scanline.ptr)), @as(c.uint32, @intCast(row_index)), 0) == -1) {
            return error.EncodeFailed;
        }
    }
};

pub fn openTiffWriter(path: []const u8, info: ImageInfo) SaveError!TiffWriter {
    const path_z = std.heap.c_allocator.dupeZ(u8, path) catch return error.OpenFailed;
    defer std.heap.c_allocator.free(path_z);

    const tiff = c.TIFFOpen(path_z.ptr, "w") orelse return error.OpenFailed;
    errdefer c.TIFFClose(tiff);

    const samples_per_pixel: u16 = info.color_channels + info.extra_channels;
    const bits_per_sample: u16 = switch (info.sample_type) {
        .u8 => 8,
        .u16 => 16,
    };
    const photometric: u16 = switch (info.color_model) {
        .grayscale => c.PHOTOMETRIC_MINISBLACK,
        .rgb => c.PHOTOMETRIC_RGB,
    };
    const sample_format: u16 = c.SAMPLEFORMAT_UINT;
    const x_resolution: f32 = 150.0;
    const y_resolution: f32 = 150.0;
    const bytes_per_sample = bits_per_sample / 8;
    const row_bytes = @as(c.uint32, @intCast(@as(usize, info.width) * @as(usize, samples_per_pixel) * @as(usize, bytes_per_sample)));

    _ = c.TIFFSetField(tiff, c.TIFFTAG_IMAGEWIDTH, @as(c.uint32, @intCast(info.width)));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_IMAGELENGTH, @as(c.uint32, @intCast(info.height)));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_SAMPLESPERPIXEL, @as(c.uint16, @intCast(samples_per_pixel)));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_BITSPERSAMPLE, @as(c.uint16, @intCast(bits_per_sample)));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_PLANARCONFIG, c.PLANARCONFIG_CONTIG);
    _ = c.TIFFSetField(tiff, c.TIFFTAG_SAMPLEFORMAT, @as(c.uint16, @intCast(sample_format)));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_PHOTOMETRIC, @as(c.uint16, @intCast(photometric)));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_COMPRESSION, c.COMPRESSION_NONE);
    _ = c.TIFFSetField(tiff, c.TIFFTAG_ORIENTATION, c.ORIENTATION_TOPLEFT);
    _ = c.TIFFSetField(tiff, c.TIFFTAG_ROWSPERSTRIP, c.TIFFDefaultStripSize(tiff, row_bytes));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_RESOLUTIONUNIT, c.RESUNIT_INCH);
    _ = c.TIFFSetField(tiff, c.TIFFTAG_XRESOLUTION, x_resolution);
    _ = c.TIFFSetField(tiff, c.TIFFTAG_YRESOLUTION, y_resolution);
    _ = c.TIFFSetField(tiff, c.TIFFTAG_PIXAR_IMAGEFULLWIDTH, @as(c.uint32, @intCast(info.width)));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_PIXAR_IMAGEFULLLENGTH, @as(c.uint32, @intCast(info.height)));
    if (info.extra_channels > 0) {
        var extra_sample_kind: c.uint16 = c.EXTRASAMPLE_UNASSALPHA;
        _ = c.TIFFSetField(tiff, c.TIFFTAG_EXTRASAMPLES, @as(c.uint16, @intCast(info.extra_channels)), &extra_sample_kind);
    }

    return .{ .tiff = tiff };
}

pub fn loadInfo(allocator: std.mem.Allocator, path: []const u8) (LoadError || std.mem.Allocator.Error)!ImageInfo {
    const prof = profiler.scope("image_io.loadInfo");
    defer prof.end();

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const detected = detectFormat(path) orelse return error.UnsupportedFormat;
    return switch (detected) {
        .jpeg => try loadJpegInfo(path_z),
        .png => try loadPngInfo(path_z),
        .tiff => try loadTiffInfo(path_z),
    };
}

pub fn loadImage(allocator: std.mem.Allocator, path: []const u8) (LoadError || std.mem.Allocator.Error)!Image {
    const prof = profiler.scope("image_io.loadImage");
    defer prof.end();

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const detected = detectFormat(path) orelse return error.UnsupportedFormat;
    return switch (detected) {
        .jpeg => try loadJpegImage(allocator, path_z),
        .png => try loadPngImage(allocator, path_z),
        .tiff => try loadTiffImage(allocator, path_z),
    };
}

pub fn writeTiff(path: []const u8, image: *const Image) SaveError!void {
    const prof = profiler.scope("image_io.writeTiff");
    defer prof.end();

    var writer = try openTiffWriter(path, image.info);
    defer writer.deinit();

    const channels = @as(usize, image.info.color_channels + image.info.extra_channels);
    const width = @as(usize, image.info.width);
    switch (image.pixels) {
        .u8 => |pixels| {
            for (0..image.info.height) |row_index| {
                const src_row = pixels[row_index * width * channels ..][0 .. width * channels];
                {
                    const write_prof = profiler.scope("image_io.writeTiff.writeScanlineU8");
                    defer write_prof.end();
                    try writer.writeScanlineU8(@intCast(row_index), src_row);
                }
            }
        },
        .u16 => |pixels| {
            for (0..image.info.height) |row_index| {
                const src_row = pixels[row_index * width * channels ..][0 .. width * channels];
                {
                    const write_prof = profiler.scope("image_io.writeTiff.writeScanlineU16");
                    defer write_prof.end();
                    try writer.writeScanlineU16(@intCast(row_index), src_row);
                }
            }
        },
    }
}

pub fn isRawPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;

    const raw_extensions = [_][]const u8{
        ".3fr", ".arw", ".cr2", ".cr3", ".dcr", ".dng", ".erf", ".iiq", ".k25", ".kdc",
        ".mdc", ".mef", ".mos", ".mrw", ".nef", ".nrw", ".orf", ".pef", ".raf", ".raw",
        ".rw2", ".rwl", ".sr2", ".srf", ".x3f",
    };

    for (raw_extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

pub fn deriveHfovDegrees(info: ImageInfo, fisheye: bool) ?f64 {
    const focal_length = info.exif_focal_length_mm orelse return null;
    const crop_factor = info.exif_crop_factor orelse return null;
    if (focal_length <= 0 or crop_factor <= 0.1) return null;

    return calcHfov(
        if (fisheye) .full_frame_fisheye else .rectilinear,
        focal_length,
        crop_factor,
        info.width,
        info.height,
    );
}

fn detectFormat(path: []const u8) ?Format {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".jpg")) return .jpeg;
    if (std.ascii.eqlIgnoreCase(ext, ".jpeg")) return .jpeg;
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return .png;
    if (std.ascii.eqlIgnoreCase(ext, ".tif")) return .tiff;
    if (std.ascii.eqlIgnoreCase(ext, ".tiff")) return .tiff;
    return null;
}

const JpegErrorManager = extern struct {
    mgr: c.jpeg_error_mgr,
    jump_buffer: c.jmp_buf,
};

fn jpegErrorExit(common: ?*c.jpeg_common_struct) callconv(.c) void {
    const mgr_ptr: *c.jpeg_error_mgr = @ptrCast(common.?.err.?);
    const err: *JpegErrorManager = @fieldParentPtr("mgr", mgr_ptr);
    c.longjmp(@ptrCast(&err.jump_buffer), 1);
}

fn loadJpegInfo(path_z: [:0]const u8) LoadError!ImageInfo {
    const prof = profiler.scope("image_io.loadJpegInfo");
    defer prof.end();

    const file = c.fopen(path_z.ptr, "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(file);

    var decompress: c.jpeg_decompress_struct = undefined;
    var err: JpegErrorManager = undefined;
    decompress.err = c.jpeg_std_error(&err.mgr);
    err.mgr.error_exit = jpegErrorExit;

    if (c.setjmp(@ptrCast(&err.jump_buffer)) != 0) {
        c.jpeg_destroy_decompress(&decompress);
        return error.InvalidImage;
    }

    c.jpeg_create_decompress(&decompress);
    defer c.jpeg_destroy_decompress(&decompress);

    c.jpeg_stdio_src(&decompress, file);
    if (c.jpeg_read_header(&decompress, c.TRUE) != c.JPEG_HEADER_OK) {
        return error.InvalidImage;
    }

    return infoFromJpegHeader(path_z, &decompress);
}

fn loadJpegImage(allocator: std.mem.Allocator, path_z: [:0]const u8) (LoadError || std.mem.Allocator.Error)!Image {
    const prof = profiler.scope("image_io.loadJpegImage");
    defer prof.end();

    const file = c.fopen(path_z.ptr, "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(file);

    var decompress: c.jpeg_decompress_struct = undefined;
    var err: JpegErrorManager = undefined;
    decompress.err = c.jpeg_std_error(&err.mgr);
    err.mgr.error_exit = jpegErrorExit;

    if (c.setjmp(@ptrCast(&err.jump_buffer)) != 0) {
        c.jpeg_destroy_decompress(&decompress);
        return error.DecodeFailed;
    }

    c.jpeg_create_decompress(&decompress);
    defer c.jpeg_destroy_decompress(&decompress);

    c.jpeg_stdio_src(&decompress, file);
    if (c.jpeg_read_header(&decompress, c.TRUE) != c.JPEG_HEADER_OK) {
        return error.InvalidImage;
    }

    const source_info = try infoFromJpegHeader(path_z, &decompress);
    decompress.out_color_space = switch (source_info.color_model) {
        .grayscale => c.JCS_GRAYSCALE,
        .rgb => c.JCS_RGB,
    };

    if (c.jpeg_start_decompress(&decompress) == 0) {
        return error.DecodeFailed;
    }
    defer _ = c.jpeg_finish_decompress(&decompress);

    const pixels = try allocator.alloc(u8, pixelCount(source_info));
    errdefer allocator.free(pixels);

    const row_stride = @as(usize, source_info.width) * @as(usize, source_info.color_channels + source_info.extra_channels);
    while (decompress.output_scanline < decompress.output_height) {
        const offset = @as(usize, decompress.output_scanline) * row_stride;
        var row_ptr = [_]c.JSAMPROW{
            @ptrCast(pixels.ptr + offset),
        };
        if (c.jpeg_read_scanlines(&decompress, @ptrCast(&row_ptr), 1) != 1) {
            return error.DecodeFailed;
        }
    }

    return .{
        .info = source_info,
        .pixels = .{ .u8 = pixels },
    };
}

fn infoFromJpegHeader(path_z: [:0]const u8, decompress: *c.jpeg_decompress_struct) LoadError!ImageInfo {
    if (decompress.data_precision != 8) return error.UnsupportedPixelFormat;

    const color_model: ColorModel = switch (decompress.jpeg_color_space) {
        c.JCS_GRAYSCALE => .grayscale,
        c.JCS_RGB, c.JCS_YCbCr => .rgb,
        else => return error.UnsupportedPixelFormat,
    };

    const color_channels: u8 = switch (color_model) {
        .grayscale => 1,
        .rgb => 3,
    };

    const exif = readExifSummary(path_z);

    return .{
        .format = .jpeg,
        .width = @intCast(decompress.image_width),
        .height = @intCast(decompress.image_height),
        .color_model = color_model,
        .sample_type = .u8,
        .color_channels = color_channels,
        .extra_channels = 0,
        .exposure_value = exif.exposure_value,
        .exif_focal_length_mm = exif.focal_length_mm,
        .exif_focal_length_35mm = exif.focal_length_35mm,
        .exif_crop_factor = exif.crop_factor,
    };
}

fn loadPngInfo(path_z: [:0]const u8) LoadError!ImageInfo {
    const prof = profiler.scope("image_io.loadPngInfo");
    defer prof.end();

    var image: c.png_image = std.mem.zeroes(c.png_image);
    image.version = c.PNG_IMAGE_VERSION;
    defer c.png_image_free(&image);

    if (c.png_image_begin_read_from_file(&image, path_z.ptr) == 0) {
        return error.InvalidImage;
    }

    return infoFromPngImage(path_z, image);
}

fn loadPngImage(allocator: std.mem.Allocator, path_z: [:0]const u8) (LoadError || std.mem.Allocator.Error)!Image {
    const prof = profiler.scope("image_io.loadPngImage");
    defer prof.end();

    var image: c.png_image = std.mem.zeroes(c.png_image);
    image.version = c.PNG_IMAGE_VERSION;
    defer c.png_image_free(&image);

    if (c.png_image_begin_read_from_file(&image, path_z.ptr) == 0) {
        return error.InvalidImage;
    }

    const source_info = infoFromPngImage(path_z, image);
    image.format = switch (source_info.color_model) {
        .grayscale => if (source_info.sample_type == .u16) c.PNG_FORMAT_LINEAR_Y else c.PNG_FORMAT_GRAY,
        .rgb => if (source_info.sample_type == .u16) c.PNG_FORMAT_LINEAR_RGB else c.PNG_FORMAT_RGB,
    };

    return switch (source_info.sample_type) {
        .u8 => blk: {
            const pixels = try allocator.alloc(u8, pixelCount(source_info));
            errdefer allocator.free(pixels);

            if (c.png_image_finish_read(&image, null, pixels.ptr, 0, null) == 0) {
                return error.DecodeFailed;
            }

            break :blk Image{
                .info = source_info,
                .pixels = .{ .u8 = pixels },
            };
        },
        .u16 => blk: {
            const pixels = try allocator.alloc(u16, pixelCount(source_info));
            errdefer allocator.free(pixels);

            if (c.png_image_finish_read(&image, null, @ptrCast(pixels.ptr), 0, null) == 0) {
                return error.DecodeFailed;
            }

            break :blk Image{
                .info = source_info,
                .pixels = .{ .u16 = pixels },
            };
        },
    };
}

fn infoFromPngImage(path_z: [:0]const u8, image: c.png_image) ImageInfo {
    const is_color = (image.format & c.PNG_FORMAT_FLAG_COLOR) != 0;
    const has_alpha = (image.format & c.PNG_FORMAT_FLAG_ALPHA) != 0;
    const is_linear = (image.format & c.PNG_FORMAT_FLAG_LINEAR) != 0;
    const exif = readExifSummary(path_z);

    return .{
        .format = .png,
        .width = @intCast(image.width),
        .height = @intCast(image.height),
        .color_model = if (is_color) .rgb else .grayscale,
        .sample_type = if (is_linear) .u16 else .u8,
        .color_channels = if (is_color) 3 else 1,
        .extra_channels = if (has_alpha) 1 else 0,
        .exposure_value = exif.exposure_value,
        .exif_focal_length_mm = exif.focal_length_mm,
        .exif_focal_length_35mm = exif.focal_length_35mm,
        .exif_crop_factor = exif.crop_factor,
    };
}

fn loadTiffInfo(path_z: [:0]const u8) LoadError!ImageInfo {
    const prof = profiler.scope("image_io.loadTiffInfo");
    defer prof.end();

    const tiff = c.TIFFOpen(path_z.ptr, "r") orelse return error.OpenFailed;
    defer c.TIFFClose(tiff);

    return try readTiffInfo(path_z, tiff);
}

fn loadTiffImage(allocator: std.mem.Allocator, path_z: [:0]const u8) (LoadError || std.mem.Allocator.Error)!Image {
    const prof = profiler.scope("image_io.loadTiffImage");
    defer prof.end();

    const tiff = c.TIFFOpen(path_z.ptr, "r") orelse return error.OpenFailed;
    defer c.TIFFClose(tiff);

    const info = try readTiffInfo(path_z, tiff);
    const samples_per_pixel = info.color_channels + info.extra_channels;

    return switch (info.sample_type) {
        .u8 => blk: {
            const pixels = try allocator.alloc(u8, pixelCount(info));
            errdefer allocator.free(pixels);
            const scanline = try allocator.alloc(u8, @as(usize, info.width) * samples_per_pixel);
            defer allocator.free(scanline);

            try readTiffRowsU8(tiff, info, scanline, pixels);
            break :blk Image{
                .info = info,
                .pixels = .{ .u8 = pixels },
            };
        },
        .u16 => blk: {
            const pixels = try allocator.alloc(u16, pixelCount(info));
            errdefer allocator.free(pixels);
            const scanline = try allocator.alloc(u16, @as(usize, info.width) * samples_per_pixel);
            defer allocator.free(scanline);

            try readTiffRowsU16(tiff, info, scanline, pixels);
            break :blk Image{
                .info = info,
                .pixels = .{ .u16 = pixels },
            };
        },
    };
}

fn readTiffInfo(path_z: [:0]const u8, tiff: ?*c.TIFF) LoadError!ImageInfo {
    var width: c.uint32 = 0;
    var height: c.uint32 = 0;
    if (c.TIFFGetField(tiff, c.TIFFTAG_IMAGEWIDTH, &width) != 1) return error.InvalidImage;
    if (c.TIFFGetField(tiff, c.TIFFTAG_IMAGELENGTH, &height) != 1) return error.InvalidImage;

    const photometric = getTiffU16(tiff, c.TIFFTAG_PHOTOMETRIC, 0);
    const samples_per_pixel = getTiffU16(tiff, c.TIFFTAG_SAMPLESPERPIXEL, 1);
    const bits_per_sample = getTiffU16(tiff, c.TIFFTAG_BITSPERSAMPLE, 1);
    const sample_format = getTiffU16(tiff, c.TIFFTAG_SAMPLEFORMAT, c.SAMPLEFORMAT_UINT);
    const planar_config = getTiffU16(tiff, c.TIFFTAG_PLANARCONFIG, c.PLANARCONFIG_CONTIG);

    if (planar_config != c.PLANARCONFIG_CONTIG) return error.UnsupportedPixelFormat;
    if (sample_format != c.SAMPLEFORMAT_UINT) return error.UnsupportedPixelFormat;

    const sample_type: SampleType = switch (bits_per_sample) {
        8 => .u8,
        16 => .u16,
        else => return error.UnsupportedPixelFormat,
    };
    const exif = readExifSummary(path_z);

    return switch (photometric) {
        c.PHOTOMETRIC_MINISBLACK, c.PHOTOMETRIC_MINISWHITE => .{
            .format = .tiff,
            .width = @intCast(width),
            .height = @intCast(height),
            .color_model = .grayscale,
            .sample_type = sample_type,
            .color_channels = 1,
            .extra_channels = @intCast(if (samples_per_pixel > 1) samples_per_pixel - 1 else 0),
            .exposure_value = exif.exposure_value,
            .exif_focal_length_mm = exif.focal_length_mm,
            .exif_focal_length_35mm = exif.focal_length_35mm,
            .exif_crop_factor = exif.crop_factor,
        },
        c.PHOTOMETRIC_RGB => .{
            .format = .tiff,
            .width = @intCast(width),
            .height = @intCast(height),
            .color_model = .rgb,
            .sample_type = sample_type,
            .color_channels = 3,
            .extra_channels = @intCast(if (samples_per_pixel > 3) samples_per_pixel - 3 else 0),
            .exposure_value = exif.exposure_value,
            .exif_focal_length_mm = exif.focal_length_mm,
            .exif_focal_length_35mm = exif.focal_length_35mm,
            .exif_crop_factor = exif.crop_factor,
        },
        else => error.UnsupportedPixelFormat,
    };
}

fn readTiffRowsU8(tiff: ?*c.TIFF, info: ImageInfo, scanline: []u8, out_pixels: []u8) LoadError!void {
    const samples_per_pixel = info.color_channels + info.extra_channels;
    const width = @as(usize, info.width);
    const out_channels = @as(usize, samples_per_pixel);
    const photometric = getTiffU16(tiff, c.TIFFTAG_PHOTOMETRIC, c.PHOTOMETRIC_MINISBLACK);

    for (0..info.height) |row| {
        if (c.TIFFReadScanline(tiff, @ptrCast(scanline.ptr), @intCast(row), 0) == -1) {
            return error.DecodeFailed;
        }

        const dst_row = out_pixels[row * width * out_channels ..][0 .. width * out_channels];
        for (0..width) |x| {
            const src = scanline[x * samples_per_pixel ..][0..samples_per_pixel];
            const dst = dst_row[x * out_channels ..][0..out_channels];
            if (info.color_channels == 1) {
                dst[0] = if (photometric == c.PHOTOMETRIC_MINISWHITE) 0xff - src[0] else src[0];
                if (out_channels > 1) {
                    @memcpy(dst[1..out_channels], src[1..out_channels]);
                }
            } else {
                @memcpy(dst, src[0..out_channels]);
            }
        }
    }
}

fn readTiffRowsU16(tiff: ?*c.TIFF, info: ImageInfo, scanline: []u16, out_pixels: []u16) LoadError!void {
    const samples_per_pixel = info.color_channels + info.extra_channels;
    const width = @as(usize, info.width);
    const out_channels = @as(usize, samples_per_pixel);
    const photometric = getTiffU16(tiff, c.TIFFTAG_PHOTOMETRIC, c.PHOTOMETRIC_MINISBLACK);

    for (0..info.height) |row| {
        if (c.TIFFReadScanline(tiff, @ptrCast(scanline.ptr), @intCast(row), 0) == -1) {
            return error.DecodeFailed;
        }

        const dst_row = out_pixels[row * width * out_channels ..][0 .. width * out_channels];
        for (0..width) |x| {
            const src = scanline[x * samples_per_pixel ..][0..samples_per_pixel];
            const dst = dst_row[x * out_channels ..][0..out_channels];
            if (info.color_channels == 1) {
                dst[0] = if (photometric == c.PHOTOMETRIC_MINISWHITE) 0xffff - src[0] else src[0];
                if (out_channels > 1) {
                    @memcpy(dst[1..out_channels], src[1..out_channels]);
                }
            } else {
                @memcpy(dst, src[0..out_channels]);
            }
        }
    }
}

fn getTiffU16(tiff: ?*c.TIFF, tag: c.ttag_t, default_value: u16) u16 {
    var value: c.uint16 = 0;
    if (c.TIFFGetField(tiff, tag, &value) == 1) {
        return @intCast(value);
    }
    return default_value;
}

fn pixelCount(info: ImageInfo) usize {
    return @as(usize, info.width) * @as(usize, info.height) * @as(usize, info.color_channels + info.extra_channels);
}

const ExifSummary = struct {
    exposure_value: ?f64 = null,
    focal_length_mm: ?f64 = null,
    focal_length_35mm: ?f64 = null,
    crop_factor: ?f64 = null,
};

fn readExifSummary(path_z: [:0]const u8) ExifSummary {
    const prof = profiler.scope("image_io.readExifSummary");
    defer prof.end();

    const exif_data = c.exif_data_new_from_file(path_z.ptr) orelse return .{};
    defer c.exif_data_unref(exif_data);

    const focal_length_mm = readExifRational(exif_data, c.EXIF_TAG_FOCAL_LENGTH);
    const focal_length_35mm = readExifShort(exif_data, c.EXIF_TAG_FOCAL_LENGTH_IN_35MM_FILM);

    var crop_factor: ?f64 = null;
    if (focal_length_mm) |focal_length| {
        if (focal_length > 0) {
            if (focal_length_35mm) |focal_length_35_raw| {
                if (focal_length_35_raw > 0) {
                    crop_factor = @as(f64, @floatFromInt(focal_length_35_raw)) / focal_length;
                }
            }
        }
    }

    var exposure_value: ?f64 = null;
    if (readExifRational(exif_data, c.EXIF_TAG_FNUMBER)) |aperture| {
        if (readExifRational(exif_data, c.EXIF_TAG_EXPOSURE_TIME)) |exposure_time| {
            if (aperture > 0 and exposure_time > 0) {
                const iso = readExifIso(exif_data) orelse 100.0;
                if (iso > 0) {
                    exposure_value = std.math.log2((aperture * aperture) / exposure_time * (100.0 / iso));
                }
            }
        }
    }

    return .{
        .exposure_value = exposure_value,
        .focal_length_mm = focal_length_mm,
        .focal_length_35mm = if (focal_length_35mm) |value| @floatFromInt(value) else null,
        .crop_factor = crop_factor,
    };
}

const Projection = enum {
    rectilinear,
    full_frame_fisheye,
};

fn calcHfov(projection: Projection, focal_length_mm: f64, crop_factor: f64, width: u32, height: u32) f64 {
    const full_frame_diagonal = @sqrt(36.0 * 36.0 + 24.0 * 24.0);
    const sensor_diagonal = full_frame_diagonal / crop_factor;
    const aspect_ratio = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(height));
    const sensor_width = sensor_diagonal / @sqrt(1.0 + 1.0 / (aspect_ratio * aspect_ratio));

    return switch (projection) {
        .rectilinear => 2.0 * std.math.radiansToDegrees(std.math.atan((sensor_width * 0.5) / focal_length_mm)),
        .full_frame_fisheye => sensor_width / focal_length_mm * std.math.deg_per_rad,
    };
}

fn readExifIso(exif_data: ?*c.ExifData) ?f64 {
    if (readExifShort(exif_data, c.EXIF_TAG_ISO_SPEED)) |iso| {
        if (iso > 0) return @floatFromInt(iso);
    }
    if (readExifShort(exif_data, c.EXIF_TAG_ISO_SPEED_RATINGS)) |iso| {
        if (iso > 0) return @floatFromInt(iso);
    }
    if (readExifShort(exif_data, c.EXIF_TAG_STANDARD_OUTPUT_SENSITIVITY)) |iso| {
        if (iso > 0) return @floatFromInt(iso);
    }
    return null;
}

fn readExifShort(exif_data: ?*c.ExifData, tag: c.ExifTag) ?u16 {
    const data = exif_data orelse return null;
    const entry = findExifEntry(exif_data, tag) orelse return null;
    if (entry.*.format != c.EXIF_FORMAT_SHORT or entry.*.components < 1 or entry.*.data == null) return null;
    return c.exif_get_short(entry.*.data, c.exif_data_get_byte_order(data));
}

fn readExifRational(exif_data: ?*c.ExifData, tag: c.ExifTag) ?f64 {
    const data = exif_data orelse return null;
    const entry = findExifEntry(exif_data, tag) orelse return null;
    if (entry.*.format != c.EXIF_FORMAT_RATIONAL or entry.*.components < 1 or entry.*.data == null) return null;

    const rational = c.exif_get_rational(entry.*.data, c.exif_data_get_byte_order(data));
    if (rational.denominator == 0) return null;
    return @as(f64, @floatFromInt(rational.numerator)) / @as(f64, @floatFromInt(rational.denominator));
}

fn findExifEntry(exif_data: ?*c.ExifData, tag: c.ExifTag) ?*c.ExifEntry {
    const data = exif_data orelse return null;

    const ifds = [_]c.ExifIfd{
        c.EXIF_IFD_0,
        c.EXIF_IFD_1,
        c.EXIF_IFD_EXIF,
        c.EXIF_IFD_GPS,
        c.EXIF_IFD_INTEROPERABILITY,
    };

    for (ifds) |ifd| {
        if (c.exif_content_get_entry(data.ifd[@as(usize, @intCast(ifd))], tag)) |entry| {
            return entry;
        }
    }
    return null;
}

test "png metadata and decode use vendored upstream icon" {
    const allocator = std.testing.allocator;
    const info = try loadInfo(allocator, "upstream/hugin-2025.0.1/platforms/linux/icons/hugin_16.png");
    try std.testing.expectEqual(Format.png, info.format);
    try std.testing.expectEqual(@as(u32, 16), info.width);
    try std.testing.expectEqual(@as(u32, 16), info.height);
    try std.testing.expectEqual(ColorModel.rgb, info.color_model);
    try std.testing.expectEqual(@as(u8, 1), info.extra_channels);

    var image = try loadImage(allocator, "upstream/hugin-2025.0.1/platforms/linux/icons/hugin_16.png");
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 16), image.info.width);
    try std.testing.expectEqual(@as(u8, 1), image.info.extra_channels);
    switch (image.pixels) {
        .u8 => |pixels| try std.testing.expectEqual(@as(usize, 16 * 16 * 4), pixels.len),
        .u16 => |_| return error.UnsupportedPixelFormat,
    }
}

test "jpeg metadata and decode use vendored upstream fixture" {
    const allocator = std.testing.allocator;
    const info = try loadInfo(allocator, "tests/golden/s003_small/0001.jpg");
    try std.testing.expectEqual(Format.jpeg, info.format);
    try std.testing.expectEqual(@as(u32, 768), info.width);
    try std.testing.expectEqual(@as(u32, 512), info.height);
    try std.testing.expectEqual(ColorModel.rgb, info.color_model);
    try std.testing.expectEqual(SampleType.u8, info.sample_type);

    var image = try loadImage(allocator, "tests/golden/s003_small/0001.jpg");
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 768), image.info.width);
    switch (image.pixels) {
        .u8 => |pixels| try std.testing.expectEqual(@as(usize, 768 * 512 * 3), pixels.len),
        .u16 => |_| return error.UnsupportedPixelFormat,
    }
}

test "raw extension detection rejects common camera formats" {
    try std.testing.expect(isRawPath("frame_0001.CR3"));
    try std.testing.expect(isRawPath("capture.nef"));
    try std.testing.expect(!isRawPath("stacked.tif"));
}

test "derive hfov matches upstream rectilinear formula" {
    const info = ImageInfo{
        .format = .jpeg,
        .width = 6000,
        .height = 4000,
        .color_model = .rgb,
        .sample_type = .u8,
        .color_channels = 3,
        .extra_channels = 0,
        .exposure_value = null,
        .exif_focal_length_mm = 90.0,
        .exif_focal_length_35mm = 135.0,
        .exif_crop_factor = 1.5,
    };

    const hfov = deriveHfovDegrees(info, false).?;
    try std.testing.expectApproxEqAbs(@as(f64, 15.18928673718289), hfov, 1e-9);
}
