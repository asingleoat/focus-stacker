const std = @import("std");
const align_core = @import("align_stack_core");
const fuse_core = @import("focus_fuse_core");

pub const Action = enum {
    run,
    help,
};

pub const ParseError = error{
    InvalidOption,
    MissingOptionValue,
    InvalidValue,
    NotEnoughInputFiles,
    MissingOutputPath,
};

pub const Config = struct {
    action: Action = .run,
    verbose: u8 = 0,
    jobs: ?u32 = null,
    memory_fraction: f32 = align_core.memory_budget.default_memory_fraction,
    pair_align_method: align_core.pair_align.Method = .phasecorr_locked,
    align_control_points: u32 = 200,
    align_grid_size: u32 = 7,
    align_error_threshold: f64 = 5.0,
    contrast_window_size: u32 = 5,
    hybrid_sharpness: f32 = fuse_core.pyramid.default_hybrid_sharpness,
    hard_mask: bool = true,
    fuse_method: fuse_core.config.Method = .pyramid_contrast,
    output_path: ?[]const u8 = null,
    dump_masks_dir: ?[]const u8 = null,
    input_files: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        self.input_files.deinit(allocator);
    }

    pub fn toAlignConfig(self: *const Config, allocator: std.mem.Allocator) std.mem.Allocator.Error!align_core.config.Config {
        var cfg = align_core.config.Config{
            .verbose = self.verbose,
            .pair_jobs = self.jobs,
            .memory_fraction = self.memory_fraction,
            .cp_error_threshold = self.align_error_threshold,
            .points_per_grid = self.align_control_points,
            .grid_size = self.align_grid_size,
            .pair_alignment_method = self.pair_align_method,
            .optimize_hfov = true,
            .optimize_distortion = true,
            .optimize_center_shift = true,
            .crop = true,
            .sort_images_by_ev = false,
        };
        try cfg.input_files.appendSlice(allocator, self.input_files.items);
        return cfg;
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) (ParseError || std.mem.Allocator.Error)!Config {
    var cfg = Config{};
    errdefer cfg.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0 or arg[0] != '-') {
            try cfg.input_files.append(allocator, arg);
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try cfg.input_files.append(allocator, args[i]);
            }
            break;
        }

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            cfg.action = .help;
            return cfg;
        }
        if (std.mem.eql(u8, arg, "-v")) {
            cfg.verbose +|= 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--hard-mask")) {
            cfg.hard_mask = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--fuse-method=")) {
            cfg.fuse_method = try fuse_core.config.parseMethod(arg["--fuse-method=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--fuse-method")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.fuse_method = try fuse_core.config.parseMethod(args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.output_path = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--output=")) {
            cfg.output_path = arg["--output=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--dump-masks-dir=")) {
            cfg.dump_masks_dir = arg["--dump-masks-dir=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.output_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--dump-masks-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.dump_masks_dir = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--threads=")) {
            cfg.jobs = try parsePositiveU32(arg["--threads=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--threads")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.jobs = try parsePositiveU32(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--memory-fraction=")) {
            cfg.memory_fraction = try parseMemoryFraction(arg["--memory-fraction=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--memory-fraction")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.memory_fraction = try parseMemoryFraction(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--pair-align=")) {
            cfg.pair_align_method = align_core.pair_align.parseMethod(arg["--pair-align=".len..]) orelse return error.InvalidValue;
            continue;
        }
        if (std.mem.eql(u8, arg, "--pair-align")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.pair_align_method = align_core.pair_align.parseMethod(args[i]) orelse return error.InvalidValue;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--contrast-window-size=")) {
            cfg.contrast_window_size = try parseWindowSize(arg["--contrast-window-size=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--contrast-window-size")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.contrast_window_size = try parseWindowSize(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--hybrid-sharpness=")) {
            cfg.hybrid_sharpness = try parseSharpness(arg["--hybrid-sharpness=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--hybrid-sharpness")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.hybrid_sharpness = try parseSharpness(args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.align_control_points = try parsePositiveU32(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-c") and arg.len > 2) {
            cfg.align_control_points = try parsePositiveU32(arg[2..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "-g")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.align_grid_size = try parsePositiveU32(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-g") and arg.len > 2) {
            cfg.align_grid_size = try parsePositiveU32(arg[2..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.align_error_threshold = try parseNonNegativeFloat(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-t") and arg.len > 2) {
            cfg.align_error_threshold = try parseNonNegativeFloat(arg[2..]);
            continue;
        }

        return error.InvalidOption;
    }

    if (cfg.action == .run and cfg.output_path == null) return error.MissingOutputPath;
    if (cfg.action == .run and cfg.input_files.items.len < 2) return error.NotEnoughInputFiles;
    return cfg;
}

pub fn renderUsage(allocator: std.mem.Allocator, exe_name: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\{s}: in-process focus stacker using the Zig aligner and Zig focus fuser
        \\
        \\Usage: {s} [options] input files
        \\Options:
        \\  -o, --output file          Output fused TIFF path
        \\  -v                         Verbose progress. Repeat for more detail
        \\  --threads num              Use up to num worker threads
        \\  --memory-fraction x        Use at most x of currently available RAM for
        \\                               coarse-grained parallel working sets and caches
        \\                               (default: {d:.2}, 0 disables)
        \\  --pair-align method        Pair alignment method:
        \\                               hugin-ncc, phasecorr-seeded, phasecorr-locked (default)
        \\  -c num                     Control points per grid cell (default: 200)
        \\  -g num                     Grid size per image axis (default: 7)
        \\  -t num                     Control-point prune threshold in pixels (default: 5)
        \\  --contrast-window-size n   Local contrast window size (default: 5)
        \\  --fuse-method method       Fusion method:
        \\                               hardmask-contrast
        \\                               softmask-contrast
        \\                               pyramid-contrast (default)
        \\                               hybrid-pyramid-contrast
        \\  --hybrid-sharpness x       Hybrid sharpening amount in [0,1]
        \\                               (default: {d:.2})
        \\  --dump-masks-dir dir       Dump raw/normalized masks for debugging
        \\  --hard-mask                Keep hard-mask winner selection
        \\  -h, --help                 Display this help text
        \\
        \\Behavior:
        \\  Uses given input order, enables magnification/distortion/center-shift optimization,
        \\  auto-crops to common overlap, remaps one image at a time in memory, and fuses
        \\  immediately without writing aligned intermediate TIFFs.
        \\
    ,
        .{ exe_name, exe_name, align_core.memory_budget.default_memory_fraction, fuse_core.pyramid.default_hybrid_sharpness },
    );
}

pub fn renderSummary(allocator: std.mem.Allocator, cfg: *const Config) std.mem.Allocator.Error![]u8 {
    var jobs_buf: [32]u8 = undefined;
    const jobs = if (cfg.jobs) |value|
        std.fmt.bufPrint(&jobs_buf, "{d}", .{value}) catch unreachable
    else
        "auto";
    var memory_fraction_buf: [32]u8 = undefined;
    const memory_fraction = std.fmt.bufPrint(&memory_fraction_buf, "{d:.2}", .{cfg.memory_fraction}) catch unreachable;

    return std.fmt.allocPrint(
        allocator,
        \\parsed configuration:
        \\  inputs: {d}
        \\  verbose: {d}
        \\  jobs: {s}
        \\  memory fraction: {s}
        \\  pair align: {s}
        \\  control points per cell: {d}
        \\  grid size: {d}
        \\  prune threshold: {d:.3}
        \\  contrast window size: {d}
        \\  hybrid sharpness: {d:.3}
        \\  hard mask: {}
        \\  fuse method: {s}
        \\  output: {s}
        \\  dump masks dir: {s}
        \\
    ,
        .{
            cfg.input_files.items.len,
            cfg.verbose,
            jobs,
            memory_fraction,
            cfg.pair_align_method.cliName(),
            cfg.align_control_points,
            cfg.align_grid_size,
            cfg.align_error_threshold,
            cfg.contrast_window_size,
            cfg.hybrid_sharpness,
            cfg.hard_mask,
            cfg.fuse_method.cliName(),
            cfg.output_path.?,
            cfg.dump_masks_dir orelse "(disabled)",
        },
    );
}

fn parseSharpness(value: []const u8) ParseError!f32 {
    const parsed = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
    if (!std.math.isFinite(parsed) or parsed < 0.0 or parsed > 1.0) return error.InvalidValue;
    return parsed;
}

fn parseMemoryFraction(value: []const u8) ParseError!f32 {
    const parsed = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
    if (!std.math.isFinite(parsed) or parsed < 0.0 or parsed > 1.0) return error.InvalidValue;
    return parsed;
}

fn parsePositiveU32(value: []const u8) ParseError!u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    if (parsed == 0) return error.InvalidValue;
    return parsed;
}

fn parseWindowSize(value: []const u8) ParseError!u32 {
    const parsed = try parsePositiveU32(value);
    if (parsed < 3 or (parsed & 1) == 0) return error.InvalidValue;
    return parsed;
}

fn parseNonNegativeFloat(value: []const u8) ParseError!f64 {
    const parsed = std.fmt.parseFloat(f64, value) catch return error.InvalidValue;
    if (!(parsed >= 0)) return error.InvalidValue;
    return parsed;
}

test "toAlignConfig enables focus-stack defaults" {
    const allocator = std.testing.allocator;
    var cfg = Config{};
    defer cfg.deinit(allocator);
    try cfg.input_files.appendSlice(allocator, &.{ "a.jpg", "b.jpg" });
    cfg.jobs = 4;
    cfg.pair_align_method = .phasecorr_locked;
    cfg.align_control_points = 24;
    cfg.align_grid_size = 4;
    cfg.align_error_threshold = 5;

    var align_cfg = try cfg.toAlignConfig(allocator);
    defer align_cfg.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), align_cfg.pair_jobs.?);
    try std.testing.expectEqual(align_core.pair_align.Method.phasecorr_locked, align_cfg.pair_alignment_method);
    try std.testing.expectEqual(@as(u32, 24), align_cfg.points_per_grid);
    try std.testing.expectEqual(@as(u32, 4), align_cfg.grid_size);
    try std.testing.expectEqual(@as(f64, 5), align_cfg.cp_error_threshold);
    try std.testing.expect(align_cfg.optimize_hfov);
    try std.testing.expect(align_cfg.optimize_distortion);
    try std.testing.expect(align_cfg.optimize_center_shift);
    try std.testing.expect(align_cfg.crop);
    try std.testing.expect(!align_cfg.sort_images_by_ev);
}
