const std = @import("std");
const gray = @import("gray.zig");

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
    max_points: u32,
) std.mem.Allocator.Error![]InterestPoint {
    if (rect.width() < 5 or rect.height() < 5 or max_points == 0) {
        return allocator.alloc(InterestPoint, 0);
    }

    const rect_width = @as(usize, rect.width());
    const rect_height = @as(usize, rect.height());
    const responses = try allocator.alloc(f32, rect_width * rect_height);
    defer allocator.free(responses);
    @memset(responses, 0);

    const response_end_y = rect.y1 - 2;
    const response_end_x = rect.x1 - 2;
    var y = rect.y0 + 2;
    while (y < response_end_y) : (y += 1) {
        var x = rect.x0 + 2;
        while (x < response_end_x) : (x += 1) {
            responses[responseIndex(rect, x, y)] = harrisResponse(image, x, y);
        }
    }

    var points: std.ArrayList(InterestPoint) = .empty;
    defer points.deinit(allocator);
    try points.ensureTotalCapacity(allocator, max_points + 1);

    var min_score: f32 = 0;

    y = rect.y0 + 2;
    while (y < response_end_y) : (y += 1) {
        var x = rect.x0 + 2;
        while (x < response_end_x) : (x += 1) {
            const score = responses[responseIndex(rect, x, y)];
            if (score <= min_score or !isLocalMaximum(responses, rect, x, y, score)) {
                continue;
            }
            points.appendAssumeCapacity(.{
                .x = x,
                .y = y,
                .score = score,
            });

            if (points.items.len > max_points) {
                const min_index = findWeakestPoint(points.items);
                _ = points.swapRemove(min_index);
                min_score = points.items[findWeakestPoint(points.items)].score;
            }
        }
    }

    const SortContext = struct {
        fn lessThan(_: void, lhs: InterestPoint, rhs: InterestPoint) bool {
            if (lhs.score == rhs.score) {
                if (lhs.y == rhs.y) return lhs.x < rhs.x;
                return lhs.y < rhs.y;
            }
            return lhs.score > rhs.score;
        }
    };
    std.sort.insertion(InterestPoint, points.items, {}, SortContext.lessThan);

    if (points.items.len > max_points) {
        points.items.len = max_points;
    }

    return points.toOwnedSlice(allocator);
}

fn responseIndex(rect: Rect, x: u32, y: u32) usize {
    return @as(usize, y - rect.y0) * @as(usize, rect.width()) + @as(usize, x - rect.x0);
}

fn findWeakestPoint(points: []const InterestPoint) usize {
    var weakest_index: usize = 0;
    var weakest_score = points[0].score;
    for (points[1..], 1..) |point, index| {
        if (point.score < weakest_score) {
            weakest_score = point.score;
            weakest_index = index;
        }
    }
    return weakest_index;
}

fn harrisResponse(image: *const gray.GrayImage, x: u32, y: u32) f32 {
    var sum_xx: f32 = 0;
    var sum_yy: f32 = 0;
    var sum_xy: f32 = 0;

    var wy = y - 1;
    while (wy <= y + 1) : (wy += 1) {
        var wx = x - 1;
        while (wx <= x + 1) : (wx += 1) {
            const ix = image.pixel(wx + 1, wy) - image.pixel(wx - 1, wy);
            const iy = image.pixel(wx, wy + 1) - image.pixel(wx, wy - 1);
            sum_xx += ix * ix;
            sum_yy += iy * iy;
            sum_xy += ix * iy;
        }
    }

    const trace = sum_xx + sum_yy;
    return (sum_xx * sum_yy - sum_xy * sum_xy) - 0.04 * trace * trace;
}

fn isLocalMaximum(
    responses: []const f32,
    rect: Rect,
    x: u32,
    y: u32,
    score: f32,
) bool {
    var ny = y - 1;
    while (ny <= y + 1) : (ny += 1) {
        var nx = x - 1;
        while (nx <= x + 1) : (nx += 1) {
            if (nx == x and ny == y) {
                continue;
            }
            if (responses[responseIndex(rect, nx, ny)] >= score) {
                return false;
            }
        }
    }
    return true;
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
    }, 8);
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
