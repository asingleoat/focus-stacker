const std = @import("std");
const core = @import("align_stack_core");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    defer writeProfilerReport();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const exe_name = if (argv.len > 0) std.fs.path.basename(argv[0]) else "align_image_stack_zig";
    const cli_args = if (argv.len > 1) argv[1..] else argv[0..0];

    var cfg = core.config.parseArgs(allocator, cli_args) catch |err| {
        switch (err) {
            error.InvalidOption => fatalWithUsage(allocator, exe_name, "invalid option\n"),
            error.MissingOptionValue => fatalWithUsage(allocator, exe_name, "missing option value\n"),
            error.InvalidValue => fatalWithUsage(allocator, exe_name, "invalid option value\n"),
            error.NotEnoughInputFiles => fatalWithUsage(allocator, exe_name, "expected at least 2 input files\n"),
            error.NoRequestedOutputs => fatalWithUsage(allocator, exe_name, "please specify at least one of -p, -o or -a\n"),
            else => return err,
        }
    };
    defer cfg.deinit(allocator);

    if (cfg.action == .help) {
        const usage = try core.config.renderUsage(allocator, exe_name);
        defer allocator.free(usage);
        try std.fs.File.stdout().writeAll(usage);
        return;
    }

    if (cfg.verbose > 0) {
        const summary = try core.config.renderSummary(allocator, &cfg);
        defer allocator.free(summary);
        try std.fs.File.stderr().writeAll(summary);
    }

    core.pipeline.run(allocator, &cfg) catch |err| switch (err) {
        error.NoUsableInputFiles => {
            try std.fs.File.stderr().writeAll("ERROR: No valid files given. Nothing to do.\n");
            exitWithReport(1);
        },
        error.NotEnoughUsableInputFiles => {
            try std.fs.File.stderr().writeAll("ERROR: Need at least two usable non-raw input images.\n");
            exitWithReport(1);
        },
        error.MismatchedImageSizes => {
            try std.fs.File.stderr().writeAll("ERROR: Align_image_stack requires all input images to have the same size.\n");
            exitWithReport(1);
        },
        error.UnsupportedPixelFormat => {
            try std.fs.File.stderr().writeAll("ERROR: Encountered an unsupported image pixel format.\n");
            exitWithReport(1);
        },
        error.ReferenceImageHasNoControlPointsAfterPruning => {
            try std.fs.File.stderr().writeAll(
                "ERROR: After control-point pruning the reference image has no remaining control points; optimizing HFOV would be ill-defined.\n",
            );
            exitWithReport(1);
        },
        error.NotEnoughControlPointsAfterPruning => {
            try std.fs.File.stderr().writeAll(
                "ERROR: After control-point pruning there are fewer control points left than active optimization parameters.\n",
            );
            exitWithReport(1);
        },
        error.OpenFailed, error.DecodeFailed, error.InvalidImage, error.UnsupportedFormat => {
            try std.fs.File.stderr().writeAll("ERROR: Image loading failed.\n");
            exitWithReport(1);
        },
        error.NotImplemented => {
            const message = try std.fmt.allocPrint(
                allocator,
                \\ported so far: CLI validation, C-backed image I/O, pure-Zig grayscale conversion, pure-Zig pyramid reduction, sequence planning, coarse interest-point detection, coarse control-point matching, full-resolution fine tuning, an optimize-vector-aware iterative camera/lens solve, residual pruning, PTO output, aligned TIFF output.
                \\remaining stages: higher-fidelity optimizer parity with align_image_stack, HDR output.
                \\reference source: {s}
                \\reference docs:   {s}
                \\
            ,
                .{
                    core.pipeline.ReferencePaths.align_image_stack_cpp,
                    core.pipeline.ReferencePaths.align_image_stack_doc,
                },
            );
            defer allocator.free(message);
            try std.fs.File.stderr().writeAll(message);
            exitWithReport(1);
        },
        else => return err,
    };
}

fn exitWithReport(code: u8) noreturn {
    writeProfilerReport();
    std.process.exit(code);
}

fn writeProfilerReport() void {
    if (!core.profiler.enabled) return;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    core.profiler.maybeWriteReport(&stderr_writer.interface) catch {};
    stderr_writer.interface.flush() catch {};
}

fn fatalWithUsage(
    allocator: std.mem.Allocator,
    exe_name: []const u8,
    message: []const u8,
) noreturn {
    std.fs.File.stderr().writeAll(message) catch {};
    const usage = core.config.renderUsage(allocator, exe_name) catch {
        exitWithReport(1);
    };
    defer allocator.free(usage);
    std.fs.File.stderr().writeAll("\n") catch {};
    std.fs.File.stderr().writeAll(usage) catch {};
    exitWithReport(1);
}

test {
    _ = @import("align_stack_core");
}
