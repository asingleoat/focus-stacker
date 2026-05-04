const std = @import("std");
const memory_budget = @import("align_stack_core").memory_budget;
const pyramid = @import("pyramid.zig");

pub const Action = enum {
    run,
    help,
};

pub const Method = enum {
    hardmask_contrast,
    softmask_contrast,
    pyramid_contrast,
    hybrid_pyramid_contrast,

    pub fn cliName(self: Method) []const u8 {
        return switch (self) {
            .hardmask_contrast => "hardmask-contrast",
            .softmask_contrast => "softmask-contrast",
            .pyramid_contrast => "pyramid-contrast",
            .hybrid_pyramid_contrast => "hybrid-pyramid-contrast",
        };
    }
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
    memory_fraction: f32 = memory_budget.default_memory_fraction,
    method: Method = .pyramid_contrast,
    hybrid_sharpness: f32 = pyramid.default_hybrid_sharpness,
    hard_mask: bool = true,
    contrast_window_size: u32 = 5,
    output_path: ?[]const u8 = null,
    dump_masks_dir: ?[]const u8 = null,
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

        if (std.mem.startsWith(u8, arg, "--method=")) {
            cfg.method = try parseMethod(arg["--method=".len..]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--method")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cfg.method = try parseMethod(args[i]);
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

        return error.InvalidOption;
    }

    if (cfg.action == .run and cfg.output_path == null) return error.MissingOutputPath;
    if (cfg.action == .run and cfg.input_files.items.len < 2) return error.NotEnoughInputFiles;

    return cfg;
}

pub fn renderUsage(
    allocator: std.mem.Allocator,
    exe_name: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\{s}: focus-stack-oriented lite fusion tool
        \\
        \\Usage: {s} [options] input files
        \\Options:
        \\  -o, --output file          Output fused TIFF path
        \\  -v                         Verbose progress. Repeat for more detail
        \\  --threads num              Use up to num worker threads
        \\  --memory-fraction x        Use at most x of currently available RAM for
        \\                               coarse-grained parallel working sets and caches
        \\                               (default: {d:.2}, 0 disables)
        \\  --method method            Fusion implementation:
        \\                               hardmask-contrast
        \\                               softmask-contrast
        \\                               pyramid-contrast (default)
        \\                               hybrid-pyramid-contrast
        \\  --hybrid-sharpness x       Hybrid sharpening amount in [0,1]
        \\                               (default: {d:.2})
        \\  --dump-masks-dir dir       Dump raw/normalized masks for debugging
        \\  --contrast-window-size n   Local contrast window size (default: 5)
        \\  --hard-mask                Keep upstream-style hard-mask winner selection
        \\  -h, --help                 Display this help text
        \\
        \\Status: pure-Zig focus-stack fusion path based on enfuse local-contrast weighting,
        \\with hard-mask, soft-mask, pyramid, and hybrid sharpened-pyramid variants.
        \\The full enfuse pyramid stack is not ported yet.
        \\
    ,
        .{ exe_name, exe_name, memory_budget.default_memory_fraction, pyramid.default_hybrid_sharpness },
    );
}

pub fn renderSummary(
    allocator: std.mem.Allocator,
    cfg: *const Config,
) std.mem.Allocator.Error![]u8 {
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
        \\  method: {s}
        \\  hybrid sharpness: {d:.3}
        \\  hard mask: {}
        \\  contrast window size: {d}
        \\  output: {s}
        \\  dump masks dir: {s}
        \\
    ,
        .{
            cfg.input_files.items.len,
            cfg.verbose,
            jobs,
            memory_fraction,
            cfg.method.cliName(),
            cfg.hybrid_sharpness,
            cfg.hard_mask,
            cfg.contrast_window_size,
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

pub fn parseMethod(value: []const u8) ParseError!Method {
    if (std.mem.eql(u8, value, "hardmask-contrast")) return .hardmask_contrast;
    if (std.mem.eql(u8, value, "softmask-contrast")) return .softmask_contrast;
    if (std.mem.eql(u8, value, "pyramid-contrast")) return .pyramid_contrast;
    if (std.mem.eql(u8, value, "hybrid-pyramid-contrast")) return .hybrid_pyramid_contrast;
    return error.InvalidValue;
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
