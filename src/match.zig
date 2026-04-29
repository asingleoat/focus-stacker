const std = @import("std");
const features = @import("features.zig");
const fft_backend = @import("fft_backend.zig");
const gray = @import("gray.zig");
const profiler = @import("profiler.zig");
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

const corr_threshold_slack: f32 = 0.00025;
const clipped_template_score_bias: f32 = 0.00075;

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
    const prof = profiler.scope("match.analyzePair");
    defer prof.end();

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
            if (!passesCorrelationThreshold(result.score, opts.corr_threshold)) {
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
                    truncFloatToPixel(result.x * scale_factor, right_full.width),
                    truncFloatToPixel(result.y * scale_factor, right_full.height),
                    opts.full_res_template_size,
                    full_res_search_width,
                );
                if (!passesCorrelationThreshold(refined.score, opts.corr_threshold)) {
                    continue;
                }
                final_right_x = refined.x;
                final_right_y = refined.y;
                final_score = refined.score;
            }

            try control_points.append(allocator, .{
                .left_image = pair.left_index,
                .right_image = pair.right_index,
                .left_x = quantizeControlPointCoord(left_x),
                .left_y = quantizeControlPointCoord(left_y),
                .right_x = quantizeControlPointCoord(final_right_x),
                .right_y = quantizeControlPointCoord(final_right_y),
                .score = final_score,
                .coarse_right_x = quantizeControlPointCoord(result.x * scale_factor),
                .coarse_right_y = quantizeControlPointCoord(result.y * scale_factor),
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

fn quantizeControlPointCoord(value: anytype) f64 {
    const scaled = @round(@as(f64, value) * 1_000_000.0);
    return scaled / 1_000_000.0;
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

pub const ProbeMatchDebug = struct {
    result: MatchResult,
    best_x: i32 = 0,
    best_y: i32 = 0,
    template_mean: ?f64 = null,
    template_variance: ?f64 = null,
    denominator: ?f64 = null,
    numerator: ?f64 = null,
    surface_center: ?f32 = null,
    surface_left: ?f32 = null,
    surface_right: ?f32 = null,
    surface_up: ?f32 = null,
    surface_down: ?f32 = null,
    direct_center: ?f32 = null,
    direct_left: ?f32 = null,
    direct_right: ?f32 = null,
    direct_up: ?f32 = null,
    direct_down: ?f32 = null,
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

pub fn probeMatchAroundCenterDebug(
    left: *const gray.GrayImage,
    right: *const gray.GrayImage,
    left_x: u32,
    left_y: u32,
    right_center_x: u32,
    right_center_y: u32,
    template_size: u32,
    search_width: u32,
) ProbeMatchDebug {
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
        return .{ .result = .{} };
    }

    const patch_w = @as(u32, @intCast(tmpl_lr_x - tmpl_ul_x));
    const patch_h = @as(u32, @intCast(tmpl_lr_y - tmpl_ul_y));

    var template_storage: [1024]f32 = undefined;
    const template = buildTemplateStats(
        left,
        tmpl_ul_x,
        tmpl_ul_y,
        patch_w,
        patch_h,
        &template_storage,
    ) orelse return .{ .result = .{} };

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
        return .{ .result = .{} };
    }

    const xstart = -kul_x;
    const xend = search_w - klr_x;
    const ystart = -kul_y;
    const yend = search_h - klr_y;
    if (xstart >= xend or ystart >= yend) {
        return .{ .result = .{} };
    }

    const allocator = std.heap.page_allocator;
    const integral = allocator.alloc(f64, @as(usize, @intCast(search_w + 1)) * @as(usize, @intCast(search_h + 1))) catch return .{ .result = .{} };
    defer allocator.free(integral);
    const integral_sq = allocator.alloc(f64, @as(usize, @intCast(search_w + 1)) * @as(usize, @intCast(search_h + 1))) catch return .{ .result = .{} };
    defer allocator.free(integral_sq);
    buildIntegralImages(
        right,
        search_ul_x,
        search_ul_y,
        @as(u32, @intCast(search_w)),
        @as(u32, @intCast(search_h)),
        integral,
        integral_sq,
    );

    if (computeCorrelationSurfaceLikeHugin(
        right,
        search_ul_x,
        search_ul_y,
        @as(u32, @intCast(search_w)),
        @as(u32, @intCast(search_h)),
        kul_x,
        kul_y,
        xstart,
        ystart,
        xend,
        yend,
        template,
        search_ul_x == 0 or search_ul_y == 0 or
            search_lr_x == @as(i32, @intCast(right.width)) or
            search_lr_y == @as(i32, @intCast(right.height)) or
            tmpl_ul_x == 0 or tmpl_ul_y == 0 or
            tmpl_lr_x == @as(i32, @intCast(left.width)) or
            tmpl_lr_y == @as(i32, @intCast(left.height)),
    ) catch null) |surface| {
        defer surface.deinit();

        const direct_center = evaluateCorrelationWindow(right, .{
            .kul_x = kul_x,
            .kul_y = kul_y,
            .search_ul_x = search_ul_x,
            .search_ul_y = search_ul_y,
            .center_local_x = surface.best_x,
            .center_local_y = surface.best_y,
        }, template);
        const direct_left = if (surface.best_x > xstart)
            evaluateCorrelationWindow(right, .{
                .kul_x = kul_x,
                .kul_y = kul_y,
                .search_ul_x = search_ul_x,
                .search_ul_y = search_ul_y,
                .center_local_x = surface.best_x - 1,
                .center_local_y = surface.best_y,
            }, template)
        else
            null;
        const direct_right = if (surface.best_x + 1 < xend)
            evaluateCorrelationWindow(right, .{
                .kul_x = kul_x,
                .kul_y = kul_y,
                .search_ul_x = search_ul_x,
                .search_ul_y = search_ul_y,
                .center_local_x = surface.best_x + 1,
                .center_local_y = surface.best_y,
            }, template)
        else
            null;
        const direct_up = if (surface.best_y > ystart)
            evaluateCorrelationWindow(right, .{
                .kul_x = kul_x,
                .kul_y = kul_y,
                .search_ul_x = search_ul_x,
                .search_ul_y = search_ul_y,
                .center_local_x = surface.best_x,
                .center_local_y = surface.best_y - 1,
            }, template)
        else
            null;
        const direct_down = if (surface.best_y + 1 < yend)
            evaluateCorrelationWindow(right, .{
                .kul_x = kul_x,
                .kul_y = kul_y,
                .search_ul_x = search_ul_x,
                .search_ul_y = search_ul_y,
                .center_local_x = surface.best_x,
                .center_local_y = surface.best_y + 1,
            }, template)
        else
            null;
        const top_x = @as(u32, @intCast(surface.best_x + kul_x));
        const top_y = @as(u32, @intCast(surface.best_y + kul_y));
        const numerator = directNumerator(
            right,
            search_ul_x,
            search_ul_y,
            top_x,
            top_y,
            template,
        );
        const sum = sumRect(integral, @as(u32, @intCast(search_w)) + 1, top_x, top_y, template.width, template.height);
        const sum_sq = sumRect(integral_sq, @as(u32, @intCast(search_w)) + 1, top_x, top_y, template.width, template.height);
        const denominator = @sqrt(@as(f64, @floatFromInt(template.width * template.height)) * sum_sq - sum * sum) * @sqrt(template.variance);

        return .{
            .result = blk: {
                var result = finalizeSurfaceResult(surface, search_ul_x, search_ul_y, templ_half, swidth);
                if (patch_w != template_size + 1 or patch_h != template_size + 1) {
                    result.score -= clipped_template_score_bias;
                }
                break :blk result;
            },
            .best_x = surface.best_x,
            .best_y = surface.best_y,
            .template_mean = template.mean,
            .template_variance = template.variance,
            .denominator = denominator,
            .numerator = numerator,
            .surface_center = surface.best_score,
            .surface_left = if (surface.best_x > 0)
                surface.pixels[@as(usize, @intCast(surface.best_y)) * @as(usize, surface.width) + @as(usize, @intCast(surface.best_x - 1))]
            else
                null,
            .surface_right = if (surface.best_x + 1 < @as(i32, @intCast(surface.width)))
                surface.pixels[@as(usize, @intCast(surface.best_y)) * @as(usize, surface.width) + @as(usize, @intCast(surface.best_x + 1))]
            else
                null,
            .surface_up = if (surface.best_y > 0)
                surface.pixels[@as(usize, @intCast(surface.best_y - 1)) * @as(usize, surface.width) + @as(usize, @intCast(surface.best_x))]
            else
                null,
            .surface_down = if (surface.best_y + 1 < @as(i32, @intCast(surface.height)))
                surface.pixels[@as(usize, @intCast(surface.best_y + 1)) * @as(usize, surface.width) + @as(usize, @intCast(surface.best_x))]
            else
                null,
            .direct_center = direct_center,
            .direct_left = direct_left,
            .direct_right = direct_right,
            .direct_up = direct_up,
            .direct_down = direct_down,
        };
    }

    return .{
        .result = matchAroundCenter(
            left,
            right,
            left_x,
            left_y,
            right_center_x,
            right_center_y,
            template_size,
            search_width,
        ),
        .best_x = 0,
        .best_y = 0,
    };
}

fn matchCandidate(
    left: *const gray.GrayImage,
    right: *const gray.GrayImage,
    candidate: features.InterestPoint,
    opts: PairOptions,
) MatchResult {
    const prof = profiler.scope("match.matchCandidate");
    defer prof.end();

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
    const prof = profiler.scope("match.matchAroundCenter");
    defer prof.end();

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

    const patch_w = @as(u32, @intCast(tmpl_lr_x - tmpl_ul_x));
    const patch_h = @as(u32, @intCast(tmpl_lr_y - tmpl_ul_y));

    var template_storage: [1024]f32 = undefined;
    const template = buildTemplateStats(
        left,
        tmpl_ul_x,
        tmpl_ul_y,
        patch_w,
        patch_h,
        &template_storage,
    ) orelse return .{};

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

    if (computeCorrelationSurfaceLikeHugin(
        right,
        search_ul_x,
        search_ul_y,
        @as(u32, @intCast(search_w)),
        @as(u32, @intCast(search_h)),
        kul_x,
        kul_y,
        xstart,
        ystart,
        xend,
        yend,
        template,
        search_ul_x == 0 or search_ul_y == 0 or
            search_lr_x == @as(i32, @intCast(right.width)) or
            search_lr_y == @as(i32, @intCast(right.height)) or
            tmpl_ul_x == 0 or tmpl_ul_y == 0 or
            tmpl_lr_x == @as(i32, @intCast(left.width)) or
            tmpl_lr_y == @as(i32, @intCast(left.height)),
    ) catch null) |surface| {
        defer surface.deinit();
        var result = finalizeSurfaceResult(surface, search_ul_x, search_ul_y, templ_half, swidth);
        if (patch_w != template_size + 1 or patch_h != template_size + 1) {
            result.score -= clipped_template_score_bias;
        }
        return result;
    }

    var best_x = xstart;
    var best_y = ystart;
    var best_score: f32 = -1;

    var y = ystart;
    while (y < yend) : (y += 1) {
        var x = xstart;
        while (x < xend) : (x += 1) {
            const score = evaluateCorrelationWindow(right, .{
                .kul_x = kul_x,
                .kul_y = kul_y,
                .search_ul_x = search_ul_x,
                .search_ul_y = search_ul_y,
                .center_local_x = x,
                .center_local_y = y,
            }, template);
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
        const score_left = evaluateCorrelationWindow(right, .{
            .kul_x = kul_x,
            .kul_y = kul_y,
            .search_ul_x = search_ul_x,
            .search_ul_y = search_ul_y,
            .center_local_x = best_x - 1,
            .center_local_y = best_y,
        }, template);
        const score_right = evaluateCorrelationWindow(right, .{
            .kul_x = kul_x,
            .kul_y = kul_y,
            .search_ul_x = search_ul_x,
            .search_ul_y = search_ul_y,
            .center_local_x = best_x + 1,
            .center_local_y = best_y,
        }, template);
        const score_up = evaluateCorrelationWindow(right, .{
            .kul_x = kul_x,
            .kul_y = kul_y,
            .search_ul_x = search_ul_x,
            .search_ul_y = search_ul_y,
            .center_local_x = best_x,
            .center_local_y = best_y - 1,
        }, template);
        const score_down = evaluateCorrelationWindow(right, .{
            .kul_x = kul_x,
            .kul_y = kul_y,
            .search_ul_x = search_ul_x,
            .search_ul_y = search_ul_y,
            .center_local_x = best_x,
            .center_local_y = best_y + 1,
        }, template);
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

fn truncFloatToPixel(value: f64, limit: u32) u32 {
    if (value <= 0) return 0;
    const rounded = @as(i64, @intFromFloat(value));
    const max_value = @as(i64, limit - 1);
    return @as(u32, @intCast(@min(max_value, @max(@as(i64, 0), rounded))));
}

const WindowContext = struct {
    kul_x: i32,
    kul_y: i32,
    search_ul_x: i32,
    search_ul_y: i32,
    center_local_x: i32,
    center_local_y: i32,
};

const CorrelationSurface = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    valid_x_start: i32,
    valid_x_end: i32,
    valid_y_start: i32,
    valid_y_end: i32,
    best_x: i32,
    best_y: i32,
    best_score: f32,
    pixels: []f32,

    fn deinit(self: CorrelationSurface) void {
        self.allocator.free(self.pixels);
    }
};

const TemplateStats = struct {
    width: u32,
    height: u32,
    mean: f64,
    variance: f64,
    zero_mean_pixels: []const f32,
};

fn buildTemplateStats(
    left: *const gray.GrayImage,
    tmpl_ul_x: i32,
    tmpl_ul_y: i32,
    patch_w: u32,
    patch_h: u32,
    storage: []f32,
) ?TemplateStats {
    const prof = profiler.scope("match.buildTemplateStats");
    defer prof.end();

    const count_usize = @as(usize, patch_w) * @as(usize, patch_h);
    if (count_usize == 0 or count_usize > storage.len) return null;

    var mean: f64 = 0;
    var count: f64 = 0;
    var variance_sum: f64 = 0;
    var dy: u32 = 0;
    while (dy < patch_h) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < patch_w) : (dx += 1) {
            const value = matchPixel(
                @as(u32, @intCast(tmpl_ul_x)) + dx,
                @as(u32, @intCast(tmpl_ul_y)) + dy,
                left,
            );
            count += 1.0;
            const t1 = value - mean;
            const t2 = t1 / count;
            mean += t2;
            variance_sum += (count - 1.0) * t1 * t2;
        }
    }

    dy = 0;
    while (dy < patch_h) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < patch_w) : (dx += 1) {
            const idx = @as(usize, dy) * @as(usize, patch_w) + @as(usize, dx);
            const value = matchPixel(
                @as(u32, @intCast(tmpl_ul_x)) + dx,
                @as(u32, @intCast(tmpl_ul_y)) + dy,
                left,
            ) - mean;
            const stored = @as(f32, @floatCast(value));
            storage[idx] = stored;
        }
    }

    if (variance_sum == 0) return null;

    return .{
        .width = patch_w,
        .height = patch_h,
        .mean = mean,
        .variance = variance_sum / count,
        .zero_mean_pixels = storage[0..count_usize],
    };
}

fn computeCorrelationSurfaceLikeHugin(
    right: *const gray.GrayImage,
    search_ul_x: i32,
    search_ul_y: i32,
    search_w: u32,
    search_h: u32,
    kul_x: i32,
    kul_y: i32,
    xstart: i32,
    ystart: i32,
    xend: i32,
    yend: i32,
    template: TemplateStats,
    use_exact_dft: bool,
) !?CorrelationSurface {
    const prof = profiler.scope("match.computeCorrelationSurfaceLikeHugin");
    defer prof.end();

    const allocator = std.heap.page_allocator;
    const patch_count = @as(f64, @floatFromInt(template.width * template.height));
    const integral = try allocator.alloc(f64, @as(usize, search_w + 1) * @as(usize, search_h + 1));
    defer allocator.free(integral);
    const integral_sq = try allocator.alloc(f64, @as(usize, search_w + 1) * @as(usize, search_h + 1));
    defer allocator.free(integral_sq);
    const pixels = try allocator.alloc(f32, @as(usize, search_w) * @as(usize, search_h));
    @memset(pixels, -1);
    errdefer allocator.free(pixels);

    buildIntegralImages(right, search_ul_x, search_ul_y, search_w, search_h, integral, integral_sq);

    const normalization = @sqrt(template.variance);
    var best_score: f32 = -1;
    var best_x: i32 = 0;
    var best_y: i32 = 0;
    var valid_x_end = xend;
    var valid_y_end = yend;

    if (use_exact_dft) {
        var center_y: i32 = ystart;
        while (center_y < yend) : (center_y += 1) {
            var center_x: i32 = xstart;
            while (center_x < xend) : (center_x += 1) {
                const top_x = center_x + kul_x;
                const top_y = center_y + kul_y;
                const sum = sumRect(integral, search_w + 1, @as(u32, @intCast(top_x)), @as(u32, @intCast(top_y)), template.width, template.height);
                const sum_sq = sumRect(integral_sq, search_w + 1, @as(u32, @intCast(top_x)), @as(u32, @intCast(top_y)), template.width, template.height);
                const denominator = @sqrt(patch_count * sum_sq - sum * sum);
                if (denominator == 0) continue;

                const numerator = circularCorrelationValue(
                    right,
                    search_ul_x,
                    search_ul_y,
                    search_w,
                    search_h,
                    @as(u32, @intCast(top_x)),
                    @as(u32, @intCast(top_y)),
                    template,
                );
                const score = @as(f32, @floatCast(numerator / normalization / denominator));
                pixels[@as(usize, @intCast(center_y)) * @as(usize, search_w) + @as(usize, @intCast(center_x))] = score;
                if (score > best_score) {
                    best_score = score;
                    best_x = center_x;
                    best_y = center_y;
                }
            }
        }

        if (best_score < 0) {
            allocator.free(pixels);
            return null;
        }

        return .{
            .allocator = allocator,
            .width = search_w,
            .height = search_h,
            .valid_x_start = xstart,
            .valid_x_end = xend,
            .valid_y_start = ystart,
            .valid_y_end = yend,
            .best_x = best_x,
            .best_y = best_y,
            .best_score = best_score,
            .pixels = pixels,
        };
    }

    const fft_w = fft_backend.preferredCorrelationComplexLength(search_w);
    const fft_h = fft_backend.preferredCorrelationComplexLength(search_h);
    const fft_count = @as(usize, fft_w) * @as(usize, fft_h);
    const retained_w = @min(search_w, fft_w);
    const retained_h = @min(search_h, fft_h);
    const klr_x = kul_x + @as(i32, @intCast(template.width)) - 1;
    const klr_y = kul_y + @as(i32, @intCast(template.height)) - 1;
    valid_x_end = @min(xend, @as(i32, @intCast(fft_w)) - klr_x);
    valid_y_end = @min(yend, @as(i32, @intCast(fft_h)) - klr_y);
    if (valid_x_end <= xstart or valid_y_end <= ystart) {
        allocator.free(pixels);
        return null;
    }

    var search_freq = try allocator.alloc(fft_backend.Complex, fft_count);
    defer allocator.free(search_freq);
    var kernel_freq = try allocator.alloc(fft_backend.Complex, fft_count);
    defer allocator.free(kernel_freq);
    var plan = try fft_backend.ComplexPlan2D.init(allocator, fft_w, fft_h);
    defer plan.deinit();

    for (search_freq) |*value| value.* = .{};
    for (kernel_freq) |*value| value.* = .{};

    var y: u32 = 0;
    while (y < retained_h) : (y += 1) {
        var x: u32 = 0;
        while (x < retained_w) : (x += 1) {
            search_freq[@as(usize, y) * @as(usize, fft_w) + @as(usize, x)].re = @as(f32, @floatCast(matchPixel(
                @as(u32, @intCast(search_ul_x)) + x,
                @as(u32, @intCast(search_ul_y)) + y,
                right,
            )));
        }
    }

    y = 0;
    while (y < template.height) : (y += 1) {
        var x: u32 = 0;
        while (x < template.width) : (x += 1) {
            const idx = @as(usize, y) * @as(usize, template.width) + @as(usize, x);
            kernel_freq[@as(usize, y) * @as(usize, fft_w) + @as(usize, x)].re = template.zero_mean_pixels[idx];
        }
    }

    plan.transformInPlace(search_freq, false);
    plan.transformInPlace(kernel_freq, false);

    for (search_freq, kernel_freq) |*lhs, rhs| {
        lhs.* = lhs.mulConj(rhs);
    }
    plan.transformInPlace(search_freq, true);

    var center_y: i32 = ystart;
    while (center_y < valid_y_end) : (center_y += 1) {
        var center_x: i32 = xstart;
        while (center_x < valid_x_end) : (center_x += 1) {
            const top_x = center_x + kul_x;
            const top_y = center_y + kul_y;
            const sum = sumRect(integral, search_w + 1, @as(u32, @intCast(top_x)), @as(u32, @intCast(top_y)), template.width, template.height);
            const sum_sq = sumRect(integral_sq, search_w + 1, @as(u32, @intCast(top_x)), @as(u32, @intCast(top_y)), template.width, template.height);
            const denominator = @sqrt(patch_count * sum_sq - sum * sum);
            if (denominator == 0) continue;

            const corr_idx = @as(usize, @intCast(top_y)) * @as(usize, fft_w) + @as(usize, @intCast(top_x));
            const score = @as(f32, @floatCast(@as(f64, search_freq[corr_idx].re) / normalization / denominator));
            pixels[@as(usize, @intCast(center_y)) * @as(usize, search_w) + @as(usize, @intCast(center_x))] = score;
            if (score > best_score) {
                best_score = score;
                best_x = center_x;
                best_y = center_y;
            }
        }
    }

    if (best_score < 0) {
        allocator.free(pixels);
        return null;
    }

    return .{
        .allocator = allocator,
        .width = search_w,
        .height = search_h,
        .valid_x_start = xstart,
        .valid_x_end = valid_x_end,
        .valid_y_start = ystart,
        .valid_y_end = valid_y_end,
        .best_x = best_x,
        .best_y = best_y,
        .best_score = best_score,
        .pixels = pixels,
    };
}

fn finalizeSurfaceResult(
    surface: CorrelationSurface,
    search_ul_x: i32,
    search_ul_y: i32,
    templ_half: i32,
    swidth: i32,
) MatchResult {
    var refined_x = @as(f64, @floatFromInt(surface.best_x + search_ul_x));
    var refined_y = @as(f64, @floatFromInt(surface.best_y + search_ul_y));
    var final_score = surface.best_score;

    const subpixel_lower_bound = 2 + templ_half;
    const subpixel_upper_bound = 2 * swidth + 1 - 2 - templ_half;
    const has_neighbor_x = surface.best_x > surface.valid_x_start and surface.best_x + 1 < surface.valid_x_end;
    const has_neighbor_y = surface.best_y > surface.valid_y_start and surface.best_y + 1 < surface.valid_y_end;
    if (surface.best_x > subpixel_lower_bound and surface.best_x < subpixel_upper_bound and
        surface.best_y > subpixel_lower_bound and surface.best_y < subpixel_upper_bound and
        has_neighbor_x and has_neighbor_y)
    {
        const score_left = surface.pixels[@as(usize, @intCast(surface.best_y)) * @as(usize, surface.width) + @as(usize, @intCast(surface.best_x - 1))];
        const score_right = surface.pixels[@as(usize, @intCast(surface.best_y)) * @as(usize, surface.width) + @as(usize, @intCast(surface.best_x + 1))];
        const score_up = surface.pixels[@as(usize, @intCast(surface.best_y - 1)) * @as(usize, surface.width) + @as(usize, @intCast(surface.best_x))];
        const score_down = surface.pixels[@as(usize, @intCast(surface.best_y + 1)) * @as(usize, surface.width) + @as(usize, @intCast(surface.best_x))];
        const subpixel_x = fitSubpixelAxis(score_left, surface.best_score, score_right);
        const subpixel_y = fitSubpixelAxis(score_up, surface.best_score, score_down);
        final_score = @as(f32, @floatCast((subpixel_x.max_value + subpixel_y.max_value) / 2.0));
        if (@abs(subpixel_x.offset) <= 1.0 and @abs(subpixel_y.offset) <= 1.0) {
            refined_x += subpixel_x.offset;
            refined_y += subpixel_y.offset;
        }
    }

    return .{ .score = final_score, .x = refined_x, .y = refined_y };
}

fn buildIntegralImages(
    right: *const gray.GrayImage,
    search_ul_x: i32,
    search_ul_y: i32,
    search_w: u32,
    search_h: u32,
    integral: []f64,
    integral_sq: []f64,
) void {
    const stride = @as(usize, search_w + 1);
    @memset(integral, 0);
    @memset(integral_sq, 0);

    var y: u32 = 0;
    while (y < search_h) : (y += 1) {
        var row_sum: f64 = 0;
        var row_sum_sq: f64 = 0;
        var x: u32 = 0;
        while (x < search_w) : (x += 1) {
            const value = matchPixel(
                @as(u32, @intCast(search_ul_x)) + x,
                @as(u32, @intCast(search_ul_y)) + y,
                right,
            );
            row_sum += value;
            row_sum_sq += value * value;
            const idx = @as(usize, y + 1) * stride + @as(usize, x + 1);
            integral[idx] = integral[@as(usize, y) * stride + @as(usize, x + 1)] + row_sum;
            integral_sq[idx] = integral_sq[@as(usize, y) * stride + @as(usize, x + 1)] + row_sum_sq;
        }
    }
}

fn sumRect(integral: []const f64, stride_u32: u32, x0: u32, y0: u32, width: u32, height: u32) f64 {
    const stride = @as(usize, stride_u32);
    const x1 = x0 + width;
    const y1 = y0 + height;
    return integral[@as(usize, y1) * stride + @as(usize, x1)] -
        integral[@as(usize, y0) * stride + @as(usize, x1)] -
        integral[@as(usize, y1) * stride + @as(usize, x0)] +
        integral[@as(usize, y0) * stride + @as(usize, x0)];
}

fn circularCorrelationValue(
    right: *const gray.GrayImage,
    search_ul_x: i32,
    search_ul_y: i32,
    search_w: u32,
    search_h: u32,
    top_x: u32,
    top_y: u32,
    template: TemplateStats,
) f64 {
    var numerator: f64 = 0;
    var dy: u32 = 0;
    while (dy < template.height) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < template.width) : (dx += 1) {
            const template_idx = @as(usize, dy) * @as(usize, template.width) + @as(usize, dx);
            const sample_x = (top_x + dx) % search_w;
            const sample_y = (top_y + dy) % search_h;
            const right_value = matchPixel(
                @as(u32, @intCast(search_ul_x)) + sample_x,
                @as(u32, @intCast(search_ul_y)) + sample_y,
                right,
            );
            numerator += @as(f64, template.zero_mean_pixels[template_idx]) * right_value;
        }
    }
    return numerator;
}

fn directNumerator(
    right: *const gray.GrayImage,
    search_ul_x: i32,
    search_ul_y: i32,
    top_x: u32,
    top_y: u32,
    template: TemplateStats,
) f64 {
    var numerator: f64 = 0;
    var dy: u32 = 0;
    while (dy < template.height) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < template.width) : (dx += 1) {
            const template_idx = @as(usize, dy) * @as(usize, template.width) + @as(usize, dx);
            const right_value = matchPixel(
                @as(u32, @intCast(search_ul_x)) + top_x + dx,
                @as(u32, @intCast(search_ul_y)) + top_y + dy,
                right,
            );
            numerator += @as(f64, template.zero_mean_pixels[template_idx]) * right_value;
        }
    }
    return numerator;
}

fn evaluateCorrelationWindow(
    right: *const gray.GrayImage,
    ctx: WindowContext,
    template: TemplateStats,
) f32 {
    const patch_w = template.width;
    const patch_h = template.height;
    const right_x0 = ctx.search_ul_x + ctx.center_local_x + ctx.kul_x;
    const right_y0 = ctx.search_ul_y + ctx.center_local_y + ctx.kul_y;

    if (right_x0 < 0 or right_y0 < 0 or
        right_x0 + @as(i32, @intCast(patch_w)) > @as(i32, @intCast(right.width)) or
        right_y0 + @as(i32, @intCast(patch_h)) > @as(i32, @intCast(right.height)))
    {
        return -1;
    }

    var numerator: f64 = 0;
    var sum_right: f64 = 0;
    var sum_right_sq: f64 = 0;
    var dy: u32 = 0;
    while (dy < patch_h) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < patch_w) : (dx += 1) {
            const template_idx = @as(usize, dy) * @as(usize, patch_w) + @as(usize, dx);
            const right_value = matchPixel(
                @as(u32, @intCast(right_x0)) + dx,
                @as(u32, @intCast(right_y0)) + dy,
                right,
            );
            numerator += template.zero_mean_pixels[template_idx] * right_value;
            sum_right += right_value;
            sum_right_sq += right_value * right_value;
        }
    }

    const count = @as(f64, @floatFromInt(patch_w * patch_h));
    const denominator = @sqrt(template.variance) * @sqrt(count * sum_right_sq - sum_right * sum_right);
    if (denominator == 0) {
        return -1;
    }
    return @as(f32, @floatCast(numerator / denominator));
}

fn matchPixel(x: u32, y: u32, image: *const gray.GrayImage) f64 {
    const value = @as(f64, image.pixel(x, y));
    if (image.sample_scale <= 1.0) {
        return value;
    }
    return @round(value * @as(f64, image.sample_scale));
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

pub fn passesCorrelationThreshold(score: f32, threshold: f32) bool {
    return score + corr_threshold_slack >= threshold;
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
