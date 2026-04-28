const std = @import("std");
const sparse_matrix = @import("sparse_matrix.zig");
const optimize = @import("optimize.zig");
const parity_pto = @import("parity_pto.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        usage();
    }

    const command = args[1];
    const pto_path = args[2];

    var project = try parity_pto.parseFile(allocator, pto_path);
    defer project.deinit(allocator);

    const base_poses = try collectBasePoses(allocator, project.images);
    defer allocator.free(base_poses);

    if (std.mem.eql(u8, command, "lm-params")) {
        const solve_x = try optimize.encodeSolveVector(allocator, project.optimize_vector, base_poses);
        defer allocator.free(solve_x);
        try printVector(solve_x);
        return;
    }

    if (std.mem.eql(u8, command, "linear-seed-lm-params")) {
        const seed_poses = try optimize.buildLinearSeedPoses(
            allocator,
            project.images.len,
            base_poses[0].base_hfov_degrees,
            project.optimize_vector,
            project.pair_matches,
        );
        defer allocator.free(seed_poses);
        const solve_x = try optimize.encodeSolveVector(allocator, project.optimize_vector, seed_poses);
        defer allocator.free(solve_x);
        try printVector(solve_x);
        return;
    }

    if (std.mem.eql(u8, command, "solve-lm-params")) {
        const decoded_initial_poses = if (args.len > 3)
            try decodeInitialPoses(allocator, project.optimize_vector, base_poses, args[3..])
        else
            null;
        defer if (decoded_initial_poses) |poses| allocator.free(poses);
        const initial_poses = decoded_initial_poses orelse base_poses;
        const result = try optimize.solvePosesFromInitial(
            allocator,
            project.images.len,
            project.pano_hfov_degrees,
            project.optimize_vector,
            project.pair_matches,
            initial_poses,
        );
        defer allocator.free(result.poses);
        defer allocator.free(result.residuals);
        const solve_x = try optimize.encodeSolveVector(allocator, project.optimize_vector, result.poses);
        defer allocator.free(solve_x);
        try printVector(solve_x);
        return;
    }

    if (std.mem.eql(u8, command, "image-vars")) {
        const solve_x = try collectSolveVector(allocator, args[3..], project.optimize_vector, base_poses);
        defer allocator.free(solve_x);
        const poses = try optimize.decodeSolveVector(allocator, project.optimize_vector, base_poses, solve_x);
        defer allocator.free(poses);
        try printImageVars(poses);
        return;
    }

    if (std.mem.eql(u8, command, "equirect-point")) {
        if (args.len < 6) usage();
        const image_index = try std.fmt.parseInt(usize, args[3], 10);
        const x = try std.fmt.parseFloat(f64, args[4]);
        const y = try std.fmt.parseFloat(f64, args[5]);
        if (image_index >= project.images.len) return error.ImageIndexOutOfRange;
        const solve_x = try collectSolveVector(allocator, args[6..], project.optimize_vector, base_poses);
        defer allocator.free(solve_x);
        const poses = try optimize.decodeSolveVector(allocator, project.optimize_vector, base_poses, solve_x);
        defer allocator.free(poses);
        const image = project.images[image_index];
        const point = optimize.imagePointToEquirectDegrees(poses[image_index], x, y, image.width, image.height);
        std.debug.print("lon={d:.12}\nlat={d:.12}\n", .{ point.x, point.y });
        return;
    }

    if (std.mem.eql(u8, command, "fvec")) {
        if (args.len < 4) usage();
        const strategy = try parseStrategy(args[3]);
        const solve_x = try collectSolveVector(allocator, args[4..], project.optimize_vector, base_poses);
        defer allocator.free(solve_x);
        const poses = try optimize.decodeSolveVector(allocator, project.optimize_vector, base_poses, solve_x);
        defer allocator.free(poses);
        const initial_avg_hfov = optimize.averageHfovDegrees(base_poses);
        const fvec = try optimize.evaluateObjectiveResidualsPadded(
            allocator,
            strategy,
            initial_avg_hfov,
            project.pair_matches,
            poses,
            optimize.countSolveParameters(project.optimize_vector),
        );
        defer allocator.free(fvec);
        try printVector(fvec);
        return;
    }

    if (std.mem.eql(u8, command, "jac-pattern-stats")) {
        if (args.len < 4) usage();
        const strategy = try parseStrategy(args[3]);
        var pattern = try optimize.buildObjectiveJacobianPattern(allocator, project.optimize_vector, project.pair_matches, strategy);
        defer pattern.deinit(allocator);
        var groups = try sparse_matrix.partitionIndependentColumns(allocator, &pattern);
        defer groups.deinit(allocator);
        var max_group_size: usize = 0;
        for (0..groups.groupCount()) |group_index| {
            max_group_size = @max(max_group_size, groups.groupColumns(group_index).len);
        }
        std.debug.print(
            "rows={d}\ncols={d}\nnnz={d}\ngroups={d}\nmax_group_size={d}\n",
            .{ pattern.row_count, pattern.col_count, pattern.row_idx.len, groups.groupCount(), max_group_size },
        );
        return;
    }

    if (std.mem.eql(u8, command, "jac-column")) {
        if (args.len < 5) usage();
        const strategy = try parseStrategy(args[3]);
        const parameter_index = try std.fmt.parseInt(usize, args[4], 10);
        const solve_x = try collectSolveVector(allocator, args[5..], project.optimize_vector, base_poses);
        defer allocator.free(solve_x);
        const column = try evaluateJacobianColumn(allocator, strategy, project.optimize_vector, base_poses, project.pair_matches, solve_x, parameter_index);
        defer allocator.free(column);
        try printVector(column);
        return;
    }

    if (std.mem.eql(u8, command, "cp-error")) {
        if (args.len < 4) usage();
        const cp_index = try std.fmt.parseInt(usize, args[3], 10);
        const solve_x = try collectSolveVector(allocator, args[4..], project.optimize_vector, base_poses);
        defer allocator.free(solve_x);
        const poses = try optimize.decodeSolveVector(allocator, project.optimize_vector, base_poses, solve_x);
        defer allocator.free(poses);
        const located = try locateControlPoint(project.pair_matches, cp_index);
        const error_value = optimize.evaluateControlPointError(poses, project.pair_matches[located.pair_index], located.cp);
        std.debug.print(
            "distance={d:.12}\ncomponent_x={d:.12}\ncomponent_y={d:.12}\n",
            .{ error_value.distance, error_value.components.x, error_value.components.y },
        );
        return;
    }

    usage();
}

fn usage() noreturn {
    std.debug.print(
        \\usage:
        \\  parity_probe lm-params <pto>
        \\  parity_probe linear-seed-lm-params <pto>
        \\  parity_probe solve-lm-params <pto>
        \\  parity_probe image-vars <pto> [x...]
        \\  parity_probe equirect-point <pto> <image_index> <x> <y> [x...]
        \\  parity_probe fvec <pto> <distance_only|componentwise|1|2> [x...]
        \\  parity_probe jac-pattern-stats <pto> <distance_only|componentwise|1|2>
        \\  parity_probe jac-column <pto> <distance_only|componentwise|1|2> <param_index> [x...]
        \\  parity_probe cp-error <pto> <cp_index> [x...]
        \\
    , .{});
    std.process.exit(1);
}

fn collectBasePoses(allocator: std.mem.Allocator, images: []const parity_pto.ImageEntry) ![]optimize.ImagePose {
    const poses = try allocator.alloc(optimize.ImagePose, images.len);
    for (images, poses) |image, *pose| {
        pose.* = image.pose;
    }
    return poses;
}

fn collectSolveVector(
    allocator: std.mem.Allocator,
    trailing_args: []const []const u8,
    optimize_vector: []const optimize.VariableSet,
    base_poses: []const optimize.ImagePose,
) ![]f64 {
    if (trailing_args.len == 0) {
        return optimize.encodeSolveVector(allocator, optimize_vector, base_poses);
    }

    const expected = optimize.countSolveParameters(optimize_vector);
    if (trailing_args.len != expected) usage();

    const values = try allocator.alloc(f64, expected);
    for (trailing_args, values) |arg, *value| {
        value.* = try std.fmt.parseFloat(f64, arg);
    }
    return values;
}

fn decodeInitialPoses(
    allocator: std.mem.Allocator,
    optimize_vector: []const optimize.VariableSet,
    base_poses: []const optimize.ImagePose,
    trailing_args: []const []const u8,
) ![]optimize.ImagePose {
    const solve_x = try collectSolveVector(allocator, trailing_args, optimize_vector, base_poses);
    defer allocator.free(solve_x);
    return optimize.decodeSolveVector(allocator, optimize_vector, base_poses, solve_x);
}

fn parseStrategy(value: []const u8) !optimize.ObjectiveStrategy {
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "distance_only")) {
        return .distance_only;
    }
    if (std.mem.eql(u8, value, "2") or std.mem.eql(u8, value, "componentwise")) {
        return .componentwise;
    }
    return error.InvalidStrategy;
}

fn printVector(values: []const f64) !void {
    for (values, 0..) |value, index| {
        std.debug.print("{d}: {d:.12}\n", .{ index, value });
    }
}

fn evaluateJacobianColumn(
    allocator: std.mem.Allocator,
    strategy: optimize.ObjectiveStrategy,
    optimize_vector: []const optimize.VariableSet,
    base_poses: []const optimize.ImagePose,
    pair_matches: []const match_mod.PairMatches,
    solve_x: []const f64,
    parameter_index: usize,
) ![]f64 {
    if (parameter_index >= solve_x.len) return error.ParameterOutOfRange;

    const initial_avg_hfov = optimize.averageHfovDegrees(base_poses);
    const residual_count = optimize.countSolveParameters(optimize_vector);

    const base_poses_eval = try optimize.decodeSolveVector(allocator, optimize_vector, base_poses, solve_x);
    defer allocator.free(base_poses_eval);
    const fvec = try optimize.evaluateObjectiveResidualsPadded(
        allocator,
        strategy,
        initial_avg_hfov,
        pair_matches,
        base_poses_eval,
        residual_count,
    );
    defer allocator.free(fvec);

    const shifted_x = try allocator.dupe(f64, solve_x);
    defer allocator.free(shifted_x);
    const eps = @sqrt(@max(std.math.floatEps(f64) * 10.0, std.math.floatEps(f64)));
    var h = eps * @abs(shifted_x[parameter_index]);
    if (h == 0.0) h = eps;
    shifted_x[parameter_index] += h;

    const shifted_poses = try optimize.decodeSolveVector(allocator, optimize_vector, base_poses, shifted_x);
    defer allocator.free(shifted_poses);
    const shifted_fvec = try optimize.evaluateObjectiveResidualsPadded(
        allocator,
        strategy,
        initial_avg_hfov,
        pair_matches,
        shifted_poses,
        residual_count,
    );
    defer allocator.free(shifted_fvec);

    const column = try allocator.alloc(f64, fvec.len);
    for (column, fvec, shifted_fvec) |*out, base_value, shifted_value| {
        out.* = (shifted_value - base_value) / h;
    }
    return column;
}

fn printImageVars(poses: []const optimize.ImagePose) !void {
    for (poses, 0..) |pose, index| {
        std.debug.print(
            "[{d}] y={d:.12} p={d:.12} r={d:.12} v={d:.12} a={d:.12} b={d:.12} c={d:.12} d={d:.12} e={d:.12} TrX={d:.12} TrY={d:.12} TrZ={d:.12} Tpy={d:.12} Tpp={d:.12}\n",
            .{
                index,
                radiansToDegrees(pose.yaw),
                radiansToDegrees(pose.pitch),
                radiansToDegrees(pose.roll),
                pose.base_hfov_degrees + pose.hfov_delta,
                pose.radial_a,
                pose.radial_b,
                pose.radial_c,
                pose.center_shift_x,
                pose.center_shift_y,
                pose.trans_x,
                pose.trans_y,
                pose.trans_z,
                radiansToDegrees(pose.translation_plane_yaw),
                radiansToDegrees(pose.translation_plane_pitch),
            },
        );
    }
}

fn radiansToDegrees(value: f64) f64 {
    return value * 180.0 / std.math.pi;
}

const LocatedControlPoint = struct {
    pair_index: usize,
    cp: match_mod.ControlPoint,
};

const match_mod = @import("match.zig");

fn locateControlPoint(pair_matches: []const match_mod.PairMatches, flat_index: usize) !LocatedControlPoint {
    var index = flat_index;
    for (pair_matches, 0..) |pair_match, pair_index| {
        if (index < pair_match.control_points.len) {
            return .{
                .pair_index = pair_index,
                .cp = pair_match.control_points[index],
            };
        }
        index -= pair_match.control_points.len;
    }
    return error.ControlPointOutOfRange;
}
