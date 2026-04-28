const std = @import("std");
const config = @import("config.zig");
const image_io = @import("image_io.zig");
const optimize = @import("optimize.zig");
const parity_pto = @import("parity_pto.zig");
const pipeline = @import("pipeline.zig");

const fixture_dir = "tests/golden/s003_small";

test "golden pair -m PTO stays stable and near upstream" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_pto = try tmpPath(allocator, &tmp, "pair.pto");
    defer allocator.free(out_pto);

    var cfg = try config.parseArgs(allocator, &.{
        "-m",
        "-p",
        out_pto,
        fixture_dir ++ "/0001.jpg",
        fixture_dir ++ "/0002.jpg",
    });
    defer cfg.deinit(allocator);

    try pipeline.run(allocator, &cfg);

    var actual = try parity_pto.parseFile(allocator, out_pto);
    defer actual.deinit(allocator);
    var golden = try parity_pto.parseFile(allocator, fixture_dir ++ "/port_pair_m.pto");
    defer golden.deinit(allocator);
    var upstream = try parity_pto.parseFile(allocator, fixture_dir ++ "/upstream_pair_m.pto");
    defer upstream.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), actual.images.len);
    try std.testing.expectEqual(@as(usize, 1), actual.pair_matches.len);
    try std.testing.expectEqual(@as(usize, 200), actual.pair_matches[0].control_points.len);

    try expectProjectsMatch(&golden, &actual, .{
        .pose_tolerance_degrees = 0.000_01,
        .hfov_tolerance_degrees = 0.000_2,
        .cp_tolerance_pixels = 0.000_01,
    });

    try expectPoseNearUpstream(golden.images[1].pose, upstream.images[1].pose, .{
        .angle_tolerance_degrees = 0.01,
        .hfov_tolerance_degrees = 0.01,
    });
    try expectPoseNearUpstream(actual.images[1].pose, upstream.images[1].pose, .{
        .angle_tolerance_degrees = 0.01,
        .hfov_tolerance_degrees = 0.01,
    });
}

test "golden three-frame -m aligned TIFFs stay within the image-diff budget" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const prefix = try tmpPath(allocator, &tmp, "stack");
    defer allocator.free(prefix);

    var cfg = try config.parseArgs(allocator, &.{
        "-m",
        "-a",
        prefix,
        fixture_dir ++ "/0001.jpg",
        fixture_dir ++ "/0002.jpg",
        fixture_dir ++ "/0003.jpg",
    });
    defer cfg.deinit(allocator);

    try pipeline.run(allocator, &cfg);

    const actual_paths = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}_0000.tif", .{prefix}),
        try std.fmt.allocPrint(allocator, "{s}_0001.tif", .{prefix}),
        try std.fmt.allocPrint(allocator, "{s}_0002.tif", .{prefix}),
    };
    defer {
        for (actual_paths) |path| allocator.free(path);
    }

    const golden_paths = [_][]const u8{
        fixture_dir ++ "/port3_0000.tif",
        fixture_dir ++ "/port3_0001.tif",
        fixture_dir ++ "/port3_0002.tif",
    };

    for (actual_paths, golden_paths) |actual_path, golden_path| {
        try expectImagesClose(allocator, golden_path, actual_path, 0.005);
    }
}

const ProjectTolerance = struct {
    pose_tolerance_degrees: f64,
    hfov_tolerance_degrees: f64,
    cp_tolerance_pixels: f64,
};

const UpstreamTolerance = struct {
    angle_tolerance_degrees: f64,
    hfov_tolerance_degrees: f64,
};

fn expectProjectsMatch(expected: *const parity_pto.Project, actual: *const parity_pto.Project, tol: ProjectTolerance) !void {
    try std.testing.expectEqual(expected.images.len, actual.images.len);
    try std.testing.expectEqual(expected.optimize_vector.len, actual.optimize_vector.len);
    try std.testing.expectEqual(expected.pair_matches.len, actual.pair_matches.len);

    try expectNear(expected.pano_hfov_degrees, actual.pano_hfov_degrees, tol.hfov_tolerance_degrees);

    for (expected.optimize_vector, actual.optimize_vector) |expected_vars, actual_vars| {
        try std.testing.expectEqual(expected_vars, actual_vars);
    }

    for (expected.images, actual.images) |expected_image, actual_image| {
        try std.testing.expectEqual(expected_image.width, actual_image.width);
        try std.testing.expectEqual(expected_image.height, actual_image.height);
        try std.testing.expectEqual(expected_image.projection, actual_image.projection);
        try expectPosesMatch(expected_image.pose, actual_image.pose, tol.pose_tolerance_degrees, tol.hfov_tolerance_degrees);
    }

    for (expected.pair_matches, actual.pair_matches) |expected_pair, actual_pair| {
        try std.testing.expectEqual(expected_pair.pair.left_index, actual_pair.pair.left_index);
        try std.testing.expectEqual(expected_pair.pair.right_index, actual_pair.pair.right_index);
        try std.testing.expectEqual(expected_pair.control_points.len, actual_pair.control_points.len);
        for (expected_pair.control_points, actual_pair.control_points) |expected_cp, actual_cp| {
            try expectNear(expected_cp.left_x, actual_cp.left_x, tol.cp_tolerance_pixels);
            try expectNear(expected_cp.left_y, actual_cp.left_y, tol.cp_tolerance_pixels);
            try expectNear(expected_cp.right_x, actual_cp.right_x, tol.cp_tolerance_pixels);
            try expectNear(expected_cp.right_y, actual_cp.right_y, tol.cp_tolerance_pixels);
        }
    }
}

fn expectPosesMatch(expected: optimize.ImagePose, actual: optimize.ImagePose, angle_tolerance_degrees: f64, hfov_tolerance_degrees: f64) !void {
    try expectNear(radiansToDegrees(expected.yaw), radiansToDegrees(actual.yaw), angle_tolerance_degrees);
    try expectNear(radiansToDegrees(expected.pitch), radiansToDegrees(actual.pitch), angle_tolerance_degrees);
    try expectNear(radiansToDegrees(expected.roll), radiansToDegrees(actual.roll), angle_tolerance_degrees);
    try expectNear(expected.base_hfov_degrees + expected.hfov_delta, actual.base_hfov_degrees + actual.hfov_delta, hfov_tolerance_degrees);
    try expectNear(expected.trans_x, actual.trans_x, 1e-9);
    try expectNear(expected.trans_y, actual.trans_y, 1e-9);
    try expectNear(expected.trans_z, actual.trans_z, 1e-9);
    try expectNear(expected.radial_a, actual.radial_a, 1e-9);
    try expectNear(expected.radial_b, actual.radial_b, 1e-9);
    try expectNear(expected.radial_c, actual.radial_c, 1e-9);
    try expectNear(expected.center_shift_x, actual.center_shift_x, 1e-9);
    try expectNear(expected.center_shift_y, actual.center_shift_y, 1e-9);
}

fn expectPoseNearUpstream(actual: optimize.ImagePose, upstream: optimize.ImagePose, tol: UpstreamTolerance) !void {
    try expectNear(radiansToDegrees(actual.yaw), radiansToDegrees(upstream.yaw), tol.angle_tolerance_degrees);
    try expectNear(radiansToDegrees(actual.pitch), radiansToDegrees(upstream.pitch), tol.angle_tolerance_degrees);
    try expectNear(radiansToDegrees(actual.roll), radiansToDegrees(upstream.roll), tol.angle_tolerance_degrees);
    try expectNear(actual.base_hfov_degrees + actual.hfov_delta, upstream.base_hfov_degrees + upstream.hfov_delta, tol.hfov_tolerance_degrees);
}

fn expectImagesClose(allocator: std.mem.Allocator, expected_path: []const u8, actual_path: []const u8, max_normalized_rmse: f64) !void {
    var expected = try image_io.loadImage(allocator, expected_path);
    defer expected.deinit(allocator);
    var actual = try image_io.loadImage(allocator, actual_path);
    defer actual.deinit(allocator);

    try std.testing.expectEqual(expected.info.width, actual.info.width);
    try std.testing.expectEqual(expected.info.height, actual.info.height);
    try std.testing.expectEqual(expected.info.color_model, actual.info.color_model);
    try std.testing.expectEqual(expected.info.sample_type, actual.info.sample_type);
    try std.testing.expectEqual(expected.info.color_channels, actual.info.color_channels);

    switch (expected.pixels) {
        .u8 => |expected_pixels| {
            const actual_pixels = switch (actual.pixels) {
                .u8 => |pixels| pixels,
                .u16 => unreachable,
            };
            try expectNormalizedRmseU8(expected_pixels, actual_pixels, max_normalized_rmse);
        },
        .u16 => |expected_pixels| {
            const actual_pixels = switch (actual.pixels) {
                .u8 => unreachable,
                .u16 => |pixels| pixels,
            };
            try expectNormalizedRmseU16(expected_pixels, actual_pixels, max_normalized_rmse);
        },
    }
}

fn tmpPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, leaf: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, leaf });
}

fn radiansToDegrees(value: f64) f64 {
    return value * 180.0 / std.math.pi;
}

fn expectNear(expected: f64, actual: f64, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, tolerance);
}

fn expectNormalizedRmseU8(expected: []const u8, actual: []const u8, max_normalized_rmse: f64) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    var sum_sq: f64 = 0.0;
    for (expected, actual) |expected_value, actual_value| {
        const delta = @as(f64, @floatFromInt(@as(i32, expected_value) - @as(i32, actual_value)));
        sum_sq += delta * delta;
    }
    const rmse = @sqrt(sum_sq / @as(f64, @floatFromInt(expected.len)));
    const normalized = rmse / 255.0;
    try std.testing.expect(normalized <= max_normalized_rmse);
}

fn expectNormalizedRmseU16(expected: []const u16, actual: []const u16, max_normalized_rmse: f64) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    var sum_sq: f64 = 0.0;
    for (expected, actual) |expected_value, actual_value| {
        const delta = @as(f64, @floatFromInt(@as(i64, expected_value) - @as(i64, actual_value)));
        sum_sq += delta * delta;
    }
    const rmse = @sqrt(sum_sq / @as(f64, @floatFromInt(expected.len)));
    const normalized = rmse / 65535.0;
    try std.testing.expect(normalized <= max_normalized_rmse);
}
