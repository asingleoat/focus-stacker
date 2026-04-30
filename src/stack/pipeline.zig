const std = @import("std");
const align_core = @import("align_stack_core");
const fuse = @import("focus_fuse_core");
const config = @import("config.zig");

pub const RunError = anyerror;

pub fn run(allocator: std.mem.Allocator, cfg: *const config.Config) RunError!void {
    const prof = align_core.profiler.scope("stack.pipeline.run");
    defer prof.end();

    var align_cfg = try cfg.toAlignConfig(allocator);
    defer align_cfg.deinit(allocator);

    const images = try align_core.pipeline.collectInputImages(allocator, &align_cfg);
    defer allocator.free(images);
    const base_hfov = align_cfg.hfov orelse images[0].hfov_degrees orelse 50.0;

    var plan = try align_core.sequence.buildPlan(allocator, &align_cfg, images);
    defer plan.deinit(allocator);
    const optimize_vector = try align_core.optimize.buildOptimizeVector(allocator, &align_cfg, images.len);
    defer allocator.free(optimize_vector);

    const summary = try align_core.sequence.renderPlanSummary(allocator, &plan, images);
    defer allocator.free(summary);
    const optimize_summary = try align_core.optimize.renderOptimizeVectorSummary(allocator, optimize_vector);
    defer allocator.free(optimize_summary);
    try std.fs.File.stderr().writeAll(summary);
    try std.fs.File.stderr().writeAll(optimize_summary);

    const pair_matches = try align_core.pipeline.analyzePairs(allocator, &align_cfg, images, &plan);
    defer {
        for (pair_matches) |*entry| entry.deinit(allocator);
        allocator.free(pair_matches);
    }

    const match_summary = try align_core.match.renderSummary(allocator, pair_matches, images);
    defer allocator.free(match_summary);
    try std.fs.File.stderr().writeAll(match_summary);

    var final_solve = try align_core.optimize.solvePosesVerbose(allocator, images.len, base_hfov, optimize_vector, pair_matches, cfg.verbose);
    defer final_solve.deinit(allocator);
    const initial_optimize_summary = try align_core.optimize.renderSolveSummary(allocator, "before pruning", &final_solve);
    defer allocator.free(initial_optimize_summary);
    try std.fs.File.stderr().writeAll(initial_optimize_summary);

    if (align_cfg.cp_error_threshold > 0) {
        const before_prune_count = final_solve.control_point_count;
        const after_prune_count = align_core.optimize.pruneByResidualThreshold(pair_matches, final_solve.residuals, align_cfg.cp_error_threshold);
        const prune_summary = try std.fmt.allocPrint(
            allocator,
            "control-point pruning:\n  threshold: {d:.3} px\n  before: {d}\n  after: {d}\n",
            .{ align_cfg.cp_error_threshold, before_prune_count, after_prune_count },
        );
        defer allocator.free(prune_summary);
        try std.fs.File.stderr().writeAll(prune_summary);

        if (align_cfg.optimize_hfov and !align_core.optimize.hasControlPointsForImage(pair_matches, 0)) {
            return error.ReferenceImageHasNoControlPointsAfterPruning;
        }
        if (after_prune_count < optimize_vector.len) {
            return error.NotEnoughControlPointsAfterPruning;
        }
        if (after_prune_count > 0 and after_prune_count != before_prune_count) {
            if (cfg.verbose > 0) {
                try std.fs.File.stderr().writeAll("optimization: restarting after control-point pruning\n");
            }
            var pruned_solve = try align_core.optimize.solvePosesFromInitialWithVerbose(
                allocator,
                images.len,
                base_hfov,
                optimize_vector,
                pair_matches,
                final_solve.poses,
                cfg.verbose,
            );
            const pruned_optimize_summary = try align_core.optimize.renderSolveSummary(allocator, "after pruning", &pruned_solve);
            defer allocator.free(pruned_optimize_summary);
            try std.fs.File.stderr().writeAll(pruned_optimize_summary);
            final_solve.deinit(allocator);
            final_solve = pruned_solve;
        }
    }

    const roi = try align_core.remap.computeCommonOverlapRoi(allocator, plan.remap_active.items, images, final_solve.poses);
    try fuseRemappedImages(allocator, cfg, images, &plan, final_solve.poses, roi);
}

fn fuseRemappedImages(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    images: []const align_core.sequence.InputImage,
    plan: *const align_core.sequence.Plan,
    poses: []const align_core.optimize.ImagePose,
    roi: ?align_core.remap.Rect,
) RunError!void {
    const prof = align_core.profiler.scope("stack.pipeline.fuseRemappedImages");
    defer prof.end();

    const jobs = resolveJobs(cfg.jobs);
    var best_weights = std.ArrayListUnmanaged(f32){};
    defer best_weights.deinit(allocator);

    var output: ?align_core.image_io.Image = null;
    defer if (output) |*image| image.deinit(allocator);

    const output_path = cfg.output_path.?;
    if (std.fs.path.dirname(output_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var active_count: usize = 0;
    for (plan.ordered_indices.items) |image_index| {
        if (!plan.remap_active.items[image_index]) continue;
        active_count += 1;
        if (cfg.verbose > 0) {
            std.debug.print("stack fuse: [{d}] remapping {s}\n", .{ active_count, images[image_index].path });
        }

        var src = try align_core.image_io.loadImage(allocator, images[image_index].path);
        defer src.deinit(allocator);

        var remapped = try align_core.remap.remapRigidImage(allocator, &src, poses[image_index], roi, jobs);
        defer remapped.deinit(allocator);

        if (output == null) {
            output = try fuse.blend.allocateOutput(allocator, fusedOutputInfo(remapped.info));
            const count = @as(usize, remapped.info.width) * @as(usize, remapped.info.height);
            try best_weights.resize(allocator, count);
            @memset(best_weights.items, -std.math.inf(f32));
        }

        var gray_image = try align_core.gray.fromLoaded(allocator, &remapped);
        defer gray_image.deinit(allocator);
        var weights = try fuse.contrast.computeLocalContrastWeights(allocator, &gray_image, cfg.contrast_window_size, jobs);
        defer weights.deinit(allocator);
        try fuse.blend.updateWinners(allocator, &remapped, &weights, best_weights.items, &output.?, jobs);
    }

    if (cfg.verbose > 0) {
        std.debug.print("stack fuse: writing {s}\n", .{output_path});
    }
    try align_core.image_io.writeTiff(output_path, &output.?);
}

fn fusedOutputInfo(info: align_core.image_io.ImageInfo) align_core.image_io.ImageInfo {
    var out = info;
    out.extra_channels = 0;
    return out;
}

fn resolveJobs(requested: ?u32) usize {
    if (requested) |value| return @max(@as(usize, value), 1);
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return if (cpu_count > 2) cpu_count - 2 else 1;
}
