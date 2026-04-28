const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("align_stack_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    configureImageDeps(core);

    const exe = b.addExecutable(.{
        .name = "align_image_stack_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "align_stack_core", .module = core },
            },
        }),
    });
    configureImageDeps(exe.root_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Zig align_image_stack port scaffold");
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{
        .root_module = core,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn configureImageDeps(module: *std.Build.Module) void {
    module.link_libc = true;
    module.linkSystemLibrary("jpeg", .{});
    module.linkSystemLibrary("libpng", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("libtiff-4", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("libexif", .{ .use_pkg_config = .force });
}
