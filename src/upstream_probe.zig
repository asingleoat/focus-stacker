const std = @import("std");
const minpack_mod = @import("minpack.zig");

const c = @cImport({
    @cInclude("filter.h");
    @cInclude("adjust.h");
});

pub fn main() !void {
    c.PT_setProgressFcn(infoCallback);
    c.PT_setInfoDlgFcn(infoCallback);

    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) usage();

    const command = args[1];
    const pto_path = args[2];

    var info = try loadAlignInfo(allocator, pto_path);
    defer c.DisposeAlignInfo(&info);
    c.SetGlobalPtr(&info);

    if (std.mem.eql(u8, command, "lm-params")) {
        const solve_x = try collectSolveVector(allocator, &info, args[3..]);
        defer allocator.free(solve_x);
        try printVector(solve_x);
        return;
    }

    if (std.mem.eql(u8, command, "solve-lm-params")) {
        const initial = if (args.len > 3) try collectSolveVector(allocator, &info, args[3..]) else null;
        defer if (initial) |values| allocator.free(values);
        try runOptimizer(&info, initial);
        const solve_x = try collectSolveVector(allocator, &info, &.{});
        defer allocator.free(solve_x);
        try printVector(solve_x);
        return;
    }

    if (std.mem.eql(u8, command, "solve-lm-params-zigminpack")) {
        const initial = if (args.len > 3) try collectSolveVector(allocator, &info, args[3..]) else null;
        defer if (initial) |values| allocator.free(values);
        const solve_x = try runZigMinpackOptimizer(allocator, &info, initial);
        defer allocator.free(solve_x);
        try printVector(solve_x);
        return;
    }

    if (std.mem.eql(u8, command, "image-vars")) {
        const solve_x = try collectSolveVector(allocator, &info, args[3..]);
        defer allocator.free(solve_x);
        _ = c.SetAlignParams(solve_x.ptr);
        try printImageVars(&info);
        return;
    }

    if (std.mem.eql(u8, command, "equirect-point")) {
        if (args.len < 6) usage();
        const image_index = try std.fmt.parseInt(usize, args[3], 10);
        const x = try std.fmt.parseFloat(f64, args[4]);
        const y = try std.fmt.parseFloat(f64, args[5]);
        if (image_index >= @as(usize, @intCast(info.numIm))) return error.ImageIndexOutOfRange;
        const solve_x = try collectSolveVector(allocator, &info, args[6..]);
        defer allocator.free(solve_x);
        _ = c.SetAlignParams(solve_x.ptr);
        const point = pointToEquirectDegrees(&info, image_index, x, y);
        std.debug.print("lon={d:.12}\nlat={d:.12}\n", .{ point.x, point.y });
        return;
    }

    if (std.mem.eql(u8, command, "cp-error")) {
        if (args.len < 4) usage();
        const cp_index = try std.fmt.parseInt(usize, args[3], 10);
        const solve_x = try collectSolveVector(allocator, &info, args[4..]);
        defer allocator.free(solve_x);
        _ = c.SetAlignParams(solve_x.ptr);

        var distance: f64 = 0.0;
        var components = [_]f64{ 0.0, 0.0 };
        if (cp_index >= @as(usize, @intCast(info.numPts))) return error.ControlPointOutOfRange;
        _ = c.EvaluateControlPointErrorAndComponents(@intCast(cp_index), &distance, &components);
        std.debug.print(
            "distance={d:.12}\ncomponent_x={d:.12}\ncomponent_y={d:.12}\n",
            .{ distance, components[0], components[1] },
        );
        return;
    }

    if (std.mem.eql(u8, command, "fvec")) {
        if (args.len < 4) usage();
        const strategy = try parseStrategy(args[3]);
        const solve_x = try collectSolveVector(allocator, &info, args[4..]);
        defer allocator.free(solve_x);
        const fvec = try evaluateFvec(allocator, &info, strategy, solve_x);
        defer allocator.free(fvec);
        try printVector(fvec);
        return;
    }

    if (std.mem.eql(u8, command, "jac-column")) {
        if (args.len < 5) usage();
        const strategy = try parseStrategy(args[3]);
        const parameter_index = try std.fmt.parseInt(usize, args[4], 10);
        const solve_x = try collectSolveVector(allocator, &info, args[5..]);
        defer allocator.free(solve_x);
        const column = try evaluateJacobianColumn(allocator, &info, strategy, solve_x, parameter_index);
        defer allocator.free(column);
        try printVector(column);
        return;
    }

    usage();
}

fn usage() noreturn {
    std.debug.print(
        \\usage:
        \\  upstream_probe lm-params <pto>
        \\  upstream_probe solve-lm-params <pto>
        \\  upstream_probe solve-lm-params-zigminpack <pto>
        \\  upstream_probe image-vars <pto> [x...]
        \\  upstream_probe equirect-point <pto> <image_index> <x> <y> [x...]
        \\  upstream_probe fvec <pto> <1|2|distance_only|componentwise> [x...]
        \\  upstream_probe jac-column <pto> <1|2|distance_only|componentwise> <param_index> [x...]
        \\  upstream_probe cp-error <pto> <cp_index> [x...]
        \\
    , .{});
    std.process.exit(1);
}

fn loadAlignInfo(allocator: std.mem.Allocator, pto_path: []const u8) !c.AlignInfo {
    const script = try std.fs.cwd().readFileAlloc(allocator, pto_path, 16 * 1024 * 1024);
    defer allocator.free(script);
    const sanitized = try sanitizeOptimizerScript(allocator, script);
    defer allocator.free(sanitized);
    const script_z = try allocator.dupeZ(u8, sanitized);
    defer allocator.free(script_z);

    var info = std.mem.zeroes(c.AlignInfo);
    if (c.ParseScript(script_z.ptr, &info) != 0) {
        return error.ParseFailed;
    }
    if (c.CheckParams(&info) != 0) {
        c.DisposeAlignInfo(&info);
        return error.InvalidParams;
    }
    return info;
}

fn sanitizeOptimizerScript(allocator: std.mem.Allocator, script: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] == 'p') {
            try out.append(allocator, 'p');
            var tokens = TokenIterator{ .line = line[1..] };
            while (tokens.next()) |token| {
                if (keepPanoToken(token)) {
                    try out.append(allocator, ' ');
                    try out.appendSlice(allocator, token);
                }
            }
            try out.append(allocator, '\n');
            continue;
        }
        if (line.len > 0 and line[0] == 'i') {
            try out.append(allocator, 'i');
            var tokens = TokenIterator{ .line = line[1..] };
            while (tokens.next()) |token| {
                if (keepImageToken(token)) {
                    try out.append(allocator, ' ');
                    try out.appendSlice(allocator, token);
                }
            }
            try out.append(allocator, '\n');
            continue;
        }
        if (line.len > 0 and line[0] == 'v') {
            const trimmed = std.mem.trim(u8, line[1..], " \t\r");
            if (trimmed.len == 0) continue;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

fn keepPanoToken(token: []const u8) bool {
    return std.mem.startsWith(u8, token, "f") or
        std.mem.startsWith(u8, token, "w") or
        std.mem.startsWith(u8, token, "h") or
        std.mem.startsWith(u8, token, "v") or
        std.mem.startsWith(u8, token, "P");
}

fn keepImageToken(token: []const u8) bool {
    return prefixedValue(token, "w") != null or
        prefixedValue(token, "h") != null or
        prefixedValue(token, "f") != null or
        prefixedValue(token, "v") != null or
        prefixedValue(token, "r") != null or
        prefixedValue(token, "p") != null or
        prefixedValue(token, "y") != null or
        prefixedValue(token, "TrX") != null or
        prefixedValue(token, "TrY") != null or
        prefixedValue(token, "TrZ") != null or
        prefixedValue(token, "Tpy") != null or
        prefixedValue(token, "Tpp") != null or
        prefixedValue(token, "a") != null or
        prefixedValue(token, "b") != null or
        prefixedValue(token, "c") != null or
        prefixedValue(token, "d") != null or
        prefixedValue(token, "e") != null or
        prefixedValue(token, "n") != null;
}

fn prefixedValue(token: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, token, prefix)) return null;
    const rest = token[prefix.len..];
    if (rest.len == 0) return rest;
    if (rest[0] == '=') return rest[1..];
    const first = rest[0];
    if (std.ascii.isDigit(first) or first == '-' or first == '+' or first == '.' or first == '"') {
        return rest;
    }
    return null;
}

fn collectSolveVector(allocator: std.mem.Allocator, info: *c.AlignInfo, trailing_args: []const []const u8) ![]f64 {
    const count: usize = @intCast(info.numParam);
    const values = try allocator.alloc(f64, count);

    if (trailing_args.len == 0) {
        if (c.SetLMParams(values.ptr) != 0) {
            return error.SetLMParamsFailed;
        }
        return values;
    }

    if (trailing_args.len != count) usage();
    for (trailing_args, values) |arg, *value| {
        value.* = try std.fmt.parseFloat(f64, arg);
    }
    return values;
}

fn evaluateFvec(allocator: std.mem.Allocator, info: *c.AlignInfo, strategy: c_int, solve_x: []f64) ![]f64 {
    c.setFcnPanoNperCP(strategy);
    const n: usize = @intCast(info.numParam);
    const num_pts: usize = @intCast(info.numPts);
    const actual_count = num_pts * @as(usize, @intCast(strategy));
    const count = @max(actual_count, n);
    const fvec = try allocator.alloc(f64, count);

    var iflag: c_int = -100;
    _ = c.fcnPano(@intCast(count), @intCast(n), solve_x.ptr, fvec.ptr, &iflag);
    if (strategy == 2) {
        c.setFcnPanoDoNotInitAvgFov();
    }
    iflag = 1;
    _ = c.fcnPano(@intCast(count), @intCast(n), solve_x.ptr, fvec.ptr, &iflag);
    return fvec;
}

fn evaluateJacobianColumn(
    allocator: std.mem.Allocator,
    info: *c.AlignInfo,
    strategy: c_int,
    solve_x: []f64,
    parameter_index: usize,
) ![]f64 {
    if (parameter_index >= solve_x.len) return error.ParameterOutOfRange;

    const base_fvec = try evaluateFvec(allocator, info, strategy, solve_x);
    defer allocator.free(base_fvec);

    const shifted_x = try allocator.dupe(f64, solve_x);
    defer allocator.free(shifted_x);
    const eps = @sqrt(@max(std.math.floatEps(f64) * 10.0, std.math.floatEps(f64)));
    var h = eps * @abs(shifted_x[parameter_index]);
    if (h == 0.0) h = eps;
    shifted_x[parameter_index] += h;

    const shifted_fvec = try evaluateFvec(allocator, info, strategy, shifted_x);
    defer allocator.free(shifted_fvec);

    const column = try allocator.alloc(f64, base_fvec.len);
    for (column, base_fvec, shifted_fvec) |*out, base_value, shifted_value| {
        out.* = (shifted_value - base_value) / h;
    }
    return column;
}

fn runOptimizer(info: *c.AlignInfo, initial: ?[]const f64) !void {
    info.fcn = c.fcnPano;
    if (initial) |values| {
        if (c.SetAlignParams(@constCast(values.ptr)) != 0) return error.SetAlignParamsFailed;
    }
    var opt = std.mem.zeroes(c.OptInfo);
    opt.numVars = info.numParam;
    opt.numData = info.numPts;
    opt.SetVarsToX = c.SetLMParams;
    opt.SetXToVars = c.SetAlignParams;
    opt.fcn = info.fcn;
    c.RunLMOptimizer(&opt);
}

const Point2 = struct {
    x: f64,
    y: f64,
};

fn pointToEquirectDegrees(info: *c.AlignInfo, image_index: usize, x: f64, y: f64) Point2 {
    var sph = std.mem.zeroes(c.Image);
    c.SetImageDefaults(&sph);
    sph.width = 360;
    sph.height = 180;
    sph.format = c._equirectangular;
    sph.hfov = 360.0;

    var stack: [15]c.fDesc = undefined;
    var mp = std.mem.zeroes(c.MakeParams);
    c.SetInvMakeParams(&stack, &mp, &info.im[image_index], &sph, 0);

    const h2 = @as(f64, @floatFromInt(info.im[image_index].height)) / 2.0 - 0.5;
    const w2 = @as(f64, @floatFromInt(info.im[image_index].width)) / 2.0 - 0.5;

    var out_x: f64 = 0.0;
    var out_y: f64 = 0.0;
    _ = c.execute_stack_new(x - w2, y - h2, &out_x, &out_y, &stack);
    return .{ .x = out_x, .y = out_y };
}

const UpstreamSolveContext = struct {
    m: usize,
    n: usize,
};

fn runZigMinpackOptimizer(allocator: std.mem.Allocator, info: *c.AlignInfo, initial: ?[]const f64) ![]f64 {
    info.fcn = c.fcnPano;
    const n: usize = @intCast(info.numParam);
    if (n == 0) return allocator.alloc(f64, 0);

    if (initial) |values| {
        if (c.SetAlignParams(@constCast(values.ptr)) != 0) return error.SetAlignParamsFailed;
    }

    const current = try allocator.alloc(f64, n);
    errdefer allocator.free(current);
    if (c.SetLMParams(current.ptr) != 0) return error.SetLMParamsFailed;

    for ([_]c_int{ 1, 2 }) |strategy| {
        c.setFcnPanoNperCP(strategy);
        const actual_m = @as(usize, @intCast(info.numPts)) * @as(usize, @intCast(strategy));
        const m = @max(actual_m, n);
        var ctx = UpstreamSolveContext{ .m = m, .n = n };

        const initial_fvec = try allocator.alloc(f64, m);
        defer allocator.free(initial_fvec);
        var reset_iflag: c_int = -100;
        _ = c.fcnPano(@intCast(m), @intCast(n), current.ptr, initial_fvec.ptr, &reset_iflag);
        if (strategy == 2) {
            c.setFcnPanoDoNotInitAvgFov();
        }

        const params = minpack_mod.Params{
            .ftol = if (strategy == 1) 0.05 else 1.0e-6,
            .xtol = std.math.floatEps(f64),
            .gtol = std.math.floatEps(f64),
            .maxfev = 100 * (n + 1) * 100,
            .epsfcn = std.math.floatEps(f64) * 10.0,
            .factor = 100.0,
        };
        _ = try minpack_mod.lmdif(UpstreamSolveContext, allocator, &ctx, evaluateUpstreamSolveVector, current, m, params);
    }

    _ = c.SetAlignParams(current.ptr);
    const final = try allocator.alloc(f64, n);
    if (c.SetLMParams(final.ptr) != 0) return error.SetLMParamsFailed;
    return final;
}

fn evaluateUpstreamSolveVector(ctx: *UpstreamSolveContext, x: []const f64, fvec: []f64) !void {
    std.debug.assert(x.len == ctx.n);
    std.debug.assert(fvec.len == ctx.m);
    var iflag: c_int = 1;
    _ = c.fcnPano(@intCast(ctx.m), @intCast(ctx.n), @constCast(x.ptr), fvec.ptr, &iflag);
}

fn printVector(values: []const f64) !void {
    for (values, 0..) |value, index| {
        std.debug.print("{d}: {d:.12}\n", .{ index, value });
    }
}

fn printImageVars(info: *c.AlignInfo) !void {
    const num_images: usize = @intCast(info.numIm);
    for (0..num_images) |index| {
        const image = info.im[index];
        std.debug.print(
            "[{d}] y={d:.12} p={d:.12} r={d:.12} v={d:.12} a={d:.12} b={d:.12} c={d:.12} d={d:.12} e={d:.12} TrX={d:.12} TrY={d:.12} TrZ={d:.12} Tpy={d:.12} Tpp={d:.12}\n",
            .{
                index,
                image.yaw,
                image.pitch,
                image.roll,
                image.hfov,
                image.cP.radial_params[0][3],
                image.cP.radial_params[0][2],
                image.cP.radial_params[0][1],
                image.cP.horizontal_params[0],
                image.cP.vertical_params[0],
                image.cP.trans_x,
                image.cP.trans_y,
                image.cP.trans_z,
                image.cP.trans_yaw,
                image.cP.trans_pitch,
            },
        );
    }
}

fn parseStrategy(value: []const u8) !c_int {
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "distance_only")) return 1;
    if (std.mem.eql(u8, value, "2") or std.mem.eql(u8, value, "componentwise")) return 2;
    return error.InvalidStrategy;
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

fn infoCallback(_: c_int, _: [*c]u8) callconv(.c) c_int {
    return 1;
}
