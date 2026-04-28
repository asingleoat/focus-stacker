const std = @import("std");
const config_mod = @import("config.zig");
const image_io = @import("image_io.zig");

pub const InputImage = struct {
    pano_index: usize,
    path: []const u8,
    format: image_io.Format,
    width: u32,
    height: u32,
    color_model: image_io.ColorModel,
    sample_type: image_io.SampleType,
    exposure_value: ?f64 = null,
    hfov_degrees: ?f64 = null,
};

pub const SortDecision = enum {
    disabled_by_config,
    disabled_missing_first_ev,
    disabled_small_spread,
    sorted_by_exposure_value,
};

pub const MatchPair = struct {
    left_index: usize,
    right_index: usize,
};

pub const Plan = struct {
    ordered_indices: std.ArrayListUnmanaged(usize) = .{},
    pairs: std.ArrayListUnmanaged(MatchPair) = .{},
    remap_active: std.ArrayListUnmanaged(bool) = .{},
    sort_decision: SortDecision,
    panorama_reference_index: usize = 0,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.ordered_indices.deinit(allocator);
        self.pairs.deinit(allocator);
        self.remap_active.deinit(allocator);
    }
};

pub fn buildPlan(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    images: []const InputImage,
) std.mem.Allocator.Error!Plan {
    var plan = Plan{
        .sort_decision = .disabled_by_config,
    };
    errdefer plan.deinit(allocator);

    try plan.ordered_indices.ensureTotalCapacity(allocator, images.len);
    for (images, 0..) |_, index| {
        plan.ordered_indices.appendAssumeCapacity(index);
    }

    plan.sort_decision = applyOrdering(images, cfg.sort_images_by_ev, plan.ordered_indices.items);

    try plan.pairs.ensureTotalCapacity(allocator, if (images.len > 0) images.len - 1 else 0);
    if (cfg.align_to_first) {
        for (plan.ordered_indices.items[1..]) |ordered_index| {
            plan.pairs.appendAssumeCapacity(.{
                .left_index = 0,
                .right_index = ordered_index,
            });
        }
    } else if (plan.ordered_indices.items.len >= 2) {
        for (plan.ordered_indices.items[1..], 1..) |ordered_index, i| {
            plan.pairs.appendAssumeCapacity(.{
                .left_index = plan.ordered_indices.items[i - 1],
                .right_index = ordered_index,
            });
        }
    }

    try plan.remap_active.ensureTotalCapacity(allocator, images.len);
    for (images, 0..) |_, index| {
        plan.remap_active.appendAssumeCapacity(!(cfg.dont_remap_ref and index == plan.panorama_reference_index));
    }

    return plan;
}

pub fn renderPlanSummary(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    images: []const InputImage,
) std.mem.Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    const writer = list.writer(allocator);

    try writer.print(
        \\sequence planning:
        \\  panorama reference index: {d}
        \\  sort decision: {s}
        \\  ordered inputs:
        \\
    , .{
        plan.panorama_reference_index,
        sortDecisionLabel(plan.sort_decision),
    });

    for (plan.ordered_indices.items, 0..) |image_index, order_index| {
        const image = images[image_index];
        if (image.exposure_value) |ev| {
            try writer.print(
                "    {d}: [{d}] {s} {s} {d}x{d} {s} (EV {d})\n",
                .{
                    order_index,
                    image.pano_index,
                    image.path,
                    @tagName(image.format),
                    image.width,
                    image.height,
                    @tagName(image.sample_type),
                    ev,
                },
            );
        } else {
            try writer.print(
                "    {d}: [{d}] {s} {s} {d}x{d} {s}\n",
                .{
                    order_index,
                    image.pano_index,
                    image.path,
                    @tagName(image.format),
                    image.width,
                    image.height,
                    @tagName(image.sample_type),
                },
            );
        }
    }

    try writer.writeAll("  match pairs:\n");
    for (plan.pairs.items) |pair| {
        try writer.print(
            "    [{d}] {s} -> [{d}] {s}\n",
            .{
                pair.left_index,
                images[pair.left_index].path,
                pair.right_index,
                images[pair.right_index].path,
            },
        );
    }

    try writer.writeAll("  remap-active images:\n");
    for (plan.remap_active.items, 0..) |is_active, index| {
        try writer.print(
            "    [{d}] {s}: {}\n",
            .{ index, images[index].path, is_active },
        );
    }

    return list.toOwnedSlice(allocator);
}

fn applyOrdering(
    images: []const InputImage,
    sort_images_by_ev: bool,
    ordered_indices: []usize,
) SortDecision {
    if (!sort_images_by_ev) {
        return .disabled_by_config;
    }

    if (images.len == 0) {
        return .disabled_by_config;
    }

    const first_ev = images[0].exposure_value orelse 0.0;
    if (images[0].exposure_value == null or @abs(first_ev) < 1e-6) {
        return .disabled_missing_first_ev;
    }

    var max_ev = first_ev;
    var min_ev = first_ev;
    for (images[1..]) |image| {
        const ev = image.exposure_value orelse 0.0;
        max_ev = @max(max_ev, ev);
        min_ev = @min(min_ev, ev);
    }

    if (max_ev - min_ev <= 0.05) {
        return .disabled_small_spread;
    }

    const Context = struct {
        images: []const InputImage,

        fn lessThan(ctx: @This(), lhs: usize, rhs: usize) bool {
            const lhs_ev = ctx.images[lhs].exposure_value orelse 0.0;
            const rhs_ev = ctx.images[rhs].exposure_value orelse 0.0;
            if (lhs_ev == rhs_ev) {
                return lhs < rhs;
            }
            return lhs_ev > rhs_ev;
        }
    };

    std.sort.insertion(usize, ordered_indices, Context{ .images = images }, Context.lessThan);
    return .sorted_by_exposure_value;
}

fn sortDecisionLabel(decision: SortDecision) []const u8 {
    return switch (decision) {
        .disabled_by_config => "disabled by configuration",
        .disabled_missing_first_ev => "disabled because the first input has no usable EV",
        .disabled_small_spread => "disabled because EV spread is too small",
        .sorted_by_exposure_value => "sorted by exposure value",
    };
}

test "align-to-first pairs all images with panorama image 0" {
    const allocator = std.testing.allocator;
    var cfg = config_mod.Config{
        .align_to_first = true,
        .sort_images_by_ev = false,
        .aligned_prefix = "out",
    };
    const images = [_]InputImage{
        .{ .pano_index = 0, .path = "a.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16 },
        .{ .pano_index = 1, .path = "b.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16 },
        .{ .pano_index = 2, .path = "c.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16 },
    };

    var plan = try buildPlan(allocator, &cfg, &images);
    defer plan.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), plan.pairs.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.pairs.items[0].left_index);
    try std.testing.expectEqual(@as(usize, 1), plan.pairs.items[0].right_index);
    try std.testing.expectEqual(@as(usize, 0), plan.pairs.items[1].left_index);
    try std.testing.expectEqual(@as(usize, 2), plan.pairs.items[1].right_index);
}

test "sort by EV when spread is large enough" {
    const allocator = std.testing.allocator;
    var cfg = config_mod.Config{
        .aligned_prefix = "out",
    };
    const images = [_]InputImage{
        .{ .pano_index = 0, .path = "a.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16, .exposure_value = 1.0 },
        .{ .pano_index = 1, .path = "b.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16, .exposure_value = 2.0 },
        .{ .pano_index = 2, .path = "c.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16, .exposure_value = 1.5 },
    };

    var plan = try buildPlan(allocator, &cfg, &images);
    defer plan.deinit(allocator);

    try std.testing.expectEqual(SortDecision.sorted_by_exposure_value, plan.sort_decision);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 2, 0 }, plan.ordered_indices.items);
    try std.testing.expectEqual(@as(usize, 1), plan.pairs.items[0].left_index);
    try std.testing.expectEqual(@as(usize, 2), plan.pairs.items[0].right_index);
}

test "small EV spread keeps given order" {
    const allocator = std.testing.allocator;
    var cfg = config_mod.Config{
        .aligned_prefix = "out",
    };
    const images = [_]InputImage{
        .{ .pano_index = 0, .path = "a.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16, .exposure_value = 1.0 },
        .{ .pano_index = 1, .path = "b.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16, .exposure_value = 1.04 },
        .{ .pano_index = 2, .path = "c.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16, .exposure_value = 1.02 },
    };

    var plan = try buildPlan(allocator, &cfg, &images);
    defer plan.deinit(allocator);

    try std.testing.expectEqual(SortDecision.disabled_small_spread, plan.sort_decision);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1, 2 }, plan.ordered_indices.items);
}

test "missing first EV disables sorting" {
    const allocator = std.testing.allocator;
    var cfg = config_mod.Config{
        .aligned_prefix = "out",
    };
    const images = [_]InputImage{
        .{ .pano_index = 0, .path = "a.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16 },
        .{ .pano_index = 1, .path = "b.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16, .exposure_value = 10.0 },
    };

    var plan = try buildPlan(allocator, &cfg, &images);
    defer plan.deinit(allocator);

    try std.testing.expectEqual(SortDecision.disabled_missing_first_ev, plan.sort_decision);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1 }, plan.ordered_indices.items);
}

test "dont-remap-ref deactivates panorama image zero even when sort order changes" {
    const allocator = std.testing.allocator;
    var cfg = config_mod.Config{
        .dont_remap_ref = true,
        .aligned_prefix = "out",
    };
    const images = [_]InputImage{
        .{ .pano_index = 0, .path = "a.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16, .exposure_value = 1.0 },
        .{ .pano_index = 1, .path = "b.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16, .exposure_value = 5.0 },
        .{ .pano_index = 2, .path = "c.tif", .format = .tiff, .width = 10, .height = 10, .color_model = .grayscale, .sample_type = .u16, .exposure_value = 3.0 },
    };

    var plan = try buildPlan(allocator, &cfg, &images);
    defer plan.deinit(allocator);

    try std.testing.expectEqual(SortDecision.sorted_by_exposure_value, plan.sort_decision);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 2, 0 }, plan.ordered_indices.items);
    try std.testing.expectEqual(false, plan.remap_active.items[0]);
    try std.testing.expectEqual(true, plan.remap_active.items[1]);
}
