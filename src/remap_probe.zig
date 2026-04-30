const std = @import("std");
const core = @import("root.zig");

pub fn main() !void {
    const allocator = core.alloc_profiler.wrap(std.heap.page_allocator);
    defer writeProfilerReport();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 4) usage();
    if (!std.mem.eql(u8, args[1], "image")) usage();

    const pto_path = args[2];
    const image_index = try std.fmt.parseInt(usize, args[3], 10);
    const repeat_count = if (args.len >= 5) try std.fmt.parseInt(usize, args[4], 10) else 1;
    const jobs = if (args.len >= 6) try std.fmt.parseInt(usize, args[5], 10) else 1;
    const output_prefix: ?[]const u8 = if (args.len >= 7 and !std.mem.eql(u8, args[6], "-")) args[6] else null;

    var project = try core.parity_pto.parseFile(allocator, pto_path);
    defer project.deinit(allocator);
    if (image_index >= project.images.len) return error.ImageIndexOutOfRange;

    const images = try buildInputImages(allocator, project.images);
    defer {
        for (images) |image| allocator.free(image.path);
        allocator.free(images);
    }

    const poses = try collectPoses(allocator, project.images);
    defer allocator.free(poses);

    const remap_active = try allocator.alloc(bool, project.images.len);
    defer allocator.free(remap_active);
    @memset(remap_active, true);

    var roi_timer = try std.time.Timer.start();
    const roi = try core.remap.computeCommonOverlapRoi(allocator, remap_active, images, poses);
    const roi_ns = roi_timer.read();

    var total_load_ns: u64 = 0;
    var total_remap_ns: u64 = 0;
    var total_write_ns: u64 = 0;

    for (0..repeat_count) |iteration| {
        var load_timer = try std.time.Timer.start();
        var src = try core.image_io.loadImage(allocator, images[image_index].path);
        total_load_ns += load_timer.read();
        defer src.deinit(allocator);

        var remap_timer = try std.time.Timer.start();
        var remapped = try core.remap.remapRigidImage(
            allocator,
            &src,
            project.images[image_index].pose,
            roi,
            jobs,
        );
        total_remap_ns += remap_timer.read();
        defer remapped.deinit(allocator);

        if (output_prefix) |prefix| {
            const path = try std.fmt.allocPrint(allocator, "{s}_{d:0>4}.tif", .{ prefix, iteration });
            defer allocator.free(path);
            if (std.fs.path.dirname(path)) |dir| {
                try std.fs.cwd().makePath(dir);
            }
            var write_timer = try std.time.Timer.start();
            try core.image_io.writeTiff(path, &remapped);
            total_write_ns += write_timer.read();
        }
    }

    var roi_width = images[image_index].width;
    var roi_height = images[image_index].height;
    if (roi) |r| {
        roi_width = @as(u32, @intCast(r.right - r.left));
        roi_height = @as(u32, @intCast(r.bottom - r.top));
    }

    std.debug.print(
        "image_index={d}\nrepeats={d}\njobs={d}\nroi_ms={d:.3}\nload_ms={d:.3}\nremap_ms={d:.3}\nwrite_ms={d:.3}\nroi_width={d}\nroi_height={d}\n",
        .{
            image_index,
            repeat_count,
            jobs,
            nsToMs(roi_ns),
            nsToMs(total_load_ns),
            nsToMs(total_remap_ns),
            nsToMs(total_write_ns),
            roi_width,
            roi_height,
        },
    );
}

fn buildInputImages(allocator: std.mem.Allocator, entries: []const core.parity_pto.ImageEntry) ![]core.sequence.InputImage {
    const images = try allocator.alloc(core.sequence.InputImage, entries.len);
    errdefer allocator.free(images);

    for (entries, images, 0..) |entry, *image, index| {
        const path_copy = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(path_copy);
        const info = try core.image_io.loadInfo(allocator, entry.path);
        image.* = .{
            .pano_index = index,
            .path = path_copy,
            .format = info.format,
            .width = info.width,
            .height = info.height,
            .color_model = info.color_model,
            .sample_type = info.sample_type,
            .exposure_value = info.exposure_value,
            .hfov_degrees = entry.pose.base_hfov_degrees + entry.pose.hfov_delta,
        };
    }

    return images;
}

fn collectPoses(allocator: std.mem.Allocator, entries: []const core.parity_pto.ImageEntry) ![]core.optimize.ImagePose {
    const poses = try allocator.alloc(core.optimize.ImagePose, entries.len);
    for (entries, poses) |entry, *pose| {
        pose.* = entry.pose;
    }
    return poses;
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn writeProfilerReport() void {
    if (!core.alloc_profiler.enabled) return;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    core.alloc_profiler.maybeWriteReport(&stderr_writer.interface) catch {};
    stderr_writer.interface.flush() catch {};
}

fn usage() noreturn {
    std.debug.print(
        "usage: remap_probe image <pto> <image_index> [repeat_count] [jobs] [output_prefix|-]\n",
        .{},
    );
    std.process.exit(1);
}
