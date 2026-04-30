const std = @import("std");
const pair_align = @import("pair_align.zig");

pub const latest_upstream_version = "hugin-2025.0.1";
pub const latest_upstream_release_date = "2025-12-13";

pub const Action = enum {
    run,
    help,
};

pub const ParseError = error{
    InvalidOption,
    MissingOptionValue,
    InvalidValue,
    NotEnoughInputFiles,
    NoRequestedOutputs,
};

pub const Config = struct {
    action: Action = .run,
    verbose: u8 = 0,
    pair_jobs: ?u32 = null,
    cp_error_threshold: f64 = 3.0,
    corr_thresh: f64 = 0.9,
    points_per_grid: u32 = 8,
    grid_size: u32 = 5,
    pair_alignment_method: pair_align.Method = .hugin_ncc,
    hfov: ?f64 = null,
    pyr_level: u8 = 1,
    linear: bool = false,
    optimize_hfov: bool = false,
    optimize_distortion: bool = false,
    optimize_center_shift: bool = false,
    optimize_translation_x: bool = false,
    optimize_translation_y: bool = false,
    optimize_translation_z: bool = false,
    fisheye: bool = false,
    stereo: bool = false,
    stereo_window: bool = false,
    pop_out: bool = false,
    crop: bool = false,
    gpu: bool = false,
    load_distortion: bool = false,
    sort_images_by_ev: bool = true,
    align_to_first: bool = false,
    dont_remap_ref: bool = false,
    aligned_prefix: ?[]const u8 = null,
    pto_file: ?[]const u8 = null,
    hdr_file: ?[]const u8 = null,
    input_files: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        self.input_files.deinit(allocator);
    }
};

pub fn parseArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) (ParseError || std.mem.Allocator.Error)!Config {
    var cfg = Config{};
    errdefer cfg.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (arg.len == 0) {
            try cfg.input_files.append(allocator, arg);
            i += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try cfg.input_files.append(allocator, args[i]);
            }
            break;
        }

        if (arg[0] != '-') {
            try cfg.input_files.append(allocator, arg);
            i += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            cfg.action = .help;
            return cfg;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            try parseLongOption(&cfg, args, &i);
        } else {
            try parseShortOptions(&cfg, args, &i);
        }

        i += 1;
    }

    if (cfg.stereo) {
        cfg.sort_images_by_ev = false;
    }

    if (cfg.action == .run and cfg.input_files.items.len < 2) {
        return error.NotEnoughInputFiles;
    }

    if (cfg.action == .run and cfg.aligned_prefix == null and cfg.pto_file == null and cfg.hdr_file == null) {
        return error.NoRequestedOutputs;
    }

    return cfg;
}

pub fn renderUsage(
    allocator: std.mem.Allocator,
    exe_name: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\{s}: align overlapping images for HDR creation
        \\experimental Zig port scaffold for Hugin {s}
        \\
        \\Usage: {s} [options] input files
        \\Valid options are:
        \\ Modes of operation:
        \\  -p file   Output .pto file (useful for debugging, or further refinement)
        \\  -a prefix align images, output as prefix_xxxx.tif
        \\  -o output merge images to HDR, generate output.hdr
        \\ Modifiers
        \\  -v        Verbose, print progress messages. Repeat for higher verbosity
        \\  -e        Assume input images are full frame fish eye (default: rectilinear)
        \\  -t num    Remove all control points with an error higher than num pixels
        \\             (default: 3)
        \\  --corr=num  Correlation threshold for identifying control points
        \\               (default: 0.9)
        \\  -f HFOV   Approximate horizontal field of view of input images
        \\  -m        Optimize field of view for all images, except for first
        \\  -d        Optimize radial distortion for all images, except for first
        \\  -i        Optimize image center shift for all images, except for first
        \\  -x        Optimize X coordinate of the camera position
        \\  -y        Optimize Y coordinate of the camera position
        \\  -z        Optimize Z coordinate of the camera position
        \\  -S        Assume stereo images
        \\  -A        Align stereo window - assumes -S
        \\  -P        Align stereo window with pop-out effect - assumes -S
        \\  -C        Auto crop the image to the area covered by all images
        \\  -c num    Number of control points per grid section (default: 8)
        \\  -l        Assume linear input files
        \\  -s scale  Scale down image by 2^scale (default: 1)
        \\  -g gsize  Break image into a gsize x gsize grid (default: 5)
        \\  --pair-align method
        \\             Pair alignment implementation to use:
        \\               hugin-ncc (default), phasecorr-seeded, phasecorr-locked
        \\  --distortion      Try to load distortion data from the lens database
        \\  --use-given-order Use the image order as given on the command line
        \\  --align-to-first  Align all images to the first one
        \\  --dont-remap-ref  Don't output the remapped reference image
        \\  --gpu             Use GPU for remapping
        \\  --threads num     Use up to num worker threads for pair analysis and remap
        \\  -h, --help        Display this help text
        \\
        \\Status: sequence planning, matching, full-resolution refinement, an optimize-vector-aware iterative camera/lens solve, PTO output, and aligned TIFF remap are ported; HDR output is not yet implemented.
        \\
    ,
        .{ exe_name, latest_upstream_version, exe_name },
    );
}

pub fn renderSummary(
    allocator: std.mem.Allocator,
    cfg: *const Config,
) std.mem.Allocator.Error![]u8 {
    var pair_jobs_buf: [32]u8 = undefined;
    const pair_jobs = if (cfg.pair_jobs) |jobs|
        std.fmt.bufPrint(&pair_jobs_buf, "{d}", .{jobs}) catch unreachable
    else
        "auto";

    return std.fmt.allocPrint(
        allocator,
        \\parsed configuration:
        \\  inputs: {d}
        \\  verbose: {d}
        \\  pair jobs: {s}
        \\  pyramid level: {d}
        \\  pair alignment: {s}
        \\  grid: {d}x{d}
        \\  points per grid: {d}
        \\  correlation threshold: {d}
        \\  error threshold: {d}
        \\  sort by EV: {}
        \\  align to first: {}
        \\
    ,
        .{
            cfg.input_files.items.len,
            cfg.verbose,
            pair_jobs,
            cfg.pyr_level,
            cfg.pair_alignment_method.cliName(),
            cfg.grid_size,
            cfg.grid_size,
            cfg.points_per_grid,
            cfg.corr_thresh,
            cfg.cp_error_threshold,
            cfg.sort_images_by_ev,
            cfg.align_to_first,
        },
    );
}

fn parseShortOptions(
    cfg: *Config,
    args: []const []const u8,
    index: *usize,
) (ParseError || std.mem.Allocator.Error)!void {
    const arg = args[index.*];
    var pos: usize = 1;
    while (pos < arg.len) {
        const opt = arg[pos];
        switch (opt) {
            'v' => cfg.verbose +|= 1,
            'e' => cfg.fisheye = true,
            'l' => cfg.linear = true,
            'm' => cfg.optimize_hfov = true,
            'd' => cfg.optimize_distortion = true,
            'i' => cfg.optimize_center_shift = true,
            'x' => cfg.optimize_translation_x = true,
            'y' => cfg.optimize_translation_y = true,
            'z' => cfg.optimize_translation_z = true,
            'S' => {
                cfg.stereo = true;
                cfg.sort_images_by_ev = false;
            },
            'A' => {
                cfg.stereo = true;
                cfg.stereo_window = true;
                cfg.sort_images_by_ev = false;
            },
            'P' => {
                cfg.stereo = true;
                cfg.stereo_window = true;
                cfg.pop_out = true;
                cfg.sort_images_by_ev = false;
            },
            'C' => cfg.crop = true,
            'a' => {
                cfg.aligned_prefix = try takeValue(args, index, arg[(pos + 1)..]);
                return;
            },
            'c' => {
                cfg.points_per_grid = try parseBoundedInt(u32, try takeValue(args, index, arg[(pos + 1)..]), 1, null);
                return;
            },
            'f' => {
                cfg.hfov = try parsePositiveFloat(try takeValue(args, index, arg[(pos + 1)..]));
                return;
            },
            'g' => {
                cfg.grid_size = try parseBoundedInt(u32, try takeValue(args, index, arg[(pos + 1)..]), 1, 50);
                return;
            },
            'o' => {
                cfg.hdr_file = try takeValue(args, index, arg[(pos + 1)..]);
                return;
            },
            'p' => {
                cfg.pto_file = try takeValue(args, index, arg[(pos + 1)..]);
                return;
            },
            's' => {
                cfg.pyr_level = try parseBoundedInt(u8, try takeValue(args, index, arg[(pos + 1)..]), 0, 8);
                return;
            },
            't' => {
                cfg.cp_error_threshold = try parsePositiveFloat(try takeValue(args, index, arg[(pos + 1)..]));
                return;
            },
            else => return error.InvalidOption,
        }
        pos += 1;
    }
}

fn parseLongOption(
    cfg: *Config,
    args: []const []const u8,
    index: *usize,
) ParseError!void {
    const arg = args[index.*][2..];
    const eq_index = std.mem.indexOfScalar(u8, arg, '=');
    const name = if (eq_index) |eq| arg[0..eq] else arg;
    const attached_value = if (eq_index) |eq| arg[(eq + 1)..] else "";

    if (std.mem.eql(u8, name, "corr")) {
        cfg.corr_thresh = try parseUnitFloat(try takeValue(args, index, attached_value));
        return;
    }
    if (std.mem.eql(u8, name, "verbose")) {
        cfg.verbose +|= 1;
        return;
    }
    if (std.mem.eql(u8, name, "threads")) {
        cfg.pair_jobs = try parseBoundedInt(u32, try takeValue(args, index, attached_value), 1, null);
        return;
    }
    if (std.mem.eql(u8, name, "pair-align")) {
        const value = try takeValue(args, index, attached_value);
        cfg.pair_alignment_method = pair_align.parseMethod(value) orelse return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, name, "gpu")) {
        cfg.gpu = true;
        return;
    }
    if (std.mem.eql(u8, name, "distortion")) {
        cfg.load_distortion = true;
        return;
    }
    if (std.mem.eql(u8, name, "use-given-order")) {
        cfg.sort_images_by_ev = false;
        return;
    }
    if (std.mem.eql(u8, name, "align-to-first")) {
        cfg.align_to_first = true;
        cfg.sort_images_by_ev = false;
        return;
    }
    if (std.mem.eql(u8, name, "dont-remap-ref")) {
        cfg.dont_remap_ref = true;
        return;
    }
    return error.InvalidOption;
}

fn takeValue(
    args: []const []const u8,
    index: *usize,
    attached: []const u8,
) ParseError![]const u8 {
    if (attached.len > 0) {
        return attached;
    }
    if (index.* + 1 >= args.len) {
        return error.MissingOptionValue;
    }
    index.* += 1;
    return args[index.*];
}

fn parsePositiveFloat(value: []const u8) ParseError!f64 {
    const parsed = std.fmt.parseFloat(f64, value) catch return error.InvalidValue;
    if (parsed <= 0) {
        return error.InvalidValue;
    }
    return parsed;
}

fn parseUnitFloat(value: []const u8) ParseError!f64 {
    const parsed = std.fmt.parseFloat(f64, value) catch return error.InvalidValue;
    if (parsed <= 0 or parsed > 1.0) {
        return error.InvalidValue;
    }
    return parsed;
}

fn parseBoundedInt(
    comptime T: type,
    value: []const u8,
    min_value: T,
    max_value: ?T,
) ParseError!T {
    const parsed = std.fmt.parseInt(T, value, 10) catch return error.InvalidValue;
    if (parsed < min_value) {
        return error.InvalidValue;
    }
    if (max_value) |max_int| {
        if (parsed > max_int) {
            return error.InvalidValue;
        }
    }
    return parsed;
}

test "parse help action" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--help" };
    var cfg = try parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(Action.help, cfg.action);
}

test "parse align-to-first disables EV sorting" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--align-to-first", "-p", "out.pto", "a.tif", "b.tif" };
    var cfg = try parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.align_to_first);
    try std.testing.expect(!cfg.sort_images_by_ev);
    try std.testing.expectEqual(@as(usize, 2), cfg.input_files.items.len);
}

test "parse clustered verbosity and value options" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "-vv", "-g", "7", "-c12", "-p", "out.pto", "a.tif", "b.tif" };
    var cfg = try parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), cfg.verbose);
    try std.testing.expectEqual(@as(u32, 7), cfg.grid_size);
    try std.testing.expectEqual(@as(u32, 12), cfg.points_per_grid);
}

test "parse threads option" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--threads=6", "-p", "out.pto", "a.tif", "b.tif" };
    var cfg = try parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, 6), cfg.pair_jobs);
}

test "parse pair-align option" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--pair-align=phasecorr-seeded", "-p", "out.pto", "a.tif", "b.tif" };
    var cfg = try parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(pair_align.Method.phasecorr_seeded, cfg.pair_alignment_method);
}

test "invalid correlation threshold is rejected" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--corr=1.5", "a.tif", "b.tif" };

    try std.testing.expectError(error.InvalidValue, parseArgs(allocator, &args));
}

test "at least one output is required" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "a.tif", "b.tif" };

    try std.testing.expectError(error.NoRequestedOutputs, parseArgs(allocator, &args));
}
