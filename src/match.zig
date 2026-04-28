const std = @import("std");
const features = @import("features.zig");
const gray = @import("gray.zig");
const sequence = @import("sequence.zig");

pub const PairOptions = struct {
    points_per_grid: u32,
    grid_size: u32,
    corr_threshold: f32,
    pyr_level: u8,
    verbose: u8 = 0,
    template_size: u32 = 20,
    search_width: u32 = 100,
    full_res_template_size: u32 = 20,
};

pub const ControlPoint = struct {
    left_image: usize,
    right_image: usize,
    left_x: f64,
    left_y: f64,
    right_x: f64,
    right_y: f64,
    score: f32,
    coarse_right_x: f64,
    coarse_right_y: f64,
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
    left_full: *const gray.GrayImage,
    right: *const gray.GrayImage,
    right_full: *const gray.GrayImage,
) std.mem.Allocator.Error!PairMatches {
    const rects = try features.buildGridRects(allocator, left.width, left.height, opts.grid_size);
    defer allocator.free(rects);

    var control_points: std.ArrayList(ControlPoint) = .empty;
    defer control_points.deinit(allocator);

    var candidates_considered: usize = 0;
    const requested_candidates = opts.points_per_grid * 5;
    const scale_factor = @as(f32, @floatFromInt(@as(u32, 1) << @intCast(opts.pyr_level)));
    const scale_factor_int = @as(u32, 1) << @intCast(opts.pyr_level);
    const full_res_search_width = @max(scale_factor_int, 1);
    var coarse_control_point_count: usize = 0;
    var coarse_score_sum: f64 = 0;
    var coarse_best_score: ?f32 = null;

    if (opts.verbose > 0) {
        std.debug.print("Trying to find {d} corners... \n", .{opts.points_per_grid});
    }

    for (rects) |rect| {
        const candidates = try features.detectInterestPointsPartial(allocator, left, rect, 2.0, requested_candidates);
        defer allocator.free(candidates);

        var accepted_in_rect: u32 = 0;
        for (candidates) |candidate| {
            candidates_considered += 1;
            const result = matchCandidate(left, right, candidate, opts);
            if (result.score < opts.corr_threshold) {
                continue;
            }

            coarse_control_point_count += 1;
            coarse_score_sum += result.score;
            coarse_best_score = if (coarse_best_score) |best|
                @max(best, result.score)
            else
                result.score;

            const left_x = @as(f32, @floatFromInt(candidate.x)) * scale_factor;
            const left_y = @as(f32, @floatFromInt(candidate.y)) * scale_factor;

            var final_right_x = result.x * scale_factor;
            var final_right_y = result.y * scale_factor;
            var final_score = result.score;

            if (opts.pyr_level > 0) {
                const refined = matchAroundCenter(
                    left_full,
                    right_full,
                    candidate.x * scale_factor_int,
                    candidate.y * scale_factor_int,
                    roundFloatToPixel(result.x * scale_factor, right_full.width),
                    roundFloatToPixel(result.y * scale_factor, right_full.height),
                    opts.full_res_template_size,
                    full_res_search_width,
                );
                if (refined.score < opts.corr_threshold) {
                    continue;
                }
                final_right_x = refined.x;
                final_right_y = refined.y;
                final_score = refined.score;
            }

            try control_points.append(allocator, .{
                .left_image = pair.left_index,
                .right_image = pair.right_index,
                .left_x = left_x,
                .left_y = left_y,
                .right_x = final_right_x,
                .right_y = final_right_y,
                .score = final_score,
                .coarse_right_x = result.x * scale_factor,
                .coarse_right_y = result.y * scale_factor,
                .coarse_score = result.score,
                .refined_score = final_score,
            });
            accepted_in_rect += 1;
            if (accepted_in_rect >= opts.points_per_grid) {
                break;
            }
        }

        if (opts.verbose > 0) {
            std.debug.print(
                "Number of good matches: {d}, bad matches: {d}\n",
                .{ accepted_in_rect, candidates.len - accepted_in_rect },
            );
        }
    }

    const coarse_mean_score = if (coarse_control_point_count == 0)
        null
    else
        @as(f32, @floatCast(coarse_score_sum / @as(f64, @floatFromInt(coarse_control_point_count))));
    const owned = try control_points.toOwnedSlice(allocator);

    return .{
        .pair = pair,
        .image_width = left.width << @intCast(opts.pyr_level),
        .image_height = left.height << @intCast(opts.pyr_level),
        .candidates_considered = candidates_considered,
        .coarse_control_point_count = coarse_control_point_count,
        .coarse_mean_score = coarse_mean_score,
        .coarse_best_score = coarse_best_score,
        .refined_control_point_count = owned.len,
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

    pair_matches.refined_control_point_count = pair_matches.control_points.len;
    _ = left_full;
    _ = right_full;
    return;
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

pub const MatchResult = struct {
    score: f32 = -1,
    x: f64 = 0,
    y: f64 = 0,
};

pub fn probeMatchAroundCenter(
    left: *const gray.GrayImage,
    right: *const gray.GrayImage,
    left_x: u32,
    left_y: u32,
    right_center_x: u32,
    right_center_y: u32,
    template_size: u32,
    search_width: u32,
) MatchResult {
    return matchAroundCenter(
        left,
        right,
        left_x,
        left_y,
        right_center_x,
        right_center_y,
        template_size,
        search_width,
    );
}

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
        opts.template_size,
        opts.search_width,
    );
}

fn matchAroundCenter(
    left: *const gray.GrayImage,
    right: *const gray.GrayImage,
    left_x: u32,
    left_y: u32,
    right_center_x: u32,
    right_center_y: u32,
    template_size: u32,
    search_width: u32,
) MatchResult {
    const templ_half = @as(i32, @intCast(template_size / 2));
    const templ_pos_x = @as(i32, @intCast(left_x));
    const templ_pos_y = @as(i32, @intCast(left_y));

    var tmpl_ul_x = templ_pos_x - templ_half;
    var tmpl_ul_y = templ_pos_y - templ_half;
    var tmpl_lr_x = templ_pos_x + templ_half + 1;
    var tmpl_lr_y = templ_pos_y + templ_half + 1;
    clipBounds(&tmpl_ul_x, &tmpl_lr_x, @as(i32, @intCast(left.width)));
    clipBounds(&tmpl_ul_y, &tmpl_lr_y, @as(i32, @intCast(left.height)));

    if (tmpl_ul_x >= tmpl_lr_x or tmpl_ul_y >= tmpl_lr_y) {
        return .{};
    }

    const kul_x = tmpl_ul_x - templ_pos_x;
    const kul_y = tmpl_ul_y - templ_pos_y;
    const klr_x = tmpl_lr_x - templ_pos_x - 1;
    const klr_y = tmpl_lr_y - templ_pos_y - 1;

    const swidth = @as(i32, @intCast(search_width / 2)) + (2 + templ_half);
    const search_pos_x = clipCoord(@as(i32, @intCast(right_center_x)), @as(i32, @intCast(right.width)));
    const search_pos_y = clipCoord(@as(i32, @intCast(right_center_y)), @as(i32, @intCast(right.height)));

    var search_ul_x = search_pos_x - swidth;
    var search_ul_y = search_pos_y - swidth;
    var search_lr_x = search_pos_x + swidth + 1;
    var search_lr_y = search_pos_y + swidth + 1;
    clipBounds(&search_ul_x, &search_lr_x, @as(i32, @intCast(right.width)));
    clipBounds(&search_ul_y, &search_lr_y, @as(i32, @intCast(right.height)));

    const search_w = search_lr_x - search_ul_x;
    const search_h = search_lr_y - search_ul_y;
    if (search_w <= 0 or search_h <= 0) {
        return .{};
    }

    const xstart = -kul_x;
    const xend = search_w - klr_x;
    const ystart = -kul_y;
    const yend = search_h - klr_y;
    if (xstart >= xend or ystart >= yend) {
        return .{};
    }

    var best_x = xstart;
    var best_y = ystart;
    var best_score: f32 = -1;

    var y = ystart;
    while (y < yend) : (y += 1) {
        var x = xstart;
        while (x < xend) : (x += 1) {
            const score = evaluateNccWindow(left, right, .{
                .tmpl_ul_x = tmpl_ul_x,
                .tmpl_ul_y = tmpl_ul_y,
                .tmpl_lr_x = tmpl_lr_x,
                .tmpl_lr_y = tmpl_lr_y,
                .kul_x = kul_x,
                .kul_y = kul_y,
                .search_ul_x = search_ul_x,
                .search_ul_y = search_ul_y,
                .center_local_x = x,
                .center_local_y = y,
            });
            if (score > best_score) {
                best_score = score;
                best_x = x;
                best_y = y;
            }
        }
    }

    if (best_score < 0) return .{};

    var refined_x = @as(f64, @floatFromInt(best_x + search_ul_x));
    var refined_y = @as(f64, @floatFromInt(best_y + search_ul_y));
    var final_score = best_score;

    const subpixel_lower_bound = 2 + templ_half;
    const subpixel_upper_bound = 2 * swidth + 1 - 2 - templ_half;
    const has_neighbor_x = best_x > xstart and best_x + 1 < xend;
    const has_neighbor_y = best_y > ystart and best_y + 1 < yend;
    if (best_x > subpixel_lower_bound and best_x < subpixel_upper_bound and
        best_y > subpixel_lower_bound and best_y < subpixel_upper_bound and
        has_neighbor_x and has_neighbor_y)
    {
        const score_left = evaluateNccWindow(left, right, .{
            .tmpl_ul_x = tmpl_ul_x,
            .tmpl_ul_y = tmpl_ul_y,
            .tmpl_lr_x = tmpl_lr_x,
            .tmpl_lr_y = tmpl_lr_y,
            .kul_x = kul_x,
            .kul_y = kul_y,
            .search_ul_x = search_ul_x,
            .search_ul_y = search_ul_y,
            .center_local_x = best_x - 1,
            .center_local_y = best_y,
        });
        const score_right = evaluateNccWindow(left, right, .{
            .tmpl_ul_x = tmpl_ul_x,
            .tmpl_ul_y = tmpl_ul_y,
            .tmpl_lr_x = tmpl_lr_x,
            .tmpl_lr_y = tmpl_lr_y,
            .kul_x = kul_x,
            .kul_y = kul_y,
            .search_ul_x = search_ul_x,
            .search_ul_y = search_ul_y,
            .center_local_x = best_x + 1,
            .center_local_y = best_y,
        });
        const score_up = evaluateNccWindow(left, right, .{
            .tmpl_ul_x = tmpl_ul_x,
            .tmpl_ul_y = tmpl_ul_y,
            .tmpl_lr_x = tmpl_lr_x,
            .tmpl_lr_y = tmpl_lr_y,
            .kul_x = kul_x,
            .kul_y = kul_y,
            .search_ul_x = search_ul_x,
            .search_ul_y = search_ul_y,
            .center_local_x = best_x,
            .center_local_y = best_y - 1,
        });
        const score_down = evaluateNccWindow(left, right, .{
            .tmpl_ul_x = tmpl_ul_x,
            .tmpl_ul_y = tmpl_ul_y,
            .tmpl_lr_x = tmpl_lr_x,
            .tmpl_lr_y = tmpl_lr_y,
            .kul_x = kul_x,
            .kul_y = kul_y,
            .search_ul_x = search_ul_x,
            .search_ul_y = search_ul_y,
            .center_local_x = best_x,
            .center_local_y = best_y + 1,
        });
        const subpixel_x = fitSubpixelAxis(score_left, best_score, score_right);
        const subpixel_y = fitSubpixelAxis(score_up, best_score, score_down);
        final_score = @as(f32, @floatCast((subpixel_x.max_value + subpixel_y.max_value) / 2.0));
        if (@abs(subpixel_x.offset) <= 1.0 and @abs(subpixel_y.offset) <= 1.0) {
            refined_x += subpixel_x.offset;
            refined_y += subpixel_y.offset;
        }
    }

    return .{ .score = final_score, .x = refined_x, .y = refined_y };
}

fn roundFloatToPixel(value: f64, limit: u32) u32 {
    if (value <= 0) return 0;
    const rounded = @as(i64, @intFromFloat(value + 0.5));
    const max_value = @as(i64, limit - 1);
    return @as(u32, @intCast(@min(max_value, @max(@as(i64, 0), rounded))));
}

const WindowContext = struct {
    tmpl_ul_x: i32,
    tmpl_ul_y: i32,
    tmpl_lr_x: i32,
    tmpl_lr_y: i32,
    kul_x: i32,
    kul_y: i32,
    search_ul_x: i32,
    search_ul_y: i32,
    center_local_x: i32,
    center_local_y: i32,
};

fn evaluateNccWindow(
    left: *const gray.GrayImage,
    right: *const gray.GrayImage,
    ctx: WindowContext,
) f32 {
    const patch_w = @as(u32, @intCast(ctx.tmpl_lr_x - ctx.tmpl_ul_x));
    const patch_h = @as(u32, @intCast(ctx.tmpl_lr_y - ctx.tmpl_ul_y));
    const count = @as(f64, @floatFromInt(patch_w * patch_h));
    const right_x0 = ctx.search_ul_x + ctx.center_local_x + ctx.kul_x;
    const right_y0 = ctx.search_ul_y + ctx.center_local_y + ctx.kul_y;

    if (ctx.tmpl_ul_x < 0 or ctx.tmpl_ul_y < 0 or
        right_x0 < 0 or right_y0 < 0 or
        ctx.tmpl_lr_x > @as(i32, @intCast(left.width)) or
        ctx.tmpl_lr_y > @as(i32, @intCast(left.height)) or
        right_x0 + @as(i32, @intCast(patch_w)) > @as(i32, @intCast(right.width)) or
        right_y0 + @as(i32, @intCast(patch_h)) > @as(i32, @intCast(right.height)))
    {
        return -1;
    }

    var mean_left: f64 = 0;
    var mean_right: f64 = 0;
    var dy: u32 = 0;
    while (dy < patch_h) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < patch_w) : (dx += 1) {
            mean_left += left.pixel(
                @as(u32, @intCast(ctx.tmpl_ul_x)) + dx,
                @as(u32, @intCast(ctx.tmpl_ul_y)) + dy,
            );
            mean_right += right.pixel(
                @as(u32, @intCast(right_x0)) + dx,
                @as(u32, @intCast(right_y0)) + dy,
            );
        }
    }
    mean_left /= count;
    mean_right /= count;

    var numerator: f64 = 0;
    var div_left: f64 = 0;
    var div_right: f64 = 0;
    dy = 0;
    while (dy < patch_h) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < patch_w) : (dx += 1) {
            const left_value = @as(f64, left.pixel(
                @as(u32, @intCast(ctx.tmpl_ul_x)) + dx,
                @as(u32, @intCast(ctx.tmpl_ul_y)) + dy,
            )) - mean_left;
            const right_value = @as(f64, right.pixel(
                @as(u32, @intCast(right_x0)) + dx,
                @as(u32, @intCast(right_y0)) + dy,
            )) - mean_right;
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

fn clipBounds(start: *i32, stop: *i32, limit: i32) void {
    start.* = @max(0, @min(limit, start.*));
    stop.* = @max(0, @min(limit, stop.*));
}

fn clipCoord(value: i32, limit: i32) i32 {
    return @max(0, @min(limit - 1, value));
}

const SubpixelAxisFit = struct {
    offset: f64,
    max_value: f64,
};

fn fitSubpixelAxis(left: f32, center: f32, right: f32) SubpixelAxisFit {
    const a = @as(f64, center);
    const b = (@as(f64, right) - @as(f64, left)) / 2.0;
    const c = (@as(f64, left) - 2.0 * @as(f64, center) + @as(f64, right)) / 2.0;

    const offset = if (@abs(c) < 1e-12) 0.0 else -b / (2.0 * c);
    const max_value = c * offset * offset + b * offset + a;
    return .{
        .offset = offset,
        .max_value = max_value,
    };
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
        .verbose = 0,
        .template_size = 8,
        .search_width = 12,
    }, .{
        .left_index = 0,
        .right_index = 1,
    }, &left, &left, &right, &right);
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
        .verbose = 0,
        .template_size = 8,
        .search_width = 12,
        .full_res_template_size = 10,
    }, .{
        .left_index = 0,
        .right_index = 1,
    }, &left_reduced, &left_full, &right_reduced, &right_full);
    defer matches.deinit(allocator);

    try std.testing.expect(matches.control_points.len > 0);

    refinePairMatches(.{
        .points_per_grid = 4,
        .grid_size = 1,
        .corr_threshold = 0.8,
        .pyr_level = 1,
        .verbose = 0,
        .template_size = 8,
        .search_width = 12,
        .full_res_template_size = 10,
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
