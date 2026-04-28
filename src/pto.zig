const std = @import("std");
const config_mod = @import("config.zig");
const match_mod = @import("match.zig");
const optimize = @import("optimize.zig");
const sequence = @import("sequence.zig");

pub fn writePtoFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    cfg: *const config_mod.Config,
    images: []const sequence.InputImage,
    optimize_vector: []const optimize.VariableSet,
    pair_matches: []const match_mod.PairMatches,
    poses: []const optimize.ImagePose,
) !void {
    const data = try renderPto(allocator, cfg, images, optimize_vector, pair_matches, poses);
    defer allocator.free(data);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

pub fn renderPto(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    images: []const sequence.InputImage,
    optimize_vector: []const optimize.VariableSet,
    pair_matches: []const match_mod.PairMatches,
    poses: []const optimize.ImagePose,
) std.mem.Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    const writer = list.writer(allocator);

    const projection: u8 = if (cfg.fisheye) 3 else 0;
    const hfov = cfg.hfov orelse if (images.len > 0) (images[0].hfov_degrees orelse 50.0) else 50.0;
    const output_ev = if (images.len > 0) (images[0].exposure_value orelse 0.0) else 0.0;
    const width: u32 = if (images.len > 0) images[0].width else 0;
    const height: u32 = if (images.len > 0) images[0].height else 0;

    try writer.writeAll("# hugin project file\n");
    try writer.writeAll("#hugin_ptoversion 2\n");
    try writer.print("p f{d} w{d} h{d} v{d:.6} k0 E{d:.6} R0 n\"TIFF_m c:LZW\"\n", .{
        projection,
        width,
        height,
        hfov,
        output_ev,
    });
    try writer.writeAll("m i2\n\n");
    try writer.writeAll("# image lines\n");

    for (images, 0..) |image, image_index| {
        try writer.writeAll("#-hugin cropFactor=1");
        if (!isRemapActive(cfg, image_index)) {
            try writer.writeAll(" disabled");
        }
        try writer.writeByte('\n');

        const pose = poses[image_index];
        const yaw_degrees = pose.yaw * 180.0 / std.math.pi;
        const pitch_degrees = pose.pitch * 180.0 / std.math.pi;
        const roll_degrees = pose.roll * 180.0 / std.math.pi;
        const translation_plane_yaw_degrees = pose.translation_plane_yaw * 180.0 / std.math.pi;
        const translation_plane_pitch_degrees = pose.translation_plane_pitch * 180.0 / std.math.pi;
        const image_hfov = optimizeHfovForPose(hfov, pose);
        try writer.print(
            "i w{d} h{d} f{d} v{d:.6} a{d:.6} b{d:.6} c{d:.6} d{d:.6} e{d:.6} y{d:.6} p{d:.6} r{d:.6} TrX{d:.6} TrY{d:.6} TrZ{d:.6} Tpy{d:.6} Tpp{d:.6} n\"{s}\"\n",
            .{
                image.width,
                image.height,
                projection,
                image_hfov,
                pose.radial_a,
                pose.radial_b,
                pose.radial_c,
                pose.center_shift_x,
                pose.center_shift_y,
                yaw_degrees,
                pitch_degrees,
                roll_degrees,
                pose.trans_x,
                pose.trans_y,
                pose.trans_z,
                translation_plane_yaw_degrees,
                translation_plane_pitch_degrees,
                image.path,
            },
        );
    }

    try writer.writeAll("\n# specify variables that should be optimized\n");
    for (optimize_vector, 0..) |set, image_index| {
        for (variableOrder) |variable| {
            if (set.contains(variable)) {
                try writer.print("v {s}{d}\n", .{ variableLabel(variable), image_index });
            }
        }
    }
    try writer.writeAll("v\n\n");

    try writer.writeAll("# control points\n");
    for (pair_matches) |pair_match| {
        for (pair_match.control_points) |cp| {
            try writer.print(
                "c n{d} N{d} x{d:.6} y{d:.6} X{d:.6} Y{d:.6} t0\n",
                .{ cp.left_image, cp.right_image, cp.left_x, cp.left_y, cp.right_x, cp.right_y },
            );
        }
    }

    try writer.writeAll("\n#hugin_optimizeReferenceImage 0\n");
    try writer.writeAll("#hugin_blender enblend\n");
    try writer.writeAll("#hugin_remapper nona\n");

    return list.toOwnedSlice(allocator);
}

fn isRemapActive(cfg: *const config_mod.Config, image_index: usize) bool {
    return !(cfg.dont_remap_ref and image_index == 0);
}

const variableOrder = [_]optimize.Variable{
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

fn variableLabel(variable: optimize.Variable) []const u8 {
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

fn optimizeHfovForPose(base_hfov_degrees: f64, pose: optimize.ImagePose) f64 {
    _ = base_hfov_degrees;
    return std.math.clamp(pose.base_hfov_degrees + pose.hfov_delta, 1e-3, 179.0);
}

test "pto render includes images variables and control points" {
    const allocator = std.testing.allocator;
    var cfg = config_mod.Config{
        .pto_file = "debug.pto",
    };

    const images = [_]sequence.InputImage{
        .{ .pano_index = 0, .path = "a.jpg", .format = .jpeg, .width = 100, .height = 80, .color_model = .rgb, .sample_type = .u8, .exposure_value = 1.0 },
        .{ .pano_index = 1, .path = "b.jpg", .format = .jpeg, .width = 100, .height = 80, .color_model = .rgb, .sample_type = .u8, .exposure_value = 1.0 },
    };
    const optvec = [_]optimize.VariableSet{
        optimize.VariableSet.initEmpty(),
        blk: {
            var set = optimize.VariableSet.initEmpty();
            set.insert(.y);
            set.insert(.p);
            set.insert(.r);
            break :blk set;
        },
    };
    const cps = try allocator.dupe(match_mod.ControlPoint, &[_]match_mod.ControlPoint{
        .{
            .left_image = 0,
            .right_image = 1,
            .left_x = 10,
            .left_y = 20,
            .right_x = 12,
            .right_y = 19,
            .score = 0.9,
            .coarse_right_x = 12,
            .coarse_right_y = 19,
            .coarse_score = 0.9,
            .refined_score = 0.9,
        },
    });
    defer allocator.free(cps);
    const pair_matches = [_]match_mod.PairMatches{
        .{
            .pair = .{ .left_index = 0, .right_index = 1 },
            .image_width = 100,
            .image_height = 80,
            .candidates_considered = 1,
            .coarse_control_point_count = 1,
            .coarse_mean_score = 0.9,
            .coarse_best_score = 0.9,
            .refined_control_point_count = 1,
            .control_point_storage = cps,
            .control_points = cps,
        },
    };
    const poses = [_]optimize.ImagePose{
        .{},
        .{ .yaw = 0.002, .pitch = -0.001, .roll = 0.01, .hfov_delta = -0.2, .trans_x = 1, .trans_y = -2, .translation_plane_yaw = 0.003, .translation_plane_pitch = -0.004, .radial_a = 0.01, .center_shift_x = 2.0, .center_shift_y = -1.5, .base_hfov_degrees = 50.0 },
    };

    const pto = try renderPto(allocator, &cfg, &images, &optvec, &pair_matches, &poses);
    defer allocator.free(pto);

    try std.testing.expect(std.mem.indexOf(u8, pto, "# hugin project file") != null);
    try std.testing.expect(std.mem.indexOf(u8, pto, "i w100 h80 f0 v50.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, pto, "v y1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pto, "c n0 N1 x10.000000 y20.000000 X12.000000 Y19.000000 t0") != null);
    try std.testing.expect(std.mem.indexOf(u8, pto, "TrX1.000000 TrY-2.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, pto, "Tpy0.171887 Tpp-0.229183") != null);
    try std.testing.expect(std.mem.indexOf(u8, pto, "a0.010000") != null);
    try std.testing.expect(std.mem.indexOf(u8, pto, "d2.000000 e-1.500000") != null);
}
