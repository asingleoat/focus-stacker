const std = @import("std");
const gray = @import("gray.zig");
const profiler = @import("profiler.zig");
const vigra = @import("vigra.zig");

pub const Rect = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    pub fn width(self: Rect) u32 {
        return self.x1 - self.x0;
    }

    pub fn height(self: Rect) u32 {
        return self.y1 - self.y0;
    }
};

pub const InterestPoint = struct {
    x: u32,
    y: u32,
    score: f32,
};

const RankedInterestPoint = struct {
    x: u32,
    y: u32,
    score: f32,
    serial: u32,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    local_pixels: []f32 = &.{},
    response_pixels: []f32 = &.{},
    ranked_points: []RankedInterestPoint = &.{},
    output_points: []InterestPoint = &.{},
    corner_workspace: vigra.CornerWorkspace,

    pub fn init(allocator: std.mem.Allocator) Workspace {
        return .{
            .allocator = allocator,
            .corner_workspace = vigra.CornerWorkspace.init(allocator),
        };
    }

    pub fn deinit(self: *Workspace) void {
        if (self.local_pixels.len != 0) self.allocator.free(self.local_pixels);
        if (self.response_pixels.len != 0) self.allocator.free(self.response_pixels);
        if (self.ranked_points.len != 0) self.allocator.free(self.ranked_points);
        if (self.output_points.len != 0) self.allocator.free(self.output_points);
        self.corner_workspace.deinit();
        self.* = undefined;
    }

    fn ensureImageCapacity(self: *Workspace, needed: usize) !void {
        try ensureSliceCapacityF32(self.allocator, &self.local_pixels, needed);
        try ensureSliceCapacityF32(self.allocator, &self.response_pixels, needed);
    }

    fn ensurePointCapacity(self: *Workspace, max_points: u32) !void {
        const ranked_needed = @as(usize, max_points) + 1;
        const output_needed = @as(usize, max_points);
        try ensureSliceCapacityRanked(self.allocator, &self.ranked_points, ranked_needed);
        try ensureSliceCapacityPoints(self.allocator, &self.output_points, output_needed);
    }
};

pub fn buildGridRects(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    grid_size: u32,
) std.mem.Allocator.Error![]Rect {
    const prof = profiler.scope("features.buildGridRects");
    defer prof.end();

    var rects: std.ArrayList(Rect) = .empty;
    defer rects.deinit(allocator);

    try rects.ensureTotalCapacity(allocator, @as(usize, grid_size) * @as(usize, grid_size));
    for (0..grid_size) |party| {
        for (0..grid_size) |partx| {
            const rect = Rect{
                .x0 = @as(u32, @intCast(partx)) * width / grid_size,
                .y0 = @as(u32, @intCast(party)) * height / grid_size,
                .x1 = @as(u32, @intCast(partx + 1)) * width / grid_size,
                .y1 = @as(u32, @intCast(party + 1)) * height / grid_size,
            };
            if (rect.width() > 0 and rect.height() > 0) {
                rects.appendAssumeCapacity(rect);
            }
        }
    }

    return rects.toOwnedSlice(allocator);
}

pub fn detectInterestPointsPartial(
    allocator: std.mem.Allocator,
    image: *const gray.GrayImage,
    rect: Rect,
    scale: f64,
    max_points: u32,
) std.mem.Allocator.Error![]InterestPoint {
    var workspace = Workspace.init(allocator);
    defer workspace.deinit();

    const borrowed = try detectInterestPointsPartialBorrowed(&workspace, image, rect, scale, max_points);
    return allocator.dupe(InterestPoint, borrowed);
}

pub fn detectInterestPointsPartialBorrowed(
    workspace: *Workspace,
    image: *const gray.GrayImage,
    rect: Rect,
    scale: f64,
    max_points: u32,
) std.mem.Allocator.Error![]const InterestPoint {
    const prof = profiler.scope("features.detectInterestPointsPartial");
    defer prof.end();

    if (rect.width() < 3 or rect.height() < 3 or max_points == 0) {
        return workspace.output_points[0..0];
    }

    const width = rect.width();
    const height = rect.height();
    const pixel_count = @as(usize, width) * @as(usize, height);
    try workspace.ensureImageCapacity(pixel_count);
    try workspace.ensurePointCapacity(max_points);

    var local = gray.GrayImage{
        .width = width,
        .height = height,
        .pixels = workspace.local_pixels[0..pixel_count],
    };
    extractRectImageInto(&local, image, rect);

    var response = try workspace.corner_workspace.cornerResponseInto(&local, scale, workspace.response_pixels[0..pixel_count]);

    var min_score: f32 = 0;
    var serial: u32 = 0;
    var point_count: usize = 0;

    var y: u32 = 1;
    while (y + 1 < local.height) : (y += 1) {
        var x: u32 = 1;
        while (x + 1 < local.width) : (x += 1) {
            const score = response.pixel(x, y);
            if (score <= min_score or !vigra.isStrictLocalMaximum(&response, x, y, 0)) {
                continue;
            }
            workspace.ranked_points[point_count] = .{
                .x = rect.x0 + x,
                .y = rect.y0 + y,
                .score = score,
                .serial = serial,
            };
            point_count += 1;
            serial += 1;

            if (point_count > max_points) {
                const min_index = findWeakestPoint(workspace.ranked_points[0..point_count]);
                workspace.ranked_points[min_index] = workspace.ranked_points[point_count - 1];
                point_count -= 1;
                min_score = workspace.ranked_points[findWeakestPoint(workspace.ranked_points[0..point_count])].score;
            }
        }
    }

    const SortContext = struct {
        fn lessThan(_: void, lhs: RankedInterestPoint, rhs: RankedInterestPoint) bool {
            if (lhs.score == rhs.score) {
                return lhs.serial > rhs.serial;
            }
            return lhs.score > rhs.score;
        }
    };
    std.sort.insertion(RankedInterestPoint, workspace.ranked_points[0..point_count], {}, SortContext.lessThan);

    if (point_count > max_points) {
        point_count = max_points;
    }

    const out = workspace.output_points[0..point_count];
    for (out, workspace.ranked_points[0..point_count]) |*dst, src_point| {
        dst.* = .{
            .x = src_point.x,
            .y = src_point.y,
            .score = src_point.score,
        };
    }
    return out;
}

fn extractRectImageInto(
    dst: *gray.GrayImage,
    image: *const gray.GrayImage,
    rect: Rect,
) void {
    const prof = profiler.scope("features.extractRectImage");
    defer prof.end();

    const width = dst.width;
    const height = dst.height;
    const src_width = @as(usize, image.width);
    const dst_width = @as(usize, width);
    for (0..height) |dy| {
        const src_row = @as(usize, rect.y0 + @as(u32, @intCast(dy))) * src_width + @as(usize, rect.x0);
        const dst_row = dy * dst_width;
        @memcpy(dst.pixels[dst_row .. dst_row + dst_width], image.pixels[src_row .. src_row + dst_width]);
    }
}

fn findWeakestPoint(points: []const RankedInterestPoint) usize {
    var weakest_index: usize = 0;
    var weakest_score = points[0].score;
    var weakest_serial = points[0].serial;
    for (points[1..], 1..) |point, index| {
        if (point.score < weakest_score or
            (point.score == weakest_score and point.serial < weakest_serial))
        {
            weakest_score = point.score;
            weakest_serial = point.serial;
            weakest_index = index;
        }
    }
    return weakest_index;
}

fn ensureSliceCapacityF32(allocator: std.mem.Allocator, slice: *[]f32, needed: usize) !void {
    if (slice.len >= needed) return;
    if (slice.len == 0) {
        slice.* = try allocator.alloc(f32, needed);
    } else {
        slice.* = try allocator.realloc(slice.*, needed);
    }
}

fn ensureSliceCapacityRanked(allocator: std.mem.Allocator, slice: *[]RankedInterestPoint, needed: usize) !void {
    if (slice.len >= needed) return;
    if (slice.len == 0) {
        slice.* = try allocator.alloc(RankedInterestPoint, needed);
    } else {
        slice.* = try allocator.realloc(slice.*, needed);
    }
}

fn ensureSliceCapacityPoints(allocator: std.mem.Allocator, slice: *[]InterestPoint, needed: usize) !void {
    if (slice.len >= needed) return;
    if (slice.len == 0) {
        slice.* = try allocator.alloc(InterestPoint, needed);
    } else {
        slice.* = try allocator.realloc(slice.*, needed);
    }
}

test "grid rectangles cover the image" {
    const allocator = std.testing.allocator;

    const rects = try buildGridRects(allocator, 10, 8, 3);
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 9), rects.len);
    try std.testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 3, .y1 = 2 }, rects[0]);
    try std.testing.expectEqual(Rect{ .x0 = 6, .y0 = 5, .x1 = 10, .y1 = 8 }, rects[8]);
}

test "interest point detector finds a strong corner" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(f32, 7 * 7);
    defer allocator.free(pixels);
    @memset(pixels, 0);

    for (0..4) |y| {
        for (0..4) |x| {
            pixels[y * 7 + x] = 1.0;
        }
    }

    var image = gray.GrayImage{
        .width = 7,
        .height = 7,
        .pixels = pixels,
    };

    const points = try detectInterestPointsPartial(allocator, &image, .{
        .x0 = 0,
        .y0 = 0,
        .x1 = 7,
        .y1 = 7,
    }, 2.0, 8);
    defer allocator.free(points);

    try std.testing.expect(points.len > 0);

    var found = false;
    for (points) |point| {
        if (point.x >= 1 and point.x <= 5 and point.y >= 1 and point.y <= 5) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
