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

    const parity_probe = b.addExecutable(.{
        .name = "parity_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parity_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "align_stack_core", .module = core },
            },
        }),
    });
    configureImageDeps(parity_probe.root_module);
    b.installArtifact(parity_probe);

    const upstream_probe = b.addExecutable(.{
        .name = "upstream_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/upstream_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    configurePano13Deps(b, upstream_probe.root_module);
    b.installArtifact(upstream_probe);

    const match_probe = b.addExecutable(.{
        .name = "match_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/match_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "align_stack_core", .module = core },
            },
        }),
    });
    configureImageDeps(match_probe.root_module);
    b.installArtifact(match_probe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Zig align_image_stack port scaffold");
    run_step.dependOn(&run_cmd.step);

    const run_parity_probe = b.addRunArtifact(parity_probe);
    run_parity_probe.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_parity_probe.addArgs(args);
    }
    const parity_step = b.step("probe-zig", "Run the Zig optimizer parity probe");
    parity_step.dependOn(&run_parity_probe.step);

    const run_upstream_probe = b.addRunArtifact(upstream_probe);
    run_upstream_probe.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_upstream_probe.addArgs(args);
    }
    const upstream_step = b.step("probe-upstream", "Run the upstream pano13 parity probe");
    upstream_step.dependOn(&run_upstream_probe.step);

    const run_match_probe = b.addRunArtifact(match_probe);
    run_match_probe.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_match_probe.addArgs(args);
    }
    const match_step = b.step("probe-match", "Run the image matching parity probe");
    match_step.dependOn(&run_match_probe.step);

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

fn configurePano13Deps(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;
    module.linkSystemLibrary("pano13", .{});
    module.addIncludePath(b.path("upstream/libpano13-2.9.23/libpano13-2.9.23"));
    module.addLibraryPath(.{ .cwd_relative = "/nix/store/05gim5y9nzjmvmkqhsxzb510cxz757bi-libpano13-2.9.23/lib" });
}
