const std = @import("std");
const config_mod = @import("config.zig");
const match_mod = @import("match.zig");
const minpack_mod = @import("minpack.zig");
const profiler = @import("profiler.zig");
const sparse_matrix = @import("sparse_matrix.zig");

const huber_sigma_pixels: f64 = 0.0;
const radial_solve_space_scale: f64 = 100.0;
const degrees_to_radians: f64 = std.math.pi / 180.0;
const solve_space_relative_epsilon: f64 = @sqrt(std.math.floatEps(f64));

pub const Variable = enum {
    y,
    p,
    r,
    v,
    a,
    b,
    c,
    d,
    e,
    tr_x,
    tr_y,
    tr_z,
    tpy,
    tpp,
};

pub const VariableSet = std.EnumSet(Variable);

pub const ImagePose = struct {
    yaw: f64 = 0,
    pitch: f64 = 0,
    roll: f64 = 0,
    hfov_delta: f64 = 0,
    trans_x: f64 = 0,
    trans_y: f64 = 0,
    trans_z: f64 = 0,
    translation_plane_yaw: f64 = 0,
    translation_plane_pitch: f64 = 0,
    radial_a: f64 = 0,
    radial_b: f64 = 0,
    radial_c: f64 = 0,
    center_shift_x: f64 = 0,
    center_shift_y: f64 = 0,
    base_hfov_degrees: f64 = 50.0,
};

pub const Point2 = struct {
    x: f64,
    y: f64,
};

pub const ControlPointResidual = struct {
    pair_index: usize,
    control_point_index: usize,
    residual: f64,
};

pub const ObjectiveStrategy = enum {
    distance_only,
    componentwise,
};

pub const ControlPointError = struct {
    distance: f64,
    components: Point2,
};

pub const SolveResult = struct {
    poses: []ImagePose,
    residuals: []ControlPointResidual,
    rms_error: f64,
    max_error: f64,
    control_point_count: usize,

    pub fn deinit(self: *SolveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.poses);
        allocator.free(self.residuals);
    }
};

pub const SolveError = error{
    NoControlPoints,
    SingularSystem,
} || std.mem.Allocator.Error;

const variable_order = [_]Variable{
    .y,
    .p,
    .r,
    .v,
    .a,
    .b,
    .c,
    .d,
    .e,
    .tr_x,
    .tr_y,
    .tr_z,
    .tpy,
    .tpp,
};

pub fn buildOptimizeVector(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    image_count: usize,
) std.mem.Allocator.Error![]VariableSet {
    const vector = try allocator.alloc(VariableSet, image_count);
    for (vector, 0..) |*set, image_index| {
        set.* = VariableSet.initEmpty();
        if (image_index == 0) {
            continue;
        }

        set.insert(.y);
        set.insert(.p);
        set.insert(.r);

        if (cfg.optimize_hfov) set.insert(.v);
        if (cfg.optimize_distortion) {
            set.insert(.a);
            set.insert(.b);
            set.insert(.c);
        }
        if (cfg.optimize_center_shift) {
            set.insert(.d);
            set.insert(.e);
        }
        if (cfg.optimize_translation_x) set.insert(.tr_x);
        if (cfg.optimize_translation_y) set.insert(.tr_y);
        if (cfg.optimize_translation_z) set.insert(.tr_z);
    }
    return vector;
}

pub fn renderOptimizeVectorSummary(
    allocator: std.mem.Allocator,
    vector: []const VariableSet,
) std.mem.Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    const writer = list.writer(allocator);

    try writer.writeAll("optimization variables:\n");
    for (vector, 0..) |set, image_index| {
        try writer.print("  image [{d}]:", .{image_index});
        var wrote_any = false;
        for (variable_order) |variable| {
            if (set.contains(variable)) {
                try writer.print(" {s}", .{label(variable)});
                wrote_any = true;
            }
        }
        if (!wrote_any) {
            try writer.writeAll(" <fixed reference>");
        }
        try writer.writeByte('\n');
    }

    return list.toOwnedSlice(allocator);
}

pub fn solvePoses(
    allocator: std.mem.Allocator,
    image_count: usize,
    base_hfov_degrees: f64,
    optimize_vector: []const VariableSet,
    pair_matches: []const match_mod.PairMatches,
) SolveError!SolveResult {
    const prof = profiler.scope("optimize.solvePoses");
    defer prof.end();

    return solvePosesFromInitial(allocator, image_count, base_hfov_degrees, optimize_vector, pair_matches, null);
}

pub fn buildLinearSeedPoses(
    allocator: std.mem.Allocator,
    image_count: usize,
    base_hfov_degrees: f64,
    optimize_vector: []const VariableSet,
    pair_matches: []const match_mod.PairMatches,
) SolveError![]ImagePose {
    const poses = try allocator.alloc(ImagePose, image_count);
    errdefer allocator.free(poses);
    @memset(poses, .{});
    for (poses) |*pose| {
        pose.base_hfov_degrees = base_hfov_degrees;
    }

    const layout = try buildSolveLayout(allocator, optimize_vector);
    defer allocator.free(layout);
    try seedPosesLinear(allocator, layout, pair_matches, poses);
    return poses;
}

pub fn solvePosesFromInitial(
    allocator: std.mem.Allocator,
    image_count: usize,
    base_hfov_degrees: f64,
    optimize_vector: []const VariableSet,
    pair_matches: []const match_mod.PairMatches,
    initial_poses: ?[]const ImagePose,
) SolveError!SolveResult {
    const prof = profiler.scope("optimize.solvePosesFromInitial");
    defer prof.end();

    const control_point_count = countControlPoints(pair_matches);
    if (control_point_count == 0) {
        return error.NoControlPoints;
    }

    const poses = try allocator.alloc(ImagePose, image_count);
    errdefer allocator.free(poses);
    if (initial_poses) |seed| {
        std.debug.assert(seed.len == image_count);
        @memcpy(poses, seed);
        for (poses) |*pose| {
            pose.base_hfov_degrees = base_hfov_degrees;
        }
    } else {
        @memset(poses, .{});
        for (poses) |*pose| {
            pose.base_hfov_degrees = base_hfov_degrees;
        }
    }

    const layout = try buildSolveLayout(allocator, optimize_vector);
    defer allocator.free(layout);

    if (initial_poses == null) {
        try seedPosesLinear(allocator, layout, pair_matches, poses);
    }
    const initial_avg_hfov = currentAverageHfovDegrees(poses);
    try refinePosesIteratively(allocator, layout, pair_matches, poses, initial_avg_hfov, .distance_only);
    try refinePosesIteratively(allocator, layout, pair_matches, poses, initial_avg_hfov, .componentwise);

    const residuals = try allocator.alloc(ControlPointResidual, control_point_count);
    errdefer allocator.free(residuals);

    var cp_flat_index: usize = 0;
    var squared_error_sum: f64 = 0;
    var max_error: f64 = 0;

    for (pair_matches, 0..) |pair_match, pair_index| {
        for (pair_match.control_points, 0..) |cp, control_point_index| {
            const residual = controlPointDistanceResidual(poses, pair_match, cp);

            residuals[cp_flat_index] = .{
                .pair_index = pair_index,
                .control_point_index = control_point_index,
                .residual = residual,
            };
            squared_error_sum += residual * residual;
            max_error = @max(max_error, residual);
            cp_flat_index += 1;
        }
    }

    return .{
        .poses = poses,
        .residuals = residuals,
        .rms_error = @sqrt(squared_error_sum / @as(f64, @floatFromInt(control_point_count))),
        .max_error = max_error,
        .control_point_count = control_point_count,
    };
}

pub fn pruneByResidualThreshold(
    pair_matches: []match_mod.PairMatches,
    residuals: []const ControlPointResidual,
    threshold: f64,
) usize {
    if (threshold <= 0) {
        return countControlPoints(pair_matches);
    }

    var residual_index: usize = 0;
    var kept: usize = 0;
    for (pair_matches) |*pair_match| {
        var write_index: usize = 0;
        for (pair_match.control_points, 0..) |cp, read_index| {
            const residual = residuals[residual_index].residual;
            residual_index += 1;
            if (residual > threshold) {
                continue;
            }
            if (write_index != read_index) {
                pair_match.control_points[write_index] = cp;
            }
            write_index += 1;
            kept += 1;
        }
        pair_match.control_points.len = write_index;
        pair_match.refined_control_point_count = write_index;
    }

    return kept;
}

pub fn renderSolveSummary(
    allocator: std.mem.Allocator,
    phase_label: []const u8,
    result: *const SolveResult,
) std.mem.Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    const writer = list.writer(allocator);
    try writer.print(
        "optimization summary ({s}):\n  control points: {d}\n  RMS residual: {d:.4} px\n  max residual: {d:.4} px\n  image poses:\n",
        .{ phase_label, result.control_point_count, result.rms_error, result.max_error },
    );
    for (result.poses, 0..) |pose, image_index| {
        const yaw_degrees = pose.yaw / degrees_to_radians;
        const pitch_degrees = pose.pitch / degrees_to_radians;
        const roll_degrees = pose.roll / degrees_to_radians;
        const translation_plane_yaw_degrees = pose.translation_plane_yaw / degrees_to_radians;
        const translation_plane_pitch_degrees = pose.translation_plane_pitch / degrees_to_radians;
        try writer.print(
            "    [{d}] y={d:.5} p={d:.5} r={d:.5} v={d:.6} TrX={d:.3} TrY={d:.3} TrZ={d:.6} Tpy={d:.5} Tpp={d:.5} a={d:.6} b={d:.6} c={d:.6} d={d:.3} e={d:.3}\n",
            .{
                image_index,
                yaw_degrees,
                pitch_degrees,
                roll_degrees,
                pose.hfov_delta,
                pose.trans_x,
                pose.trans_y,
                pose.trans_z,
                translation_plane_yaw_degrees,
                translation_plane_pitch_degrees,
                pose.radial_a,
                pose.radial_b,
                pose.radial_c,
                pose.center_shift_x,
                pose.center_shift_y,
            },
        );
    }

    return list.toOwnedSlice(allocator);
}

pub fn countSolveParameters(optimize_vector: []const VariableSet) usize {
    var total: usize = 0;
    for (optimize_vector, 0..) |set, image_index| {
        if (image_index == 0) continue;
        for (variable_order) |variable| {
            if (set.contains(variable)) total += 1;
        }
    }
    return total;
}

pub fn hasControlPointsForImage(pair_matches: []const match_mod.PairMatches, image_index: usize) bool {
    for (pair_matches) |pair_match| {
        for (pair_match.control_points) |cp| {
            if (cp.left_image == image_index or cp.right_image == image_index) {
                return true;
            }
        }
    }
    return false;
}

pub fn buildObjectiveJacobianPattern(
    allocator: std.mem.Allocator,
    optimize_vector: []const VariableSet,
    pair_matches: []const match_mod.PairMatches,
    strategy: ObjectiveStrategy,
) !sparse_matrix.CcsPattern {
    const layout = try buildSolveLayout(allocator, optimize_vector);
    defer allocator.free(layout);

    return buildObjectiveJacobianPatternWithLayout(allocator, layout, pair_matches, strategy);
}

fn buildObjectiveJacobianPatternWithLayout(
    allocator: std.mem.Allocator,
    layout: []const SolveLayout,
    pair_matches: []const match_mod.PairMatches,
    strategy: ObjectiveStrategy,
) !sparse_matrix.CcsPattern {
    const row_count = switch (strategy) {
        .distance_only => countControlPoints(pair_matches),
        .componentwise => countControlPoints(pair_matches) * 2,
    };
    const col_count = countLayoutVariables(layout);

    const row_ptr = try allocator.alloc(usize, row_count + 1);
    errdefer allocator.free(row_ptr);
    row_ptr[0] = 0;

    var row_index: usize = 0;
    var nnz: usize = 0;
    for (pair_matches) |pair_match| {
        for (pair_match.control_points) |cp| {
            const row_nnz = countLayoutEntryVariables(layout[cp.left_image]) + countLayoutEntryVariables(layout[cp.right_image]);
            nnz += row_nnz;
            row_index += 1;
            row_ptr[row_index] = nnz;
            if (strategy == .componentwise) {
                nnz += row_nnz;
                row_index += 1;
                row_ptr[row_index] = nnz;
            }
        }
    }
    std.debug.assert(row_index == row_count);

    const col_idx = try allocator.alloc(usize, nnz);
    errdefer allocator.free(col_idx);

    row_index = 0;
    var write_index: usize = 0;
    for (pair_matches) |pair_match| {
        for (pair_match.control_points) |cp| {
            appendRowParameterIndices(layout[cp.left_image], col_idx, &write_index);
            appendRowParameterIndices(layout[cp.right_image], col_idx, &write_index);
            row_index += 1;
            if (strategy == .componentwise) {
                appendRowParameterIndices(layout[cp.left_image], col_idx, &write_index);
                appendRowParameterIndices(layout[cp.right_image], col_idx, &write_index);
                row_index += 1;
            }
        }
    }
    std.debug.assert(write_index == nnz);

    var crs = sparse_matrix.CrsPattern{
        .row_count = row_count,
        .col_count = col_count,
        .row_ptr = row_ptr,
        .col_idx = col_idx,
    };
    defer crs.deinit(allocator);

    return sparse_matrix.crsToCcs(allocator, &crs);
}

fn countControlPoints(pair_matches: []const match_mod.PairMatches) usize {
    var total: usize = 0;
    for (pair_matches) |pair_match| {
        total += pair_match.control_points.len;
    }
    return total;
}

const SolveLayout = struct {
    yaw_index: ?usize = null,
    pitch_index: ?usize = null,
    roll_index: ?usize = null,
    hfov_index: ?usize = null,
    trans_x_index: ?usize = null,
    trans_y_index: ?usize = null,
    trans_z_index: ?usize = null,
    translation_plane_yaw_index: ?usize = null,
    translation_plane_pitch_index: ?usize = null,
    radial_a_index: ?usize = null,
    radial_b_index: ?usize = null,
    radial_c_index: ?usize = null,
    center_shift_x_index: ?usize = null,
    center_shift_y_index: ?usize = null,
};

const LinearTerms = struct {
    sx: f64,
    sy: f64,
    rx: f64,
    ry: f64,
    focal: f64,
};

fn linearTerms(x: f64, y: f64, width: u32, height: u32, base_hfov_degrees: f64) LinearTerms {
    const cx = (@as(f64, @floatFromInt(width)) - 1.0) * 0.5;
    const cy = (@as(f64, @floatFromInt(height)) - 1.0) * 0.5;
    const dx = x - cx;
    const dy = y - cy;
    return .{
        .sx = dx,
        .sy = dy,
        .rx = -dy,
        .ry = dx,
        .focal = focalLengthPixels(width, base_hfov_degrees),
    };
}

fn buildSolveLayout(allocator: std.mem.Allocator, optimize_vector: []const VariableSet) std.mem.Allocator.Error![]SolveLayout {
    const layout = try allocator.alloc(SolveLayout, optimize_vector.len);
    var next_index: usize = 0;
    for (layout, optimize_vector, 0..) |*entry, set, image_index| {
        entry.* = .{};
        if (image_index == 0) continue;
        if (set.contains(.y)) {
            entry.yaw_index = next_index;
            next_index += 1;
        }
        if (set.contains(.p)) {
            entry.pitch_index = next_index;
            next_index += 1;
        }
        if (set.contains(.r)) {
            entry.roll_index = next_index;
            next_index += 1;
        }
        if (set.contains(.v)) {
            entry.hfov_index = next_index;
            next_index += 1;
        }
        if (set.contains(.tr_x)) {
            entry.trans_x_index = next_index;
            next_index += 1;
        }
        if (set.contains(.tr_y)) {
            entry.trans_y_index = next_index;
            next_index += 1;
        }
        if (set.contains(.tr_z)) {
            entry.trans_z_index = next_index;
            next_index += 1;
        }
        if (set.contains(.tpy)) {
            entry.translation_plane_yaw_index = next_index;
            next_index += 1;
        }
        if (set.contains(.tpp)) {
            entry.translation_plane_pitch_index = next_index;
            next_index += 1;
        }
        if (set.contains(.a)) {
            entry.radial_a_index = next_index;
            next_index += 1;
        }
        if (set.contains(.b)) {
            entry.radial_b_index = next_index;
            next_index += 1;
        }
        if (set.contains(.c)) {
            entry.radial_c_index = next_index;
            next_index += 1;
        }
        if (set.contains(.d)) {
            entry.center_shift_x_index = next_index;
            next_index += 1;
        }
        if (set.contains(.e)) {
            entry.center_shift_y_index = next_index;
            next_index += 1;
        }
    }
    return layout;
}

fn seedPosesLinear(
    allocator: std.mem.Allocator,
    layout: []const SolveLayout,
    pair_matches: []const match_mod.PairMatches,
    poses: []ImagePose,
) SolveError!void {
    const variable_count = countLayoutVariables(layout);
    if (variable_count == 0) {
        return;
    }

    const matrix_len = variable_count * variable_count;
    const normal = try allocator.alloc(f64, matrix_len);
    defer allocator.free(normal);
    const rhs = try allocator.alloc(f64, variable_count);
    defer allocator.free(rhs);
    @memset(normal, 0);
    @memset(rhs, 0);

    for (pair_matches) |pair_match| {
        for (pair_match.control_points) |cp| {
            const weight = @max(@as(f64, cp.score), 1e-3);
            const observed_dx = @as(f64, cp.right_x) - @as(f64, cp.left_x);
            const observed_dy = @as(f64, cp.right_y) - @as(f64, cp.left_y);
            const left_term = linearTerms(cp.left_x, cp.left_y, pair_match.image_width, pair_match.image_height, poses[0].base_hfov_degrees);
            const right_term = linearTerms(cp.right_x, cp.right_y, pair_match.image_width, pair_match.image_height, poses[0].base_hfov_degrees);

            var indices_x = [_]usize{0} ** 8;
            var values_x = [_]f64{0} ** 8;
            var count_x: usize = 0;
            appendImageCoefficients(layout, cp.left_image, -1, left_term, &indices_x, &values_x, &count_x, .x);
            appendImageCoefficients(layout, cp.right_image, 1, right_term, &indices_x, &values_x, &count_x, .x);

            var indices_y = [_]usize{0} ** 8;
            var values_y = [_]f64{0} ** 8;
            var count_y: usize = 0;
            appendImageCoefficients(layout, cp.left_image, -1, left_term, &indices_y, &values_y, &count_y, .y);
            appendImageCoefficients(layout, cp.right_image, 1, right_term, &indices_y, &values_y, &count_y, .y);

            accumulateEquation(normal, rhs, variable_count, indices_x[0..count_x], values_x[0..count_x], observed_dx, weight);
            accumulateEquation(normal, rhs, variable_count, indices_y[0..count_y], values_y[0..count_y], observed_dy, weight);
        }
    }

    // Light damping to keep the system invertible for weakly-constrained chains.
    for (0..variable_count) |i| {
        normal[i * variable_count + i] += 1e-6;
    }
    accumulateAbsolutePriors(normal, variable_count, layout);

    const solution = try allocator.dupe(f64, rhs);
    defer allocator.free(solution);
    try solveLinearSystemInPlace(normal, solution, variable_count);

    const reference_hfov = poses[0].base_hfov_degrees;
    poses[0] = .{};
    poses[0].base_hfov_degrees = reference_hfov;
    for (1..poses.len) |image_index| {
        if (layout[image_index].yaw_index) |idx| poses[image_index].yaw = solution[idx];
        if (layout[image_index].pitch_index) |idx| poses[image_index].pitch = solution[idx];
        if (layout[image_index].roll_index) |idx| poses[image_index].roll = solution[idx];
        if (layout[image_index].hfov_index) |idx| poses[image_index].hfov_delta = solution[idx];
        if (layout[image_index].trans_x_index) |idx| poses[image_index].trans_x = solution[idx];
        if (layout[image_index].trans_y_index) |idx| poses[image_index].trans_y = solution[idx];
        if (layout[image_index].trans_z_index) |idx| poses[image_index].trans_z = solution[idx];
        if (layout[image_index].translation_plane_yaw_index) |idx| poses[image_index].translation_plane_yaw = solution[idx];
        if (layout[image_index].translation_plane_pitch_index) |idx| poses[image_index].translation_plane_pitch = solution[idx];
        if (layout[image_index].radial_a_index) |idx| poses[image_index].radial_a = solution[idx];
        if (layout[image_index].radial_b_index) |idx| poses[image_index].radial_b = solution[idx];
        if (layout[image_index].radial_c_index) |idx| poses[image_index].radial_c = solution[idx];
        if (layout[image_index].center_shift_x_index) |idx| poses[image_index].center_shift_x = solution[idx];
        if (layout[image_index].center_shift_y_index) |idx| poses[image_index].center_shift_y = solution[idx];
    }
}

const Vec2d = struct {
    x: f64,
    y: f64,
};

const PoseField = enum {
    yaw,
    pitch,
    roll,
    hfov_delta,
    trans_x,
    trans_y,
    trans_z,
    translation_plane_yaw,
    translation_plane_pitch,
    radial_a,
    radial_b,
    radial_c,
    center_shift_x,
    center_shift_y,
};

const SolveStrategy = enum {
    distance_only,
    componentwise,
};

pub fn averageHfovDegrees(poses: []const ImagePose) f64 {
    return currentAverageHfovDegrees(poses);
}

pub fn encodeSolveVector(
    allocator: std.mem.Allocator,
    optimize_vector: []const VariableSet,
    poses: []const ImagePose,
) ![]f64 {
    const layout = try buildSolveLayout(allocator, optimize_vector);
    defer allocator.free(layout);

    const solve_x = try allocator.alloc(f64, countLayoutVariables(layout));
    fillSolveVector(layout, poses, solve_x);
    return solve_x;
}

pub fn decodeSolveVector(
    allocator: std.mem.Allocator,
    optimize_vector: []const VariableSet,
    base_poses: []const ImagePose,
    solve_x: []const f64,
) ![]ImagePose {
    const layout = try buildSolveLayout(allocator, optimize_vector);
    defer allocator.free(layout);

    const poses = try allocator.dupe(ImagePose, base_poses);
    applySolveVector(layout, poses, solve_x);
    return poses;
}

pub fn evaluateObjectiveResiduals(
    allocator: std.mem.Allocator,
    strategy: ObjectiveStrategy,
    initial_avg_hfov: f64,
    pair_matches: []const match_mod.PairMatches,
    poses: []const ImagePose,
) ![]f64 {
    return evaluateObjectiveResidualsPadded(allocator, strategy, initial_avg_hfov, pair_matches, poses, null);
}

pub fn evaluateObjectiveJacobianSparse(
    allocator: std.mem.Allocator,
    strategy: ObjectiveStrategy,
    optimize_vector: []const VariableSet,
    base_poses: []const ImagePose,
    pair_matches: []const match_mod.PairMatches,
    solve_x: []const f64,
    mindeltax: f64,
) !sparse_matrix.CcsMatrix {
    var pattern = try buildObjectiveJacobianPattern(allocator, optimize_vector, pair_matches, strategy);
    defer pattern.deinit(allocator);
    var groups = try sparse_matrix.partitionIndependentColumns(allocator, &pattern);
    defer groups.deinit(allocator);

    const initial_avg_hfov = averageHfovDegrees(base_poses);
    const base_eval_poses = try decodeSolveVector(allocator, optimize_vector, base_poses, solve_x);
    defer allocator.free(base_eval_poses);
    const base_fvec = try evaluateObjectiveResidualsPadded(
        allocator,
        strategy,
        initial_avg_hfov,
        pair_matches,
        base_eval_poses,
        null,
    );
    defer allocator.free(base_fvec);

    var matrix = try sparse_matrix.clonePatternToMatrix(allocator, &pattern);
    errdefer matrix.deinit(allocator);
    const shifted_x = try allocator.dupe(f64, solve_x);
    defer allocator.free(shifted_x);
    const step_sizes = try allocator.alloc(f64, solve_x.len);
    defer allocator.free(step_sizes);
    @memset(step_sizes, 0.0);

    const eps = @sqrt(@max(std.math.floatEps(f64) * 10.0, std.math.floatEps(f64)));
    for (0..groups.groupCount()) |group_index| {
        @memcpy(shifted_x, solve_x);
        const columns = groups.groupColumns(group_index);
        for (columns) |column| {
            var h = eps * @abs(shifted_x[column]);
            if (h < mindeltax) h = mindeltax;
            if (h == 0.0) h = eps;
            step_sizes[column] = h;
            shifted_x[column] += h;
        }

        const shifted_poses = try decodeSolveVector(allocator, optimize_vector, base_poses, shifted_x);
        defer allocator.free(shifted_poses);
        const shifted_fvec = try evaluateObjectiveResidualsPadded(
            allocator,
            strategy,
            initial_avg_hfov,
            pair_matches,
            shifted_poses,
            null,
        );
        defer allocator.free(shifted_fvec);

        for (columns) |column| {
            const h = step_sizes[column];
            const start = matrix.col_ptr[column];
            const end = matrix.col_ptr[column + 1];
            for (start..end) |entry_index| {
                const row = matrix.row_idx[entry_index];
                matrix.values[entry_index] = (shifted_fvec[row] - base_fvec[row]) / h;
            }
        }
    }

    return matrix;
}

pub fn evaluateObjectiveResidualsPadded(
    allocator: std.mem.Allocator,
    strategy: ObjectiveStrategy,
    initial_avg_hfov: f64,
    pair_matches: []const match_mod.PairMatches,
    poses: []const ImagePose,
    min_count: ?usize,
) ![]f64 {
    const prof = profiler.scope("optimize.evaluateObjectiveResidualsPadded");
    defer prof.end();

    const residual_count = switch (strategy) {
        .distance_only => countControlPoints(pair_matches),
        .componentwise => countControlPoints(pair_matches) * 2,
    };
    const output_count = @max(residual_count, min_count orelse 0);
    const values = try allocator.alloc(f64, output_count);
    const objective_scale = objectiveFovScale(initial_avg_hfov, currentAverageHfovDegrees(poses));
    const basic_rect_caches = try allocator.alloc(BasicRectEquirectCache, poses.len);
    defer allocator.free(basic_rect_caches);
    if (pair_matches.len > 0) {
        populateBasicRectEquirectCaches(poses, pair_matches[0].image_width, pair_matches[0].image_height, basic_rect_caches);
    } else {
        for (basic_rect_caches) |*cache| cache.* = .{ .valid = false };
    }

    var out_index: usize = 0;
    var squared_sum: f64 = 0.0;
    for (pair_matches) |pair_match| {
        for (pair_match.control_points) |cp| {
            switch (strategy) {
                .distance_only => {
                    const residual = objectiveDistanceResidualCached(poses, basic_rect_caches, objective_scale, pair_match, cp);
                    values[out_index] = residual;
                    squared_sum += residual * residual;
                    out_index += 1;
                },
                .componentwise => {
                    const residual = objectiveResidualVectorCached(poses, basic_rect_caches, objective_scale, pair_match, cp);
                    values[out_index] = residual.x;
                    values[out_index + 1] = residual.y;
                    squared_sum += residual.x * residual.x + residual.y * residual.y;
                    out_index += 2;
                },
            }
        }
    }

    const fill_value = if (residual_count > 0)
        @sqrt(squared_sum / @as(f64, @floatFromInt(residual_count)))
    else
        0.0;
    for (out_index..values.len) |i| {
        values[i] = fill_value;
    }

    return values;
}

pub fn evaluateControlPointError(
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
) ControlPointError {
    const components = controlPointResidualVector(poses, pair_match, cp);
    return .{
        .distance = controlPointDistanceResidual(poses, pair_match, cp),
        .components = .{ .x = components.x, .y = components.y },
    };
}

fn refinePosesIteratively(
    allocator: std.mem.Allocator,
    layout: []const SolveLayout,
    pair_matches: []const match_mod.PairMatches,
    poses: []ImagePose,
    initial_avg_hfov: f64,
    strategy: SolveStrategy,
) SolveError!void {
    const prof = profiler.scope("optimize.refinePosesIteratively");
    defer prof.end();

    const variable_count = countLayoutVariables(layout);
    if (variable_count == 0) {
        return;
    }
    const solve_x = try allocator.alloc(f64, variable_count);
    defer allocator.free(solve_x);
    const seed_poses = try allocator.dupe(ImagePose, poses);
    defer allocator.free(seed_poses);
    const work_poses = try allocator.dupe(ImagePose, poses);
    defer allocator.free(work_poses);
    const basic_rect_caches = try allocator.alloc(BasicRectEquirectCache, poses.len);
    defer allocator.free(basic_rect_caches);
    const last_solve_x = try allocator.alloc(f64, variable_count);
    defer allocator.free(last_solve_x);
    const changed_images = try allocator.alloc(bool, poses.len);
    defer allocator.free(changed_images);
    const parameter_images = try buildParameterImageIndex(allocator, layout);
    defer allocator.free(parameter_images);
    fillSolveVector(layout, poses, solve_x);
    applyUpstreamZeroStartNudges(layout, solve_x);
    @memcpy(last_solve_x, solve_x);
    @memset(changed_images, false);

    const actual_residual_count = switch (strategy) {
        .distance_only => countControlPoints(pair_matches),
        .componentwise => countControlPoints(pair_matches) * 2,
    };
    const residual_count = @max(actual_residual_count, variable_count);
    const objective_strategy: ObjectiveStrategy = switch (strategy) {
        .distance_only => .distance_only,
        .componentwise => .componentwise,
    };
    var grouped_jacobian = if (actual_residual_count == residual_count)
        try GroupedJacobianWorkspace.init(allocator, layout, pair_matches, objective_strategy, variable_count, residual_count)
    else
        null;
    defer if (grouped_jacobian) |*workspace| workspace.deinit(allocator);

    var ctx = SolveContext{
        .layout = layout,
        .pair_matches = pair_matches,
        .seed_poses = seed_poses,
        .work_poses = work_poses,
        .basic_rect_caches = basic_rect_caches,
        .last_solve_x = last_solve_x,
        .changed_images = changed_images,
        .parameter_images = parameter_images,
        .cache_initialized = false,
        .image_width = pair_matches[0].image_width,
        .image_height = pair_matches[0].image_height,
        .initial_avg_hfov = initial_avg_hfov,
        .strategy = strategy,
        .actual_residual_count = actual_residual_count,
        .grouped_jacobian = if (grouped_jacobian) |*workspace| workspace else null,
    };

    const params = minpack_mod.Params{
        .ftol = switch (strategy) {
            .distance_only => 0.05,
            .componentwise => 1.0e-6,
        },
        .xtol = std.math.floatEps(f64),
        .gtol = std.math.floatEps(f64),
        .maxfev = 100 * (variable_count + 1) * 100,
        .epsfcn = std.math.floatEps(f64) * 10.0,
        .factor = 100.0,
    };
    const solve_result = if (ctx.grouped_jacobian != null)
        minpack_mod.lmdifWithJacobian(
            SolveContext,
            allocator,
            &ctx,
            evaluateSolveVector,
            evaluateSolveJacobianGrouped,
            solve_x,
            residual_count,
            params,
        )
    else
        minpack_mod.lmdif(SolveContext, allocator, &ctx, evaluateSolveVector, solve_x, residual_count, params);
    _ = solve_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    applySolveVector(layout, poses, solve_x);
}

fn applyUpstreamZeroStartNudges(layout: []const SolveLayout, solve_x: []f64) void {
    for (layout) |entry| {
        // Hugin writes 1e-5 instead of exact zero for these optimized variables
        // when generating PTOptimizer scripts.
        nudgeSolveIndexFromZero(entry.trans_x_index, solve_x);
        nudgeSolveIndexFromZero(entry.trans_y_index, solve_x);
        nudgeSolveIndexFromZero(entry.trans_z_index, solve_x);
        nudgeSolveIndexFromZero(entry.radial_a_index, solve_x);
        nudgeSolveIndexFromZero(entry.radial_b_index, solve_x);
        nudgeSolveIndexFromZero(entry.radial_c_index, solve_x);
    }
}

fn nudgeSolveIndexFromZero(maybe_index: ?usize, solve_x: []f64) void {
    if (maybe_index) |idx| {
        if (solve_x[idx] == 0.0) {
            solve_x[idx] = 1.0e-5;
        }
    }
}

const SolveContext = struct {
    layout: []const SolveLayout,
    pair_matches: []const match_mod.PairMatches,
    seed_poses: []const ImagePose,
    work_poses: []ImagePose,
    basic_rect_caches: []BasicRectEquirectCache,
    last_solve_x: []f64,
    changed_images: []bool,
    parameter_images: []const usize,
    cache_initialized: bool,
    image_width: u32,
    image_height: u32,
    initial_avg_hfov: f64,
    strategy: SolveStrategy,
    actual_residual_count: usize,
    grouped_jacobian: ?*GroupedJacobianWorkspace,
};

const GroupedJacobianWorkspace = struct {
    pattern: sparse_matrix.CcsPattern,
    groups: sparse_matrix.ColumnGroups,
    shifted_x: []f64,
    shifted_fvec: []f64,
    step_sizes: []f64,

    fn init(
        allocator: std.mem.Allocator,
        layout: []const SolveLayout,
        pair_matches: []const match_mod.PairMatches,
        strategy: ObjectiveStrategy,
        parameter_count: usize,
        residual_count: usize,
    ) !GroupedJacobianWorkspace {
        var pattern = try buildObjectiveJacobianPatternWithLayout(allocator, layout, pair_matches, strategy);
        errdefer pattern.deinit(allocator);
        var groups = try sparse_matrix.partitionIndependentColumns(allocator, &pattern);
        errdefer groups.deinit(allocator);
        const shifted_x = try allocator.alloc(f64, parameter_count);
        errdefer allocator.free(shifted_x);
        const shifted_fvec = try allocator.alloc(f64, residual_count);
        errdefer allocator.free(shifted_fvec);
        const step_sizes = try allocator.alloc(f64, parameter_count);
        errdefer allocator.free(step_sizes);

        return .{
            .pattern = pattern,
            .groups = groups,
            .shifted_x = shifted_x,
            .shifted_fvec = shifted_fvec,
            .step_sizes = step_sizes,
        };
    }

    fn deinit(self: *GroupedJacobianWorkspace, allocator: std.mem.Allocator) void {
        self.pattern.deinit(allocator);
        self.groups.deinit(allocator);
        allocator.free(self.shifted_x);
        allocator.free(self.shifted_fvec);
        allocator.free(self.step_sizes);
        self.* = undefined;
    }
};

fn evaluateSolveVector(ctx: *SolveContext, x: []const f64, fvec: []f64) anyerror!void {
    const prof = profiler.scope("optimize.evaluateSolveVector");
    defer prof.end();

    std.debug.assert(fvec.len >= ctx.actual_residual_count);
    updateSolveContextState(ctx, x);
    const current_avg_hfov = currentAverageHfovDegrees(ctx.work_poses);
    const objective_scale = objectiveFovScale(ctx.initial_avg_hfov, current_avg_hfov);

    var out_index: usize = 0;
    var squared_sum: f64 = 0.0;
    for (ctx.pair_matches) |pair_match| {
        for (pair_match.control_points) |cp| {
            switch (ctx.strategy) {
                .distance_only => {
                    const residual = objectiveDistanceResidualCached(ctx.work_poses, ctx.basic_rect_caches, objective_scale, pair_match, cp);
                    fvec[out_index] = residual;
                    squared_sum += residual * residual;
                    out_index += 1;
                },
                .componentwise => {
                    const residual = objectiveResidualVectorCached(ctx.work_poses, ctx.basic_rect_caches, objective_scale, pair_match, cp);
                    fvec[out_index] = residual.x;
                    fvec[out_index + 1] = residual.y;
                    squared_sum += residual.x * residual.x + residual.y * residual.y;
                    out_index += 2;
                },
            }
        }
    }

    const fill_value = if (ctx.actual_residual_count > 0)
        @sqrt(squared_sum / @as(f64, @floatFromInt(ctx.actual_residual_count)))
    else
        0.0;
    for (out_index..fvec.len) |i| {
        fvec[i] = fill_value;
    }
}

fn evaluateSolveJacobianGrouped(
    ctx: *SolveContext,
    x: []const f64,
    fvec: []const f64,
    fjac: []f64,
    m: usize,
    n: usize,
    epsfcn: f64,
) !usize {
    const prof = profiler.scope("optimize.evaluateSolveJacobianGrouped");
    defer prof.end();

    const workspace = ctx.grouped_jacobian orelse return error.MissingGroupedJacobian;
    std.debug.assert(ctx.actual_residual_count == m);
    std.debug.assert(workspace.pattern.row_count == m);
    std.debug.assert(workspace.pattern.col_count == n);

    @memset(fjac, 0.0);

    const eps = @sqrt(@max(epsfcn, std.math.floatEps(f64)));
    var nfev: usize = 0;
    for (0..workspace.groups.groupCount()) |group_index| {
        @memcpy(workspace.shifted_x, x);
        const columns = workspace.groups.groupColumns(group_index);
        for (columns) |column| {
            var h = eps * @abs(workspace.shifted_x[column]);
            if (h < solve_space_relative_epsilon) h = solve_space_relative_epsilon;
            if (h == 0.0) h = eps;
            workspace.step_sizes[column] = h;
            workspace.shifted_x[column] += h;
        }

        try evaluateSolveVector(ctx, workspace.shifted_x, workspace.shifted_fvec);
        nfev += 1;

        for (columns) |column| {
            const inv_h = 1.0 / workspace.step_sizes[column];
            const start = workspace.pattern.col_ptr[column];
            const end = workspace.pattern.col_ptr[column + 1];
            for (start..end) |entry_index| {
                const row = workspace.pattern.row_idx[entry_index];
                fjac[row + m * column] = (workspace.shifted_fvec[row] - fvec[row]) * inv_h;
            }
        }
    }

    return nfev;
}

fn updateSolveContextState(ctx: *SolveContext, x: []const f64) void {
    const prof = profiler.scope("optimize.updateSolveContextState");
    defer prof.end();

    std.debug.assert(x.len == ctx.last_solve_x.len);

    if (!ctx.cache_initialized) {
        @memcpy(ctx.work_poses, ctx.seed_poses);
        applySolveVector(ctx.layout, ctx.work_poses, x);
        populateBasicRectEquirectCaches(ctx.work_poses, ctx.image_width, ctx.image_height, ctx.basic_rect_caches);
        @memcpy(ctx.last_solve_x, x);
        ctx.cache_initialized = true;
        return;
    }

    @memset(ctx.changed_images, false);
    var changed_parameter_count: usize = 0;
    var changed_image_count: usize = 0;
    for (x, ctx.last_solve_x, 0..) |value, old_value, parameter_index| {
        if (value == old_value) continue;
        changed_parameter_count += 1;
        const image_index = ctx.parameter_images[parameter_index];
        if (!ctx.changed_images[image_index]) {
            ctx.changed_images[image_index] = true;
            changed_image_count += 1;
        }
    }

    if (changed_parameter_count == 0) {
        return;
    }

    const use_incremental = changed_parameter_count <= 4 and changed_image_count <= 2;
    if (!use_incremental) {
        @memcpy(ctx.work_poses, ctx.seed_poses);
        applySolveVector(ctx.layout, ctx.work_poses, x);
        populateBasicRectEquirectCaches(ctx.work_poses, ctx.image_width, ctx.image_height, ctx.basic_rect_caches);
        @memcpy(ctx.last_solve_x, x);
        return;
    }

    for (1..ctx.work_poses.len) |image_index| {
        if (!ctx.changed_images[image_index]) continue;
        ctx.work_poses[image_index] = ctx.seed_poses[image_index];
        applySolveVectorImage(ctx.layout[image_index], &ctx.work_poses[image_index], x);
        populateBasicRectEquirectCache(ctx.work_poses[image_index], ctx.image_width, ctx.image_height, &ctx.basic_rect_caches[image_index]);
    }
    @memcpy(ctx.last_solve_x, x);
}

const EquationAxis = enum { x, y };

fn countLayoutVariables(layout: []const SolveLayout) usize {
    var count: usize = 0;
    for (layout) |entry| {
        if (entry.yaw_index) |_| count += 1;
        if (entry.pitch_index) |_| count += 1;
        if (entry.roll_index) |_| count += 1;
        if (entry.hfov_index) |_| count += 1;
        if (entry.trans_x_index) |_| count += 1;
        if (entry.trans_y_index) |_| count += 1;
        if (entry.trans_z_index) |_| count += 1;
        if (entry.translation_plane_yaw_index) |_| count += 1;
        if (entry.translation_plane_pitch_index) |_| count += 1;
        if (entry.radial_a_index) |_| count += 1;
        if (entry.radial_b_index) |_| count += 1;
        if (entry.radial_c_index) |_| count += 1;
        if (entry.center_shift_x_index) |_| count += 1;
        if (entry.center_shift_y_index) |_| count += 1;
    }
    return count;
}

fn countLayoutEntryVariables(entry: SolveLayout) usize {
    var count: usize = 0;
    if (entry.yaw_index) |_| count += 1;
    if (entry.pitch_index) |_| count += 1;
    if (entry.roll_index) |_| count += 1;
    if (entry.hfov_index) |_| count += 1;
    if (entry.trans_x_index) |_| count += 1;
    if (entry.trans_y_index) |_| count += 1;
    if (entry.trans_z_index) |_| count += 1;
    if (entry.translation_plane_yaw_index) |_| count += 1;
    if (entry.translation_plane_pitch_index) |_| count += 1;
    if (entry.radial_a_index) |_| count += 1;
    if (entry.radial_b_index) |_| count += 1;
    if (entry.radial_c_index) |_| count += 1;
    if (entry.center_shift_x_index) |_| count += 1;
    if (entry.center_shift_y_index) |_| count += 1;
    return count;
}

fn appendRowParameterIndices(entry: SolveLayout, out: []usize, write_index: *usize) void {
    if (entry.yaw_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.pitch_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.roll_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.hfov_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.trans_x_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.trans_y_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.trans_z_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.translation_plane_yaw_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.translation_plane_pitch_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.radial_a_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.radial_b_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.radial_c_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.center_shift_x_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
    if (entry.center_shift_y_index) |idx| {
        out[write_index.*] = idx;
        write_index.* += 1;
    }
}

fn buildParameterImageIndex(allocator: std.mem.Allocator, layout: []const SolveLayout) ![]usize {
    const parameter_images = try allocator.alloc(usize, countLayoutVariables(layout));
    var next_index: usize = 0;
    for (layout, 0..) |entry, image_index| {
        if (image_index == 0) continue;
        if (entry.yaw_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.pitch_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.roll_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.hfov_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.trans_x_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.trans_y_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.trans_z_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.translation_plane_yaw_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.translation_plane_pitch_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.radial_a_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.radial_b_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.radial_c_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.center_shift_x_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
        if (entry.center_shift_y_index) |_| {
            parameter_images[next_index] = image_index;
            next_index += 1;
        }
    }
    return parameter_images;
}

fn appendImageCoefficients(
    layout: []const SolveLayout,
    image_index: usize,
    sign: f64,
    terms: LinearTerms,
    indices: []usize,
    values: []f64,
    count: *usize,
    axis: EquationAxis,
) void {
    if (image_index == 0) return;
    const entry = layout[image_index];
    switch (axis) {
        .x => {
            if (entry.trans_x_index) |idx| {
                indices[count.*] = idx;
                values[count.*] = sign * terms.focal;
                count.* += 1;
            }
            if (entry.yaw_index) |idx| {
                indices[count.*] = idx;
                values[count.*] = sign * terms.focal;
                count.* += 1;
            }
            if (entry.roll_index) |idx| {
                indices[count.*] = idx;
                values[count.*] = sign * terms.rx;
                count.* += 1;
            }
        },
        .y => {
            if (entry.trans_y_index) |idx| {
                indices[count.*] = idx;
                values[count.*] = sign * terms.focal;
                count.* += 1;
            }
            if (entry.pitch_index) |idx| {
                indices[count.*] = idx;
                values[count.*] = sign * -terms.focal;
                count.* += 1;
            }
            if (entry.roll_index) |idx| {
                indices[count.*] = idx;
                values[count.*] = sign * terms.ry;
                count.* += 1;
            }
        },
    }
}

fn appendImageJacobian(
    layout: []const SolveLayout,
    poses: []const ImagePose,
    image_index: usize,
    x: f32,
    y: f32,
    width: u32,
    height: u32,
    sign: f64,
    indices: []usize,
    values_x: []f64,
    values_y: []f64,
    count: *usize,
) void {
    if (image_index == 0) return;
    const entry = layout[image_index];
    const pose = poses[image_index];

    if (entry.yaw_index) |idx| {
        indices[count.*] = idx;
        const deriv = numericalDerivative(pose, x, y, width, height, .yaw);
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.pitch_index) |idx| {
        indices[count.*] = idx;
        const deriv = numericalDerivative(pose, x, y, width, height, .pitch);
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.roll_index) |idx| {
        const deriv = numericalDerivative(pose, x, y, width, height, .roll);
        indices[count.*] = idx;
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.hfov_index) |idx| {
        const deriv = numericalDerivative(pose, x, y, width, height, .hfov_delta);
        indices[count.*] = idx;
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.trans_x_index) |idx| {
        const deriv = numericalDerivative(pose, x, y, width, height, .trans_x);
        indices[count.*] = idx;
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.trans_y_index) |idx| {
        const deriv = numericalDerivative(pose, x, y, width, height, .trans_y);
        indices[count.*] = idx;
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.trans_z_index) |idx| {
        const deriv = numericalDerivative(pose, x, y, width, height, .trans_z);
        indices[count.*] = idx;
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.translation_plane_yaw_index) |idx| {
        const deriv = numericalDerivative(pose, x, y, width, height, .translation_plane_yaw);
        indices[count.*] = idx;
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.translation_plane_pitch_index) |idx| {
        const deriv = numericalDerivative(pose, x, y, width, height, .translation_plane_pitch);
        indices[count.*] = idx;
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.radial_a_index) |idx| {
        const deriv = numericalDerivative(pose, x, y, width, height, .radial_a);
        indices[count.*] = idx;
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.radial_b_index) |idx| {
        const deriv = numericalDerivative(pose, x, y, width, height, .radial_b);
        indices[count.*] = idx;
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.radial_c_index) |idx| {
        const deriv = numericalDerivative(pose, x, y, width, height, .radial_c);
        indices[count.*] = idx;
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.center_shift_x_index) |idx| {
        const deriv = numericalDerivative(pose, x, y, width, height, .center_shift_x);
        indices[count.*] = idx;
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
    if (entry.center_shift_y_index) |idx| {
        const deriv = numericalDerivative(pose, x, y, width, height, .center_shift_y);
        indices[count.*] = idx;
        values_x[count.*] = sign * deriv.x;
        values_y[count.*] = sign * deriv.y;
        count.* += 1;
    }
}

fn appendResidualJacobian(
    layout: []const SolveLayout,
    initial_avg_hfov: f64,
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
    image_index: usize,
    indices: []usize,
    values_x: []f64,
    values_y: []f64,
    count: *usize,
) void {
    if (image_index == 0) return;
    const entry = layout[image_index];

    if (entry.yaw_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .yaw);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.pitch_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .pitch);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.roll_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .roll);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.hfov_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .hfov_delta);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.trans_x_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .trans_x);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.trans_y_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .trans_y);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.trans_z_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .trans_z);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.translation_plane_yaw_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .translation_plane_yaw);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.translation_plane_pitch_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .translation_plane_pitch);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.radial_a_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .radial_a);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.radial_b_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .radial_b);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.radial_c_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .radial_c);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.center_shift_x_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .center_shift_x);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
    if (entry.center_shift_y_index) |idx| {
        const deriv = numericalResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .center_shift_y);
        indices[count.*] = idx;
        values_x[count.*] = deriv.x;
        values_y[count.*] = deriv.y;
        count.* += 1;
    }
}

fn appendDistanceResidualJacobian(
    layout: []const SolveLayout,
    initial_avg_hfov: f64,
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
    image_index: usize,
    indices: []usize,
    values: []f64,
    count: *usize,
) void {
    if (image_index == 0) return;
    const entry = layout[image_index];

    if (entry.yaw_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .yaw);
        count.* += 1;
    }
    if (entry.pitch_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .pitch);
        count.* += 1;
    }
    if (entry.roll_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .roll);
        count.* += 1;
    }
    if (entry.hfov_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .hfov_delta);
        count.* += 1;
    }
    if (entry.trans_x_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .trans_x);
        count.* += 1;
    }
    if (entry.trans_y_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .trans_y);
        count.* += 1;
    }
    if (entry.trans_z_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .trans_z);
        count.* += 1;
    }
    if (entry.translation_plane_yaw_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .translation_plane_yaw);
        count.* += 1;
    }
    if (entry.translation_plane_pitch_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .translation_plane_pitch);
        count.* += 1;
    }
    if (entry.radial_a_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .radial_a);
        count.* += 1;
    }
    if (entry.radial_b_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .radial_b);
        count.* += 1;
    }
    if (entry.radial_c_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .radial_c);
        count.* += 1;
    }
    if (entry.center_shift_x_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .center_shift_x);
        count.* += 1;
    }
    if (entry.center_shift_y_index) |idx| {
        indices[count.*] = idx;
        values[count.*] = numericalDistanceResidualDerivative(initial_avg_hfov, poses, pair_match, cp, image_index, .center_shift_y);
        count.* += 1;
    }
}

fn numericalResidualDerivative(
    initial_avg_hfov: f64,
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
    image_index: usize,
    field: PoseField,
) Vec2d {
    const prof = profiler.scope("optimize.numericalResidualDerivative");
    defer prof.end();

    var perturbed_pose = poses[image_index];
    const base_value = solveSpaceValue(perturbed_pose, field);
    const epsilon = solveSpaceEpsilon(base_value);
    setSolveSpaceValue(&perturbed_pose, field, base_value + epsilon);
    const base = objectiveResidualVector(initial_avg_hfov, poses, pair_match, cp);
    const moved = objectiveResidualVectorWithPoseOverride(initial_avg_hfov, poses, pair_match, cp, image_index, perturbed_pose);
    return .{
        .x = (moved.x - base.x) / epsilon,
        .y = (moved.y - base.y) / epsilon,
    };
}

fn numericalDistanceResidualDerivative(
    initial_avg_hfov: f64,
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
    image_index: usize,
    field: PoseField,
) f64 {
    const prof = profiler.scope("optimize.numericalDistanceResidualDerivative");
    defer prof.end();

    var perturbed_pose = poses[image_index];
    const base_value = solveSpaceValue(perturbed_pose, field);
    const epsilon = solveSpaceEpsilon(base_value);
    setSolveSpaceValue(&perturbed_pose, field, base_value + epsilon);
    const base = objectiveDistanceResidual(initial_avg_hfov, poses, pair_match, cp);
    const moved = objectiveDistanceResidualWithPoseOverride(initial_avg_hfov, poses, pair_match, cp, image_index, perturbed_pose);
    return (moved - base) / epsilon;
}

fn numericalDerivative(
    pose: ImagePose,
    x: f32,
    y: f32,
    width: u32,
    height: u32,
    field: PoseField,
) Vec2d {
    const prof = profiler.scope("optimize.numericalDerivative");
    defer prof.end();

    const epsilon: f64 = switch (field) {
        .yaw, .pitch, .roll => 1e-5,
        .hfov_delta => 1e-5,
        .trans_x, .trans_y => 1e-3,
        .trans_z => 1e-5,
        .translation_plane_yaw, .translation_plane_pitch => 1e-5,
        .radial_a, .radial_b, .radial_c => 1e-6,
        .center_shift_x, .center_shift_y => 1e-3,
    };

    const base = transformPoint(pose, x, y, width, height);
    var perturbed = pose;
    switch (field) {
        .yaw => perturbed.yaw += epsilon,
        .pitch => perturbed.pitch += epsilon,
        .roll => perturbed.roll += epsilon,
        .hfov_delta => perturbed.hfov_delta += epsilon,
        .trans_x => perturbed.trans_x += epsilon,
        .trans_y => perturbed.trans_y += epsilon,
        .trans_z => perturbed.trans_z += epsilon,
        .translation_plane_yaw => perturbed.translation_plane_yaw += epsilon,
        .translation_plane_pitch => perturbed.translation_plane_pitch += epsilon,
        .radial_a => perturbed.radial_a += epsilon,
        .radial_b => perturbed.radial_b += epsilon,
        .radial_c => perturbed.radial_c += epsilon,
        .center_shift_x => perturbed.center_shift_x += epsilon,
        .center_shift_y => perturbed.center_shift_y += epsilon,
    }
    const moved = transformPoint(perturbed, x, y, width, height);
    return .{
        .x = (moved.x - base.x) / epsilon,
        .y = (moved.y - base.y) / epsilon,
    };
}

fn controlPointResidualVector(
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
) Vec2d {
    return controlPointResidualVectorWithPoseOverride(poses, pair_match, cp, null, .{});
}

fn controlPointResidualVectorWithPoseOverride(
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
    override_image_index: ?usize,
    override_pose: ImagePose,
) Vec2d {
    const prof = profiler.scope("optimize.controlPointResidualVectorWithPoseOverride");
    defer prof.end();

    const left_pose = if (override_image_index != null and override_image_index.? == cp.left_image) override_pose else poses[cp.left_image];
    const right_pose = if (override_image_index != null and override_image_index.? == cp.right_image) override_pose else poses[cp.right_image];
    if (hasBasicRectilinearPose(left_pose) and hasBasicRectilinearPose(right_pose)) {
        return exactDistSphereResidualVector(left_pose, right_pose, pair_match, cp);
    }

    const left = panoramaVectorForControlPoint(poses, pair_match, cp.left_image, cp.left_x, cp.left_y, override_image_index, override_pose);
    const right = panoramaVectorForControlPoint(poses, pair_match, cp.right_image, cp.right_x, cp.right_y, override_image_index, override_pose);
    const scale = panoRadiansToPixels(pair_match.image_width, poses[0].base_hfov_degrees);
    const left_theta = zenithAngle(left);
    const right_theta = zenithAngle(right);
    var delta_lon = longitudeOf(left) - longitudeOf(right);
    if (delta_lon < -std.math.pi) delta_lon += 2.0 * std.math.pi;
    if (delta_lon > std.math.pi) delta_lon -= 2.0 * std.math.pi;
    return .{
        .x = delta_lon * @sin(0.5 * (left_theta + right_theta)) * scale,
        .y = (left_theta - right_theta) * scale,
    };
}

fn controlPointDistanceResidual(
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
) f64 {
    return controlPointDistanceResidualWithPoseOverride(poses, pair_match, cp, null, .{});
}

fn controlPointDistanceResidualWithPoseOverride(
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
    override_image_index: ?usize,
    override_pose: ImagePose,
) f64 {
    const prof = profiler.scope("optimize.controlPointDistanceResidualWithPoseOverride");
    defer prof.end();

    const left_pose = if (override_image_index != null and override_image_index.? == cp.left_image) override_pose else poses[cp.left_image];
    const right_pose = if (override_image_index != null and override_image_index.? == cp.right_image) override_pose else poses[cp.right_image];
    if (hasBasicRectilinearPose(left_pose) and hasBasicRectilinearPose(right_pose)) {
        return exactDistSphereDistance(left_pose, right_pose, pair_match, cp);
    }

    const left = panoramaVectorForControlPoint(poses, pair_match, cp.left_image, cp.left_x, cp.left_y, override_image_index, override_pose);
    const right = panoramaVectorForControlPoint(poses, pair_match, cp.right_image, cp.right_x, cp.right_y, override_image_index, override_pose);
    const cross = cross3(left, right);
    var dangle = std.math.asin(std.math.clamp(length3(cross), 0.0, 1.0));
    if (dot3(left, right) < 0.0) {
        dangle = std.math.pi - dangle;
    }
    return dangle * panoRadiansToPixels(pair_match.image_width, poses[0].base_hfov_degrees);
}

fn objectiveResidualVector(
    initial_avg_hfov: f64,
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
) Vec2d {
    const objective_scale = objectiveFovScale(initial_avg_hfov, currentAverageHfovDegrees(poses));
    return objectiveResidualVectorCached(poses, &.{}, objective_scale, pair_match, cp);
}

fn objectiveDistanceResidual(
    initial_avg_hfov: f64,
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
) f64 {
    const objective_scale = objectiveFovScale(initial_avg_hfov, currentAverageHfovDegrees(poses));
    return objectiveDistanceResidualCached(poses, &.{}, objective_scale, pair_match, cp);
}

fn objectiveResidualVectorWithPoseOverride(
    initial_avg_hfov: f64,
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
    override_image_index: ?usize,
    override_pose: ImagePose,
) Vec2d {
    var residual = controlPointResidualVectorWithPoseOverride(poses, pair_match, cp, override_image_index, override_pose);
    residual.x = huberResidualComponent(residual.x, huber_sigma_pixels);
    residual.y = huberResidualComponent(residual.y, huber_sigma_pixels);
    const scale = objectiveFovScale(initial_avg_hfov, currentAverageHfovDegreesWithOverride(poses, override_image_index, override_pose));
    residual.x *= scale;
    residual.y *= scale;
    return residual;
}

fn objectiveDistanceResidualWithPoseOverride(
    initial_avg_hfov: f64,
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
    override_image_index: ?usize,
    override_pose: ImagePose,
) f64 {
    const residual = controlPointDistanceResidualWithPoseOverride(poses, pair_match, cp, override_image_index, override_pose);
    const scale = objectiveFovScale(initial_avg_hfov, currentAverageHfovDegreesWithOverride(poses, override_image_index, override_pose));
    return scale * residual;
}

fn objectiveResidualVectorCached(
    poses: []const ImagePose,
    basic_rect_caches: []const BasicRectEquirectCache,
    objective_scale: f64,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
) Vec2d {
    const prof = profiler.scope("optimize.objectiveResidualVectorCached");
    defer prof.end();

    var residual = controlPointResidualVectorCached(poses, basic_rect_caches, pair_match, cp);
    residual.x = huberResidualComponent(residual.x, huber_sigma_pixels);
    residual.y = huberResidualComponent(residual.y, huber_sigma_pixels);
    residual.x *= objective_scale;
    residual.y *= objective_scale;
    return residual;
}

fn objectiveDistanceResidualCached(
    poses: []const ImagePose,
    basic_rect_caches: []const BasicRectEquirectCache,
    objective_scale: f64,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
) f64 {
    const prof = profiler.scope("optimize.objectiveDistanceResidualCached");
    defer prof.end();

    return objective_scale * controlPointDistanceResidualCached(poses, basic_rect_caches, pair_match, cp);
}

fn controlPointResidualVectorCached(
    poses: []const ImagePose,
    basic_rect_caches: []const BasicRectEquirectCache,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
) Vec2d {
    if (basic_rect_caches.len == poses.len and basic_rect_caches[cp.left_image].valid and basic_rect_caches[cp.right_image].valid) {
        return exactDistSphereResidualVectorCached(basic_rect_caches[cp.left_image], basic_rect_caches[cp.right_image], cp);
    }
    return controlPointResidualVector(poses, pair_match, cp);
}

fn controlPointDistanceResidualCached(
    poses: []const ImagePose,
    basic_rect_caches: []const BasicRectEquirectCache,
    pair_match: match_mod.PairMatches,
    cp: match_mod.ControlPoint,
) f64 {
    if (basic_rect_caches.len == poses.len and basic_rect_caches[cp.left_image].valid and basic_rect_caches[cp.right_image].valid) {
        return exactDistSphereDistanceCached(basic_rect_caches[cp.left_image], basic_rect_caches[cp.right_image], cp);
    }
    return controlPointDistanceResidual(poses, pair_match, cp);
}

fn hasBasicRectilinearPose(pose: ImagePose) bool {
    return !hasTranslation(pose) and
        @abs(pose.radial_a) <= 1e-12 and
        @abs(pose.radial_b) <= 1e-12 and
        @abs(pose.radial_c) <= 1e-12 and
        @abs(pose.center_shift_x) <= 1e-12 and
        @abs(pose.center_shift_y) <= 1e-12;
}

fn exactDistSphereResidualVector(left_pose: ImagePose, right_pose: ImagePose, pair_match: match_mod.PairMatches, cp: match_mod.ControlPoint) Vec2d {
    const prof = profiler.scope("optimize.exactDistSphereResidualVector");
    defer prof.end();

    const left = imageToEquirectDegrees(left_pose, @as(f64, cp.left_x), @as(f64, cp.left_y), pair_match.image_width, pair_match.image_height);
    const right = imageToEquirectDegrees(right_pose, @as(f64, cp.right_x), @as(f64, cp.right_y), pair_match.image_width, pair_match.image_height);
    const lon_left = left.x * degrees_to_radians;
    const lon_right = right.x * degrees_to_radians;
    const lat_left = left.y * degrees_to_radians + std.math.pi * 0.5;
    const lat_right = right.y * degrees_to_radians + std.math.pi * 0.5;
    var delta_lon = lon_left - lon_right;
    if (delta_lon < -std.math.pi) delta_lon += 2.0 * std.math.pi;
    if (delta_lon > std.math.pi) delta_lon -= 2.0 * std.math.pi;
    const scale = panoRadiansToPixels(pair_match.image_width, left_pose.base_hfov_degrees);
    return .{
        .x = (delta_lon * @sin(0.5 * (lat_left + lat_right))) * scale,
        .y = (lat_left - lat_right) * scale,
    };
}

fn exactDistSphereResidualVectorCached(left: BasicRectEquirectCache, right: BasicRectEquirectCache, cp: match_mod.ControlPoint) Vec2d {
    const prof = profiler.scope("optimize.exactDistSphereResidualVectorCached");
    defer prof.end();

    const left_ray = imageToWorldRayCached(left, @as(f64, cp.left_x), @as(f64, cp.left_y));
    const right_ray = imageToWorldRayCached(right, @as(f64, cp.right_x), @as(f64, cp.right_y));
    const lon_left = std.math.atan2(left_ray.x, -left_ray.z);
    const lon_right = std.math.atan2(right_ray.x, -right_ray.z);
    const lat_left = std.math.asin(std.math.clamp(left_ray.y, -1.0, 1.0)) + std.math.pi * 0.5;
    const lat_right = std.math.asin(std.math.clamp(right_ray.y, -1.0, 1.0)) + std.math.pi * 0.5;
    var delta_lon = lon_left - lon_right;
    if (delta_lon < -std.math.pi) delta_lon += 2.0 * std.math.pi;
    if (delta_lon > std.math.pi) delta_lon -= 2.0 * std.math.pi;
    return .{
        .x = (delta_lon * @sin(0.5 * (lat_left + lat_right))) * left.radians_to_pixels,
        .y = (lat_left - lat_right) * left.radians_to_pixels,
    };
}

fn exactDistSphereDistance(left_pose: ImagePose, right_pose: ImagePose, pair_match: match_mod.PairMatches, cp: match_mod.ControlPoint) f64 {
    const prof = profiler.scope("optimize.exactDistSphereDistance");
    defer prof.end();

    const left = imageToEquirectDegrees(left_pose, @as(f64, cp.left_x), @as(f64, cp.left_y), pair_match.image_width, pair_match.image_height);
    const right = imageToEquirectDegrees(right_pose, @as(f64, cp.right_x), @as(f64, cp.right_y), pair_match.image_width, pair_match.image_height);
    const left_lon = left.x * degrees_to_radians;
    const right_lon = right.x * degrees_to_radians;
    const left_lat = left.y * degrees_to_radians + std.math.pi * 0.5;
    const right_lat = right.y * degrees_to_radians + std.math.pi * 0.5;
    const left_vec = latLonToVec3(left_lon, left_lat);
    const right_vec = latLonToVec3(right_lon, right_lat);
    const cross = cross3(left_vec, right_vec);
    var dangle = std.math.asin(std.math.clamp(length3(cross), 0.0, 1.0));
    if (dot3(left_vec, right_vec) < 0.0) dangle = std.math.pi - dangle;
    return dangle * panoRadiansToPixels(pair_match.image_width, left_pose.base_hfov_degrees);
}

fn exactDistSphereDistanceCached(left: BasicRectEquirectCache, right: BasicRectEquirectCache, cp: match_mod.ControlPoint) f64 {
    const prof = profiler.scope("optimize.exactDistSphereDistanceCached");
    defer prof.end();

    const left_vec = imageToWorldRayCached(left, @as(f64, cp.left_x), @as(f64, cp.left_y));
    const right_vec = imageToWorldRayCached(right, @as(f64, cp.right_x), @as(f64, cp.right_y));
    const cross = cross3(left_vec, right_vec);
    var dangle = std.math.asin(std.math.clamp(length3(cross), 0.0, 1.0));
    if (dot3(left_vec, right_vec) < 0.0) dangle = std.math.pi - dangle;
    return dangle * left.radians_to_pixels;
}

fn latLonToVec3(lon: f64, lat_zenith: f64) Vec3 {
    return .{
        .x = @sin(lon) * @sin(lat_zenith),
        .y = @cos(lat_zenith),
        .z = -@cos(lon) * @sin(lat_zenith),
    };
}

pub fn imagePointToEquirectDegrees(pose: ImagePose, x: f64, y: f64, width: u32, height: u32) Point2 {
    return imageToEquirectDegrees(pose, x, y, width, height);
}

fn imageToEquirectDegrees(pose: ImagePose, x: f64, y: f64, width: u32, height: u32) Point2 {
    const prof = profiler.scope("optimize.imageToEquirectDegrees");
    defer prof.end();

    const center = distortionCenter(pose, width, height);
    const pano_distance = 180.0 / std.math.pi;
    const image_focal = focalLengthPixels(width, effectiveHfovDegrees(pose));
    const scale = pano_distance / image_focal;

    var p = Point2{
        .x = (x - center.x) * scale,
        .y = (y - center.y) * scale,
    };
    p = sphereTpRectPoint(p, pano_distance);
    p = perspSpherePoint(p, setMatrix(pose.pitch, 0.0, pose.roll, true), pano_distance);
    p = erectSphereTpPoint(p, pano_distance);
    return rotateErectPoint(p, pano_distance * std.math.pi, pose.yaw / degrees_to_radians);
}

fn imageToEquirectDegreesCached(cache: BasicRectEquirectCache, x: f64, y: f64) Point2 {
    const prof = profiler.scope("optimize.imageToEquirectDegreesCached");
    defer prof.end();

    const ray = imageToWorldRayCached(cache, x, y);
    return .{
        .x = std.math.atan2(ray.x, -ray.z) / degrees_to_radians,
        .y = std.math.asin(std.math.clamp(ray.y, -1.0, 1.0)) / degrees_to_radians,
    };
}

fn imageToWorldRayCached(cache: BasicRectEquirectCache, x: f64, y: f64) Vec3 {
    const prof = profiler.scope("optimize.imageToWorldRayCached");
    defer prof.end();

    const dx = x - cache.center.x;
    const dy = y - cache.center.y;
    const local = Vec3{
        .x = dx,
        .y = dy,
        .z = -cache.image_focal,
    };
    const world = matrixMul(cache.world_from_local, local);
    const inv_norm = 1.0 / @sqrt(dx * dx + dy * dy + cache.image_focal * cache.image_focal);
    return .{
        .x = world.x * inv_norm,
        .y = world.y * inv_norm,
        .z = world.z * inv_norm,
    };
}

fn sphereTpRectPoint(p: Point2, distance: f64) Point2 {
    const r = @sqrt(p.x * p.x + p.y * p.y) / distance;
    const theta = if (r == 0.0) 1.0 else std.math.atan(r) / r;
    return .{ .x = theta * p.x, .y = theta * p.y };
}

fn sphereTpErectPoint(p: Point2, distance: f64) Point2 {
    var phi = p.x / distance;
    var theta = -(p.y / distance) + std.math.pi * 0.5;
    if (theta < 0.0) {
        theta = -theta;
        phi += std.math.pi;
    }
    if (theta > std.math.pi) {
        theta = std.math.pi - (theta - std.math.pi);
        phi += std.math.pi;
    }

    const s = @sin(theta);
    const v0 = s * @sin(phi);
    const v1 = @cos(theta);
    const r = @sqrt(v1 * v1 + v0 * v0);
    const scale = if (r == 0.0) 0.0 else distance * std.math.atan2(r, s * @cos(phi)) / r;
    return .{
        .x = scale * v0,
        .y = scale * v1,
    };
}

fn perspSpherePoint(p: Point2, m: Matrix3, distance: f64) Point2 {
    const r = @sqrt(p.x * p.x + p.y * p.y);
    const theta = r / distance;
    const s = if (r == 0.0) 0.0 else @sin(theta) / r;
    var v = Vec3{
        .x = s * p.x,
        .y = s * p.y,
        .z = @cos(theta),
    };
    v = matrixInvMul(m, v);
    const r2 = @sqrt(v.x * v.x + v.y * v.y);
    const scale = if (r2 == 0.0) 0.0 else distance * std.math.atan2(r2, v.z) / r2;
    return .{ .x = scale * v.x, .y = scale * v.y };
}

fn erectSphereTpPoint(p: Point2, distance: f64) Point2 {
    const r = @sqrt(p.x * p.x + p.y * p.y);
    const theta = r / distance;
    const s = if (theta == 0.0) 1.0 / distance else @sin(theta) / r;
    const v1 = s * p.x;
    const v0 = @cos(theta);
    return .{
        .x = distance * std.math.atan2(v1, v0),
        .y = distance * std.math.atan((s * p.y) / @sqrt(v0 * v0 + v1 * v1)),
    };
}

fn rectSphereTpPoint(p: Point2, distance: f64) Point2 {
    const r = @sqrt(p.x * p.x + p.y * p.y);
    const theta = r / distance;
    const rho = if (theta >= std.math.pi * 0.5)
        1.6e16
    else if (theta == 0.0)
        1.0
    else
        @tan(theta) / theta;
    return .{
        .x = rho * p.x,
        .y = rho * p.y,
    };
}

fn rectErectPoint(p: Point2, distance: f64) ?Point2 {
    const phi = p.x / distance;
    if (phi < -std.math.pi * 0.5 or phi > std.math.pi * 0.5) return null;
    const theta = -(p.y / distance) + std.math.pi * 0.5;
    return .{
        .x = distance * @tan(phi),
        .y = distance / (@tan(theta) * @cos(phi)),
    };
}

fn erectRectPoint(p: Point2, distance: f64) Point2 {
    return .{
        .x = distance * std.math.atan2(p.x, distance),
        .y = distance * std.math.atan2(p.y, @sqrt(distance * distance + p.x * p.x)),
    };
}

fn rotateErectPoint(p: Point2, half_turn: f64, turn: f64) Point2 {
    var x = p.x + turn;
    while (x < -half_turn) x += 2.0 * half_turn;
    while (x > half_turn) x -= 2.0 * half_turn;
    return .{ .x = x, .y = p.y };
}

fn currentAverageHfovDegrees(poses: []const ImagePose) f64 {
    const prof = profiler.scope("optimize.currentAverageHfovDegrees");
    defer prof.end();

    return currentAverageHfovDegreesWithOverride(poses, null, .{});
}

fn currentAverageHfovDegreesWithOverride(poses: []const ImagePose, override_image_index: ?usize, override_pose: ImagePose) f64 {
    var sum: f64 = 0;
    for (poses, 0..) |pose, image_index| {
        const active_pose = if (override_image_index != null and override_image_index.? == image_index) override_pose else pose;
        sum += effectiveHfovDegrees(active_pose);
    }
    return sum / @as(f64, @floatFromInt(poses.len));
}

fn objectiveFovScale(initial_avg_hfov: f64, current_avg_hfov: f64) f64 {
    const prof = profiler.scope("optimize.objectiveFovScale");
    defer prof.end();

    if (current_avg_hfov <= 1e-9) return 1.0;
    const ratio = initial_avg_hfov / current_avg_hfov;
    return if (ratio > 1.0) ratio else 1.0;
}

fn huberResidualComponent(value: f64, sigma: f64) f64 {
    if (sigma <= 0) return value;
    const magnitude = @abs(value);
    if (magnitude < sigma) return value;
    return @sqrt(2.0 * sigma * magnitude - sigma * sigma);
}

fn solveSpaceEpsilon(base_value: f64) f64 {
    const scaled = @abs(solve_space_relative_epsilon * base_value);
    return if (scaled > 0.0) scaled else solve_space_relative_epsilon;
}

fn solveSpaceValue(pose: ImagePose, field: PoseField) f64 {
    switch (field) {
        .yaw => return pose.yaw / degrees_to_radians,
        .pitch => return pose.pitch / degrees_to_radians,
        .roll => return pose.roll / degrees_to_radians,
        .hfov_delta => return effectiveHfovDegrees(pose),
        .trans_x => return pose.trans_x,
        .trans_y => return pose.trans_y,
        .trans_z => return pose.trans_z,
        .translation_plane_yaw => return pose.translation_plane_yaw / degrees_to_radians,
        .translation_plane_pitch => return pose.translation_plane_pitch / degrees_to_radians,
        .radial_a => return pose.radial_a * radial_solve_space_scale,
        .radial_b => return pose.radial_b * radial_solve_space_scale,
        .radial_c => return pose.radial_c * radial_solve_space_scale,
        .center_shift_x => return pose.center_shift_x,
        .center_shift_y => return pose.center_shift_y,
    }
}

fn fillSolveVector(layout: []const SolveLayout, poses: []const ImagePose, solve_x: []f64) void {
    for (1..poses.len) |image_index| {
        const pose = poses[image_index];
        if (layout[image_index].yaw_index) |idx| solve_x[idx] = solveSpaceValue(pose, .yaw);
        if (layout[image_index].pitch_index) |idx| solve_x[idx] = solveSpaceValue(pose, .pitch);
        if (layout[image_index].roll_index) |idx| solve_x[idx] = solveSpaceValue(pose, .roll);
        if (layout[image_index].hfov_index) |idx| solve_x[idx] = solveSpaceValue(pose, .hfov_delta);
        if (layout[image_index].trans_x_index) |idx| solve_x[idx] = solveSpaceValue(pose, .trans_x);
        if (layout[image_index].trans_y_index) |idx| solve_x[idx] = solveSpaceValue(pose, .trans_y);
        if (layout[image_index].trans_z_index) |idx| solve_x[idx] = solveSpaceValue(pose, .trans_z);
        if (layout[image_index].translation_plane_yaw_index) |idx| solve_x[idx] = solveSpaceValue(pose, .translation_plane_yaw);
        if (layout[image_index].translation_plane_pitch_index) |idx| solve_x[idx] = solveSpaceValue(pose, .translation_plane_pitch);
        if (layout[image_index].radial_a_index) |idx| solve_x[idx] = solveSpaceValue(pose, .radial_a);
        if (layout[image_index].radial_b_index) |idx| solve_x[idx] = solveSpaceValue(pose, .radial_b);
        if (layout[image_index].radial_c_index) |idx| solve_x[idx] = solveSpaceValue(pose, .radial_c);
        if (layout[image_index].center_shift_x_index) |idx| solve_x[idx] = solveSpaceValue(pose, .center_shift_x);
        if (layout[image_index].center_shift_y_index) |idx| solve_x[idx] = solveSpaceValue(pose, .center_shift_y);
    }
}

fn applySolveVector(layout: []const SolveLayout, poses: []ImagePose, solve_x: []const f64) void {
    const prof = profiler.scope("optimize.applySolveVector");
    defer prof.end();

    for (1..poses.len) |image_index| {
        applySolveVectorImage(layout[image_index], &poses[image_index], solve_x);
    }
}

fn applySolveVectorImage(entry: SolveLayout, pose: *ImagePose, solve_x: []const f64) void {
    if (entry.yaw_index) |idx| setSolveSpaceValue(pose, .yaw, solve_x[idx]);
    if (entry.pitch_index) |idx| setSolveSpaceValue(pose, .pitch, solve_x[idx]);
    if (entry.roll_index) |idx| setSolveSpaceValue(pose, .roll, solve_x[idx]);
    if (entry.hfov_index) |idx| setSolveSpaceValue(pose, .hfov_delta, solve_x[idx]);
    if (entry.trans_x_index) |idx| setSolveSpaceValue(pose, .trans_x, solve_x[idx]);
    if (entry.trans_y_index) |idx| setSolveSpaceValue(pose, .trans_y, solve_x[idx]);
    if (entry.trans_z_index) |idx| setSolveSpaceValue(pose, .trans_z, solve_x[idx]);
    if (entry.translation_plane_yaw_index) |idx| setSolveSpaceValue(pose, .translation_plane_yaw, solve_x[idx]);
    if (entry.translation_plane_pitch_index) |idx| setSolveSpaceValue(pose, .translation_plane_pitch, solve_x[idx]);
    if (entry.radial_a_index) |idx| setSolveSpaceValue(pose, .radial_a, solve_x[idx]);
    if (entry.radial_b_index) |idx| setSolveSpaceValue(pose, .radial_b, solve_x[idx]);
    if (entry.radial_c_index) |idx| setSolveSpaceValue(pose, .radial_c, solve_x[idx]);
    if (entry.center_shift_x_index) |idx| setSolveSpaceValue(pose, .center_shift_x, solve_x[idx]);
    if (entry.center_shift_y_index) |idx| setSolveSpaceValue(pose, .center_shift_y, solve_x[idx]);
}

fn setSolveSpaceValue(pose: *ImagePose, field: PoseField, solve_value: f64) void {
    switch (field) {
        .yaw => pose.yaw = normalizeAngleRadians(solve_value * degrees_to_radians),
        .pitch => pose.pitch = normalizeAngleRadians(solve_value * degrees_to_radians),
        .roll => pose.roll = normalizeAngleRadians(solve_value * degrees_to_radians),
        .hfov_delta => pose.hfov_delta = @abs(solve_value) - pose.base_hfov_degrees,
        .trans_x => pose.trans_x = solve_value,
        .trans_y => pose.trans_y = solve_value,
        .trans_z => pose.trans_z = solve_value,
        .translation_plane_yaw => {
            pose.translation_plane_yaw = solve_value * degrees_to_radians;
            const limit = 80.0 * degrees_to_radians;
            while (pose.translation_plane_yaw > pose.yaw + limit) pose.translation_plane_yaw -= std.math.pi;
            while (pose.translation_plane_yaw < pose.yaw - limit) pose.translation_plane_yaw += std.math.pi;
        },
        .translation_plane_pitch => {
            pose.translation_plane_pitch = solve_value * degrees_to_radians;
            const limit = 80.0 * degrees_to_radians;
            while (pose.translation_plane_pitch > pose.pitch + limit) pose.translation_plane_pitch -= std.math.pi;
            while (pose.translation_plane_pitch < pose.pitch - limit) pose.translation_plane_pitch += std.math.pi;
        },
        .radial_a => pose.radial_a = solve_value / radial_solve_space_scale,
        .radial_b => pose.radial_b = solve_value / radial_solve_space_scale,
        .radial_c => pose.radial_c = solve_value / radial_solve_space_scale,
        .center_shift_x => pose.center_shift_x = solve_value,
        .center_shift_y => pose.center_shift_y = solve_value,
    }
}

fn applySolveSpaceDelta(pose: *ImagePose, field: PoseField, solve_delta: f64) void {
    const current = solveSpaceValue(pose.*, field);
    setSolveSpaceValue(pose, field, current + solve_delta);
}

fn normalizeAngleRadians(angle: f64) f64 {
    return std.math.atan2(@sin(angle), @cos(angle));
}

pub fn transformPoint(pose: ImagePose, x: anytype, y: anytype, width: u32, height: u32) Point2 {
    const xf = @as(f64, x);
    const yf = @as(f64, y);
    if (hasBasicRectilinearPose(pose)) {
        return basicRectilinearTransformPoint(pose, xf, yf, width, height);
    }
    const src_center = distortionCenter(pose, width, height);
    const dest_center = panoramaCenter(width, height);
    const dest_focal = panoramaFocalLengthPixels(width, pose);
    const ray = sourceWorldRay(pose, xf - src_center.x, yf - src_center.y, width, height);
    const projected = if (hasTranslation(pose))
        projectViaTranslationPlane(pose, ray)
    else
        ray;
    const projected_xy = projectRectilinear(projected, dest_focal) orelse return .{ .x = -1.0, .y = -1.0 };
    return .{
        .x = dest_center.x + projected_xy.x,
        .y = dest_center.y + projected_xy.y,
    };
}

pub fn inverseTransformPoint(pose: ImagePose, out_x: f64, out_y: f64, width: u32, height: u32) Point2 {
    if (hasBasicRectilinearPose(pose)) {
        return basicRectilinearInverseTransformPoint(pose, out_x, out_y, width, height);
    }
    const src_center = distortionCenter(pose, width, height);
    const dest_center = panoramaCenter(width, height);
    const dest_focal = panoramaFocalLengthPixels(width, pose);
    const pano_ray = rectilinearRay(out_x - dest_center.x, out_y - dest_center.y, dest_focal);
    const camera_ray = if (hasTranslation(pose))
        rayFromTranslationPlane(pose, pano_ray) orelse return .{ .x = -1.0, .y = -1.0 }
    else
        pano_ray;
    const radial = imagePlaneFromWorldRay(pose, camera_ray, width);
    const radial_x = radial.x;
    const radial_y = radial.y;
    const undistorted = invertRadialDistortion(pose, radial_x, radial_y, width, height);
    return .{
        .x = src_center.x + undistorted.x,
        .y = src_center.y + undistorted.y,
    };
}

fn basicRectilinearTransformPoint(pose: ImagePose, x: f64, y: f64, width: u32, height: u32) Point2 {
    const src_center = distortionCenter(pose, width, height);
    const dest_center = panoramaCenter(width, height);
    const pano_distance = panoramaFocalLengthPixels(width, pose);
    const image_focal = focalLengthPixels(width, effectiveHfovDegrees(pose));
    const resize_scale = pano_distance / image_focal;

    var p = Point2{
        .x = (x - src_center.x) * resize_scale,
        .y = (y - src_center.y) * resize_scale,
    };
    p = sphereTpRectPoint(p, pano_distance);
    p = perspSpherePoint(p, setMatrix(pose.pitch, 0.0, pose.roll, true), pano_distance);
    p = erectSphereTpPoint(p, pano_distance);
    p = rotateErectPoint(p, pano_distance * std.math.pi, pose.yaw * pano_distance);
    p = rectErectPoint(p, pano_distance) orelse return .{ .x = -1.0, .y = -1.0 };
    return .{
        .x = dest_center.x + p.x,
        .y = dest_center.y + p.y,
    };
}

fn basicRectilinearInverseTransformPoint(pose: ImagePose, out_x: f64, out_y: f64, width: u32, height: u32) Point2 {
    const src_center = distortionCenter(pose, width, height);
    const dest_center = panoramaCenter(width, height);
    const pano_distance = panoramaFocalLengthPixels(width, pose);
    const image_focal = focalLengthPixels(width, effectiveHfovDegrees(pose));
    const resize_scale = image_focal / pano_distance;

    var p = Point2{
        .x = out_x - dest_center.x,
        .y = out_y - dest_center.y,
    };
    p = erectRectPoint(p, pano_distance);
    p = rotateErectPoint(p, pano_distance * std.math.pi, -pose.yaw * pano_distance);
    p = sphereTpErectPoint(p, pano_distance);
    p = perspSpherePoint(p, setMatrix(pose.pitch, 0.0, pose.roll, true), pano_distance);
    p = rectSphereTpPoint(p, pano_distance);
    p.x *= resize_scale;
    p.y *= resize_scale;
    return .{
        .x = src_center.x + p.x,
        .y = src_center.y + p.y,
    };
}

fn focalLengthPixels(width: u32, hfov_degrees: f64) f64 {
    const clamped_hfov = std.math.clamp(hfov_degrees, 1e-3, 179.0);
    return (@as(f64, @floatFromInt(width)) * 0.5) / @tan(clamped_hfov * std.math.pi / 360.0);
}

fn panoramaCenter(width: u32, height: u32) Point2 {
    return .{
        .x = (@as(f64, @floatFromInt(width)) - 1.0) * 0.5,
        .y = (@as(f64, @floatFromInt(height)) - 1.0) * 0.5,
    };
}

fn panoramaFocalLengthPixels(width: u32, pose: ImagePose) f64 {
    return focalLengthPixels(width, pose.base_hfov_degrees);
}

fn effectiveHfovDegrees(pose: ImagePose) f64 {
    return std.math.clamp(pose.base_hfov_degrees + pose.hfov_delta, 1e-3, 179.0);
}

const Vec3 = struct {
    x: f64,
    y: f64,
    z: f64,
};

fn normalize3(v: Vec3) Vec3 {
    const norm = length3(v);
    if (norm < 1e-12) return .{ .x = 0, .y = 0, .z = 1 };
    return .{
        .x = v.x / norm,
        .y = v.y / norm,
        .z = v.z / norm,
    };
}

const Matrix3 = [3][3]f64;

const BasicRectEquirectCache = struct {
    valid: bool = false,
    center: Point2 = .{ .x = 0.0, .y = 0.0 },
    pano_distance: f64 = 0.0,
    image_scale: f64 = 0.0,
    image_focal: f64 = 0.0,
    pitch_roll: Matrix3 = .{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
    },
    world_from_local: Matrix3 = .{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
    },
    yaw_turn: f64 = 0.0,
    radians_to_pixels: f64 = 0.0,
};

fn populateBasicRectEquirectCaches(poses: []const ImagePose, width: u32, height: u32, caches: []BasicRectEquirectCache) void {
    const prof = profiler.scope("optimize.populateBasicRectEquirectCaches");
    defer prof.end();

    std.debug.assert(poses.len == caches.len);
    for (poses, caches) |pose, *cache| {
        populateBasicRectEquirectCache(pose, width, height, cache);
    }
}

fn populateBasicRectEquirectCache(pose: ImagePose, width: u32, height: u32, cache: *BasicRectEquirectCache) void {
    if (!hasBasicRectilinearPose(pose)) {
        cache.* = .{ .valid = false };
        return;
    }
    const pano_distance = 180.0 / std.math.pi;
    const image_focal = focalLengthPixels(width, effectiveHfovDegrees(pose));
    const pitch_roll = setMatrix(pose.pitch, 0.0, pose.roll, true);
    const source_pitch_roll = setMatrix(-pose.pitch, 0.0, pose.roll, true);
    const world_from_local = matrixMatrixMul(yawMatrix(pose.yaw), transposeMatrix3(source_pitch_roll));
    cache.* = .{
        .valid = true,
        .center = distortionCenter(pose, width, height),
        .pano_distance = pano_distance,
        .image_scale = pano_distance / image_focal,
        .image_focal = image_focal,
        .pitch_roll = pitch_roll,
        .world_from_local = world_from_local,
        .yaw_turn = pose.yaw / degrees_to_radians,
        .radians_to_pixels = panoRadiansToPixels(width, pose.base_hfov_degrees),
    };
}

fn sourceWorldRay(pose: ImagePose, dx: f64, dy: f64, width: u32, height: u32) Vec3 {
    const shifted = Point2{
        .x = dx - pose.center_shift_x,
        .y = dy - pose.center_shift_y,
    };
    const distorted = applyRadialDistortion(pose, shifted.x, shifted.y, width, height);
    const src_focal = focalLengthPixels(width, effectiveHfovDegrees(pose));
    const local_ray = rectilinearRay(distorted.x, distorted.y, src_focal);
    const pitch_roll = setMatrix(-pose.pitch, 0.0, pose.roll, true);
    const pitched_rolled = matrixInvMul(pitch_roll, local_ray);
    return rotateYaw(pitched_rolled, pose.yaw);
}

fn panoramaVectorForControlPoint(
    poses: []const ImagePose,
    pair_match: match_mod.PairMatches,
    image_index: usize,
    x: f64,
    y: f64,
    override_image_index: ?usize,
    override_pose: ImagePose,
) Vec3 {
    const pose = if (override_image_index != null and override_image_index.? == image_index) override_pose else poses[image_index];
    const center = distortionCenter(pose, pair_match.image_width, pair_match.image_height);
    const ray = sourceWorldRay(
        pose,
        x - center.x,
        y - center.y,
        pair_match.image_width,
        pair_match.image_height,
    );
    const projected = if (hasTranslation(pose))
        projectViaTranslationPlane(pose, ray)
    else
        ray;
    return normalize3(projected);
}

fn panoRadiansToPixels(width: u32, hfov_degrees: f64) f64 {
    return @as(f64, @floatFromInt(width)) / (hfov_degrees * std.math.pi / 180.0);
}

fn longitudeOf(v: Vec3) f64 {
    return std.math.atan2(v.x, -v.z);
}

fn zenithAngle(v: Vec3) f64 {
    return std.math.acos(std.math.clamp(v.y, -1.0, 1.0));
}

fn imagePlaneFromWorldRay(pose: ImagePose, world_ray: Vec3, width: u32) Point2 {
    const pitch_roll = setMatrix(-pose.pitch, 0.0, pose.roll, true);
    const unyawed = rotateYaw(world_ray, -pose.yaw);
    const local_ray = matrixMul(pitch_roll, unyawed);
    const src_focal = focalLengthPixels(width, effectiveHfovDegrees(pose));
    const denom = -local_ray.z;
    if (@abs(denom) < 1e-12) return .{ .x = -1.0, .y = -1.0 };
    return .{
        .x = src_focal * (local_ray.x / denom) + pose.center_shift_x,
        .y = src_focal * (local_ray.y / denom) + pose.center_shift_y,
    };
}

fn rectilinearRay(x: f64, y: f64, focal: f64) Vec3 {
    return normalize3(.{
        .x = x,
        .y = y,
        .z = -focal,
    });
}

fn rotateYaw(ray: Vec3, yaw: f64) Vec3 {
    const c = @cos(yaw);
    const s = @sin(yaw);
    return .{
        .x = c * ray.x - s * ray.z,
        .y = ray.y,
        .z = s * ray.x + c * ray.z,
    };
}

fn yawMatrix(yaw: f64) Matrix3 {
    const c = @cos(yaw);
    const s = @sin(yaw);
    return .{
        .{ c, 0.0, -s },
        .{ 0.0, 1.0, 0.0 },
        .{ s, 0.0, c },
    };
}

fn setMatrix(a: f64, b: f64, c: f64, cl: bool) Matrix3 {
    const mx: Matrix3 = .{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, @cos(a), @sin(a) },
        .{ 0.0, -@sin(a), @cos(a) },
    };
    const my: Matrix3 = .{
        .{ @cos(b), 0.0, -@sin(b) },
        .{ 0.0, 1.0, 0.0 },
        .{ @sin(b), 0.0, @cos(b) },
    };
    const mz: Matrix3 = .{
        .{ @cos(c), @sin(c), 0.0 },
        .{ -@sin(c), @cos(c), 0.0 },
        .{ 0.0, 0.0, 1.0 },
    };
    const dummy = if (cl) matrixMatrixMul(mz, mx) else matrixMatrixMul(mx, mz);
    return matrixMatrixMul(dummy, my);
}

fn matrixMul(m: Matrix3, v: Vec3) Vec3 {
    return .{
        .x = m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
        .y = m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
        .z = m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z,
    };
}

fn matrixInvMul(m: Matrix3, v: Vec3) Vec3 {
    return .{
        .x = m[0][0] * v.x + m[1][0] * v.y + m[2][0] * v.z,
        .y = m[0][1] * v.x + m[1][1] * v.y + m[2][1] * v.z,
        .z = m[0][2] * v.x + m[1][2] * v.y + m[2][2] * v.z,
    };
}

fn transposeMatrix3(m: Matrix3) Matrix3 {
    return .{
        .{ m[0][0], m[1][0], m[2][0] },
        .{ m[0][1], m[1][1], m[2][1] },
        .{ m[0][2], m[1][2], m[2][2] },
    };
}

fn matrixMatrixMul(m1: Matrix3, m2: Matrix3) Matrix3 {
    var result: Matrix3 = undefined;
    for (0..3) |i| {
        for (0..3) |k| {
            result[i][k] = m1[i][0] * m2[0][k] + m1[i][1] * m2[1][k] + m1[i][2] * m2[2][k];
        }
    }
    return result;
}

fn hasTranslation(pose: ImagePose) bool {
    return @abs(pose.trans_x) > 1e-12 or @abs(pose.trans_y) > 1e-12 or @abs(pose.trans_z) > 1e-12;
}

fn translationPlaneNormal(pose: ImagePose) Vec3 {
    return cartErect(pose.translation_plane_yaw, -pose.translation_plane_pitch, 1.0);
}

fn projectViaTranslationPlane(pose: ImagePose, world_ray: Vec3) Vec3 {
    const camera = Vec3{ .x = pose.trans_x, .y = pose.trans_y, .z = pose.trans_z };
    const target = Vec3{
        .x = camera.x + world_ray.x,
        .y = camera.y + world_ray.y,
        .z = camera.z + world_ray.z,
    };
    return linePlaneIntersection(translationPlaneNormal(pose), camera, target) orelse .{ .x = 0.0, .y = 0.0, .z = 1.0 };
}

fn rayFromTranslationPlane(pose: ImagePose, pano_ray: Vec3) ?Vec3 {
    const plane_hit = linePlaneIntersection(
        translationPlaneNormal(pose),
        .{ .x = 0.0, .y = 0.0, .z = 0.0 },
        pano_ray,
    ) orelse return null;
    return normalize3(.{
        .x = plane_hit.x - pose.trans_x,
        .y = plane_hit.y - pose.trans_y,
        .z = plane_hit.z - pose.trans_z,
    });
}

fn linePlaneIntersection(normal: Vec3, p1: Vec3, p2: Vec3) ?Vec3 {
    const direction = Vec3{
        .x = p2.x - p1.x,
        .y = p2.y - p1.y,
        .z = p2.z - p1.z,
    };
    const numerator = 1.0 - dot3(normal, p1);
    const denominator = dot3(normal, direction);
    if (@abs(denominator) < 1e-12) return null;
    const u = numerator / denominator;
    return .{
        .x = p1.x + u * direction.x,
        .y = p1.y + u * direction.y,
        .z = p1.z + u * direction.z,
    };
}

fn cartErect(x: f64, y: f64, distance: f64) Vec3 {
    const phi = x / distance;
    const theta_zenith = std.math.pi * 0.5 - (y / distance);
    return .{
        .x = @sin(theta_zenith) * @sin(phi),
        .y = @cos(theta_zenith),
        .z = @sin(theta_zenith) * -@cos(phi),
    };
}

fn dot3(a: Vec3, b: Vec3) f64 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

fn cross3(a: Vec3, b: Vec3) Vec3 {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x,
    };
}

fn length3(v: Vec3) f64 {
    return @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

fn projectRectilinear(v: Vec3, focal: f64) ?Point2 {
    const denom = -v.z;
    if (denom <= 1e-12) return null;
    return .{
        .x = focal * (v.x / denom),
        .y = focal * (v.y / denom),
    };
}

fn distortionCenter(pose: ImagePose, width: u32, height: u32) Point2 {
    _ = pose;
    return .{
        .x = (@as(f64, @floatFromInt(width)) - 1.0) * 0.5,
        .y = (@as(f64, @floatFromInt(height)) - 1.0) * 0.5,
    };
}

fn radialNormalizer(width: u32, height: u32) f64 {
    const half_w = (@as(f64, @floatFromInt(width)) - 1.0) * 0.5;
    const half_h = (@as(f64, @floatFromInt(height)) - 1.0) * 0.5;
    const denom = half_w * half_w + half_h * half_h;
    if (denom >= 1e-12) return 1.0 / denom;
    return 1.0;
}

fn radialScale(pose: ImagePose, normalized_r2: f64) f64 {
    const r4 = normalized_r2 * normalized_r2;
    const r6 = r4 * normalized_r2;
    return 1.0 + pose.radial_a * normalized_r2 + pose.radial_b * r4 + pose.radial_c * r6;
}

fn applyRadialDistortion(pose: ImagePose, dx: f64, dy: f64, width: u32, height: u32) Point2 {
    const normalized_r2 = (dx * dx + dy * dy) * radialNormalizer(width, height);
    const factor = radialScale(pose, normalized_r2);
    return .{
        .x = dx * factor,
        .y = dy * factor,
    };
}

fn invertRadialDistortion(pose: ImagePose, dx: f64, dy: f64, width: u32, height: u32) Point2 {
    const q_radius = @sqrt(dx * dx + dy * dy);
    if (q_radius < 1e-12) {
        return .{ .x = dx, .y = dy };
    }

    const inv_norm = radialNormalizer(width, height);
    var radius = q_radius;
    for (0..6) |_| {
        const normalized_r2 = radius * radius * inv_norm;
        const normalized_r4 = normalized_r2 * normalized_r2;
        const factor = radialScale(pose, normalized_r2);
        const factor_derivative =
            pose.radial_a +
            2.0 * pose.radial_b * normalized_r2 +
            3.0 * pose.radial_c * normalized_r4;
        const f = radius * factor - q_radius;
        const df = factor + 2.0 * radius * radius * inv_norm * factor_derivative;
        if (@abs(df) < 1e-12) break;
        radius -= f / df;
        radius = @max(radius, 0.0);
    }

    const scale = radius / q_radius;
    return .{
        .x = dx * scale,
        .y = dy * scale,
    };
}

fn applySolveUpdate(layout: []const SolveLayout, poses: []ImagePose, delta: []const f64) void {
    applyScaledSolveUpdate(layout, poses, delta, 1.0);
}

fn applyScaledSolveUpdate(layout: []const SolveLayout, poses: []ImagePose, delta: []const f64, scale: f64) void {
    for (1..poses.len) |image_index| {
        if (layout[image_index].yaw_index) |idx| applySolveSpaceDelta(&poses[image_index], .yaw, scale * delta[idx]);
        if (layout[image_index].pitch_index) |idx| applySolveSpaceDelta(&poses[image_index], .pitch, scale * delta[idx]);
        if (layout[image_index].roll_index) |idx| applySolveSpaceDelta(&poses[image_index], .roll, scale * delta[idx]);
        if (layout[image_index].hfov_index) |idx| applySolveSpaceDelta(&poses[image_index], .hfov_delta, scale * delta[idx]);
        if (layout[image_index].trans_x_index) |idx| applySolveSpaceDelta(&poses[image_index], .trans_x, scale * delta[idx]);
        if (layout[image_index].trans_y_index) |idx| applySolveSpaceDelta(&poses[image_index], .trans_y, scale * delta[idx]);
        if (layout[image_index].trans_z_index) |idx| applySolveSpaceDelta(&poses[image_index], .trans_z, scale * delta[idx]);
        if (layout[image_index].translation_plane_yaw_index) |idx| applySolveSpaceDelta(&poses[image_index], .translation_plane_yaw, scale * delta[idx]);
        if (layout[image_index].translation_plane_pitch_index) |idx| applySolveSpaceDelta(&poses[image_index], .translation_plane_pitch, scale * delta[idx]);
        if (layout[image_index].radial_a_index) |idx| applySolveSpaceDelta(&poses[image_index], .radial_a, scale * delta[idx]);
        if (layout[image_index].radial_b_index) |idx| applySolveSpaceDelta(&poses[image_index], .radial_b, scale * delta[idx]);
        if (layout[image_index].radial_c_index) |idx| applySolveSpaceDelta(&poses[image_index], .radial_c, scale * delta[idx]);
        if (layout[image_index].center_shift_x_index) |idx| applySolveSpaceDelta(&poses[image_index], .center_shift_x, scale * delta[idx]);
        if (layout[image_index].center_shift_y_index) |idx| applySolveSpaceDelta(&poses[image_index], .center_shift_y, scale * delta[idx]);
    }
}

fn suppressUnstableLensTerms(iteration: usize, layout: []const SolveLayout, delta: []f64) void {
    if (iteration < 3) {
        for (layout[1..]) |entry| {
            if (entry.radial_a_index) |idx| delta[idx] = 0;
            if (entry.radial_b_index) |idx| delta[idx] = 0;
            if (entry.radial_c_index) |idx| delta[idx] = 0;
            if (entry.center_shift_x_index) |idx| delta[idx] = 0;
            if (entry.center_shift_y_index) |idx| delta[idx] = 0;
        }
        return;
    }
    if (iteration < 6) {
        for (layout[1..]) |entry| {
            if (entry.radial_a_index) |idx| delta[idx] = 0;
            if (entry.radial_b_index) |idx| delta[idx] = 0;
            if (entry.radial_c_index) |idx| delta[idx] = 0;
            if (entry.center_shift_x_index) |idx| delta[idx] = 0;
            if (entry.center_shift_y_index) |idx| delta[idx] = 0;
        }
    }
}

fn clampSolveDelta(layout: []const SolveLayout, delta: []f64) void {
    for (layout[1..]) |entry| {
        if (entry.trans_x_index) |idx| delta[idx] = std.math.clamp(delta[idx], -0.02, 0.02);
        if (entry.trans_y_index) |idx| delta[idx] = std.math.clamp(delta[idx], -0.02, 0.02);
        if (entry.trans_z_index) |idx| delta[idx] = std.math.clamp(delta[idx], -0.01, 0.01);
        if (entry.radial_a_index) |idx| delta[idx] = std.math.clamp(delta[idx], -4.0, 4.0);
        if (entry.radial_b_index) |idx| delta[idx] = std.math.clamp(delta[idx], -4.0, 4.0);
        if (entry.radial_c_index) |idx| delta[idx] = std.math.clamp(delta[idx], -4.0, 4.0);
        if (entry.center_shift_x_index) |idx| delta[idx] = std.math.clamp(delta[idx], -32.0, 32.0);
        if (entry.center_shift_y_index) |idx| delta[idx] = std.math.clamp(delta[idx], -32.0, 32.0);
    }
}

fn maxAbs(values: []const f64) f64 {
    var best: f64 = 0;
    for (values) |value| {
        best = @max(best, @abs(value));
    }
    return best;
}

fn totalSquaredResidual(pair_matches: []const match_mod.PairMatches, poses: []const ImagePose) f64 {
    var total: f64 = 0;
    for (pair_matches) |pair_match| {
        for (pair_match.control_points) |cp| {
            const residual = controlPointResidualVector(poses, pair_match, cp);
            total += residual.x * residual.x + residual.y * residual.y;
        }
    }
    return total;
}

fn totalSquaredObjectiveResidual(initial_avg_hfov: f64, pair_matches: []const match_mod.PairMatches, poses: []const ImagePose) f64 {
    var total: f64 = 0;
    for (pair_matches) |pair_match| {
        for (pair_match.control_points) |cp| {
            const residual = objectiveResidualVector(initial_avg_hfov, poses, pair_match, cp);
            total += residual.x * residual.x + residual.y * residual.y;
        }
    }
    return total;
}

fn totalSquaredDistanceResidual(initial_avg_hfov: f64, pair_matches: []const match_mod.PairMatches, poses: []const ImagePose) f64 {
    var total: f64 = 0;
    for (pair_matches) |pair_match| {
        for (pair_match.control_points) |cp| {
            const residual = objectiveDistanceResidual(initial_avg_hfov, poses, pair_match, cp);
            total += residual * residual;
        }
    }
    return total;
}

fn totalSquaredStrategyResidual(strategy: SolveStrategy, initial_avg_hfov: f64, pair_matches: []const match_mod.PairMatches, poses: []const ImagePose) f64 {
    return switch (strategy) {
        .distance_only => totalSquaredDistanceResidual(initial_avg_hfov, pair_matches, poses),
        .componentwise => totalSquaredObjectiveResidual(initial_avg_hfov, pair_matches, poses),
    };
}

fn accumulateAbsolutePriors(normal: []f64, variable_count: usize, layout: []const SolveLayout) void {
    for (layout) |entry| {
        addEntryAbsolutePriors(normal, variable_count, entry);
    }
}

fn addEntryAbsolutePriors(normal: []f64, variable_count: usize, entry: SolveLayout) void {
    if (entry.trans_x_index) |idx| addDiagonalPrior(normal, variable_count, idx, 4.0);
    if (entry.trans_y_index) |idx| addDiagonalPrior(normal, variable_count, idx, 4.0);
    if (entry.trans_z_index) |idx| addDiagonalPrior(normal, variable_count, idx, 25.0);
    if (entry.translation_plane_yaw_index) |idx| addDiagonalPrior(normal, variable_count, idx, 10.0);
    if (entry.translation_plane_pitch_index) |idx| addDiagonalPrior(normal, variable_count, idx, 10.0);
    if (entry.radial_a_index) |idx| addDiagonalPrior(normal, variable_count, idx, 1e-2);
    if (entry.radial_b_index) |idx| addDiagonalPrior(normal, variable_count, idx, 1e-2);
    if (entry.radial_c_index) |idx| addDiagonalPrior(normal, variable_count, idx, 1e-2);
    if (entry.center_shift_x_index) |idx| addDiagonalPrior(normal, variable_count, idx, 1e-4);
    if (entry.center_shift_y_index) |idx| addDiagonalPrior(normal, variable_count, idx, 1e-4);
}

fn accumulateUpdatePriors(normal: []f64, rhs: []f64, variable_count: usize, layout: []const SolveLayout, poses: []const ImagePose) void {
    for (layout, poses) |entry, pose| {
        addEntryUpdatePrior(normal, rhs, variable_count, entry.trans_x_index, pose.trans_x, 4.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.trans_y_index, pose.trans_y, 4.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.trans_z_index, pose.trans_z, 25.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.translation_plane_yaw_index, solveSpaceValue(pose, .translation_plane_yaw), 10.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.translation_plane_pitch_index, solveSpaceValue(pose, .translation_plane_pitch), 10.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.radial_a_index, pose.radial_a * radial_solve_space_scale, 1e-2);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.radial_b_index, pose.radial_b * radial_solve_space_scale, 1e-2);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.radial_c_index, pose.radial_c * radial_solve_space_scale, 1e-2);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.center_shift_x_index, pose.center_shift_x, 1e-4);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.center_shift_y_index, pose.center_shift_y, 1e-4);
    }
}

fn addEntryUpdatePrior(normal: []f64, rhs: []f64, variable_count: usize, maybe_index: ?usize, value: f64, weight: f64) void {
    if (maybe_index) |idx| {
        addDiagonalPrior(normal, variable_count, idx, weight);
        rhs[idx] += -weight * value;
    }
}

fn addDiagonalPrior(normal: []f64, variable_count: usize, index: usize, weight: f64) void {
    normal[index * variable_count + index] += weight;
}

fn accumulateEquation(
    normal: []f64,
    rhs: []f64,
    variable_count: usize,
    indices: []const usize,
    values: []const f64,
    observation: f64,
    weight: f64,
) void {
    for (indices, values) |row, value_i| {
        rhs[row] += weight * value_i * observation;
        for (indices, values) |col, value_j| {
            normal[row * variable_count + col] += weight * value_i * value_j;
        }
    }
}

fn solveLinearSystemInPlace(a: []f64, b: []f64, n: usize) SolveError!void {
    for (0..n) |pivot_index| {
        var best_row = pivot_index;
        var best_value = @abs(a[pivot_index * n + pivot_index]);
        for ((pivot_index + 1)..n) |row| {
            const value = @abs(a[row * n + pivot_index]);
            if (value > best_value) {
                best_value = value;
                best_row = row;
            }
        }

        if (best_value < 1e-9) {
            return error.SingularSystem;
        }

        if (best_row != pivot_index) {
            swapRows(a, b, n, pivot_index, best_row);
        }

        const pivot = a[pivot_index * n + pivot_index];
        for (pivot_index..n) |col| {
            a[pivot_index * n + col] /= pivot;
        }
        b[pivot_index] /= pivot;

        for (0..n) |row| {
            if (row == pivot_index) continue;
            const factor = a[row * n + pivot_index];
            if (@abs(factor) < 1e-12) continue;
            for (pivot_index..n) |col| {
                a[row * n + col] -= factor * a[pivot_index * n + col];
            }
            b[row] -= factor * b[pivot_index];
        }
    }
}

fn swapRows(a: []f64, b: []f64, n: usize, lhs: usize, rhs: usize) void {
    for (0..n) |col| {
        const lhs_index = lhs * n + col;
        const rhs_index = rhs * n + col;
        const tmp = a[lhs_index];
        a[lhs_index] = a[rhs_index];
        a[rhs_index] = tmp;
    }
    const tmp_b = b[lhs];
    b[lhs] = b[rhs];
    b[rhs] = tmp_b;
}

fn label(variable: Variable) []const u8 {
    return switch (variable) {
        .y => "y",
        .p => "p",
        .r => "r",
        .v => "v",
        .a => "a",
        .b => "b",
        .c => "c",
        .d => "d",
        .e => "e",
        .tr_x => "TrX",
        .tr_y => "TrY",
        .tr_z => "TrZ",
        .tpy => "Tpy",
        .tpp => "Tpp",
    };
}

test "first image stays fixed and later images default to y p r" {
    const allocator = std.testing.allocator;
    var cfg = config_mod.Config{
        .aligned_prefix = "out",
    };

    const vector = try buildOptimizeVector(allocator, &cfg, 3);
    defer allocator.free(vector);

    try std.testing.expect(!vector[0].contains(.y));
    try std.testing.expect(vector[1].contains(.y));
    try std.testing.expect(vector[1].contains(.p));
    try std.testing.expect(vector[1].contains(.r));
    try std.testing.expect(!vector[1].contains(.v));
}

test "optional optimization flags add their variables" {
    const allocator = std.testing.allocator;
    var cfg = config_mod.Config{
        .aligned_prefix = "out",
        .optimize_hfov = true,
        .optimize_distortion = true,
        .optimize_center_shift = true,
        .optimize_translation_x = true,
        .optimize_translation_y = true,
        .optimize_translation_z = true,
    };

    const vector = try buildOptimizeVector(allocator, &cfg, 2);
    defer allocator.free(vector);

    try std.testing.expect(vector[1].contains(.v));
    try std.testing.expect(vector[1].contains(.a));
    try std.testing.expect(vector[1].contains(.b));
    try std.testing.expect(vector[1].contains(.c));
    try std.testing.expect(vector[1].contains(.d));
    try std.testing.expect(vector[1].contains(.e));
    try std.testing.expect(vector[1].contains(.tr_x));
    try std.testing.expect(vector[1].contains(.tr_y));
    try std.testing.expect(vector[1].contains(.tr_z));
    try std.testing.expect(!vector[1].contains(.tpy));
    try std.testing.expect(!vector[1].contains(.tpp));
}

test "translation solve recovers a simple chain with TrX/TrY enabled" {
    const allocator = std.testing.allocator;
    const optimize_vector = [_]VariableSet{
        VariableSet.initEmpty(),
        blk: {
            var set = VariableSet.initEmpty();
            set.insert(.tr_x);
            set.insert(.tr_y);
            break :blk set;
        },
        blk: {
            var set = VariableSet.initEmpty();
            set.insert(.tr_x);
            set.insert(.tr_y);
            break :blk set;
        },
    };

    const cps01 = try allocator.dupe(match_mod.ControlPoint, &[_]match_mod.ControlPoint{
        .{
            .left_image = 0,
            .right_image = 1,
            .left_x = 10,
            .left_y = 20,
            .right_x = 13,
            .right_y = 18,
            .score = 0.95,
            .coarse_right_x = 13,
            .coarse_right_y = 18,
            .coarse_score = 0.95,
            .refined_score = 0.95,
        },
        .{
            .left_image = 0,
            .right_image = 1,
            .left_x = 30,
            .left_y = 10,
            .right_x = 33,
            .right_y = 8,
            .score = 0.9,
            .coarse_right_x = 33,
            .coarse_right_y = 8,
            .coarse_score = 0.9,
            .refined_score = 0.9,
        },
    });
    defer allocator.free(cps01);

    const cps12 = try allocator.dupe(match_mod.ControlPoint, &[_]match_mod.ControlPoint{
        .{
            .left_image = 1,
            .right_image = 2,
            .left_x = 12,
            .left_y = 22,
            .right_x = 16,
            .right_y = 19,
            .score = 0.96,
            .coarse_right_x = 16,
            .coarse_right_y = 19,
            .coarse_score = 0.96,
            .refined_score = 0.96,
        },
    });
    defer allocator.free(cps12);

    var pair_matches = [_]match_mod.PairMatches{
        .{
            .pair = .{ .left_index = 0, .right_index = 1 },
            .image_width = 100,
            .image_height = 80,
            .candidates_considered = 2,
            .coarse_control_point_count = cps01.len,
            .coarse_mean_score = 0.925,
            .coarse_best_score = 0.95,
            .refined_control_point_count = cps01.len,
            .control_point_storage = cps01,
            .control_points = cps01,
        },
        .{
            .pair = .{ .left_index = 1, .right_index = 2 },
            .image_width = 100,
            .image_height = 80,
            .candidates_considered = 1,
            .coarse_control_point_count = cps12.len,
            .coarse_mean_score = 0.96,
            .coarse_best_score = 0.96,
            .refined_control_point_count = cps12.len,
            .control_point_storage = cps12,
            .control_points = cps12,
        },
    };

    var result = try solvePoses(allocator, 3, 50.0, &optimize_vector, &pair_matches);
    defer result.deinit(allocator);

    const focal = focalLengthPixels(100, 50.0);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 / focal), @abs(result.poses[1].trans_x), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / focal), @abs(result.poses[1].trans_y), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0 / focal), @abs(result.poses[2].trans_x), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0 / focal), @abs(result.poses[2].trans_y), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.poses[1].roll, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.poses[2].roll, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.rms_error, 0.001);
}

test "parameter counting matches the active solve layout" {
    const vector = [_]VariableSet{
        VariableSet.initEmpty(),
        blk: {
            var set = VariableSet.initEmpty();
            set.insert(.y);
            set.insert(.p);
            set.insert(.r);
            break :blk set;
        },
        blk: {
            var set = VariableSet.initEmpty();
            set.insert(.y);
            set.insert(.p);
            set.insert(.v);
            set.insert(.a);
            set.insert(.b);
            set.insert(.d);
            break :blk set;
        },
    };

    try std.testing.expectEqual(@as(usize, 9), countSolveParameters(&vector));
}

test "transform round trip preserves points with extended pose terms" {
    const pose = ImagePose{
        .yaw = 0.004,
        .pitch = -0.003,
        .roll = 0.012,
        .hfov_delta = 0.15,
        .trans_x = -3.2,
        .trans_y = 2.4,
        .trans_z = -0.015,
        .translation_plane_yaw = 0.02,
        .translation_plane_pitch = -0.015,
        .radial_a = 0.02,
        .radial_b = -0.01,
        .radial_c = 0.005,
        .center_shift_x = 4.0,
        .center_shift_y = -2.5,
        .base_hfov_degrees = 50.0,
    };

    const mapped = transformPoint(pose, 120.0, 80.0, 400, 300);
    const recovered = inverseTransformPoint(pose, mapped.x, mapped.y, 400, 300);
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), recovered.x, 0.05);
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), recovered.y, 0.05);
}

test "basic rectilinear equirect cache matches uncached distSphere math" {
    const width: u32 = 7952;
    const height: u32 = 5304;
    const poses = [_]ImagePose{
        .{
            .yaw = 0.0,
            .pitch = 0.0,
            .roll = 0.0,
            .hfov_delta = 0.0,
            .base_hfov_degrees = 22.616454,
        },
        .{
            .yaw = -0.0787870154624771 * degrees_to_radians,
            .pitch = 0.0770185391742314 * degrees_to_radians,
            .roll = -0.375207122194465 * degrees_to_radians,
            .hfov_delta = 22.9667758269161 - 22.616454,
            .base_hfov_degrees = 22.616454,
        },
    };
    var caches: [poses.len]BasicRectEquirectCache = undefined;
    populateBasicRectEquirectCaches(&poses, width, height, &caches);

    const pair_match = match_mod.PairMatches{
        .pair = .{ .left_index = 0, .right_index = 1 },
        .image_width = width,
        .image_height = height,
        .candidates_considered = 0,
        .control_point_storage = &.{},
        .control_points = &.{},
    };
    const cp = match_mod.ControlPoint{
        .left_image = 0,
        .right_image = 1,
        .left_x = 1644.0,
        .left_y = 1510.0,
        .right_x = 1643.494,
        .right_y = 1513.182,
        .score = 1.0,
        .coarse_right_x = 1643.494,
        .coarse_right_y = 1513.182,
        .coarse_score = 1.0,
        .refined_score = 1.0,
    };

    const uncached_distance = exactDistSphereDistance(poses[0], poses[1], pair_match, cp);
    const cached_distance = exactDistSphereDistanceCached(caches[0], caches[1], cp);
    try std.testing.expectApproxEqAbs(uncached_distance, cached_distance, 1e-9);

    const uncached_vector = exactDistSphereResidualVector(poses[0], poses[1], pair_match, cp);
    const cached_vector = exactDistSphereResidualVectorCached(caches[0], caches[1], cp);
    try std.testing.expectApproxEqAbs(uncached_vector.x, cached_vector.x, 1e-9);
    try std.testing.expectApproxEqAbs(uncached_vector.y, cached_vector.y, 1e-9);
}

test "objective jacobian sparsity matches image-pair locality" {
    const allocator = std.testing.allocator;

    const optimize_vector = [_]VariableSet{
        VariableSet.initEmpty(),
        VariableSet.initMany(&.{ .y, .p, .r, .v }),
        VariableSet.initMany(&.{ .y, .p, .r, .v }),
    };
    var cps = [_]match_mod.ControlPoint{
        .{
            .left_image = 0,
            .right_image = 1,
            .left_x = 10,
            .left_y = 20,
            .right_x = 11,
            .right_y = 21,
            .score = 1.0,
            .coarse_right_x = 11,
            .coarse_right_y = 21,
            .coarse_score = 1.0,
            .refined_score = 1.0,
        },
        .{
            .left_image = 0,
            .right_image = 2,
            .left_x = 30,
            .left_y = 40,
            .right_x = 31,
            .right_y = 41,
            .score = 1.0,
            .coarse_right_x = 31,
            .coarse_right_y = 41,
            .coarse_score = 1.0,
            .refined_score = 1.0,
        },
    };
    const pair_matches = [_]match_mod.PairMatches{
        .{
            .pair = .{ .left_index = 0, .right_index = 1 },
            .image_width = 100,
            .image_height = 80,
            .candidates_considered = 1,
            .control_point_storage = cps[0..1],
            .control_points = cps[0..1],
        },
        .{
            .pair = .{ .left_index = 0, .right_index = 2 },
            .image_width = 100,
            .image_height = 80,
            .candidates_considered = 1,
            .control_point_storage = cps[1..2],
            .control_points = cps[1..2],
        },
    };

    var pattern = try buildObjectiveJacobianPattern(allocator, &optimize_vector, &pair_matches, .componentwise);
    defer pattern.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), pattern.row_count);
    try std.testing.expectEqual(@as(usize, 8), pattern.col_count);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 4, 6, 8, 10, 12, 14, 16 }, pattern.col_ptr);

    var groups = try sparse_matrix.partitionIndependentColumns(allocator, &pattern);
    defer groups.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), groups.groupCount());
    try std.testing.expectEqualSlices(usize, &.{ 0, 4 }, groups.groupColumns(0));
    try std.testing.expectEqualSlices(usize, &.{ 1, 5 }, groups.groupColumns(1));
    try std.testing.expectEqualSlices(usize, &.{ 2, 6 }, groups.groupColumns(2));
    try std.testing.expectEqualSlices(usize, &.{ 3, 7 }, groups.groupColumns(3));
}

test "sparse grouped objective jacobian matches dense finite differences" {
    const allocator = std.testing.allocator;

    const optimize_vector = [_]VariableSet{
        VariableSet.initEmpty(),
        VariableSet.initMany(&.{ .y, .p, .r, .v }),
        VariableSet.initMany(&.{ .y, .p, .r, .v }),
    };
    const base_poses = [_]ImagePose{
        .{ .base_hfov_degrees = 50.0 },
        .{ .yaw = 0.001, .pitch = -0.002, .roll = 0.003, .hfov_delta = 0.25, .base_hfov_degrees = 50.0 },
        .{ .yaw = -0.002, .pitch = 0.001, .roll = -0.004, .hfov_delta = 0.5, .base_hfov_degrees = 50.0 },
    };
    var cps = [_]match_mod.ControlPoint{
        .{
            .left_image = 0,
            .right_image = 1,
            .left_x = 10,
            .left_y = 20,
            .right_x = 11,
            .right_y = 21,
            .score = 1.0,
            .coarse_right_x = 11,
            .coarse_right_y = 21,
            .coarse_score = 1.0,
            .refined_score = 1.0,
        },
        .{
            .left_image = 0,
            .right_image = 2,
            .left_x = 30,
            .left_y = 40,
            .right_x = 31,
            .right_y = 41,
            .score = 1.0,
            .coarse_right_x = 31,
            .coarse_right_y = 41,
            .coarse_score = 1.0,
            .refined_score = 1.0,
        },
    };
    const pair_matches = [_]match_mod.PairMatches{
        .{
            .pair = .{ .left_index = 0, .right_index = 1 },
            .image_width = 100,
            .image_height = 80,
            .candidates_considered = 1,
            .control_point_storage = cps[0..1],
            .control_points = cps[0..1],
        },
        .{
            .pair = .{ .left_index = 0, .right_index = 2 },
            .image_width = 100,
            .image_height = 80,
            .candidates_considered = 1,
            .control_point_storage = cps[1..2],
            .control_points = cps[1..2],
        },
    };

    const solve_x = try encodeSolveVector(allocator, &optimize_vector, &base_poses);
    defer allocator.free(solve_x);
    var sparse_jac = try evaluateObjectiveJacobianSparse(
        allocator,
        .componentwise,
        &optimize_vector,
        &base_poses,
        &pair_matches,
        solve_x,
        0.0,
    );
    defer sparse_jac.deinit(allocator);

    const initial_avg_hfov = averageHfovDegrees(&base_poses);
    const base_eval_poses = try decodeSolveVector(allocator, &optimize_vector, &base_poses, solve_x);
    defer allocator.free(base_eval_poses);
    const base_fvec = try evaluateObjectiveResidualsPadded(
        allocator,
        .componentwise,
        initial_avg_hfov,
        &pair_matches,
        base_eval_poses,
        null,
    );
    defer allocator.free(base_fvec);

    const shifted_x = try allocator.dupe(f64, solve_x);
    defer allocator.free(shifted_x);
    const eps = @sqrt(@max(std.math.floatEps(f64) * 10.0, std.math.floatEps(f64)));
    for (0..solve_x.len) |column| {
        @memcpy(shifted_x, solve_x);
        var h = eps * @abs(shifted_x[column]);
        if (h == 0.0) h = eps;
        shifted_x[column] += h;

        const shifted_poses = try decodeSolveVector(allocator, &optimize_vector, &base_poses, shifted_x);
        defer allocator.free(shifted_poses);
        const shifted_fvec = try evaluateObjectiveResidualsPadded(
            allocator,
            .componentwise,
            initial_avg_hfov,
            &pair_matches,
            shifted_poses,
            null,
        );
        defer allocator.free(shifted_fvec);

        const start = sparse_jac.col_ptr[column];
        const end = sparse_jac.col_ptr[column + 1];
        for (start..end) |entry_index| {
            const row = sparse_jac.row_idx[entry_index];
            const dense_value = (shifted_fvec[row] - base_fvec[row]) / h;
            try std.testing.expectApproxEqAbs(dense_value, sparse_jac.values[entry_index], 1e-9);
        }
    }
}

test "pruning removes residual outliers" {
    const allocator = std.testing.allocator;

    const cps = try allocator.dupe(match_mod.ControlPoint, &[_]match_mod.ControlPoint{
        .{
            .left_image = 0,
            .right_image = 1,
            .left_x = 0,
            .left_y = 0,
            .right_x = 5,
            .right_y = 0,
            .score = 0.9,
            .coarse_right_x = 5,
            .coarse_right_y = 0,
            .coarse_score = 0.9,
            .refined_score = 0.9,
        },
        .{
            .left_image = 0,
            .right_image = 1,
            .left_x = 10,
            .left_y = 0,
            .right_x = 50,
            .right_y = 0,
            .score = 0.8,
            .coarse_right_x = 50,
            .coarse_right_y = 0,
            .coarse_score = 0.8,
            .refined_score = 0.8,
        },
    });
    defer allocator.free(cps);

    var pair_matches = [_]match_mod.PairMatches{
        .{
            .pair = .{ .left_index = 0, .right_index = 1 },
            .image_width = 100,
            .image_height = 80,
            .candidates_considered = 2,
            .coarse_control_point_count = cps.len,
            .coarse_mean_score = 0.85,
            .coarse_best_score = 0.9,
            .refined_control_point_count = cps.len,
            .control_point_storage = cps,
            .control_points = cps,
        },
    };

    const residuals = [_]ControlPointResidual{
        .{ .pair_index = 0, .control_point_index = 0, .residual = 1.0 },
        .{ .pair_index = 0, .control_point_index = 1, .residual = 12.0 },
    };
    const kept = pruneByResidualThreshold(&pair_matches, &residuals, 3.0);

    try std.testing.expectEqual(@as(usize, 1), kept);
    try std.testing.expectEqual(@as(usize, 1), pair_matches[0].control_points.len);
    try std.testing.expectEqual(@as(f32, 5.0), pair_matches[0].control_points[0].right_x);
}
