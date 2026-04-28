const std = @import("std");
const features = @import("features.zig");
const gray = @import("gray.zig");
const sequence = @import("sequence.zig");

pub const PairOptions = struct {
    points_per_grid: u32,
    grid_size: u32,
    corr_threshold: f32,
    pyr_level: u8,
    template_radius: u32 = 5,
    search_radius: u32 = 18,
    full_res_template_radius: u32 = 10,
};

pub const ControlPoint = struct {
    left_image: usize,
    right_image: usize,
    left_x: f32,
    left_y: f32,
    right_x: f32,
    right_y: f32,
    score: f32,
    coarse_right_x: f32,
    coarse_right_y: f32,
    coarse_score: f32,
    refined_score: ?f32 = null,
};

pub const PairMatches = struct {
    pair: sequence.MatchPair,
    image_width: u32,
    image_height: u32,
    candidates_considered: usize,
    coarse_control_point_count: usize = 0,
    coarse_mean_score: ?f32 = null,
    coarse_best_score: ?f32 = null,
    refined_control_point_count: usize = 0,
    control_point_storage: []ControlPoint,
    control_points: []ControlPoint,

    pub fn deinit(self: *PairMatches, allocator: std.mem.Allocator) void {
        allocator.free(self.control_point_storage);
    }

    pub fn strongestScore(self: *const PairMatches) ?f32 {
        if (self.control_points.len == 0) return null;
        var best = self.control_points[0].score;
        for (self.control_points[1..]) |cp| {
            best = @max(best, cp.score);
        }
        return best;
    }

    pub fn meanScore(self: *const PairMatches) ?f32 {
        if (self.control_points.len == 0) return null;
        var sum: f64 = 0;
        for (self.control_points) |cp| {
            sum += cp.score;
        }
        return @as(f32, @floatCast(sum / @as(f64, @floatFromInt(self.control_points.len))));
    }

    pub fn strongestCoarseScore(self: *const PairMatches) ?f32 {
        return self.coarse_best_score;
    }

    pub fn meanCoarseScore(self: *const PairMatches) ?f32 {
        return self.coarse_mean_score;
    }
};

pub fn analyzePair(
    allocator: std.mem.Allocator,
    opts: PairOptions,
    pair: sequence.MatchPair,
    left: *const gray.GrayImage,
    right: *const gray.GrayImage,
) std.mem.Allocator.Error!PairMatches {
    const rects = try features.buildGridRects(allocator, left.width, left.height, opts.grid_size);
    defer allocator.free(rects);

    var control_points: std.ArrayList(ControlPoint) = .empty;
    defer control_points.deinit(allocator);

    var candidates_considered: usize = 0;
    const requested_candidates = opts.points_per_grid * 5;
    const scale_factor = @as(f32, @floatFromInt(@as(u32, 1) << @intCast(opts.pyr_level)));

    for (rects) |rect| {
        const candidates = try features.detectInterestPointsPartial(allocator, left, rect, requested_candidates);
        defer allocator.free(candidates);

        var accepted_in_rect: u32 = 0;
        for (candidates) |candidate| {
            candidates_considered += 1;
            const result = matchCandidate(left, right, candidate, opts);
            if (result.score < opts.corr_threshold) {
                continue;
            }

            try control_points.append(allocator, .{
                .left_image = pair.left_index,
                .right_image = pair.right_index,
                .left_x = @as(f32, @floatFromInt(candidate.x)) * scale_factor,
                .left_y = @as(f32, @floatFromInt(candidate.y)) * scale_factor,
                .right_x = result.x * scale_factor,
                .right_y = result.y * scale_factor,
                .score = result.score,
                .coarse_right_x = result.x * scale_factor,
                .coarse_right_y = result.y * scale_factor,
                .coarse_score = result.score,
            });
            accepted_in_rect += 1;
            if (accepted_in_rect >= opts.points_per_grid) {
                break;
            }
        }
    }

    const coarse_control_point_count = control_points.items.len;
    const coarse_mean_score = computeMeanCoarseScore(control_points.items);
    const coarse_best_score = computeBestCoarseScore(control_points.items);
    const owned = try control_points.toOwnedSlice(allocator);

    return .{
        .pair = pair,
        .image_width = left.width << @intCast(opts.pyr_level),
        .image_height = left.height << @intCast(opts.pyr_level),
        .candidates_considered = candidates_considered,
        .coarse_control_point_count = coarse_control_point_count,
        .coarse_mean_score = coarse_mean_score,
        .coarse_best_score = coarse_best_score,
        .control_point_storage = owned,
        .control_points = owned,
    };
}

pub fn refinePairMatches(
    opts: PairOptions,
    pair_matches: *PairMatches,
    left_full: *const gray.GrayImage,
    right_full: *const gray.GrayImage,
) void {
    if (opts.pyr_level == 0 or pair_matches.control_points.len == 0) {
        pair_matches.refined_control_point_count = pair_matches.control_points.len;
        for (pair_matches.control_points) |*cp| {
            cp.refined_score = cp.score;
        }
        return;
    }

    const scale_factor = @as(u32, 1) << @intCast(opts.pyr_level);
    const full_res_search_radius = @max(scale_factor, 2);

    var write_index: usize = 0;
    for (pair_matches.control_points, 0..) |cp, read_index| {
        const left_x = floatCenterToPixel(cp.left_x, left_full.width);
        const left_y = floatCenterToPixel(cp.left_y, left_full.height);
        const right_x = floatCenterToPixel(cp.coarse_right_x, right_full.width);
        const right_y = floatCenterToPixel(cp.coarse_right_y, right_full.height);

        const refined = matchAroundCenter(
            left_full,
            right_full,
            left_x,
            left_y,
            right_x,
            right_y,
            opts.full_res_template_radius,
            full_res_search_radius,
        );
        if (refined.score < opts.corr_threshold) {
            continue;
        }

        var updated = cp;
        updated.right_x = refined.x;
        updated.right_y = refined.y;
        updated.score = refined.score;
        updated.refined_score = refined.score;

        if (write_index != read_index) {
            pair_matches.control_points[write_index] = updated;
        } else {
            pair_matches.control_points[read_index] = updated;
        }
        write_index += 1;
    }

    pair_matches.control_points.len = write_index;
    pair_matches.refined_control_point_count = write_index;
}

pub fn renderSummary(
    allocator: std.mem.Allocator,
    pair_matches: []const PairMatches,
    images: []const sequence.InputImage,
) std.mem.Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    const writer = list.writer(allocator);
    try writer.writeAll("control-point matching:\n");
    for (pair_matches) |entry| {
        try writer.print(
            "  [{d}] {s} -> [{d}] {s}\n",
            .{
                entry.pair.left_index,
                images[entry.pair.left_index].path,
                entry.pair.right_index,
                images[entry.pair.right_index].path,
            },
        );
        try writer.print("    candidates considered: {d}\n", .{entry.candidates_considered});
        try writer.print("    coarse control points: {d}\n", .{entry.coarse_control_point_count});
        if (entry.meanCoarseScore()) |mean_score| {
            try writer.print("    coarse mean score: {d:.4}\n", .{mean_score});
        }
        if (entry.strongestCoarseScore()) |best_score| {
            try writer.print("    coarse best score: {d:.4}\n", .{best_score});
        }
        if (entry.refined_control_point_count > 0 or entry.coarse_control_point_count > 0) {
            try writer.print("    refined control points: {d}\n", .{entry.refined_control_point_count});
        }
        if (entry.meanScore()) |mean_score| {
            try writer.print("    refined mean score: {d:.4}\n", .{mean_score});
        }
        if (entry.strongestScore()) |best_score| {
            try writer.print("    refined best score: {d:.4}\n", .{best_score});
        }
    }

    return list.toOwnedSlice(allocator);
}

const MatchResult = struct {
    score: f32 = -1,
    x: f32 = 0,
    y: f32 = 0,
};

fn matchCandidate(
    left: *const gray.GrayImage,
    right: *const gray.GrayImage,
    candidate: features.InterestPoint,
    opts: PairOptions,
) MatchResult {
    return matchAroundCenter(
        left,
        right,
        candidate.x,
        candidate.y,
        candidate.x,
        candidate.y,
        opts.template_radius,
        opts.search_radius,
    );
}

const ClampDirection = enum { min, max };

fn matchAroundCenter(
    left: *const gray.GrayImage,
    right: *const gray.GrayImage,
    left_x: u32,
    left_y: u32,
    right_center_x: u32,
    right_center_y: u32,
    radius: u32,
    search_radius: u32,
) MatchResult {
    if (!isPatchInside(left, left_x, left_y, radius)) {
        return .{};
    }

    const min_x = clampCenter(right_center_x, radius, right.width, search_radius, .min);
    const max_x = clampCenter(right_center_x, radius, right.width, search_radius, .max);
    const min_y = clampCenter(right_center_y, radius, right.height, search_radius, .min);
    const max_y = clampCenter(right_center_y, radius, right.height, search_radius, .max);

    if (min_x > max_x or min_y > max_y) {
        return .{};
    }

    var best_x: u32 = min_x;
    var best_y: u32 = min_y;
    var best_score: f32 = -1;

    const coarse_step: u32 = if (search_radius > 6) 2 else 1;
    var cy = min_y;
    while (cy <= max_y) : (cy += coarse_step) {
        var cx = min_x;
        while (cx <= max_x) : (cx += coarse_step) {
            const score = evaluateNcc(left, right, left_x, left_y, cx, cy, radius);
            if (score > best_score) {
                best_score = score;
                best_x = cx;
                best_y = cy;
            }

            if (coarse_step > 1 and cx + coarse_step > max_x and cx != max_x) {
                cx = max_x - coarse_step;
            }
        }
        if (coarse_step > 1 and cy + coarse_step > max_y and cy != max_y) {
            cy = max_y - coarse_step;
        }
    }

    const refine_start_x = best_x -| coarse_step;
    const refine_end_x = @min(best_x + coarse_step, max_x);
    const refine_start_y = best_y -| coarse_step;
    const refine_end_y = @min(best_y + coarse_step, max_y);

    var ry = refine_start_y;
    while (ry <= refine_end_y) : (ry += 1) {
        var rx = refine_start_x;
        while (rx <= refine_end_x) : (rx += 1) {
            const score = evaluateNcc(left, right, left_x, left_y, rx, ry, radius);
            if (score > best_score) {
                best_score = score;
                best_x = rx;
                best_y = ry;
            }
        }
    }

    var refined_x = @as(f32, @floatFromInt(best_x));
    var refined_y = @as(f32, @floatFromInt(best_y));

    if (best_x > min_x and best_x < max_x) {
        const score_left = evaluateNcc(left, right, left_x, left_y, best_x - 1, best_y, radius);
        const score_center = best_score;
        const score_right = evaluateNcc(left, right, left_x, left_y, best_x + 1, best_y, radius);
        refined_x += refineParabola(score_left, score_center, score_right);
    }
    if (best_y > min_y and best_y < max_y) {
        const score_up = evaluateNcc(left, right, left_x, left_y, best_x, best_y - 1, radius);
        const score_center = best_score;
        const score_down = evaluateNcc(left, right, left_x, left_y, best_x, best_y + 1, radius);
        refined_y += refineParabola(score_up, score_center, score_down);
    }

    return .{
        .score = best_score,
        .x = refined_x,
        .y = refined_y,
    };
}

fn clampCenter(
    center: u32,
    radius: u32,
    limit: u32,
    search_radius: u32,
    direction: ClampDirection,
) u32 {
    const minimum = radius;
    const maximum = limit - radius - 1;
    return switch (direction) {
        .min => @max(minimum, center -| search_radius),
        .max => @min(maximum, center + search_radius),
    };
}

fn isPatchInside(image: *const gray.GrayImage, x: u32, y: u32, radius: u32) bool {
    return x >= radius and y >= radius and x + radius < image.width and y + radius < image.height;
}

fn floatCenterToPixel(value: f32, limit: u32) u32 {
    if (value <= 0) return 0;
    const rounded = @as(i64, @intFromFloat(@round(value)));
    const max_value = @as(i64, limit - 1);
    return @as(u32, @intCast(@min(max_value, @max(@as(i64, 0), rounded))));
}

fn computeMeanCoarseScore(points: []const ControlPoint) ?f32 {
    if (points.len == 0) return null;
    var sum: f64 = 0;
    for (points) |cp| {
        sum += cp.coarse_score;
    }
    return @as(f32, @floatCast(sum / @as(f64, @floatFromInt(points.len))));
}

fn computeBestCoarseScore(points: []const ControlPoint) ?f32 {
    if (points.len == 0) return null;
    var best = points[0].coarse_score;
    for (points[1..]) |cp| {
        best = @max(best, cp.coarse_score);
    }
    return best;
}

fn evaluateNcc(
    left: *const gray.GrayImage,
    right: *const gray.GrayImage,
    left_x: u32,
    left_y: u32,
    right_x: u32,
    right_y: u32,
    radius: u32,
) f32 {
    const x0_left = left_x - radius;
    const y0_left = left_y - radius;
    const x0_right = right_x - radius;
    const y0_right = right_y - radius;
    const diameter = radius * 2 + 1;
    const count = @as(f64, @floatFromInt(diameter * diameter));

    var mean_left: f64 = 0;
    var mean_right: f64 = 0;
    var dy: u32 = 0;
    while (dy < diameter) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < diameter) : (dx += 1) {
            mean_left += left.pixel(x0_left + dx, y0_left + dy);
            mean_right += right.pixel(x0_right + dx, y0_right + dy);
        }
    }
    mean_left /= count;
    mean_right /= count;

    var numerator: f64 = 0;
    var div_left: f64 = 0;
    var div_right: f64 = 0;
    dy = 0;
    while (dy < diameter) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < diameter) : (dx += 1) {
            const left_value = @as(f64, left.pixel(x0_left + dx, y0_left + dy)) - mean_left;
            const right_value = @as(f64, right.pixel(x0_right + dx, y0_right + dy)) - mean_right;
            numerator += left_value * right_value;
            div_left += left_value * left_value;
            div_right += right_value * right_value;
        }
    }

    if (div_left == 0 or div_right == 0) {
        return -1;
    }
    return @as(f32, @floatCast(numerator / @sqrt(div_left * div_right)));
}

fn refineParabola(left: f32, center: f32, right: f32) f32 {
    const denominator = left - 2 * center + right;
    if (@abs(denominator) < 1e-6) {
        return 0;
    }
    const offset = 0.5 * (left - right) / denominator;
    if (@abs(offset) > 1.0) {
        return 0;
    }
    return offset;
}

test "pair matching recovers a small translation" {
    const allocator = std.testing.allocator;

    const left_pixels = try allocator.alloc(f32, 48 * 48);
    defer allocator.free(left_pixels);
    @memset(left_pixels, 0);

    for (14..30) |y| {
        for (12..20) |x| {
            left_pixels[y * 48 + x] = 1.0;
        }
    }
    for (22..30) |y| {
        for (12..28) |x| {
            left_pixels[y * 48 + x] = 1.0;
        }
    }
    for (8..14) |y| {
        for (26..32) |x| {
            left_pixels[y * 48 + x] = 0.6;
        }
    }

    const right_pixels = try allocator.alloc(f32, 48 * 48);
    defer allocator.free(right_pixels);
    @memset(right_pixels, 0);

    const shift_x: usize = 3;
    const shift_y: usize = 2;
    for (0..46) |y| {
        for (0..45) |x| {
            right_pixels[(y + shift_y) * 48 + (x + shift_x)] = left_pixels[y * 48 + x];
        }
    }

    var left = gray.GrayImage{
        .width = 48,
        .height = 48,
        .pixels = left_pixels,
    };
    var right = gray.GrayImage{
        .width = 48,
        .height = 48,
        .pixels = right_pixels,
    };

    var matches = try analyzePair(allocator, .{
        .points_per_grid = 4,
        .grid_size = 1,
        .corr_threshold = 0.8,
        .pyr_level = 0,
        .template_radius = 3,
        .search_radius = 6,
    }, .{
        .left_index = 0,
        .right_index = 1,
    }, &left, &right);
    defer matches.deinit(allocator);

    try std.testing.expect(matches.control_points.len > 0);

    var found = false;
    for (matches.control_points) |cp| {
        if (@abs((cp.right_x - cp.left_x) - 3.0) < 0.5 and @abs((cp.right_y - cp.left_y) - 2.0) < 0.5) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "full-resolution refinement can prune and tighten coarse matches" {
    const allocator = std.testing.allocator;

    const full_width = 64;
    const full_height = 64;
    const left_pixels = try allocator.alloc(f32, full_width * full_height);
    defer allocator.free(left_pixels);
    @memset(left_pixels, 0);

    for (12..30) |y| {
        for (10..18) |x| {
            left_pixels[y * full_width + x] = 1.0;
        }
    }
    for (24..32) |y| {
        for (10..28) |x| {
            left_pixels[y * full_width + x] = 1.0;
        }
    }
    for (8..16) |y| {
        for (30..36) |x| {
            left_pixels[y * full_width + x] = 0.5;
        }
    }

    const right_pixels = try allocator.alloc(f32, full_width * full_height);
    defer allocator.free(right_pixels);
    @memset(right_pixels, 0);

    const shift_x: usize = 4;
    const shift_y: usize = 2;
    for (0..(full_height - shift_y)) |y| {
        for (0..(full_width - shift_x)) |x| {
            right_pixels[(y + shift_y) * full_width + (x + shift_x)] = left_pixels[y * full_width + x];
        }
    }

    var left_full = gray.GrayImage{
        .width = full_width,
        .height = full_height,
        .pixels = left_pixels,
    };
    var right_full = gray.GrayImage{
        .width = full_width,
        .height = full_height,
        .pixels = right_pixels,
    };

    var left_reduced = try gray.reduceNTimes(allocator, &left_full, 1);
    defer left_reduced.deinit(allocator);
    var right_reduced = try gray.reduceNTimes(allocator, &right_full, 1);
    defer right_reduced.deinit(allocator);

    var matches = try analyzePair(allocator, .{
        .points_per_grid = 4,
        .grid_size = 1,
        .corr_threshold = 0.8,
        .pyr_level = 1,
        .template_radius = 3,
        .search_radius = 6,
        .full_res_template_radius = 5,
    }, .{
        .left_index = 0,
        .right_index = 1,
    }, &left_reduced, &right_reduced);
    defer matches.deinit(allocator);

    try std.testing.expect(matches.control_points.len > 0);

    refinePairMatches(.{
        .points_per_grid = 4,
        .grid_size = 1,
        .corr_threshold = 0.8,
        .pyr_level = 1,
        .template_radius = 3,
        .search_radius = 6,
        .full_res_template_radius = 5,
    }, &matches, &left_full, &right_full);

    try std.testing.expect(matches.refined_control_point_count > 0);

    var found = false;
    for (matches.control_points) |cp| {
        if (@abs((cp.right_x - cp.left_x) - 4.0) < 0.5 and @abs((cp.right_y - cp.left_y) - 2.0) < 0.5) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
