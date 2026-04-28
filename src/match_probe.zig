const std = @import("std");
const features = @import("align_stack_core").features;
const gray = @import("align_stack_core").gray;
const image_io = @import("align_stack_core").image_io;
const match_mod = @import("align_stack_core").match;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try std.process.argsWithAllocator(arena);
    defer args.deinit();

    _ = args.next();
    const command = args.next() orelse {
        try usage();
        return error.InvalidArguments;
    };

    if (std.mem.eql(u8, command, "dump-reduced-pgm")) {
        const image_path = args.next() orelse return error.InvalidArguments;
        const pyr_level = try parseU8(args.next() orelse return error.InvalidArguments);
        const output_path = args.next() orelse return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;

        var reduced = try loadReducedGrayImage(arena, image_path, pyr_level);
        defer reduced.deinit(arena);
        try writePgm(arena, &reduced, output_path);
        return;
    }

    if (std.mem.eql(u8, command, "dump-import-ppm")) {
        const image_path = args.next() orelse return error.InvalidArguments;
        const output_path = args.next() orelse return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;

        var image = try image_io.loadImage(arena, image_path);
        defer image.deinit(arena);
        try writeImportedImage(arena, &image, output_path);
        return;
    }

    if (std.mem.eql(u8, command, "dump-interest")) {
        const image_path = args.next() orelse return error.InvalidArguments;
        const pyr_level = try parseU8(args.next() orelse return error.InvalidArguments);
        const grid_size = try parseU32(args.next() orelse return error.InvalidArguments);
        const rect_index = try parseU32(args.next() orelse return error.InvalidArguments);
        const max_points = try parseU32(args.next() orelse return error.InvalidArguments);
        if (args.next() != null) return error.InvalidArguments;

        var reduced = try loadReducedGrayImage(arena, image_path, pyr_level);
        defer reduced.deinit(arena);

        const rects = try features.buildGridRects(arena, reduced.width, reduced.height, grid_size);
        if (rect_index >= rects.len) return error.RectIndexOutOfRange;
        const points = try features.detectInterestPointsPartial(arena, &reduced, rects[rect_index], 2.0, max_points);

        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.print("rect {d}: {d} {d} {d} {d}\n", .{
            rect_index,
            rects[rect_index].x0,
            rects[rect_index].y0,
            rects[rect_index].x1,
            rects[rect_index].y1,
        });
        for (points, 0..) |point, idx| {
            try stdout.print("{d} {d} {d} {d:.9}\n", .{
                idx,
                point.x,
                point.y,
                point.score,
            });
        }
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "match-point")) {
        const left_path = args.next() orelse return error.InvalidArguments;
        const right_path = args.next() orelse return error.InvalidArguments;
        const pyr_level = try parseU8(args.next() orelse return error.InvalidArguments);
        const left_x = try parseU32(args.next() orelse return error.InvalidArguments);
        const left_y = try parseU32(args.next() orelse return error.InvalidArguments);
        const right_center_x = try parseU32(args.next() orelse return error.InvalidArguments);
        const right_center_y = try parseU32(args.next() orelse return error.InvalidArguments);
        const template_size = try parseU32(args.next() orelse return error.InvalidArguments);
        const search_width = try parseU32(args.next() orelse return error.InvalidArguments);
        if (args.next() != null) return error.InvalidArguments;

        var left = try loadReducedGrayImage(arena, left_path, pyr_level);
        defer left.deinit(arena);
        var right = try loadReducedGrayImage(arena, right_path, pyr_level);
        defer right.deinit(arena);

        const result = match_mod.probeMatchAroundCenter(
            &left,
            &right,
            left_x,
            left_y,
            right_center_x,
            right_center_y,
            template_size,
            search_width,
        );

        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.print("{d:.9} {d:.9} {d:.9}\n", .{ result.score, result.x, result.y });
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "match-rect")) {
        const left_path = args.next() orelse return error.InvalidArguments;
        const right_path = args.next() orelse return error.InvalidArguments;
        const pyr_level = try parseU8(args.next() orelse return error.InvalidArguments);
        const grid_size = try parseU32(args.next() orelse return error.InvalidArguments);
        const rect_index = try parseU32(args.next() orelse return error.InvalidArguments);
        const points_per_grid = try parseU32(args.next() orelse return error.InvalidArguments);
        const corr_threshold = try std.fmt.parseFloat(f32, args.next() orelse return error.InvalidArguments);
        if (args.next() != null) return error.InvalidArguments;

        var left = try loadReducedGrayImage(arena, left_path, pyr_level);
        defer left.deinit(arena);
        var right = try loadReducedGrayImage(arena, right_path, pyr_level);
        defer right.deinit(arena);
        var left_full = try loadReducedGrayImage(arena, left_path, 0);
        defer left_full.deinit(arena);
        var right_full = try loadReducedGrayImage(arena, right_path, 0);
        defer right_full.deinit(arena);

        const rects = try features.buildGridRects(arena, left.width, left.height, grid_size);
        if (rect_index >= rects.len) return error.RectIndexOutOfRange;
        const requested_candidates = points_per_grid * 5;
        const candidates = try features.detectInterestPointsPartial(arena, &left, rects[rect_index], 2.0, requested_candidates);

        const scale_factor_int = @as(u32, 1) << @intCast(pyr_level);
        const scale_factor = @as(f64, @floatFromInt(scale_factor_int));
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.print("rect {d}: {d} {d} {d} {d}\n", .{
            rect_index,
            rects[rect_index].x0,
            rects[rect_index].y0,
            rects[rect_index].x1,
            rects[rect_index].y1,
        });

        var accepted: u32 = 0;
        for (candidates, 0..) |candidate, idx| {
            if (accepted >= points_per_grid) break;

            const coarse = match_mod.probeMatchAroundCenter(
                &left,
                &right,
                candidate.x,
                candidate.y,
                candidate.x,
                candidate.y,
                20,
                100,
            );
            if (!match_mod.passesCorrelationThreshold(coarse.score, corr_threshold)) continue;

            var final_score = coarse.score;
            var final_x = coarse.x * scale_factor;
            var final_y = coarse.y * scale_factor;
            if (pyr_level > 0) {
                const refined = match_mod.probeMatchAroundCenter(
                    &left_full,
                    &right_full,
                    candidate.x * scale_factor_int,
                    candidate.y * scale_factor_int,
                    truncFloatToPixel(coarse.x * scale_factor, right_full.width),
                    truncFloatToPixel(coarse.y * scale_factor, right_full.height),
                    20,
                    scale_factor_int,
                );
                if (!match_mod.passesCorrelationThreshold(refined.score, corr_threshold)) continue;
                final_score = refined.score;
                final_x = refined.x;
                final_y = refined.y;
            }

            try stdout.print(
                "{d} cand={d} left={d:.3},{d:.3} coarse={d:.9},{d:.9} coarse_score={d:.9} final={d:.9},{d:.9} final_score={d:.9}\n",
                .{
                    accepted,
                    idx,
                    @as(f64, @floatFromInt(candidate.x)) * scale_factor,
                    @as(f64, @floatFromInt(candidate.y)) * scale_factor,
                    coarse.x * scale_factor,
                    coarse.y * scale_factor,
                    coarse.score,
                    final_x,
                    final_y,
                    final_score,
                },
            );
            accepted += 1;
        }
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "trace-rect")) {
        const left_path = args.next() orelse return error.InvalidArguments;
        const right_path = args.next() orelse return error.InvalidArguments;
        const pyr_level = try parseU8(args.next() orelse return error.InvalidArguments);
        const grid_size = try parseU32(args.next() orelse return error.InvalidArguments);
        const rect_index = try parseU32(args.next() orelse return error.InvalidArguments);
        const points_per_grid = try parseU32(args.next() orelse return error.InvalidArguments);
        const corr_threshold = try std.fmt.parseFloat(f32, args.next() orelse return error.InvalidArguments);
        if (args.next() != null) return error.InvalidArguments;

        var left = try loadReducedGrayImage(arena, left_path, pyr_level);
        defer left.deinit(arena);
        var right = try loadReducedGrayImage(arena, right_path, pyr_level);
        defer right.deinit(arena);
        var left_full = try loadReducedGrayImage(arena, left_path, 0);
        defer left_full.deinit(arena);
        var right_full = try loadReducedGrayImage(arena, right_path, 0);
        defer right_full.deinit(arena);

        const rects = try features.buildGridRects(arena, left.width, left.height, grid_size);
        if (rect_index >= rects.len) return error.RectIndexOutOfRange;
        const requested_candidates = points_per_grid * 5;
        const candidates = try features.detectInterestPointsPartial(arena, &left, rects[rect_index], 2.0, requested_candidates);

        const scale_factor_int = @as(u32, 1) << @intCast(pyr_level);
        const scale_factor = @as(f64, @floatFromInt(scale_factor_int));
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.print("rect {d}: {d} {d} {d} {d}\n", .{
            rect_index,
            rects[rect_index].x0,
            rects[rect_index].y0,
            rects[rect_index].x1,
            rects[rect_index].y1,
        });

        var accepted: u32 = 0;
        for (candidates, 0..) |candidate, idx| {
            const coarse = match_mod.probeMatchAroundCenter(
                &left,
                &right,
                candidate.x,
                candidate.y,
                candidate.x,
                candidate.y,
                20,
                100,
            );
            const coarse_ok = match_mod.passesCorrelationThreshold(coarse.score, corr_threshold);

            var final_score = coarse.score;
            var final_x = coarse.x * scale_factor;
            var final_y = coarse.y * scale_factor;
            var refined_ok = coarse_ok;
            if (coarse_ok and pyr_level > 0) {
                const refined = match_mod.probeMatchAroundCenter(
                    &left_full,
                    &right_full,
                    candidate.x * scale_factor_int,
                    candidate.y * scale_factor_int,
                    truncFloatToPixel(coarse.x * scale_factor, right_full.width),
                    truncFloatToPixel(coarse.y * scale_factor, right_full.height),
                    20,
                    scale_factor_int,
                );
                final_score = refined.score;
                final_x = refined.x;
                final_y = refined.y;
                refined_ok = match_mod.passesCorrelationThreshold(refined.score, corr_threshold);
            }

            const accepted_now = coarse_ok and refined_ok and accepted < points_per_grid;
            try stdout.print(
                "cand={d} left={d},{d} coarse={d:.9},{d:.9} coarse_score={d:.9} final={d:.9},{d:.9} final_score={d:.9} coarse_ok={d} refined_ok={d} accepted={d}\n",
                .{
                    idx,
                    candidate.x * scale_factor_int,
                    candidate.y * scale_factor_int,
                    coarse.x * scale_factor,
                    coarse.y * scale_factor,
                    coarse.score,
                    final_x,
                    final_y,
                    final_score,
                    @intFromBool(coarse_ok),
                    @intFromBool(refined_ok),
                    @intFromBool(accepted_now),
                },
            );
            if (accepted_now) accepted += 1;
        }
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "count-grid")) {
        const left_path = args.next() orelse return error.InvalidArguments;
        const right_path = args.next() orelse return error.InvalidArguments;
        const pyr_level = try parseU8(args.next() orelse return error.InvalidArguments);
        const grid_size = try parseU32(args.next() orelse return error.InvalidArguments);
        const points_per_grid = try parseU32(args.next() orelse return error.InvalidArguments);
        const corr_threshold = try std.fmt.parseFloat(f32, args.next() orelse return error.InvalidArguments);
        if (args.next() != null) return error.InvalidArguments;

        var left = try loadReducedGrayImage(arena, left_path, pyr_level);
        defer left.deinit(arena);
        var right = try loadReducedGrayImage(arena, right_path, pyr_level);
        defer right.deinit(arena);
        var left_full = try loadReducedGrayImage(arena, left_path, 0);
        defer left_full.deinit(arena);
        var right_full = try loadReducedGrayImage(arena, right_path, 0);
        defer right_full.deinit(arena);

        const rects = try features.buildGridRects(arena, left.width, left.height, grid_size);
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        var total: u32 = 0;

        for (rects, 0..) |rect, rect_index| {
            const accepted = try countAcceptedInRect(
                arena,
                &left,
                &right,
                &left_full,
                &right_full,
                rect,
                pyr_level,
                points_per_grid,
                corr_threshold,
            );
            total += accepted;
            try stdout.print("rect {d} count={d}\n", .{ rect_index, accepted });
        }
        try stdout.print("total={d}\n", .{total});
        try stdout.flush();
        return;
    }

    try usage();
    return error.InvalidArguments;
}

fn usage() !void {
    try std.fs.File.stderr().writeAll(
        \\usage:
        \\  match_probe dump-reduced-pgm <image> <pyr_level> <output.pgm>
        \\  match_probe dump-import-ppm <image> <output.ppm>
        \\  match_probe dump-interest <image> <pyr_level> <grid_size> <rect_index> <max_points>
        \\  match_probe match-point <left> <right> <pyr_level> <left_x> <left_y> <right_center_x> <right_center_y> <template_size> <search_width>
        \\  match_probe match-rect <left> <right> <pyr_level> <grid_size> <rect_index> <points_per_grid> <corr_threshold>
        \\  match_probe trace-rect <left> <right> <pyr_level> <grid_size> <rect_index> <points_per_grid> <corr_threshold>
        \\  match_probe count-grid <left> <right> <pyr_level> <grid_size> <points_per_grid> <corr_threshold>
        \\
    );
}

fn parseU8(value: []const u8) !u8 {
    return std.fmt.parseInt(u8, value, 10);
}

fn parseU32(value: []const u8) !u32 {
    return std.fmt.parseInt(u32, value, 10);
}

fn loadReducedGrayImage(
    allocator: std.mem.Allocator,
    path: []const u8,
    pyr_level: u8,
) !gray.GrayImage {
    var decoded = try loadProbeImage(allocator, path);
    defer decoded.deinit(allocator);
    return gray.fromLoadedReducedLikeHugin(allocator, &decoded, pyr_level);
}

fn loadProbeImage(allocator: std.mem.Allocator, path: []const u8) !image_io.Image {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".pgm") or std.mem.eql(u8, ext, ".ppm")) {
        return loadPortablePixmap(allocator, path);
    }
    return image_io.loadImage(allocator, path);
}

fn loadPortablePixmap(allocator: std.mem.Allocator, path: []const u8) !image_io.Image {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 30);
    errdefer allocator.free(data);

    var index: usize = 0;
    const magic = try nextPnmToken(data, &index);
    const width_token = try nextPnmToken(data, &index);
    const height_token = try nextPnmToken(data, &index);
    const max_token = try nextPnmToken(data, &index);

    const width = try std.fmt.parseInt(u32, width_token, 10);
    const height = try std.fmt.parseInt(u32, height_token, 10);
    const max_value = try std.fmt.parseInt(u32, max_token, 10);
    if (max_value != 255) return error.InvalidArguments;

    while (index < data.len and std.ascii.isWhitespace(data[index])) : (index += 1) {}

    const color_model: image_io.ColorModel = if (std.mem.eql(u8, magic, "P6")) .rgb else if (std.mem.eql(u8, magic, "P5")) .grayscale else return error.InvalidArguments;
    const channels: usize = if (color_model == .rgb) 3 else 1;
    const pixel_bytes = @as(usize, width) * @as(usize, height) * channels;
    if (index + pixel_bytes > data.len) return error.InvalidArguments;

    const pixels = try allocator.dupe(u8, data[index .. index + pixel_bytes]);
    allocator.free(data);

    return .{
        .info = .{
            .format = .png,
            .width = width,
            .height = height,
            .color_model = color_model,
            .sample_type = .u8,
            .color_channels = @as(u8, @intCast(channels)),
            .extra_channels = 0,
            .exposure_value = null,
        },
        .pixels = .{ .u8 = pixels },
    };
}

fn nextPnmToken(data: []const u8, index: *usize) ![]const u8 {
    while (index.* < data.len) {
        if (std.ascii.isWhitespace(data[index.*])) {
            index.* += 1;
            continue;
        }
        if (data[index.*] == '#') {
            while (index.* < data.len and data[index.*] != '\n') : (index.* += 1) {}
            continue;
        }
        break;
    }
    if (index.* >= data.len) return error.InvalidArguments;
    const start = index.*;
    while (index.* < data.len and !std.ascii.isWhitespace(data[index.*]) and data[index.*] != '#') : (index.* += 1) {}
    return data[start..index.*];
}

fn writePgm(
    allocator: std.mem.Allocator,
    image: *const gray.GrayImage,
    output_path: []const u8,
) !void {
    const header = try std.fmt.allocPrint(allocator, "P5\n{d} {d}\n255\n", .{ image.width, image.height });
    defer allocator.free(header);

    const pixels = try allocator.alloc(u8, @as(usize, image.width) * @as(usize, image.height));
    defer allocator.free(pixels);

    for (pixels, image.pixels) |*dst, src| {
        const clamped = @max(@as(f32, 0), @min(@as(f32, 1), src));
        dst.* = @as(u8, @intFromFloat(@round(clamped * 255.0)));
    }

    const file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(header);
    try file.writeAll(pixels);
}

fn writeImportedImage(
    allocator: std.mem.Allocator,
    image: *const image_io.Image,
    output_path: []const u8,
) !void {
    const count = @as(usize, image.info.width) * @as(usize, image.info.height);
    const file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer file.close();

    switch (image.info.color_model) {
        .grayscale => {
            const header = try std.fmt.allocPrint(allocator, "P5\n{d} {d}\n255\n", .{ image.info.width, image.info.height });
            defer allocator.free(header);
            try file.writeAll(header);

            switch (image.pixels) {
                .u8 => |pixels| try file.writeAll(pixels[0..count]),
                .u16 => |pixels| {
                    const out = try allocator.alloc(u8, count);
                    defer allocator.free(out);
                    for (out, pixels[0..count]) |*dst, src| {
                        dst.* = @as(u8, @intCast(src >> 8));
                    }
                    try file.writeAll(out);
                },
            }
        },
        .rgb => {
            const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ image.info.width, image.info.height });
            defer allocator.free(header);
            try file.writeAll(header);

            switch (image.pixels) {
                .u8 => |pixels| try file.writeAll(pixels[0 .. count * 3]),
                .u16 => |pixels| {
                    const out = try allocator.alloc(u8, count * 3);
                    defer allocator.free(out);
                    for (out, pixels[0 .. count * 3]) |*dst, src| {
                        dst.* = @as(u8, @intCast(src >> 8));
                    }
                    try file.writeAll(out);
                },
            }
        },
    }
}

fn truncFloatToPixel(value: f64, limit: u32) u32 {
    if (value <= 0) return 0;
    const rounded = @as(i64, @intFromFloat(value));
    const max_value = @as(i64, limit - 1);
    return @as(u32, @intCast(@min(max_value, @max(@as(i64, 0), rounded))));
}

fn countAcceptedInRect(
    allocator: std.mem.Allocator,
    left: *const gray.GrayImage,
    right: *const gray.GrayImage,
    left_full: *const gray.GrayImage,
    right_full: *const gray.GrayImage,
    rect: features.Rect,
    pyr_level: u8,
    points_per_grid: u32,
    corr_threshold: f32,
) !u32 {
    const requested_candidates = points_per_grid * 5;
    const candidates = try features.detectInterestPointsPartial(allocator, left, rect, 2.0, requested_candidates);
    const scale_factor_int = @as(u32, 1) << @intCast(pyr_level);
    const scale_factor = @as(f64, @floatFromInt(scale_factor_int));

    var accepted: u32 = 0;
    for (candidates) |candidate| {
        if (accepted >= points_per_grid) break;

        const coarse = match_mod.probeMatchAroundCenter(
            left,
            right,
            candidate.x,
            candidate.y,
            candidate.x,
            candidate.y,
            20,
            100,
        );
        if (!match_mod.passesCorrelationThreshold(coarse.score, corr_threshold)) continue;

        if (pyr_level > 0) {
            const refined = match_mod.probeMatchAroundCenter(
                left_full,
                right_full,
                candidate.x * scale_factor_int,
                candidate.y * scale_factor_int,
                truncFloatToPixel(coarse.x * scale_factor, right_full.width),
                truncFloatToPixel(coarse.y * scale_factor, right_full.height),
                20,
                scale_factor_int,
            );
            if (!match_mod.passesCorrelationThreshold(refined.score, corr_threshold)) continue;
        }

        accepted += 1;
    }
    return accepted;
}
