const std = @import("std");
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

    if (std.mem.eql(u8, command, "image-vars")) {
        const solve_x = try collectSolveVector(allocator, args[3..], project.optimize_vector, base_poses);
        defer allocator.free(solve_x);
        const poses = try optimize.decodeSolveVector(allocator, project.optimize_vector, base_poses, solve_x);
        defer allocator.free(poses);
        try printImageVars(poses);
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
        const fvec = try optimize.evaluateObjectiveResiduals(allocator, strategy, initial_avg_hfov, project.pair_matches, poses);
        defer allocator.free(fvec);
        try printVector(fvec);
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
        \\  parity_probe image-vars <pto> [x...]
        \\  parity_probe fvec <pto> <distance_only|componentwise|1|2> [x...]
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
