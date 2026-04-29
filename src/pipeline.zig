const std = @import("std");
const config_mod = @import("config.zig");
const features = @import("features.zig");
const gray = @import("gray.zig");
const image_io = @import("image_io.zig");
const match = @import("match.zig");
const optimize = @import("optimize.zig");
const profiler = @import("profiler.zig");
const pto = @import("pto.zig");
const remap = @import("remap.zig");
const sequence = @import("sequence.zig");

pub const ReferencePaths = struct {
    pub const align_image_stack_cpp = "upstream/hugin-2025.0.1/src/tools/align_image_stack.cpp";
    pub const align_image_stack_doc = "upstream/hugin-2025.0.1/doc/align_image_stack.pod";
};

pub const Stage = enum {
    read_image_metadata,
    sort_input_sequence,
    decode_reference_image,
    detect_interest_points,
    match_control_points,
    optimize_geometry,
    prune_outliers,
    auto_crop,
    remap_outputs,
    write_pto,
};

pub const RunError = anyerror;

pub fn run(allocator: std.mem.Allocator, cfg: *const config_mod.Config) RunError!void {
    const prof = profiler.scope("pipeline.run");
    defer prof.end();

    const images = try collectInputImages(allocator, cfg);
    defer allocator.free(images);
    const base_hfov = cfg.hfov orelse images[0].hfov_degrees orelse 50.0;

    var plan = try sequence.buildPlan(allocator, cfg, images);
    defer plan.deinit(allocator);
    const optimize_vector = try optimize.buildOptimizeVector(allocator, cfg, images.len);
    defer allocator.free(optimize_vector);

    const summary = try sequence.renderPlanSummary(allocator, &plan, images);
    defer allocator.free(summary);
    const optimize_summary = try optimize.renderOptimizeVectorSummary(allocator, optimize_vector);
    defer allocator.free(optimize_summary);

    try std.fs.File.stderr().writeAll(summary);
    try std.fs.File.stderr().writeAll(optimize_summary);

    const pair_matches = try analyzePairs(allocator, cfg, images, &plan);
    defer {
        for (pair_matches) |*entry| {
            entry.deinit(allocator);
        }
        allocator.free(pair_matches);
    }

    const match_summary = try match.renderSummary(allocator, pair_matches, images);
    defer allocator.free(match_summary);
    try std.fs.File.stderr().writeAll(match_summary);

    var final_solve = try optimize.solvePosesVerbose(allocator, images.len, base_hfov, optimize_vector, pair_matches, cfg.verbose);
    defer final_solve.deinit(allocator);
    const initial_optimize_summary = try optimize.renderSolveSummary(allocator, "before pruning", &final_solve);
    defer allocator.free(initial_optimize_summary);
    try std.fs.File.stderr().writeAll(initial_optimize_summary);

    if (cfg.cp_error_threshold > 0) {
        const before_prune_count = final_solve.control_point_count;
        const after_prune_count = optimize.pruneByResidualThreshold(pair_matches, final_solve.residuals, cfg.cp_error_threshold);
        const prune_summary = try std.fmt.allocPrint(
            allocator,
            "control-point pruning:\n  threshold: {d:.3} px\n  before: {d}\n  after: {d}\n",
            .{ cfg.cp_error_threshold, before_prune_count, after_prune_count },
        );
        defer allocator.free(prune_summary);
        try std.fs.File.stderr().writeAll(prune_summary);

        if (cfg.optimize_hfov and !optimize.hasControlPointsForImage(pair_matches, 0)) {
            return error.ReferenceImageHasNoControlPointsAfterPruning;
        }

        if (after_prune_count < optimize_vector.len) {
            return error.NotEnoughControlPointsAfterPruning;
        }

        if (after_prune_count > 0 and after_prune_count != before_prune_count) {
            if (cfg.verbose > 0) {
                try std.fs.File.stderr().writeAll("optimization: restarting after control-point pruning\n");
            }
            var pruned_solve = try optimize.solvePosesFromInitialWithVerbose(
                allocator,
                images.len,
                base_hfov,
                optimize_vector,
                pair_matches,
                final_solve.poses,
                cfg.verbose,
            );
            const pruned_optimize_summary = try optimize.renderSolveSummary(allocator, "after pruning", &pruned_solve);
            defer allocator.free(pruned_optimize_summary);
            try std.fs.File.stderr().writeAll(pruned_optimize_summary);
            final_solve.deinit(allocator);
            final_solve = pruned_solve;
        }
    }

    if (cfg.verbose > 0 and images.len > 0) {
        try writeFirstPairPreview(allocator, cfg, images, &plan, pair_matches);
    }

    if (cfg.pto_file) |pto_path| {
        try pto.writePtoFile(allocator, pto_path, cfg, images, optimize_vector, pair_matches, final_solve.poses);
        if (cfg.verbose > 0) {
            const message = try std.fmt.allocPrint(allocator, "written PTO output to {s}\n", .{pto_path});
            defer allocator.free(message);
            try std.fs.File.stderr().writeAll(message);
        }
    }

    if (cfg.aligned_prefix) |aligned_prefix| {
        const roi = if (cfg.crop)
            try remap.computeCommonOverlapRoi(allocator, plan.remap_active.items, images, final_solve.poses)
        else
            null;
        try remap.writeAlignedImages(
            allocator,
            aligned_prefix,
            plan.ordered_indices.items,
            plan.remap_active.items,
            images,
            final_solve.poses,
            roi,
            effectiveWorkJobs(cfg, countActiveRemapImages(plan.remap_active.items)),
        );
        if (cfg.verbose > 0) {
            const message = try std.fmt.allocPrint(allocator, "written aligned TIFF output with prefix {s}\n", .{aligned_prefix});
            defer allocator.free(message);
            try std.fs.File.stderr().writeAll(message);
        }
    }

    if (cfg.hdr_file == null) {
        return;
    }

    return error.NotImplemented;
}

pub fn collectInputImages(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
) RunError![]sequence.InputImage {
    const prof = profiler.scope("pipeline.collectInputImages");
    defer prof.end();

    const paths = cfg.input_files.items;
    var images: std.ArrayList(sequence.InputImage) = .empty;
    defer images.deinit(allocator);

    var expected_width: ?u32 = null;
    var expected_height: ?u32 = null;

    for (paths) |path| {
        if (image_io.isRawPath(path)) {
            std.debug.print("Ignoring raw file {s}\n", .{path});
            continue;
        }

        const info = image_io.loadInfo(allocator, path) catch |err| switch (err) {
            error.UnsupportedFormat, error.InvalidImage => {
                std.debug.print("Could not read file {s}\n", .{path});
                continue;
            },
            else => return err,
        };

        if (expected_width == null) {
            expected_width = info.width;
            expected_height = info.height;
        } else if (expected_width.? != info.width or expected_height.? != info.height) {
            return error.MismatchedImageSizes;
        }

        try images.append(allocator, .{
            .pano_index = images.items.len,
            .path = path,
            .format = info.format,
            .width = info.width,
            .height = info.height,
            .color_model = info.color_model,
            .sample_type = info.sample_type,
            .exposure_value = info.exposure_value,
            .hfov_degrees = cfg.hfov orelse image_io.deriveHfovDegrees(info, cfg.fisheye),
        });
    }

    if (images.items.len == 0) return error.NoUsableInputFiles;
    if (images.items.len < 2) return error.NotEnoughUsableInputFiles;

    return images.toOwnedSlice(allocator);
}

pub fn analyzePairs(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    images: []const sequence.InputImage,
    plan: *const sequence.Plan,
) RunError![]match.PairMatches {
    const prof = profiler.scope("pipeline.analyzePairs");
    defer prof.end();

    if (plan.pairs.items.len == 0) {
        return allocator.alloc(match.PairMatches, 0);
    }

    var results: std.ArrayList(match.PairMatches) = .empty;
    defer results.deinit(allocator);

    const options = match.PairOptions{
        .points_per_grid = cfg.points_per_grid,
        .grid_size = cfg.grid_size,
        .corr_threshold = @as(f32, @floatCast(cfg.corr_thresh)),
        .pyr_level = cfg.pyr_level,
        .verbose = cfg.verbose,
    };

    const pair_jobs = effectivePairJobs(cfg, plan.pairs.items.len);
    if (pair_jobs == 1) {
        if (cfg.align_to_first) {
            var left = try loadReducedGrayImage(allocator, images[plan.pairs.items[0].left_index].path, cfg.pyr_level);
            defer left.deinit(allocator);
            var left_full = try loadReducedGrayImage(allocator, images[plan.pairs.items[0].left_index].path, 0);
            defer left_full.deinit(allocator);

            for (plan.pairs.items) |pair| {
                var right = try loadReducedGrayImage(allocator, images[pair.right_index].path, cfg.pyr_level);
                defer right.deinit(allocator);
                var right_full = try loadReducedGrayImage(allocator, images[pair.right_index].path, 0);
                defer right_full.deinit(allocator);

                var pair_result = try match.analyzePair(allocator, options, pair, &left, &left_full, &right, &right_full);
                match.refinePairMatches(options, &pair_result, &left_full, &right_full);
                try results.append(allocator, pair_result);
            }
        } else {
            var left_index = plan.pairs.items[0].left_index;
            var left = try loadReducedGrayImage(allocator, images[left_index].path, cfg.pyr_level);
            defer left.deinit(allocator);
            var left_full = try loadReducedGrayImage(allocator, images[left_index].path, 0);
            defer left_full.deinit(allocator);

            for (plan.pairs.items, 0..) |pair, pair_idx| {
                if (pair.left_index != left_index) {
                    left.deinit(allocator);
                    left = try loadReducedGrayImage(allocator, images[pair.left_index].path, cfg.pyr_level);
                    left_full.deinit(allocator);
                    left_full = try loadReducedGrayImage(allocator, images[pair.left_index].path, 0);
                    left_index = pair.left_index;
                }

                var right = try loadReducedGrayImage(allocator, images[pair.right_index].path, cfg.pyr_level);
                var right_full = try loadReducedGrayImage(allocator, images[pair.right_index].path, 0);
                var pair_result = try match.analyzePair(allocator, options, pair, &left, &left_full, &right, &right_full);
                match.refinePairMatches(options, &pair_result, &left_full, &right_full);
                try results.append(allocator, pair_result);

                const should_reuse_right = pair_idx + 1 < plan.pairs.items.len and
                    plan.pairs.items[pair_idx + 1].left_index == pair.right_index;
                if (should_reuse_right) {
                    left.deinit(allocator);
                    left = right;
                    left_full.deinit(allocator);
                    left_full = right_full;
                    left_index = pair.right_index;
                } else {
                    right.deinit(allocator);
                    right_full.deinit(allocator);
                }
            }
        }

        return results.toOwnedSlice(allocator);
    }

    const parallel_results = try analyzePairsParallel(allocator, cfg, images, plan.pairs.items, options, pair_jobs);
    defer allocator.free(parallel_results);
    try results.ensureTotalCapacityPrecise(allocator, parallel_results.len);
    for (parallel_results) |pair_result| {
        results.appendAssumeCapacity(pair_result);
    }
    return results.toOwnedSlice(allocator);
}

const PairWorkerResult = struct {
    value: ?match.PairMatches = null,
};

const PairWorkerState = struct {
    allocator: std.mem.Allocator,
    images: []const sequence.InputImage,
    pairs: []const sequence.MatchPair,
    options: match.PairOptions,
    pyr_level: u8,
    next_index: usize = 0,
    first_error: ?RunError = null,
    mutex: std.Thread.Mutex = .{},
    results: []PairWorkerResult,
};

fn analyzePairsParallel(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    images: []const sequence.InputImage,
    pairs: []const sequence.MatchPair,
    options: match.PairOptions,
    pair_jobs: usize,
) RunError![]match.PairMatches {
    var thread_safe_allocator: std.heap.ThreadSafeAllocator = .{ .child_allocator = allocator };
    const worker_results = try allocator.alloc(PairWorkerResult, pairs.len);
    errdefer allocator.free(worker_results);
    for (worker_results) |*entry| entry.* = .{};

    var state = PairWorkerState{
        .allocator = thread_safe_allocator.allocator(),
        .images = images,
        .pairs = pairs,
        .options = options,
        .pyr_level = cfg.pyr_level,
        .results = worker_results,
    };

    const spawned_count = pair_jobs - 1;
    var threads = try allocator.alloc(std.Thread, spawned_count);
    defer allocator.free(threads);

    var started_threads: usize = 0;
    errdefer {
        for (threads[0..started_threads]) |thread| {
            thread.join();
        }
        cleanupWorkerResults(allocator, worker_results);
    }

    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, pairWorkerMain, .{&state});
        started_threads += 1;
    }

    pairWorkerMain(&state);

    for (threads) |thread| {
        thread.join();
    }

    if (state.first_error) |err| {
        cleanupWorkerResults(allocator, worker_results);
        return err;
    }

    var ordered = try allocator.alloc(match.PairMatches, pairs.len);
    errdefer allocator.free(ordered);
    for (worker_results, 0..) |entry, pair_index| {
        ordered[pair_index] = entry.value orelse return error.InternalInvariantViolation;
    }
    allocator.free(worker_results);
    return ordered;
}

fn pairWorkerMain(state: *PairWorkerState) void {
    while (true) {
        const pair_index = nextPairIndex(state) orelse return;
        const pair = state.pairs[pair_index];
        const result = analyzePairDecodedOnDemand(state.allocator, state.images, state.options, state.pyr_level, pair) catch |err| {
            recordError(state, err);
            return;
        };
        state.results[pair_index].value = result;
    }
}

fn analyzePairDecodedOnDemand(
    allocator: std.mem.Allocator,
    images: []const sequence.InputImage,
    options: match.PairOptions,
    pyr_level: u8,
    pair: sequence.MatchPair,
) RunError!match.PairMatches {
    var left = try loadReducedGrayImage(allocator, images[pair.left_index].path, pyr_level);
    defer left.deinit(allocator);
    var left_full = try loadReducedGrayImage(allocator, images[pair.left_index].path, 0);
    defer left_full.deinit(allocator);
    var right = try loadReducedGrayImage(allocator, images[pair.right_index].path, pyr_level);
    defer right.deinit(allocator);
    var right_full = try loadReducedGrayImage(allocator, images[pair.right_index].path, 0);
    defer right_full.deinit(allocator);

    var pair_result = try match.analyzePair(allocator, options, pair, &left, &left_full, &right, &right_full);
    match.refinePairMatches(options, &pair_result, &left_full, &right_full);
    return pair_result;
}

fn cleanupWorkerResults(allocator: std.mem.Allocator, worker_results: []PairWorkerResult) void {
    for (worker_results) |*entry| {
        if (entry.value) |*value| {
            value.deinit(allocator);
            entry.value = null;
        }
    }
}

fn effectivePairJobs(cfg: *const config_mod.Config, pair_count: usize) usize {
    return effectiveWorkJobs(cfg, pair_count);
}

fn effectiveWorkJobs(cfg: *const config_mod.Config, work_count: usize) usize {
    if (work_count == 0) return 1;
    const requested = if (cfg.pair_jobs) |jobs|
        @as(usize, jobs)
    else
        defaultPairJobs();
    return @max(@as(usize, 1), @min(requested, work_count));
}

fn defaultPairJobs() usize {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return if (cpu_count > 2) cpu_count - 2 else 1;
}

fn countActiveRemapImages(remap_active: []const bool) usize {
    var count: usize = 0;
    for (remap_active) |is_active| {
        if (is_active) count += 1;
    }
    return count;
}

fn nextPairIndex(state: *PairWorkerState) ?usize {
    state.mutex.lock();
    defer state.mutex.unlock();

    if (state.first_error != null) return null;
    if (state.next_index >= state.pairs.len) return null;

    const pair_index = state.next_index;
    state.next_index += 1;
    return pair_index;
}

fn recordError(state: *PairWorkerState, err: RunError) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (state.first_error == null) {
        state.first_error = err;
    }
}

fn loadReducedGrayImage(
    allocator: std.mem.Allocator,
    path: []const u8,
    pyr_level: u8,
) RunError!gray.GrayImage {
    const prof = profiler.scope("pipeline.loadReducedGrayImage");
    defer prof.end();

    var decoded = try image_io.loadImage(allocator, path);
    defer decoded.deinit(allocator);
    return gray.fromLoadedReducedLikeHugin(allocator, &decoded, pyr_level);
}

fn writeFirstPairPreview(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    images: []const sequence.InputImage,
    plan: *const sequence.Plan,
    pair_matches: []const match.PairMatches,
) RunError!void {
    const prof = profiler.scope("pipeline.writeFirstPairPreview");
    defer prof.end();

    const first_index = plan.ordered_indices.items[0];
    var reduced = try loadReducedGrayImage(allocator, images[first_index].path, cfg.pyr_level);
    defer reduced.deinit(allocator);

    const rects = try features.buildGridRects(allocator, reduced.width, reduced.height, cfg.grid_size);
    defer allocator.free(rects);

    const total_features = if (rects.len > 0) blk: {
        const first_rect = rects[0];
        const points = try features.detectInterestPointsPartial(allocator, &reduced, first_rect, 2.0, cfg.points_per_grid * 5);
        defer allocator.free(points);
        break :blk points.len;
    } else 0;

    const first_pair_coarse_count: usize = if (pair_matches.len > 0) pair_matches[0].coarse_control_point_count else 0;
    const first_pair_remaining_count: usize = if (pair_matches.len > 0) pair_matches[0].refined_control_point_count else 0;

    const preview = try std.fmt.allocPrint(
        allocator,
        \\processing preview:
        \\  source: {s}
        \\  source dimensions: {d}x{d}
        \\  reduced ({d}): {d}x{d}
        \\  first grid candidate count: {d}
        \\  first pair coarse control points: {d}
        \\  first pair remaining control points: {d}
        \\
    ,
        .{
            images[first_index].path,
            images[first_index].width,
            images[first_index].height,
            cfg.pyr_level,
            reduced.width,
            reduced.height,
            total_features,
            first_pair_coarse_count,
            first_pair_remaining_count,
        },
    );
    defer allocator.free(preview);

    try std.fs.File.stderr().writeAll(preview);
}
