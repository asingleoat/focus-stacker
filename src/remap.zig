const std = @import("std");
const image_io = @import("image_io.zig");
const optimize = @import("optimize.zig");
const profiler = @import("profiler.zig");
const sequence = @import("sequence.zig");

pub fn writeAlignedImages(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    ordered_indices: []const usize,
    remap_active: []const bool,
    images: []const sequence.InputImage,
    poses: []const optimize.ImagePose,
    roi: ?Rect,
    jobs: usize,
) !void {
    const prof = profiler.scope("remap.writeAlignedImages");
    defer prof.end();

    const prefix_dir = std.fs.path.dirname(prefix);
    if (prefix_dir) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var tasks: std.ArrayListUnmanaged(OutputTask) = .{};
    defer tasks.deinit(allocator);
    var output_index: usize = 0;
    for (ordered_indices) |image_index| {
        if (!remap_active[image_index]) continue;
        try tasks.append(allocator, .{
            .image_index = image_index,
            .output_index = output_index,
        });
        output_index += 1;
    }

    if (tasks.items.len == 0) return;
    const image_parallelism = @min(tasks.items.len, jobs);
    const row_jobs_per_image = @max(@as(usize, 1), jobs / image_parallelism);

    if (jobs <= 1 or tasks.items.len == 1) {
        for (tasks.items) |task| {
            try writeAlignedImageTask(allocator, prefix, images, poses, roi, row_jobs_per_image, task);
        }
        return;
    }

    var thread_safe_allocator: std.heap.ThreadSafeAllocator = .{ .child_allocator = allocator };
    var state = OutputWorkerState{
        .allocator = thread_safe_allocator.allocator(),
        .prefix = prefix,
        .images = images,
        .poses = poses,
        .roi = roi,
        .tasks = tasks.items,
        .row_jobs_per_image = row_jobs_per_image,
    };

    const worker_count = image_parallelism - 1;
    var threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var started_threads: usize = 0;
    errdefer {
        for (threads[0..started_threads]) |thread| {
            thread.join();
        }
    }

    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, outputWorkerMain, .{&state});
        started_threads += 1;
    }

    outputWorkerMain(&state);

    for (threads) |thread| {
        thread.join();
    }

    if (state.first_error) |err| {
        return err;
    }
}

const OutputTask = struct {
    image_index: usize,
    output_index: usize,
};

const OutputWorkerState = struct {
    allocator: std.mem.Allocator,
    prefix: []const u8,
    images: []const sequence.InputImage,
    poses: []const optimize.ImagePose,
    roi: ?Rect,
    tasks: []const OutputTask,
    row_jobs_per_image: usize,
    next_index: usize = 0,
    first_error: ?anyerror = null,
    mutex: std.Thread.Mutex = .{},
};

fn outputWorkerMain(state: *OutputWorkerState) void {
    while (true) {
        const task = nextOutputTask(state) orelse return;
        writeAlignedImageTask(state.allocator, state.prefix, state.images, state.poses, state.roi, state.row_jobs_per_image, task) catch |err| {
            recordOutputError(state, err);
            return;
        };
    }
}

fn nextOutputTask(state: *OutputWorkerState) ?OutputTask {
    state.mutex.lock();
    defer state.mutex.unlock();

    if (state.first_error != null) return null;
    if (state.next_index >= state.tasks.len) return null;

    const task = state.tasks[state.next_index];
    state.next_index += 1;
    return task;
}

fn recordOutputError(state: *OutputWorkerState, err: anyerror) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (state.first_error == null) {
        state.first_error = err;
    }
}

fn writeAlignedImageTask(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    images: []const sequence.InputImage,
    poses: []const optimize.ImagePose,
    roi: ?Rect,
    remap_jobs: usize,
    task: OutputTask,
) !void {
    var src = blk: {
        const phase_prof = profiler.scope("remap.loadSourceImage");
        defer phase_prof.end();
        break :blk try image_io.loadImage(allocator, images[task.image_index].path);
    };
    defer src.deinit(allocator);

    var remapped = blk: {
        const phase_prof = profiler.scope("remap.remapImage");
        defer phase_prof.end();
        break :blk try remapRigidImage(allocator, &src, poses[task.image_index], roi, remap_jobs);
    };
    defer remapped.deinit(allocator);

    const path = try std.fmt.allocPrint(allocator, "{s}_{d:0>4}.tif", .{ prefix, task.output_index });
    defer allocator.free(path);
    {
        const phase_prof = profiler.scope("remap.writeTiff");
        defer phase_prof.end();
        try image_io.writeTiff(path, &remapped);
    }
}

pub fn remapRigidImage(
    allocator: std.mem.Allocator,
    src: *const image_io.Image,
    pose: optimize.ImagePose,
    roi: ?Rect,
    jobs: usize,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!image_io.Image {
    const prof = profiler.scope("remap.remapRigidImage");
    defer prof.end();

    const out_rect = roi orelse Rect{
        .left = 0,
        .top = 0,
        .right = @intCast(src.info.width),
        .bottom = @intCast(src.info.height),
    };
    const info = imageInfoForRect(src, out_rect);

    return switch (src.pixels) {
        .u8 => blk: {
            const pixels = try allocator.alloc(u8, pixelCount(info));
            errdefer allocator.free(pixels);
            try remapU8(allocator, pixels, src, pose, out_rect, jobs);
            break :blk .{
                .info = info,
                .pixels = .{ .u8 = pixels },
            };
        },
        .u16 => blk: {
            const pixels = try allocator.alloc(u16, pixelCount(info));
            errdefer allocator.free(pixels);
            try remapU16(allocator, pixels, src, pose, out_rect, jobs);
            break :blk .{
                .info = info,
                .pixels = .{ .u16 = pixels },
            };
        },
    };
}

fn imageInfoForRect(src: *const image_io.Image, out_rect: Rect) image_io.ImageInfo {
    return .{
        .format = .tiff,
        .width = @intCast(out_rect.right - out_rect.left),
        .height = @intCast(out_rect.bottom - out_rect.top),
        .color_model = src.info.color_model,
        .sample_type = src.info.sample_type,
        .color_channels = src.info.color_channels,
        .extra_channels = 1,
        .exposure_value = src.info.exposure_value,
        .exif_focal_length_mm = src.info.exif_focal_length_mm,
        .exif_focal_length_35mm = src.info.exif_focal_length_35mm,
        .exif_crop_factor = src.info.exif_crop_factor,
    };
}

fn remapU8(allocator: std.mem.Allocator, dst: []u8, src: *const image_io.Image, pose: optimize.ImagePose, roi: Rect, jobs: usize) !void {
    const prof = profiler.scope("remap.remapU8");
    defer prof.end();

    const width = src.info.width;
    const height = src.info.height;
    const out_width = @as(u32, @intCast(roi.right - roi.left));
    const out_height = @as(u32, @intCast(roi.bottom - roi.top));
    const src_channels = @as(usize, src.info.color_channels);
    const dst_channels = src_channels + 1;
    const src_pixels = src.pixels.u8;
    const cache = optimize.initInverseTransformCache(pose, width, height);

    if (jobs <= 1 or out_height <= 32) {
        remapU8Rows(dst, src_pixels, width, height, src_channels, dst_channels, roi, cache, out_width, 0, out_height);
        return;
    }

    const worker_count = @min(jobs, @as(usize, out_height));
    if (worker_count <= 1) {
        remapU8Rows(dst, src_pixels, width, height, src_channels, dst_channels, roi, cache, out_width, 0, out_height);
        return;
    }

    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);

    const rows_per_worker = std.math.divCeil(usize, out_height, worker_count) catch unreachable;
    var ranges = try allocator.alloc(RemapRowRange, worker_count);
    defer allocator.free(ranges);
    for (0..worker_count) |worker_index| {
        const start = @min(worker_index * rows_per_worker, @as(usize, out_height));
        const end = @min(start + rows_per_worker, @as(usize, out_height));
        ranges[worker_index] = .{ .start = @intCast(start), .end = @intCast(end) };
    }

    for (threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, remapU8RowsWorker, .{
            dst,
            src_pixels,
            width,
            height,
            src_channels,
            dst_channels,
            roi,
            cache,
            out_width,
            ranges[i + 1],
        });
    }

    remapU8Rows(dst, src_pixels, width, height, src_channels, dst_channels, roi, cache, out_width, ranges[0].start, ranges[0].end);

    for (threads) |thread| {
        thread.join();
    }
}

fn remapU16(allocator: std.mem.Allocator, dst: []u16, src: *const image_io.Image, pose: optimize.ImagePose, roi: Rect, jobs: usize) !void {
    const prof = profiler.scope("remap.remapU16");
    defer prof.end();

    const width = src.info.width;
    const height = src.info.height;
    const out_width = @as(u32, @intCast(roi.right - roi.left));
    const out_height = @as(u32, @intCast(roi.bottom - roi.top));
    const src_channels = @as(usize, src.info.color_channels);
    const dst_channels = src_channels + 1;
    const src_pixels = src.pixels.u16;
    const cache = optimize.initInverseTransformCache(pose, width, height);

    if (jobs <= 1 or out_height <= 32) {
        remapU16Rows(dst, src_pixels, width, height, src_channels, dst_channels, roi, cache, out_width, 0, out_height);
        return;
    }

    const worker_count = @min(jobs, @as(usize, out_height));
    if (worker_count <= 1) {
        remapU16Rows(dst, src_pixels, width, height, src_channels, dst_channels, roi, cache, out_width, 0, out_height);
        return;
    }

    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);

    const rows_per_worker = std.math.divCeil(usize, out_height, worker_count) catch unreachable;
    var ranges = try allocator.alloc(RemapRowRange, worker_count);
    defer allocator.free(ranges);
    for (0..worker_count) |worker_index| {
        const start = @min(worker_index * rows_per_worker, @as(usize, out_height));
        const end = @min(start + rows_per_worker, @as(usize, out_height));
        ranges[worker_index] = .{ .start = @intCast(start), .end = @intCast(end) };
    }

    for (threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, remapU16RowsWorker, .{
            dst,
            src_pixels,
            width,
            height,
            src_channels,
            dst_channels,
            roi,
            cache,
            out_width,
            ranges[i + 1],
        });
    }

    remapU16Rows(dst, src_pixels, width, height, src_channels, dst_channels, roi, cache, out_width, ranges[0].start, ranges[0].end);

    for (threads) |thread| {
        thread.join();
    }
}

const RemapRowRange = struct {
    start: u32,
    end: u32,
};

fn remapU8Rows(
    dst: []u8,
    src_pixels: []const u8,
    width: u32,
    height: u32,
    src_channels: usize,
    dst_channels: usize,
    roi: Rect,
    cache: optimize.InverseTransformCache,
    out_width: u32,
    row_start: u32,
    row_end: u32,
) void {
    if (!cache.basic_rectilinear and !cache.has_translation) {
        remapU8RowsNoTranslationLens(dst, src_pixels, width, height, src_channels, dst_channels, roi, cache, out_width, row_start, row_end);
        return;
    }

    const roi_left = @as(f64, @floatFromInt(roi.left));
    const roi_top = @as(f64, @floatFromInt(roi.top));
    const out_width_usize = @as(usize, out_width);
    for (row_start..row_end) |y| {
        const world_y = roi_top + @as(f64, @floatFromInt(y));
        var world_x = roi_left;
        var dst_base = (@as(usize, y) * out_width_usize) * dst_channels;
        for (0..out_width) |_| {
            const sample = optimize.inverseTransformPointCached(cache, world_x, world_y);
            samplePixelBilinearU8(dst[dst_base .. dst_base + dst_channels], src_pixels, width, height, src_channels, dst_channels, sample.x, sample.y);
            dst_base += dst_channels;
            world_x += 1.0;
        }
    }
}

fn remapU8RowsNoTranslationLens(
    dst: []u8,
    src_pixels: []const u8,
    width: u32,
    height: u32,
    src_channels: usize,
    dst_channels: usize,
    roi: Rect,
    cache: optimize.InverseTransformCache,
    out_width: u32,
    row_start: u32,
    row_end: u32,
) void {
    const prof = profiler.scope("remap.remapU8RowsNoTranslationLens");
    defer prof.end();

    const roi_left = @as(f64, @floatFromInt(roi.left));
    const roi_top = @as(f64, @floatFromInt(roi.top));
    const out_width_usize = @as(usize, out_width);
    const pano_x_step_x = cache.world_to_local[0][0];
    const pano_x_step_y = cache.world_to_local[1][0];
    const pano_x_step_z = cache.world_to_local[2][0];
    const constant_z = -cache.dest_focal;
    const base_x = roi_left - cache.dest_center_x;

    for (row_start..row_end) |y| {
        const pano_y = (roi_top + @as(f64, @floatFromInt(y))) - cache.dest_center_y;
        var local_x =
            cache.world_to_local[0][0] * base_x +
            cache.world_to_local[0][1] * pano_y +
            cache.world_to_local[0][2] * constant_z;
        var local_y =
            cache.world_to_local[1][0] * base_x +
            cache.world_to_local[1][1] * pano_y +
            cache.world_to_local[1][2] * constant_z;
        var local_z =
            cache.world_to_local[2][0] * base_x +
            cache.world_to_local[2][1] * pano_y +
            cache.world_to_local[2][2] * constant_z;

        var dst_base = (@as(usize, y) * out_width_usize) * dst_channels;
        for (0..out_width) |_| {
            const denom = -local_z;
            if (@abs(denom) < 1e-12) {
                @memset(dst[dst_base .. dst_base + dst_channels], 0);
            } else {
                const radial_x = cache.image_focal * (local_x / denom) + cache.center_shift_x;
                const radial_y = cache.image_focal * (local_y / denom) + cache.center_shift_y;
                const sample = undistortSourcePoint(cache, radial_x, radial_y);
                samplePixelBilinearU8(dst[dst_base .. dst_base + dst_channels], src_pixels, width, height, src_channels, dst_channels, sample.x, sample.y);
            }
            dst_base += dst_channels;
            local_x += pano_x_step_x;
            local_y += pano_x_step_y;
            local_z += pano_x_step_z;
        }
    }
}

fn remapU16Rows(
    dst: []u16,
    src_pixels: []const u16,
    width: u32,
    height: u32,
    src_channels: usize,
    dst_channels: usize,
    roi: Rect,
    cache: optimize.InverseTransformCache,
    out_width: u32,
    row_start: u32,
    row_end: u32,
) void {
    if (!cache.basic_rectilinear and !cache.has_translation) {
        remapU16RowsNoTranslationLens(dst, src_pixels, width, height, src_channels, dst_channels, roi, cache, out_width, row_start, row_end);
        return;
    }

    const roi_left = @as(f64, @floatFromInt(roi.left));
    const roi_top = @as(f64, @floatFromInt(roi.top));
    const out_width_usize = @as(usize, out_width);
    for (row_start..row_end) |y| {
        const world_y = roi_top + @as(f64, @floatFromInt(y));
        var world_x = roi_left;
        var dst_base = (@as(usize, y) * out_width_usize) * dst_channels;
        for (0..out_width) |_| {
            const sample = optimize.inverseTransformPointCached(cache, world_x, world_y);
            samplePixelBilinearU16(dst[dst_base .. dst_base + dst_channels], src_pixels, width, height, src_channels, dst_channels, sample.x, sample.y);
            dst_base += dst_channels;
            world_x += 1.0;
        }
    }
}

fn remapU16RowsNoTranslationLens(
    dst: []u16,
    src_pixels: []const u16,
    width: u32,
    height: u32,
    src_channels: usize,
    dst_channels: usize,
    roi: Rect,
    cache: optimize.InverseTransformCache,
    out_width: u32,
    row_start: u32,
    row_end: u32,
) void {
    const prof = profiler.scope("remap.remapU16RowsNoTranslationLens");
    defer prof.end();

    const roi_left = @as(f64, @floatFromInt(roi.left));
    const roi_top = @as(f64, @floatFromInt(roi.top));
    const out_width_usize = @as(usize, out_width);
    const pano_x_step_x = cache.world_to_local[0][0];
    const pano_x_step_y = cache.world_to_local[1][0];
    const pano_x_step_z = cache.world_to_local[2][0];
    const constant_z = -cache.dest_focal;
    const base_x = roi_left - cache.dest_center_x;

    for (row_start..row_end) |y| {
        const pano_y = (roi_top + @as(f64, @floatFromInt(y))) - cache.dest_center_y;
        var local_x =
            cache.world_to_local[0][0] * base_x +
            cache.world_to_local[0][1] * pano_y +
            cache.world_to_local[0][2] * constant_z;
        var local_y =
            cache.world_to_local[1][0] * base_x +
            cache.world_to_local[1][1] * pano_y +
            cache.world_to_local[1][2] * constant_z;
        var local_z =
            cache.world_to_local[2][0] * base_x +
            cache.world_to_local[2][1] * pano_y +
            cache.world_to_local[2][2] * constant_z;

        var dst_base = (@as(usize, y) * out_width_usize) * dst_channels;
        for (0..out_width) |_| {
            const denom = -local_z;
            if (@abs(denom) < 1e-12) {
                @memset(dst[dst_base .. dst_base + dst_channels], 0);
            } else {
                const radial_x = cache.image_focal * (local_x / denom) + cache.center_shift_x;
                const radial_y = cache.image_focal * (local_y / denom) + cache.center_shift_y;
                const sample = undistortSourcePoint(cache, radial_x, radial_y);
                samplePixelBilinearU16(dst[dst_base .. dst_base + dst_channels], src_pixels, width, height, src_channels, dst_channels, sample.x, sample.y);
            }
            dst_base += dst_channels;
            local_x += pano_x_step_x;
            local_y += pano_x_step_y;
            local_z += pano_x_step_z;
        }
    }
}

fn remapU8RowsWorker(
    dst: []u8,
    src_pixels: []const u8,
    width: u32,
    height: u32,
    src_channels: usize,
    dst_channels: usize,
    roi: Rect,
    cache: optimize.InverseTransformCache,
    out_width: u32,
    range: RemapRowRange,
) void {
    remapU8Rows(dst, src_pixels, width, height, src_channels, dst_channels, roi, cache, out_width, range.start, range.end);
}

fn remapU16RowsWorker(
    dst: []u16,
    src_pixels: []const u16,
    width: u32,
    height: u32,
    src_channels: usize,
    dst_channels: usize,
    roi: Rect,
    cache: optimize.InverseTransformCache,
    out_width: u32,
    range: RemapRowRange,
) void {
    remapU16Rows(dst, src_pixels, width, height, src_channels, dst_channels, roi, cache, out_width, range.start, range.end);
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

fn samplePixelBilinearU8(
    dst: []u8,
    pixels: []const u8,
    width: u32,
    height: u32,
    src_channels: usize,
    dst_channels: usize,
    x: f64,
    y: f64,
) void {
    const prof = profiler.scope("remap.samplePixelBilinearU8");
    defer prof.end();

    const support = bilinearSupport(width, height, x, y);
    if (support <= 0) {
        @memset(dst[0..dst_channels], 0);
        return;
    }

    const x0 = @as(i32, @intFromFloat(@floor(x)));
    const y0 = @as(i32, @intFromFloat(@floor(y)));
    const x1 = x0 + 1;
    const y1 = y0 + 1;
    const fx = x - @as(f64, @floatFromInt(x0));
    const fy = y - @as(f64, @floatFromInt(y0));
    const one_minus_fx = 1.0 - fx;
    const one_minus_fy = 1.0 - fy;
    const w00 = one_minus_fx * one_minus_fy;
    const w10 = fx * one_minus_fy;
    const w01 = one_minus_fx * fy;
    const w11 = fx * fy;

    for (0..src_channels) |channel| {
        dst[channel] = bilinearChannelU8Soft(pixels, width, height, src_channels, x0, y0, x1, y1, channel, w00, w10, w01, w11, support);
    }
    if (dst_channels > src_channels) {
        dst[src_channels] = @as(u8, @intFromFloat(@round(support * 255.0)));
    }
}

fn undistortSourcePoint(cache: optimize.InverseTransformCache, dx: f64, dy: f64) optimize.Point2 {
    const q_radius = @sqrt(dx * dx + dy * dy);
    if (q_radius < 1e-12) {
        return .{
            .x = cache.src_center_x + dx,
            .y = cache.src_center_y + dy,
        };
    }

    var radius = q_radius;
    for (0..6) |_| {
        const normalized_r2 = radius * radius * cache.radial_inv_norm;
        const normalized_r4 = normalized_r2 * normalized_r2;
        const factor = 1.0 + cache.radial_a * normalized_r2 + cache.radial_b * normalized_r4 + cache.radial_c * normalized_r4 * normalized_r2;
        const factor_derivative =
            cache.radial_a +
            2.0 * cache.radial_b * normalized_r2 +
            3.0 * cache.radial_c * normalized_r4;
        const f = radius * factor - q_radius;
        if (@abs(f) <= 1e-9) break;
        const df = factor + 2.0 * radius * radius * cache.radial_inv_norm * factor_derivative;
        if (@abs(df) < 1e-12) break;
        radius -= f / df;
        radius = @max(radius, 0.0);
    }

    const scale = radius / q_radius;
    return .{
        .x = cache.src_center_x + (dx * scale),
        .y = cache.src_center_y + (dy * scale),
    };
}

fn samplePixelBilinearU16(
    dst: []u16,
    pixels: []const u16,
    width: u32,
    height: u32,
    src_channels: usize,
    dst_channels: usize,
    x: f64,
    y: f64,
) void {
    const prof = profiler.scope("remap.samplePixelBilinearU16");
    defer prof.end();

    const support = bilinearSupport(width, height, x, y);
    if (support <= 0) {
        @memset(dst[0..dst_channels], 0);
        return;
    }

    const x0 = @as(i32, @intFromFloat(@floor(x)));
    const y0 = @as(i32, @intFromFloat(@floor(y)));
    const x1 = x0 + 1;
    const y1 = y0 + 1;
    const fx = x - @as(f64, @floatFromInt(x0));
    const fy = y - @as(f64, @floatFromInt(y0));
    const one_minus_fx = 1.0 - fx;
    const one_minus_fy = 1.0 - fy;
    const w00 = one_minus_fx * one_minus_fy;
    const w10 = fx * one_minus_fy;
    const w01 = one_minus_fx * fy;
    const w11 = fx * fy;

    for (0..src_channels) |channel| {
        dst[channel] = bilinearChannelU16Soft(pixels, width, height, src_channels, x0, y0, x1, y1, channel, w00, w10, w01, w11, support);
    }
    if (dst_channels > src_channels) {
        dst[src_channels] = @as(u16, @intFromFloat(@round(support * 65535.0)));
    }
}

fn bilinearSupport(width: u32, height: u32, x: f64, y: f64) f64 {
    const x0 = @as(i32, @intFromFloat(@floor(x)));
    const y0 = @as(i32, @intFromFloat(@floor(y)));
    const x1 = x0 + 1;
    const y1 = y0 + 1;
    const fx = x - @as(f64, @floatFromInt(x0));
    const fy = y - @as(f64, @floatFromInt(y0));
    const one_minus_fx = 1.0 - fx;
    const one_minus_fy = 1.0 - fy;

    var support: f64 = 0.0;
    if (inBounds(x0, y0, width, height)) support += one_minus_fx * one_minus_fy;
    if (inBounds(x1, y0, width, height)) support += fx * one_minus_fy;
    if (inBounds(x0, y1, width, height)) support += one_minus_fx * fy;
    if (inBounds(x1, y1, width, height)) support += fx * fy;
    return support;
}

fn bilinearChannelU8Soft(
    pixels: []const u8,
    width: u32,
    height: u32,
    channels: usize,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    channel: usize,
    w00: f64,
    w10: f64,
    w01: f64,
    w11: f64,
    support: f64,
) u8 {
    var value: f64 = 0.0;
    if (inBounds(x0, y0, width, height)) value += @as(f64, @floatFromInt(sampleU8(pixels, width, channels, @intCast(x0), @intCast(y0), channel))) * w00;
    if (inBounds(x1, y0, width, height)) value += @as(f64, @floatFromInt(sampleU8(pixels, width, channels, @intCast(x1), @intCast(y0), channel))) * w10;
    if (inBounds(x0, y1, width, height)) value += @as(f64, @floatFromInt(sampleU8(pixels, width, channels, @intCast(x0), @intCast(y1), channel))) * w01;
    if (inBounds(x1, y1, width, height)) value += @as(f64, @floatFromInt(sampleU8(pixels, width, channels, @intCast(x1), @intCast(y1), channel))) * w11;
    return @as(u8, @intFromFloat(@round(value / support)));
}

fn bilinearChannelU16Soft(
    pixels: []const u16,
    width: u32,
    height: u32,
    channels: usize,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    channel: usize,
    w00: f64,
    w10: f64,
    w01: f64,
    w11: f64,
    support: f64,
) u16 {
    var value: f64 = 0.0;
    if (inBounds(x0, y0, width, height)) value += @as(f64, @floatFromInt(sampleU16(pixels, width, channels, @intCast(x0), @intCast(y0), channel))) * w00;
    if (inBounds(x1, y0, width, height)) value += @as(f64, @floatFromInt(sampleU16(pixels, width, channels, @intCast(x1), @intCast(y0), channel))) * w10;
    if (inBounds(x0, y1, width, height)) value += @as(f64, @floatFromInt(sampleU16(pixels, width, channels, @intCast(x0), @intCast(y1), channel))) * w01;
    if (inBounds(x1, y1, width, height)) value += @as(f64, @floatFromInt(sampleU16(pixels, width, channels, @intCast(x1), @intCast(y1), channel))) * w11;
    return @as(u16, @intFromFloat(@round(value / support)));
}

fn inBounds(x: i32, y: i32, width: u32, height: u32) bool {
    return x >= 0 and y >= 0 and x < @as(i32, @intCast(width)) and y < @as(i32, @intCast(height));
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
    return @as(usize, info.width) * @as(usize, info.height) * @as(usize, info.color_channels + info.extra_channels);
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

    var remapped = try remapRigidImage(allocator, &src, .{}, null, 1);
    defer remapped.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 5), remapped.info.width);
    try std.testing.expectEqual(@as(u32, 5), remapped.info.height);
    try std.testing.expectEqual(@as(u8, 1), remapped.info.color_channels);
    try std.testing.expectEqual(@as(u8, 1), remapped.info.extra_channels);
    const stride: usize = remapped.info.color_channels + remapped.info.extra_channels;
    try std.testing.expectEqual(@as(u8, 13), remapped.pixels.u8[(2 * 5 + 2) * stride]);
    try std.testing.expectEqual(@as(u8, 255), remapped.pixels.u8[(2 * 5 + 2) * stride + 1]);
    try std.testing.expectEqual(@as(u8, 18), remapped.pixels.u8[(3 * 5 + 2) * stride]);
    try std.testing.expectEqual(@as(u8, 255), remapped.pixels.u8[(3 * 5 + 2) * stride + 1]);
    try std.testing.expectEqual(@as(u8, 14), remapped.pixels.u8[(2 * 5 + 3) * stride]);
    try std.testing.expectEqual(@as(u8, 255), remapped.pixels.u8[(2 * 5 + 3) * stride + 1]);
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
