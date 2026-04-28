const std = @import("std");
const core = @import("align_stack_core");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 4) usage();
    const command = args[1];
    if (!std.mem.eql(u8, command, "compare-solve")) usage();

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

    var live_timer = try std.time.Timer.start();
    var live_result = try core.optimize.solvePoses(allocator, images.len, base_hfov, optimize_vector, pair_matches);
    defer live_result.deinit(allocator);
    const live_ns = live_timer.read();

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

    std.debug.print(
        "control_points={d}\nlive_ms={d:.3}\nroundtrip_ms={d:.3}\nlive_rms={d:.6}\nroundtrip_rms={d:.6}\n",
        .{
            live_result.control_point_count,
            @as(f64, @floatFromInt(live_ns)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(roundtrip_ns)) / std.time.ns_per_ms,
            live_result.rms_error,
            roundtrip_result.rms_error,
        },
    );
}

fn collectBasePoses(allocator: std.mem.Allocator, images: []const core.parity_pto.ImageEntry) ![]core.optimize.ImagePose {
    const poses = try allocator.alloc(core.optimize.ImagePose, images.len);
    for (images, poses) |image, *pose| {
        pose.* = image.pose;
    }
    return poses;
}

fn usage() noreturn {
    std.debug.print("usage: live_probe compare-solve <image1> <image2> [image...]\n", .{});
    std.process.exit(1);
}
