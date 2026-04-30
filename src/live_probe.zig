const std = @import("std");
const core = @import("root.zig");

pub fn main() !void {
    const allocator = core.alloc_profiler.wrap(std.heap.page_allocator);
    defer writeProfilerReport();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) usage();
    const command = args[1];
    if (std.mem.eql(u8, command, "pto-solve")) {
        if (args.len != 3) usage();
        var project = try core.parity_pto.parseFile(allocator, args[2]);
        defer project.deinit(allocator);
        const seed_poses = try core.optimize.buildLinearSeedPoses(
            allocator,
            project.images.len,
            project.pano_hfov_degrees,
            project.optimize_vector,
            project.pair_matches,
        );
        defer allocator.free(seed_poses);
        var timer = try std.time.Timer.start();
        var result = try core.optimize.solvePosesFromInitial(
            allocator,
            project.images.len,
            project.pano_hfov_degrees,
            project.optimize_vector,
            project.pair_matches,
            seed_poses,
        );
        defer result.deinit(allocator);
        const elapsed_ns = timer.read();
        std.debug.print(
            "pto_ms={d:.3}\nrms={d:.6}\ncontrol_points={d}\n",
            .{
                @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms,
                result.rms_error,
                result.control_point_count,
            },
        );
        printLmStats("pto.distance", result.distance_lm);
        printLmStats("pto.component", result.component_lm);
        return;
    }
    if (std.mem.eql(u8, command, "pto-seed")) {
        if (args.len != 3) usage();
        var project = try core.parity_pto.parseFile(allocator, args[2]);
        defer project.deinit(allocator);
        const seed_poses = try core.optimize.buildLinearSeedPoses(
            allocator,
            project.images.len,
            project.pano_hfov_degrees,
            project.optimize_vector,
            project.pair_matches,
        );
        defer allocator.free(seed_poses);
        const solve_x = try core.optimize.encodeSolveVector(allocator, project.optimize_vector, seed_poses);
        defer allocator.free(solve_x);
        try printVector(solve_x);
        return;
    }
    if (std.mem.eql(u8, command, "pto-fvec")) {
        if (args.len != 4) usage();
        var project = try core.parity_pto.parseFile(allocator, args[2]);
        defer project.deinit(allocator);
        const seed_poses = try core.optimize.buildLinearSeedPoses(
            allocator,
            project.images.len,
            project.pano_hfov_degrees,
            project.optimize_vector,
            project.pair_matches,
        );
        defer allocator.free(seed_poses);
        const strategy = try parseStrategy(args[3]);
        const fvec = try core.optimize.evaluateObjectiveResidualsPadded(
            allocator,
            strategy,
            core.optimize.averageHfovDegrees(seed_poses),
            project.pair_matches,
            seed_poses,
            core.optimize.countSolveParameters(project.optimize_vector),
        );
        defer allocator.free(fvec);
        try printVector(fvec);
        return;
    }
    if (std.mem.eql(u8, command, "pto-fvec-uncached")) {
        if (args.len != 4) usage();
        var project = try core.parity_pto.parseFile(allocator, args[2]);
        defer project.deinit(allocator);
        const seed_poses = try core.optimize.buildLinearSeedPoses(
            allocator,
            project.images.len,
            project.pano_hfov_degrees,
            project.optimize_vector,
            project.pair_matches,
        );
        defer allocator.free(seed_poses);
        const strategy = try parseStrategy(args[3]);
        const fvec = try core.optimize.evaluateObjectiveResidualsPaddedUncached(
            allocator,
            strategy,
            core.optimize.averageHfovDegrees(seed_poses),
            project.pair_matches,
            seed_poses,
            core.optimize.countSolveParameters(project.optimize_vector),
        );
        defer allocator.free(fvec);
        try printVector(fvec);
        return;
    }
    if (std.mem.eql(u8, command, "pto-equirect-point")) {
        if (args.len != 6) usage();
        var project = try core.parity_pto.parseFile(allocator, args[2]);
        defer project.deinit(allocator);
        const seed_poses = try core.optimize.buildLinearSeedPoses(
            allocator,
            project.images.len,
            project.pano_hfov_degrees,
            project.optimize_vector,
            project.pair_matches,
        );
        defer allocator.free(seed_poses);
        const image_index = try std.fmt.parseInt(usize, args[3], 10);
        const x = try std.fmt.parseFloat(f64, args[4]);
        const y = try std.fmt.parseFloat(f64, args[5]);
        if (image_index >= project.images.len) return error.ImageIndexOutOfRange;
        const image = project.images[image_index];
        const point = core.optimize.imagePointToEquirectDegrees(seed_poses[image_index], x, y, image.width, image.height);
        std.debug.print("lon={d:.12}\nlat={d:.12}\n", .{ point.x, point.y });
        return;
    }
    if (!std.mem.eql(u8, command, "compare-solve")) usage();
    if (args.len < 4) usage();

    var cfg = core.config.Config{
        .optimize_hfov = true,
        .pto_file = "unused.pto",
    };
    defer cfg.deinit(allocator);
    try cfg.input_files.appendSlice(allocator, args[2..]);

    const images = try core.pipeline.collectInputImages(allocator, &cfg);
    defer allocator.free(images);
    const base_hfov = cfg.hfov orelse images[0].hfov_degrees orelse 50.0;

    var plan = try core.sequence.buildPlan(allocator, &cfg, images);
    defer plan.deinit(allocator);
    const optimize_vector = try core.optimize.buildOptimizeVector(allocator, &cfg, images.len);
    defer allocator.free(optimize_vector);
    const pair_matches = try core.pipeline.analyzePairs(allocator, &cfg, images, &plan);
    defer {
        for (pair_matches) |*entry| entry.deinit(allocator);
        allocator.free(pair_matches);
    }

    const seed_poses = try core.optimize.buildLinearSeedPoses(
        allocator,
        images.len,
        base_hfov,
        optimize_vector,
        pair_matches,
    );
    defer allocator.free(seed_poses);
    const rendered = try core.pto.renderPto(allocator, &cfg, images, optimize_vector, pair_matches, seed_poses);
    defer allocator.free(rendered);

    var project = try core.parity_pto.parse(allocator, rendered);
    defer project.deinit(allocator);
    const base_poses = try collectBasePoses(allocator, project.images);
    defer allocator.free(base_poses);
    const reseeded_poses = try core.optimize.buildLinearSeedPoses(
        allocator,
        project.images.len,
        project.pano_hfov_degrees,
        project.optimize_vector,
        project.pair_matches,
    );
    defer allocator.free(reseeded_poses);

    var roundtrip_timer = try std.time.Timer.start();
    var roundtrip_result = try core.optimize.solvePosesFromInitial(
        allocator,
        project.images.len,
        project.pano_hfov_degrees,
        project.optimize_vector,
        project.pair_matches,
        base_poses,
    );
    defer roundtrip_result.deinit(allocator);
    const roundtrip_ns = roundtrip_timer.read();

    var reseeded_timer = try std.time.Timer.start();
    var reseeded_result = try core.optimize.solvePosesFromInitial(
        allocator,
        project.images.len,
        project.pano_hfov_degrees,
        project.optimize_vector,
        project.pair_matches,
        reseeded_poses,
    );
    defer reseeded_result.deinit(allocator);
    const reseeded_ns = reseeded_timer.read();

    var live_timer = try std.time.Timer.start();
    var live_result = try core.optimize.solvePoses(allocator, images.len, base_hfov, optimize_vector, pair_matches);
    defer live_result.deinit(allocator);
    const live_ns = live_timer.read();

    std.debug.print(
        "control_points={d}\nlive_ms={d:.3}\nroundtrip_ms={d:.3}\nreseeded_ms={d:.3}\nlive_rms={d:.6}\nroundtrip_rms={d:.6}\nreseeded_rms={d:.6}\n",
        .{
            live_result.control_point_count,
            @as(f64, @floatFromInt(live_ns)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(roundtrip_ns)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(reseeded_ns)) / std.time.ns_per_ms,
            live_result.rms_error,
            roundtrip_result.rms_error,
            reseeded_result.rms_error,
        },
    );
    printLmStats("live.distance", live_result.distance_lm);
    printLmStats("live.component", live_result.component_lm);
    printLmStats("roundtrip.distance", roundtrip_result.distance_lm);
    printLmStats("roundtrip.component", roundtrip_result.component_lm);
    printLmStats("reseeded.distance", reseeded_result.distance_lm);
    printLmStats("reseeded.component", reseeded_result.component_lm);
}

fn writeProfilerReport() void {
    if (!core.alloc_profiler.enabled) return;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    core.alloc_profiler.maybeWriteReport(&stderr_writer.interface) catch {};
    stderr_writer.interface.flush() catch {};
}

fn collectBasePoses(allocator: std.mem.Allocator, images: []const core.parity_pto.ImageEntry) ![]core.optimize.ImagePose {
    const poses = try allocator.alloc(core.optimize.ImagePose, images.len);
    for (images, poses) |image, *pose| {
        pose.* = image.pose;
    }
    return poses;
}

fn usage() noreturn {
    std.debug.print("usage: live_probe compare-solve <image1> <image2> [image...]\n       live_probe pto-solve <pto>\n       live_probe pto-seed <pto>\n       live_probe pto-fvec <pto> <distance_only|componentwise>\n       live_probe pto-fvec-uncached <pto> <distance_only|componentwise>\n       live_probe pto-equirect-point <pto> <image_index> <x> <y>\n", .{});
    std.process.exit(1);
}

fn printLmStats(label: []const u8, result: core.minpack.Result) void {
    std.debug.print(
        "{s}: info={d} nfev={d} outer={d} trial={d} accepted={d} lmpar_iter={d} jac_eval={d}\n",
        .{
            label,
            result.info,
            result.nfev,
            result.outer_iterations,
            result.trial_steps,
            result.accepted_steps,
            result.lmpar_iterations,
            result.jacobian_evaluations,
        },
    );
}

fn printVector(values: []const f64) !void {
    for (values, 0..) |value, index| {
        std.debug.print("{d}: {d:.12}\n", .{ index, value });
    }
}

fn parseStrategy(value: []const u8) !core.optimize.ObjectiveStrategy {
    if (std.mem.eql(u8, value, "distance_only") or std.mem.eql(u8, value, "1")) return .distance_only;
    if (std.mem.eql(u8, value, "componentwise") or std.mem.eql(u8, value, "2")) return .componentwise;
    return error.InvalidStrategy;
}
