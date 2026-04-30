const std = @import("std");
const core = @import("root.zig");
const align_core = @import("align_stack_core");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = align_core.alloc_profiler.wrap(gpa.allocator());
    defer writeProfilerReport();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const exe_name = if (argv.len > 0) std.fs.path.basename(argv[0]) else "focus_stack_zig";
    const cli_args = if (argv.len > 1) argv[1..] else argv[0..0];

    var cfg = core.config.parseArgs(allocator, cli_args) catch |err| {
        switch (err) {
            error.InvalidOption => fatalWithUsage(allocator, exe_name, "invalid option\n"),
            error.MissingOptionValue => fatalWithUsage(allocator, exe_name, "missing option value\n"),
            error.InvalidValue => fatalWithUsage(allocator, exe_name, "invalid option value\n"),
            error.NotEnoughInputFiles => fatalWithUsage(allocator, exe_name, "expected at least 2 input files\n"),
            error.MissingOutputPath => fatalWithUsage(allocator, exe_name, "please specify --output\n"),
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
        error.MismatchedImageSizes => {
            try std.fs.File.stderr().writeAll("ERROR: all stacked inputs must have the same dimensions.\n");
            exitWithReport(1);
        },
        error.OpenFailed, error.DecodeFailed, error.InvalidImage, error.UnsupportedFormat => {
            try std.fs.File.stderr().writeAll("ERROR: image loading failed.\n");
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
    if (!align_core.profiler.enabled and !align_core.alloc_profiler.enabled) return;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    align_core.profiler.maybeWriteReport(&stderr_writer.interface) catch {};
    align_core.alloc_profiler.maybeWriteReport(&stderr_writer.interface) catch {};
    stderr_writer.interface.flush() catch {};
}

fn fatalWithUsage(allocator: std.mem.Allocator, exe_name: []const u8, message: []const u8) noreturn {
    std.fs.File.stderr().writeAll(message) catch {};
    const usage = core.config.renderUsage(allocator, exe_name) catch exitWithReport(1);
    defer allocator.free(usage);
    std.fs.File.stderr().writeAll("\n") catch {};
    std.fs.File.stderr().writeAll(usage) catch {};
    exitWithReport(1);
}

test {
    _ = @import("root.zig");
}
