const std = @import("std");
const config_mod = @import("config.zig");
const match_mod = @import("match.zig");

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
    const control_point_count = countControlPoints(pair_matches);
    if (control_point_count == 0) {
        return error.NoControlPoints;
    }

    const poses = try allocator.alloc(ImagePose, image_count);
    errdefer allocator.free(poses);
    @memset(poses, .{});
    for (poses) |*pose| {
        pose.base_hfov_degrees = base_hfov_degrees;
    }

    const layout = try buildSolveLayout(allocator, optimize_vector);
    defer allocator.free(layout);

    try seedPosesLinear(allocator, layout, pair_matches, poses);
    try refinePosesIteratively(allocator, layout, pair_matches, poses);

    const residuals = try allocator.alloc(ControlPointResidual, control_point_count);
    errdefer allocator.free(residuals);

    var cp_flat_index: usize = 0;
    var squared_error_sum: f64 = 0;
    var max_error: f64 = 0;

    for (pair_matches, 0..) |pair_match, pair_index| {
        for (pair_match.control_points, 0..) |cp, control_point_index| {
            const residual_vec = controlPointResidualVector(poses, pair_match, cp);
            const residual = @sqrt(residual_vec.x * residual_vec.x + residual_vec.y * residual_vec.y);

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
        try writer.print(
            "    [{d}] y={d:.5} p={d:.5} r={d:.5} v={d:.6} TrX={d:.3} TrY={d:.3} TrZ={d:.6} Tpy={d:.5} Tpp={d:.5} a={d:.6} b={d:.6} c={d:.6} d={d:.3} e={d:.3}\n",
            .{
                image_index,
                pose.yaw,
                pose.pitch,
                pose.roll,
                pose.hfov_delta,
                pose.trans_x,
                pose.trans_y,
                pose.trans_z,
                pose.translation_plane_yaw,
                pose.translation_plane_pitch,
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

fn linearTerms(x: f32, y: f32, width: u32, height: u32, base_hfov_degrees: f64) LinearTerms {
    const cx = (@as(f64, @floatFromInt(width)) - 1.0) * 0.5;
    const cy = (@as(f64, @floatFromInt(height)) - 1.0) * 0.5;
    const dx = @as(f64, x) - cx;
    const dy = @as(f64, y) - cy;
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

fn refinePosesIteratively(
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
    const delta = try allocator.alloc(f64, variable_count);
    defer allocator.free(delta);

    const max_iterations: usize = 8;
    const damping: f64 = 1e-3;

    for (0..max_iterations) |_| {
        @memset(normal, 0);
        @memset(rhs, 0);

        for (pair_matches) |pair_match| {
            for (pair_match.control_points) |cp| {
                const weight = @max(@as(f64, cp.score), 1e-3);
                const residual = controlPointResidualVector(poses, pair_match, cp);

                var indices = [_]usize{0} ** 16;
                var values_x = [_]f64{0} ** 16;
                var values_y = [_]f64{0} ** 16;
                var count: usize = 0;

                appendImageJacobian(layout, poses, cp.left_image, cp.left_x, cp.left_y, pair_match.image_width, pair_match.image_height, -1, &indices, &values_x, &values_y, &count);
                appendImageJacobian(layout, poses, cp.right_image, cp.right_x, cp.right_y, pair_match.image_width, pair_match.image_height, 1, &indices, &values_x, &values_y, &count);

                accumulateEquation(normal, rhs, variable_count, indices[0..count], values_x[0..count], -residual.x, weight);
                accumulateEquation(normal, rhs, variable_count, indices[0..count], values_y[0..count], -residual.y, weight);
            }
        }

        for (0..variable_count) |i| {
            normal[i * variable_count + i] += damping;
        }
        accumulateUpdatePriors(normal, rhs, variable_count, layout, poses);

        @memcpy(delta, rhs);
        try solveLinearSystemInPlace(normal, delta, variable_count);
        applySolveUpdate(layout, poses, delta);

        if (maxAbs(delta) < 1e-4) {
            break;
        }
    }
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
            if (entry.hfov_index) |idx| {
                indices[count.*] = idx;
                values[count.*] = sign * terms.sx / @max(terms.focal, 1.0);
                count.* += 1;
            }
            if (entry.trans_z_index) |idx| {
                indices[count.*] = idx;
                values[count.*] = sign * terms.sx / @max(terms.focal, 1.0);
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
            if (entry.hfov_index) |idx| {
                indices[count.*] = idx;
                values[count.*] = sign * terms.sy / @max(terms.focal, 1.0);
                count.* += 1;
            }
            if (entry.trans_z_index) |idx| {
                indices[count.*] = idx;
                values[count.*] = sign * terms.sy / @max(terms.focal, 1.0);
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

fn numericalDerivative(
    pose: ImagePose,
    x: f32,
    y: f32,
    width: u32,
    height: u32,
    field: PoseField,
) Vec2d {
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
    const left = transformPoint(poses[cp.left_image], cp.left_x, cp.left_y, pair_match.image_width, pair_match.image_height);
    const right = transformPoint(poses[cp.right_image], cp.right_x, cp.right_y, pair_match.image_width, pair_match.image_height);
    return .{
        .x = right.x - left.x,
        .y = right.y - left.y,
    };
}

pub fn transformPoint(pose: ImagePose, x: anytype, y: anytype, width: u32, height: u32) Point2 {
    const xf = @as(f64, x);
    const yf = @as(f64, y);
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
    const norm = @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (norm < 1e-12) return .{ .x = 0, .y = 0, .z = 1 };
    return .{
        .x = v.x / norm,
        .y = v.y / norm,
        .z = v.z / norm,
    };
}

const Matrix3 = [3][3]f64;

fn sourceWorldRay(pose: ImagePose, dx: f64, dy: f64, width: u32, height: u32) Vec3 {
    const distorted = applyRadialDistortion(pose, dx, dy, width, height);
    const src_focal = focalLengthPixels(width, effectiveHfovDegrees(pose));
    const local_ray = rectilinearRay(distorted.x, distorted.y, src_focal);
    const pitch_roll = setMatrix(-pose.pitch, 0.0, pose.roll, true);
    const pitched_rolled = matrixInvMul(pitch_roll, local_ray);
    return rotateYaw(pitched_rolled, pose.yaw);
}

fn imagePlaneFromWorldRay(pose: ImagePose, world_ray: Vec3, width: u32) Point2 {
    const pitch_roll = setMatrix(-pose.pitch, 0.0, pose.roll, true);
    const unyawed = rotateYaw(world_ray, -pose.yaw);
    const local_ray = matrixMul(pitch_roll, unyawed);
    const src_focal = focalLengthPixels(width, effectiveHfovDegrees(pose));
    const denom = -local_ray.z;
    if (@abs(denom) < 1e-12) return .{ .x = -1.0, .y = -1.0 };
    return .{
        .x = src_focal * (local_ray.x / denom),
        .y = src_focal * (local_ray.y / denom),
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

fn projectRectilinear(v: Vec3, focal: f64) ?Point2 {
    const denom = -v.z;
    if (denom <= 1e-12) return null;
    return .{
        .x = focal * (v.x / denom),
        .y = focal * (v.y / denom),
    };
}

fn distortionCenter(pose: ImagePose, width: u32, height: u32) Point2 {
    return .{
        .x = (@as(f64, @floatFromInt(width)) - 1.0) * 0.5 + pose.center_shift_x,
        .y = (@as(f64, @floatFromInt(height)) - 1.0) * 0.5 + pose.center_shift_y,
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
    for (1..poses.len) |image_index| {
        if (layout[image_index].yaw_index) |idx| poses[image_index].yaw += delta[idx];
        if (layout[image_index].pitch_index) |idx| poses[image_index].pitch += delta[idx];
        if (layout[image_index].roll_index) |idx| poses[image_index].roll += delta[idx];
        if (layout[image_index].hfov_index) |idx| poses[image_index].hfov_delta += delta[idx];
        if (layout[image_index].trans_x_index) |idx| poses[image_index].trans_x += delta[idx];
        if (layout[image_index].trans_y_index) |idx| poses[image_index].trans_y += delta[idx];
        if (layout[image_index].trans_z_index) |idx| poses[image_index].trans_z += delta[idx];
        if (layout[image_index].translation_plane_yaw_index) |idx| poses[image_index].translation_plane_yaw += delta[idx];
        if (layout[image_index].translation_plane_pitch_index) |idx| poses[image_index].translation_plane_pitch += delta[idx];
        if (layout[image_index].radial_a_index) |idx| poses[image_index].radial_a += delta[idx];
        if (layout[image_index].radial_b_index) |idx| poses[image_index].radial_b += delta[idx];
        if (layout[image_index].radial_c_index) |idx| poses[image_index].radial_c += delta[idx];
        if (layout[image_index].center_shift_x_index) |idx| poses[image_index].center_shift_x += delta[idx];
        if (layout[image_index].center_shift_y_index) |idx| poses[image_index].center_shift_y += delta[idx];
    }
}

fn maxAbs(values: []const f64) f64 {
    var best: f64 = 0;
    for (values) |value| {
        best = @max(best, @abs(value));
    }
    return best;
}

fn accumulateAbsolutePriors(normal: []f64, variable_count: usize, layout: []const SolveLayout) void {
    for (layout) |entry| {
        addEntryAbsolutePriors(normal, variable_count, entry);
    }
}

fn addEntryAbsolutePriors(normal: []f64, variable_count: usize, entry: SolveLayout) void {
    if (entry.trans_x_index) |idx| addDiagonalPrior(normal, variable_count, idx, 16.0);
    if (entry.trans_y_index) |idx| addDiagonalPrior(normal, variable_count, idx, 16.0);
    if (entry.hfov_index) |idx| addDiagonalPrior(normal, variable_count, idx, 1.0);
    if (entry.trans_z_index) |idx| addDiagonalPrior(normal, variable_count, idx, 400.0);
    if (entry.translation_plane_yaw_index) |idx| addDiagonalPrior(normal, variable_count, idx, 100.0);
    if (entry.translation_plane_pitch_index) |idx| addDiagonalPrior(normal, variable_count, idx, 100.0);
    if (entry.radial_a_index) |idx| addDiagonalPrior(normal, variable_count, idx, 64.0);
    if (entry.radial_b_index) |idx| addDiagonalPrior(normal, variable_count, idx, 64.0);
    if (entry.radial_c_index) |idx| addDiagonalPrior(normal, variable_count, idx, 64.0);
    if (entry.center_shift_x_index) |idx| addDiagonalPrior(normal, variable_count, idx, 0.0025);
    if (entry.center_shift_y_index) |idx| addDiagonalPrior(normal, variable_count, idx, 0.0025);
}

fn accumulateUpdatePriors(normal: []f64, rhs: []f64, variable_count: usize, layout: []const SolveLayout, poses: []const ImagePose) void {
    for (layout, poses) |entry, pose| {
        addEntryUpdatePrior(normal, rhs, variable_count, entry.trans_x_index, pose.trans_x, 16.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.trans_y_index, pose.trans_y, 16.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.hfov_index, pose.hfov_delta, 1.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.trans_z_index, pose.trans_z, 400.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.translation_plane_yaw_index, pose.translation_plane_yaw, 100.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.translation_plane_pitch_index, pose.translation_plane_pitch, 100.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.radial_a_index, pose.radial_a, 64.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.radial_b_index, pose.radial_b, 64.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.radial_c_index, pose.radial_c, 64.0);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.center_shift_x_index, pose.center_shift_x, 0.0025);
        addEntryUpdatePrior(normal, rhs, variable_count, entry.center_shift_y_index, pose.center_shift_y, 0.0025);
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
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 / focal), result.poses[1].trans_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -2.0 / focal), result.poses[1].trans_y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0 / focal), result.poses[2].trans_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -5.0 / focal), result.poses[2].trans_y, 0.001);
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

    try std.testing.expectEqual(@as(usize, 7), countSolveParameters(&vector));
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
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), recovered.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), recovered.y, 1e-5);
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
