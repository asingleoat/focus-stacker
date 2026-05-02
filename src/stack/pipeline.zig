const std = @import("std");
const align_core = @import("align_stack_core");
const fuse = @import("focus_fuse_core");
const config = @import("config.zig");
const max_cached_pyramid_bytes: usize = 2 * 1024 * 1024 * 1024;

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
    var gray_buffer = std.ArrayListUnmanaged(f32){};
    defer gray_buffer.deinit(allocator);
    var support_buffer = std.ArrayListUnmanaged(f32){};
    defer support_buffer.deinit(allocator);
    var weight_buffer = std.ArrayListUnmanaged(f32){};
    defer weight_buffer.deinit(allocator);
    var smoothed_weight_buffer = std.ArrayListUnmanaged(f32){};
    defer smoothed_weight_buffer.deinit(allocator);
    var soft_blend: ?fuse.blend.SoftBlendState = null;
    defer if (soft_blend) |*state| state.deinit(allocator);
    var contrast_workspace: ?fuse.contrast.Workspace = null;
    defer if (contrast_workspace) |*value| value.deinit(allocator);
    var norm_weight_sums = std.ArrayListUnmanaged(f32){};
    defer norm_weight_sums.deinit(allocator);
    var union_support = std.ArrayListUnmanaged(f32){};
    defer union_support.deinit(allocator);
    var pyramid_accumulator: ?fuse.pyramid.Accumulator = null;
    defer if (pyramid_accumulator) |*value| value.deinit(allocator);

    var output: ?align_core.image_io.Image = null;
    defer if (output) |*image| image.deinit(allocator);

    const output_path = cfg.output_path.?;
    if (std.fs.path.dirname(output_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    switch (cfg.fuse_method) {
        .hardmask_contrast, .softmask_contrast => {
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
                    try gray_buffer.resize(allocator, count);
                    try support_buffer.resize(allocator, count);
                    try weight_buffer.resize(allocator, count);
                    switch (cfg.fuse_method) {
                        .hardmask_contrast => {
                            try best_weights.resize(allocator, count);
                            @memset(best_weights.items, -std.math.inf(f32));
                        },
                        .softmask_contrast => {
                            try smoothed_weight_buffer.resize(allocator, count);
                            soft_blend = try fuse.blend.SoftBlendState.init(allocator, output.?.info);
                        },
                        .pyramid_contrast => unreachable,
                    }
                    contrast_workspace = try fuse.contrast.Workspace.init(allocator, remapped.info.width, jobs);
                }

                try computeWeightMapForRemapped(cfg, jobs, &remapped, gray_buffer.items, support_buffer.items, weight_buffer.items, &(contrast_workspace.?));
                var weights = fuse.contrast.WeightMap{
                    .width = remapped.info.width,
                    .height = remapped.info.height,
                    .pixels = weight_buffer.items,
                };
                switch (cfg.fuse_method) {
                    .hardmask_contrast => try fuse.blend.updateWinners(allocator, &remapped, &weights, best_weights.items, &output.?, jobs),
                    .softmask_contrast => {
                        fuse.masks.applySupportInto(&remapped, weight_buffer.items);
                        try fuse.masks.blurFiveTapInto(allocator, remapped.info.width, remapped.info.height, jobs, weight_buffer.items, smoothed_weight_buffer.items, weight_buffer.items);
                        try fuse.blend.accumulateSoft(allocator, &remapped, weight_buffer.items, &soft_blend.?, jobs);
                    },
                    .pyramid_contrast => unreachable,
                }
            }
            switch (cfg.fuse_method) {
                .hardmask_contrast => {},
                .softmask_contrast => fuse.blend.finalizeSoft(&soft_blend.?, &output.?),
                .pyramid_contrast => unreachable,
            }
        },
        .pyramid_contrast => {
            try runPyramidStackFusion(allocator, cfg, images, plan, poses, roi, jobs, &gray_buffer, &support_buffer, &weight_buffer, &norm_weight_sums, &union_support, &output, &pyramid_accumulator);
            const collapsed_info = fusedOutputInfo(output.?.info);
            output.?.deinit(allocator);
            output = try fuse.pyramid.collapseToImageWithJobsAndDebug(
                allocator,
                collapsed_info,
                &pyramid_accumulator.?,
                jobs,
                cfg.dump_masks_dir,
            );
        },
    }

    if (cfg.verbose > 0) {
        std.debug.print("stack fuse: writing {s}\n", .{output_path});
    }
    try align_core.image_io.writeTiff(output_path, &output.?);
}

fn runPyramidStackFusion(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    images: []const align_core.sequence.InputImage,
    plan: *const align_core.sequence.Plan,
    poses: []const align_core.optimize.ImagePose,
    roi: ?align_core.remap.Rect,
    jobs: usize,
    gray_buffer: *std.ArrayListUnmanaged(f32),
    support_buffer: *std.ArrayListUnmanaged(f32),
    weight_buffer: *std.ArrayListUnmanaged(f32),
    norm_weight_sums: *std.ArrayListUnmanaged(f32),
    union_support: *std.ArrayListUnmanaged(f32),
    output: *?align_core.image_io.Image,
    pyramid_accumulator: *?fuse.pyramid.Accumulator,
) RunError!void {
    const prof = align_core.profiler.scope("stack.pipeline.runPyramidStackFusion");
    defer prof.end();

    var active_indices = std.ArrayListUnmanaged(usize){};
    defer active_indices.deinit(allocator);
    for (plan.ordered_indices.items) |image_index| {
        if (plan.remap_active.items[image_index]) {
            try active_indices.append(allocator, image_index);
        }
    }

    var cached_remapped = std.ArrayListUnmanaged(align_core.image_io.Image){};
    defer {
        for (cached_remapped.items) |*image| image.deinit(allocator);
        cached_remapped.deinit(allocator);
    }
    var workspace: ?fuse.pyramid.Workspace = null;
    defer if (workspace) |*value| value.deinit(allocator);
    var contrast_workspace: ?fuse.contrast.Workspace = null;
    defer if (contrast_workspace) |*value| value.deinit(allocator);
    var debug_mask_sum_levels: ?[]fuse.pyramid.ScalarLevel = null;
    defer if (debug_mask_sum_levels) |levels| {
        for (levels) |*level| level.deinit(allocator);
        allocator.free(levels);
    };
    var cache_images = false;
    const debug_level_index = active_indices.items.len / 2;

    for (active_indices.items, 0..) |image_index, active_i| {
        if (cfg.verbose > 0) {
            std.debug.print("stack fuse: [{d}] remapping {s} for weight normalization\n", .{ active_i + 1, images[image_index].path });
        }
        var src = try align_core.image_io.loadImage(allocator, images[image_index].path);
        defer src.deinit(allocator);
        var remapped = try align_core.remap.remapRigidImage(allocator, &src, poses[image_index], roi, jobs);
        var keep_remapped = false;
        errdefer if (!keep_remapped) remapped.deinit(allocator);

        if (output.* == null) {
            output.* = try fuse.blend.allocateOutput(allocator, fusedOutputInfo(remapped.info));
            const count = @as(usize, remapped.info.width) * @as(usize, remapped.info.height);
            try gray_buffer.resize(allocator, count);
            try support_buffer.resize(allocator, count);
            try weight_buffer.resize(allocator, count);
            try norm_weight_sums.resize(allocator, count);
            try union_support.resize(allocator, count);
            @memset(norm_weight_sums.items, 0);
            @memset(union_support.items, 0);
            pyramid_accumulator.* = try fuse.pyramid.Accumulator.init(allocator, remapped.info.width, remapped.info.height);
            workspace = try fuse.pyramid.Workspace.init(allocator, remapped.info.width, remapped.info.height);
            contrast_workspace = try fuse.contrast.Workspace.init(allocator, remapped.info.width, jobs);
            if (cfg.dump_masks_dir != null) {
                const template_levels = workspace.?.mask_levels;
                const levels = try allocator.alloc(fuse.pyramid.ScalarLevel, template_levels.len);
                errdefer allocator.free(levels);
                for (template_levels, 0..) |template_level, i| {
                    const level_count = @as(usize, template_level.width) * @as(usize, template_level.height);
                    levels[i] = .{
                        .width = template_level.width,
                        .height = template_level.height,
                        .pixels = try allocator.alloc(f32, level_count),
                    };
                    @memset(levels[i].pixels, 0);
                }
                debug_mask_sum_levels = levels;
            }
            cache_images = estimatedCacheBytes(remapped.info, active_indices.items.len) <= max_cached_pyramid_bytes;
            if (cfg.verbose > 0 and cache_images) {
                std.debug.print("stack fuse: caching remapped images in memory for pyramid blend\n", .{});
            }
        }

        try computeWeightMapForRemapped(cfg, jobs, &remapped, gray_buffer.items, support_buffer.items, weight_buffer.items, &(contrast_workspace.?));
        fuse.masks.applySupportInto(&remapped, weight_buffer.items);
        fuse.masks.accumulateBinarySupportMax(&remapped, union_support.items);
        for (norm_weight_sums.items, weight_buffer.items) |*sum, weight| sum.* += weight;
        if (cache_images) {
            try cached_remapped.append(allocator, remapped);
            keep_remapped = true;
        }
    }

    if (cfg.dump_masks_dir) |dump_dir| {
        try fuse.debug.dumpPyramidScalars(
            allocator,
            dump_dir,
            output.*.?.info.width,
            output.*.?.info.height,
            norm_weight_sums.items,
            union_support.items,
        );
    }

    if (cache_images) {
        for (cached_remapped.items, 0..) |*remapped, active_i| {
            if (cfg.verbose > 0) {
                std.debug.print("stack fuse: [{d}] pyramid blend from cached remap\n", .{ active_i + 1 });
            }
            try computeWeightMapForRemapped(cfg, jobs, remapped, gray_buffer.items, support_buffer.items, weight_buffer.items, &(contrast_workspace.?));
            fuse.masks.applySupportInto(remapped, weight_buffer.items);
            if (cfg.dump_masks_dir) |dump_dir| {
                try fuse.debug.dumpRawMask(
                    allocator,
                    dump_dir,
                    remapped.info.width,
                    remapped.info.height,
                    active_i,
                    weight_buffer.items,
                    fuse.grayscale.sampleScaleForType(remapped.info.sample_type),
                );
            }
            fuse.pyramid.normalizeWeightsInto(weight_buffer.items, norm_weight_sums.items, active_indices.items.len, gray_buffer.items);
            if (cfg.dump_masks_dir) |dump_dir| {
                try fuse.debug.dumpNormalizedMask(
                    allocator,
                    dump_dir,
                    remapped.info.width,
                    remapped.info.height,
                    active_i,
                    gray_buffer.items,
                );
            }
            try fuse.pyramid.accumulateImageWithWorkspace(allocator, remapped, gray_buffer.items, union_support.items, &pyramid_accumulator.*.?, &workspace.?, jobs);
            if (debug_mask_sum_levels) |levels| {
                for (levels, workspace.?.mask_levels) |*dst_level, src_level| {
                    for (dst_level.pixels, src_level.pixels) |*dst, src_value| dst.* += src_value;
                }
            }
            if (cfg.dump_masks_dir) |dump_dir| {
                if (active_i == debug_level_index) {
                    try fuse.debug.dumpWorkspaceLevels(allocator, dump_dir, active_i, &workspace.?);
                }
            }
        }
    } else {
        for (active_indices.items, 0..) |image_index, active_i| {
            if (cfg.verbose > 0) {
                std.debug.print("stack fuse: [{d}] remapping {s} for pyramid blend\n", .{ active_i + 1, images[image_index].path });
            }
            var src = try align_core.image_io.loadImage(allocator, images[image_index].path);
            defer src.deinit(allocator);
            var remapped = try align_core.remap.remapRigidImage(allocator, &src, poses[image_index], roi, jobs);
            defer remapped.deinit(allocator);

            try computeWeightMapForRemapped(cfg, jobs, &remapped, gray_buffer.items, support_buffer.items, weight_buffer.items, &(contrast_workspace.?));
            fuse.masks.applySupportInto(&remapped, weight_buffer.items);
            if (cfg.dump_masks_dir) |dump_dir| {
                try fuse.debug.dumpRawMask(
                    allocator,
                    dump_dir,
                    remapped.info.width,
                    remapped.info.height,
                    active_i,
                    weight_buffer.items,
                    fuse.grayscale.sampleScaleForType(remapped.info.sample_type),
                );
            }
            fuse.pyramid.normalizeWeightsInto(weight_buffer.items, norm_weight_sums.items, active_indices.items.len, gray_buffer.items);
            if (cfg.dump_masks_dir) |dump_dir| {
                try fuse.debug.dumpNormalizedMask(
                    allocator,
                    dump_dir,
                    remapped.info.width,
                    remapped.info.height,
                    active_i,
                    gray_buffer.items,
                );
            }
            try fuse.pyramid.accumulateImageWithWorkspace(allocator, &remapped, gray_buffer.items, union_support.items, &pyramid_accumulator.*.?, &workspace.?, jobs);
            if (debug_mask_sum_levels) |levels| {
                for (levels, workspace.?.mask_levels) |*dst_level, src_level| {
                    for (dst_level.pixels, src_level.pixels) |*dst, src_value| dst.* += src_value;
                }
            }
            if (cfg.dump_masks_dir) |dump_dir| {
                if (active_i == debug_level_index) {
                    try fuse.debug.dumpWorkspaceLevels(allocator, dump_dir, active_i, &workspace.?);
                }
            }
        }
    }

    if (cfg.dump_masks_dir) |dump_dir| {
        try fuse.debug.dumpAccumulatorLevels(allocator, dump_dir, &pyramid_accumulator.*.?);
        if (debug_mask_sum_levels) |levels| {
            try fuse.debug.dumpScalarLevels(allocator, dump_dir, "mask_sum_levels", "mask_sum", levels);
        }
    }
}

fn computeWeightMapForRemapped(
    cfg: *const config.Config,
    jobs: usize,
    remapped: *const align_core.image_io.Image,
    gray_pixels: []f32,
    support_pixels: []f32,
    weights: []f32,
    workspace: *fuse.contrast.Workspace,
) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
    fuse.grayscale.fillAverageFromLoaded(gray_pixels, remapped);
    fuse.masks.fillBinarySupport(remapped, support_pixels);
    var gray_image = align_core.gray.GrayImage{
        .width = remapped.info.width,
        .height = remapped.info.height,
        .pixels = gray_pixels,
        .sample_scale = fuse.grayscale.sampleScaleForType(remapped.info.sample_type),
    };
    try fuse.contrast.computeLocalContrastWeightsWithWorkspace(&gray_image, support_pixels, cfg.contrast_window_size, jobs, weights, workspace);
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

fn estimatedCacheBytes(info: align_core.image_io.ImageInfo, image_count: usize) usize {
    const sample_bytes: usize = switch (info.sample_type) {
        .u8 => 1,
        .u16 => 2,
    };
    const pixel_bytes = @as(usize, info.width) * @as(usize, info.height) * @as(usize, info.color_channels + info.extra_channels) * sample_bytes;
    return pixel_bytes * image_count;
}
