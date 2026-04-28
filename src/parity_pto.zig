const std = @import("std");
const match_mod = @import("match.zig");
const optimize = @import("optimize.zig");

pub const ParseError = error{
    MissingPanoLine,
    MissingImageDimensions,
    InvalidOptimizeImageIndex,
    UnsupportedControlPointMode,
};

pub const ImageEntry = struct {
    width: u32 = 0,
    height: u32 = 0,
    projection: u8 = 0,
    path: []const u8 = "",
    pose: optimize.ImagePose = .{},
};

pub const Project = struct {
    pano_width: u32,
    pano_height: u32,
    pano_hfov_degrees: f64,
    images: []ImageEntry,
    optimize_vector: []optimize.VariableSet,
    pair_matches: []match_mod.PairMatches,

    pub fn deinit(self: *Project, allocator: std.mem.Allocator) void {
        for (self.images) |image| {
            allocator.free(image.path);
        }
        allocator.free(self.images);
        allocator.free(self.optimize_vector);
        for (self.pair_matches) |*pair_match| {
            pair_match.deinit(allocator);
        }
        allocator.free(self.pair_matches);
    }
};

const PendingOptimize = struct {
    image_index: usize,
    variable: optimize.Variable,
};

const PendingPair = struct {
    pair: match_mod.PairMatches,
    points: std.ArrayList(match_mod.ControlPoint),

    fn init(left_index: usize, right_index: usize, width: u32, height: u32) PendingPair {
        return .{
            .pair = .{
                .pair = .{ .left_index = left_index, .right_index = right_index },
                .image_width = width,
                .image_height = height,
                .candidates_considered = 0,
                .control_point_storage = &.{},
                .control_points = &.{},
            },
            .points = std.ArrayList(match_mod.ControlPoint).empty,
        };
    }

    fn deinit(self: *PendingPair, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
    }
};

pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !Project {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024);
    defer allocator.free(data);
    return parse(allocator, data);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Project {
    var images = std.ArrayList(ImageEntry).empty;
    defer {
        for (images.items) |image| {
            allocator.free(image.path);
        }
        images.deinit(allocator);
    }

    var pending_opt = std.ArrayList(PendingOptimize).empty;
    defer pending_opt.deinit(allocator);

    var pending_pairs = std.ArrayList(PendingPair).empty;
    defer {
        for (pending_pairs.items) |*pair| {
            pair.deinit(allocator);
        }
        pending_pairs.deinit(allocator);
    }

    var pano_width: u32 = 0;
    var pano_height: u32 = 0;
    var pano_hfov_degrees: f64 = 0.0;
    var saw_pano = false;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        switch (line[0]) {
            'p' => {
                saw_pano = true;
                var token_iter = TokenIterator{ .line = line[1..] };
                while (token_iter.next()) |token| {
                    if (prefixed(token, "w")) |value| {
                        pano_width = try std.fmt.parseInt(u32, value, 10);
                    } else if (prefixed(token, "h")) |value| {
                        pano_height = try std.fmt.parseInt(u32, value, 10);
                    } else if (prefixed(token, "v")) |value| {
                        pano_hfov_degrees = try std.fmt.parseFloat(f64, value);
                    }
                }
            },
            'i' => {
                var image = ImageEntry{};
                image.pose.base_hfov_degrees = pano_hfov_degrees;
                var token_iter = TokenIterator{ .line = line[1..] };
                while (token_iter.next()) |token| {
                    if (prefixed(token, "w")) |value| {
                        image.width = try std.fmt.parseInt(u32, value, 10);
                    } else if (prefixed(token, "h")) |value| {
                        image.height = try std.fmt.parseInt(u32, value, 10);
                    } else if (prefixed(token, "f")) |value| {
                        image.projection = try std.fmt.parseInt(u8, value, 10);
                    } else if (prefixed(token, "TrX")) |value| {
                        image.pose.trans_x = try std.fmt.parseFloat(f64, value);
                    } else if (prefixed(token, "TrY")) |value| {
                        image.pose.trans_y = try std.fmt.parseFloat(f64, value);
                    } else if (prefixed(token, "TrZ")) |value| {
                        image.pose.trans_z = try std.fmt.parseFloat(f64, value);
                    } else if (prefixed(token, "Tpy")) |value| {
                        image.pose.translation_plane_yaw = degreesToRadians(try std.fmt.parseFloat(f64, value));
                    } else if (prefixed(token, "Tpp")) |value| {
                        image.pose.translation_plane_pitch = degreesToRadians(try std.fmt.parseFloat(f64, value));
                    } else if (prefixed(token, "v")) |value| {
                        const hfov = try std.fmt.parseFloat(f64, value);
                        image.pose.hfov_delta = hfov - pano_hfov_degrees;
                    } else if (prefixed(token, "a")) |value| {
                        image.pose.radial_a = try std.fmt.parseFloat(f64, value);
                    } else if (prefixed(token, "b")) |value| {
                        image.pose.radial_b = try std.fmt.parseFloat(f64, value);
                    } else if (prefixed(token, "c")) |value| {
                        image.pose.radial_c = try std.fmt.parseFloat(f64, value);
                    } else if (prefixed(token, "d")) |value| {
                        image.pose.center_shift_x = try std.fmt.parseFloat(f64, value);
                    } else if (prefixed(token, "e")) |value| {
                        image.pose.center_shift_y = try std.fmt.parseFloat(f64, value);
                    } else if (prefixed(token, "y")) |value| {
                        image.pose.yaw = degreesToRadians(try std.fmt.parseFloat(f64, value));
                    } else if (prefixed(token, "p")) |value| {
                        image.pose.pitch = degreesToRadians(try std.fmt.parseFloat(f64, value));
                    } else if (prefixed(token, "r")) |value| {
                        image.pose.roll = degreesToRadians(try std.fmt.parseFloat(f64, value));
                    } else if (prefixed(token, "n")) |value| {
                        image.path = try allocator.dupe(u8, stripQuotes(value));
                    }
                }
                if (image.width == 0 or image.height == 0) return error.MissingImageDimensions;
                try images.append(allocator, image);
            },
            'v' => {
                const trimmed = std.mem.trim(u8, line[1..], " \t");
                if (trimmed.len == 0) continue;
                var split_index = trimmed.len;
                while (split_index > 0 and std.ascii.isDigit(trimmed[split_index - 1])) {
                    split_index -= 1;
                }
                if (split_index == trimmed.len) continue;
                const variable = parseVariableLabel(trimmed[0..split_index]) orelse continue;
                const image_index = try std.fmt.parseInt(usize, trimmed[split_index..], 10);
                try pending_opt.append(allocator, .{
                    .image_index = image_index,
                    .variable = variable,
                });
            },
            'c' => {
                var left_image: usize = 0;
                var right_image: usize = 0;
                var left_x: f32 = 0;
                var left_y: f32 = 0;
                var right_x: f32 = 0;
                var right_y: f32 = 0;
                var mode: u8 = 0;

                var token_iter = TokenIterator{ .line = line[1..] };
                while (token_iter.next()) |token| {
                    if (prefixed(token, "n")) |value| {
                        left_image = try std.fmt.parseInt(usize, value, 10);
                    } else if (prefixed(token, "N")) |value| {
                        right_image = try std.fmt.parseInt(usize, value, 10);
                    } else if (prefixed(token, "x")) |value| {
                        left_x = @floatCast(try std.fmt.parseFloat(f64, value));
                    } else if (prefixed(token, "y")) |value| {
                        left_y = @floatCast(try std.fmt.parseFloat(f64, value));
                    } else if (prefixed(token, "X")) |value| {
                        right_x = @floatCast(try std.fmt.parseFloat(f64, value));
                    } else if (prefixed(token, "Y")) |value| {
                        right_y = @floatCast(try std.fmt.parseFloat(f64, value));
                    } else if (prefixed(token, "t")) |value| {
                        mode = try std.fmt.parseInt(u8, value, 10);
                    }
                }
                if (mode != 0) return error.UnsupportedControlPointMode;
                const pair_index = try getOrCreatePair(
                    allocator,
                    &pending_pairs,
                    left_image,
                    right_image,
                    if (images.items.len > 0) images.items[0].width else 0,
                    if (images.items.len > 0) images.items[0].height else 0,
                );
                try pending_pairs.items[pair_index].points.append(allocator, .{
                    .left_image = left_image,
                    .right_image = right_image,
                    .left_x = left_x,
                    .left_y = left_y,
                    .right_x = right_x,
                    .right_y = right_y,
                    .score = 1.0,
                    .coarse_right_x = right_x,
                    .coarse_right_y = right_y,
                    .coarse_score = 1.0,
                    .refined_score = 1.0,
                });
            },
            else => {},
        }
    }

    if (!saw_pano) return error.MissingPanoLine;

    const optimize_vector = try allocator.alloc(optimize.VariableSet, images.items.len);
    @memset(optimize_vector, optimize.VariableSet.initEmpty());
    for (pending_opt.items) |entry| {
        if (entry.image_index >= optimize_vector.len) return error.InvalidOptimizeImageIndex;
        optimize_vector[entry.image_index].insert(entry.variable);
    }

    const pair_matches = try allocator.alloc(match_mod.PairMatches, pending_pairs.items.len);
    for (pending_pairs.items, pair_matches) |*pending_pair, *pair_match| {
        const owned = try pending_pair.points.toOwnedSlice(allocator);
        pending_pair.points = .empty;
        pair_match.* = pending_pair.pair;
        pair_match.control_point_storage = owned;
        pair_match.control_points = owned;
        pair_match.coarse_control_point_count = owned.len;
        pair_match.refined_control_point_count = owned.len;
        pair_match.coarse_mean_score = if (owned.len > 0) 1.0 else null;
        pair_match.coarse_best_score = if (owned.len > 0) 1.0 else null;
    }

    return .{
        .pano_width = pano_width,
        .pano_height = pano_height,
        .pano_hfov_degrees = pano_hfov_degrees,
        .images = try images.toOwnedSlice(allocator),
        .optimize_vector = optimize_vector,
        .pair_matches = pair_matches,
    };
}

fn getOrCreatePair(
    allocator: std.mem.Allocator,
    pairs: *std.ArrayList(PendingPair),
    left_index: usize,
    right_index: usize,
    width: u32,
    height: u32,
) !usize {
    for (pairs.items, 0..) |pair, index| {
        if (pair.pair.pair.left_index == left_index and pair.pair.pair.right_index == right_index) {
            return index;
        }
    }
    try pairs.append(allocator, PendingPair.init(left_index, right_index, width, height));
    return pairs.items.len - 1;
}

fn degreesToRadians(value: f64) f64 {
    return value * std.math.pi / 180.0;
}

fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn prefixed(token: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, token, prefix)) {
        return token[prefix.len..];
    }
    return null;
}

fn parseVariableLabel(label: []const u8) ?optimize.Variable {
    if (std.mem.eql(u8, label, "y")) return .y;
    if (std.mem.eql(u8, label, "p")) return .p;
    if (std.mem.eql(u8, label, "r")) return .r;
    if (std.mem.eql(u8, label, "v")) return .v;
    if (std.mem.eql(u8, label, "a")) return .a;
    if (std.mem.eql(u8, label, "b")) return .b;
    if (std.mem.eql(u8, label, "c")) return .c;
    if (std.mem.eql(u8, label, "d")) return .d;
    if (std.mem.eql(u8, label, "e")) return .e;
    if (std.mem.eql(u8, label, "TrX")) return .tr_x;
    if (std.mem.eql(u8, label, "TrY")) return .tr_y;
    if (std.mem.eql(u8, label, "TrZ")) return .tr_z;
    if (std.mem.eql(u8, label, "Tpy")) return .tpy;
    if (std.mem.eql(u8, label, "Tpp")) return .tpp;
    return null;
}

const TokenIterator = struct {
    line: []const u8,
    index: usize = 0,

    fn next(self: *TokenIterator) ?[]const u8 {
        while (self.index < self.line.len and (self.line[self.index] == ' ' or self.line[self.index] == '\t')) {
            self.index += 1;
        }
        if (self.index >= self.line.len) return null;

        const start = self.index;
        while (self.index < self.line.len and self.line[self.index] != ' ' and self.line[self.index] != '\t') {
            if (self.line[self.index] == '"') {
                self.index += 1;
                while (self.index < self.line.len and self.line[self.index] != '"') {
                    self.index += 1;
                }
                if (self.index < self.line.len) self.index += 1;
                continue;
            }
            self.index += 1;
        }
        return self.line[start..self.index];
    }
};
