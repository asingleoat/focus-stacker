const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const function_timing = b.option(bool, "function-timing", "Enable comptime-gated function timing instrumentation") orelse false;
    const allocation_profiling = b.option(bool, "allocation-profiling", "Enable comptime-gated allocation churn profiling") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "function_timing", function_timing);
    build_options.addOption(bool, "allocation_profiling", allocation_profiling);
    const smooth_numbers = b.addModule("smooth_numbers", .{
        .root_source_file = b.path("vendor/smooth-numbers/src/largest_n_smooth.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core = b.addModule("align_stack_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.addOptions("build_options", build_options);
    core.addImport("smooth_numbers", smooth_numbers);
    configureImageDeps(core);
    configureFftDeps(b, core);

    const fuse_core = b.addModule("focus_fuse_core", .{
        .root_source_file = b.path("src/fuse/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuse_core.addOptions("build_options", build_options);
    fuse_core.addImport("align_stack_core", core);
    configureImageDeps(fuse_core);

    const exe = b.addExecutable(.{
        .name = "align_image_stack_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addImport("smooth_numbers", smooth_numbers);
    configureImageDeps(exe.root_module);
    configureFftDeps(b, exe.root_module);

    b.installArtifact(exe);

    const fuse_exe = b.addExecutable(.{
        .name = "focus_fuse_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuse/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fuse_exe.root_module.addOptions("build_options", build_options);
    fuse_exe.root_module.addImport("align_stack_core", core);
    configureImageDeps(fuse_exe.root_module);

    b.installArtifact(fuse_exe);

    const stack_exe = b.addExecutable(.{
        .name = "focus_stack_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stack/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "align_stack_core", .module = core },
                .{ .name = "focus_fuse_core", .module = fuse_core },
            },
        }),
    });
    stack_exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(stack_exe);

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
    parity_probe.root_module.addOptions("build_options", build_options);
    parity_probe.root_module.addImport("smooth_numbers", smooth_numbers);
    configureImageDeps(parity_probe.root_module);
    configureFftDeps(b, parity_probe.root_module);

    const upstream_probe = b.addExecutable(.{
        .name = "upstream_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/upstream_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    upstream_probe.root_module.addOptions("build_options", build_options);
    configurePano13Deps(b, upstream_probe.root_module);

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
    match_probe.root_module.addOptions("build_options", build_options);
    match_probe.root_module.addImport("smooth_numbers", smooth_numbers);
    configureImageDeps(match_probe.root_module);
    configureFftDeps(b, match_probe.root_module);

    const live_probe = b.addExecutable(.{
        .name = "live_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/live_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    live_probe.root_module.addOptions("build_options", build_options);
    live_probe.root_module.addImport("smooth_numbers", smooth_numbers);
    configureImageDeps(live_probe.root_module);
    configureFftDeps(b, live_probe.root_module);

    const remap_probe = b.addExecutable(.{
        .name = "remap_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/remap_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    remap_probe.root_module.addOptions("build_options", build_options);
    remap_probe.root_module.addImport("smooth_numbers", smooth_numbers);
    configureImageDeps(remap_probe.root_module);
    configureFftDeps(b, remap_probe.root_module);

    const fuse_mask_probe = b.addExecutable(.{
        .name = "fuse_mask_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuse_mask_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "align_stack_core", .module = core },
                .{ .name = "focus_fuse_core", .module = fuse_core },
            },
        }),
    });
    fuse_mask_probe.root_module.addOptions("build_options", build_options);
    configureImageDeps(fuse_mask_probe.root_module);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Zig align_image_stack port scaffold");
    run_step.dependOn(&run_cmd.step);

    const run_fuse_cmd = b.addRunArtifact(fuse_exe);
    if (b.args) |args| {
        run_fuse_cmd.addArgs(args);
    }
    const run_fuse_step = b.step("run-fuse", "Run the Zig focus-fuse tool");
    run_fuse_step.dependOn(&run_fuse_cmd.step);

    const run_stack_cmd = b.addRunArtifact(stack_exe);
    if (b.args) |args| {
        run_stack_cmd.addArgs(args);
    }
    const run_stack_step = b.step("run-stack", "Run the in-process Zig focus stack tool");
    run_stack_step.dependOn(&run_stack_cmd.step);

    const run_parity_probe = b.addRunArtifact(parity_probe);
    if (b.args) |args| {
        run_parity_probe.addArgs(args);
    }
    const parity_step = b.step("probe-zig", "Run the Zig optimizer parity probe");
    parity_step.dependOn(&run_parity_probe.step);

    const run_upstream_probe = b.addRunArtifact(upstream_probe);
    if (b.args) |args| {
        run_upstream_probe.addArgs(args);
    }
    const upstream_step = b.step("probe-upstream", "Run the upstream pano13 parity probe");
    upstream_step.dependOn(&run_upstream_probe.step);

    const run_match_probe = b.addRunArtifact(match_probe);
    if (b.args) |args| {
        run_match_probe.addArgs(args);
    }
    const match_step = b.step("probe-match", "Run the image matching parity probe");
    match_step.dependOn(&run_match_probe.step);

    const run_live_probe = b.addRunArtifact(live_probe);
    if (b.args) |args| {
        run_live_probe.addArgs(args);
    }
    const live_step = b.step("probe-live", "Run the live pipeline solve comparison probe");
    live_step.dependOn(&run_live_probe.step);

    const run_remap_probe = b.addRunArtifact(remap_probe);
    if (b.args) |args| {
        run_remap_probe.addArgs(args);
    }
    const remap_step = b.step("probe-remap", "Run the remap/output benchmark probe");
    remap_step.dependOn(&run_remap_probe.step);

    const run_fuse_mask_probe = b.addRunArtifact(fuse_mask_probe);
    if (b.args) |args| {
        run_fuse_mask_probe.addArgs(args);
    }
    const fuse_mask_step = b.step("probe-fuse-masks", "Dump normalized focus-fusion masks");
    fuse_mask_step.dependOn(&run_fuse_mask_probe.step);

    const core_tests = b.addTest(.{
        .root_module = core,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const fuse_core_tests = b.addTest(.{
        .root_module = fuse_core,
    });
    const run_fuse_core_tests = b.addRunArtifact(fuse_core_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_fuse_core_tests.step);
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
    module.linkSystemLibrary("pano13", .{
        .use_pkg_config = .no,
        .search_strategy = .paths_first,
    });
    module.addIncludePath(b.path("upstream/libpano13-2.9.23/libpano13-2.9.23"));
}

fn configureFftDeps(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;
    if (b.graph.env_map.get("PFFFT_INCLUDE_DIR")) |pffft_include| {
        module.addIncludePath(.{ .cwd_relative = pffft_include });
    }
    if (b.graph.env_map.get("PFFFT_LIB_DIR")) |pffft_lib| {
        module.addLibraryPath(.{ .cwd_relative = pffft_lib });
    }
    module.linkSystemLibrary("pffft", .{
        .use_pkg_config = .no,
        .search_strategy = .paths_first,
    });

    if (b.graph.env_map.get("VKFFT_INCLUDE_DIR")) |vkfft_include| {
        module.addIncludePath(.{ .cwd_relative = vkfft_include });
    }
}
