const std = @import("std");
const gray = @import("gray.zig");
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

pub fn buildGridRects(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    grid_size: u32,
) std.mem.Allocator.Error![]Rect {
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
    if (rect.width() < 3 or rect.height() < 3 or max_points == 0) {
        return allocator.alloc(InterestPoint, 0);
    }

    var local = try extractRectImage(allocator, image, rect);
    defer local.deinit(allocator);

    var response = try vigra.cornerResponse(allocator, &local, scale);
    defer response.deinit(allocator);

    var points: std.ArrayList(RankedInterestPoint) = .empty;
    defer points.deinit(allocator);
    try points.ensureTotalCapacity(allocator, max_points + 1);

    var min_score: f32 = 0;
    var serial: u32 = 0;

    var y: u32 = 1;
    while (y + 1 < local.height) : (y += 1) {
        var x: u32 = 1;
        while (x + 1 < local.width) : (x += 1) {
            const score = response.pixel(x, y);
            if (score <= min_score or !vigra.isStrictLocalMaximum(&response, x, y, 0)) {
                continue;
            }
            points.appendAssumeCapacity(.{
                .x = rect.x0 + x,
                .y = rect.y0 + y,
                .score = score,
                .serial = serial,
            });
            serial += 1;

            if (points.items.len > max_points) {
                const min_index = findWeakestPoint(points.items);
                _ = points.swapRemove(min_index);
                min_score = points.items[findWeakestPoint(points.items)].score;
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
    std.sort.insertion(RankedInterestPoint, points.items, {}, SortContext.lessThan);

    if (points.items.len > max_points) {
        points.items.len = max_points;
    }

    const owned_ranked = try points.toOwnedSlice(allocator);
    defer allocator.free(owned_ranked);

    const owned = try allocator.alloc(InterestPoint, owned_ranked.len);
    for (owned, owned_ranked) |*dst, src_point| {
        dst.* = .{
            .x = src_point.x,
            .y = src_point.y,
            .score = src_point.score,
        };
    }
    return owned;
}

fn extractRectImage(
    allocator: std.mem.Allocator,
    image: *const gray.GrayImage,
    rect: Rect,
) std.mem.Allocator.Error!gray.GrayImage {
    const width = rect.width();
    const height = rect.height();
    const pixels = try allocator.alloc(f32, @as(usize, width) * @as(usize, height));
    errdefer allocator.free(pixels);

    for (0..height) |dy| {
        for (0..width) |dx| {
            pixels[dy * width + dx] = image.pixel(rect.x0 + @as(u32, @intCast(dx)), rect.y0 + @as(u32, @intCast(dy)));
        }
    }

    return .{
        .width = width,
        .height = height,
        .pixels = pixels,
    };
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
        if (point.x >= 2 and point.x <= 4 and point.y >= 2 and point.y <= 4) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
