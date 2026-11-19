const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The shared module is imported by tools, tests, and platform adapters.
    const ufs_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core = b.addStaticLibrary(.{
        .name = "ufs_core",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.addIncludePath(b.path("src"));
    b.installArtifact(core);

    const c_api_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_api_module.addImport("ufs", ufs_module);
    const shared = b.addSharedLibrary(.{
        .name = "ufs",
        .root_module = c_api_module,
    });
    shared.addIncludePath(b.path("src"));
    shared.linkLibC();
    b.installArtifact(shared);

    const unit = addTest(b, target, optimize, ufs_module, "src/tests.zig", "test", "Run unit tests");
    const integration = addTest(b, target, .Debug, ufs_module, "src/integration_test.zig", "integration-test", "Run integration tests");
    const reliability = addTest(b, target, .Debug, ufs_module, "src/reliability_test.zig", "test-reliability", "Run reliability tests");
    const tool_tests = addTest(b, target, optimize, ufs_module, "tools/test_tools.zig", "test-tools", "Run tool tests");
    _ = unit;
    _ = integration;
    _ = reliability;
    _ = tool_tests;

    const bench = addExecutable(b, target, optimize, ufs_module, "ufs_bench", "src/bench.zig");
    const fuzz = addExecutable(b, target, .ReleaseFast, ufs_module, "ufs_fuzz", "src/fuzz.zig");
    const mkufs = addExecutable(b, target, optimize, ufs_module, "mkufs", "tools/mkufs/main.zig");
    const ufsck = addExecutable(b, target, optimize, ufs_module, "ufsck", "tools/ufsck/main.zig");
    const ufsinfo = addExecutable(b, target, optimize, ufs_module, "ufsinfo", "tools/ufsinfo/main.zig");
    const ufsctl = addExecutable(b, target, optimize, ufs_module, "ufsctl", "tools/ufsctl/main.zig");
    const fuse_test = addExecutable(b, target, optimize, ufs_module, "ufs_fuse_test", "tools/fuse_test/main.zig");
    const perf_compare = addExecutable(b, target, optimize, ufs_module, "ufs_perf_compare", "tools/perf_compare/main.zig");

    const tools = b.step("tools", "Build and install all UFS command-line tools");
    for ([_]*std.Build.Step.Compile{ bench, fuzz, mkufs, ufsck, ufsinfo, ufsctl, fuse_test, perf_compare }) |artifact| {
        const install_tool = b.addInstallArtifact(artifact, .{});
        tools.dependOn(&install_tool.step);
    }

    _ = addTest(b, target, optimize, ufs_module, "src/fuzz.zig", "fuzz", "Run randomized parser fuzz checks");

    const NamedTool = struct {
        name: []const u8,
        description: []const u8,
        artifact: *std.Build.Step.Compile,
    };
    const named_tools = [_]NamedTool{
        .{ .name = "mkufs", .description = "Build and install mkufs", .artifact = mkufs },
        .{ .name = "ufsck", .description = "Build and install ufsck", .artifact = ufsck },
        .{ .name = "ufsinfo", .description = "Build and install ufsinfo", .artifact = ufsinfo },
        .{ .name = "ufsctl", .description = "Build and install ufsctl", .artifact = ufsctl },
    };
    for (named_tools) |item| {
        const target_step = b.step(item.name, item.description);
        const install_tool = b.addInstallArtifact(item.artifact, .{});
        target_step.dependOn(&install_tool.step);
    }

    const bench_run = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run the UFS benchmark suite");
    bench_step.dependOn(&bench_run.step);

    // FUSE driver is C-only; its entry point is in ufs_fuse.c.
    const fuse = b.addExecutable(.{
        .name = "ufs-fuse",
        .target = target,
        .optimize = optimize,
    });
    fuse.addCSourceFile(.{
        .file = b.path("drivers/fuse/ufs_fuse.c"),
        .flags = &.{ "-Isrc", "-std=c11", "-D_FILE_OFFSET_BITS=64", "-DFUSE_USE_VERSION=35" },
    });
    fuse.addIncludePath(b.path("src"));
    fuse.linkSystemLibrary("fuse3");
    fuse.linkSystemLibrary("pthread");
    fuse.linkLibrary(shared);
    fuse.linkLibC();
    const fuse_step = b.step("fuse", "Build and install the libfuse3 driver");
    const fuse_install = b.addInstallArtifact(fuse, .{});
    const fuse_shared_install = b.addInstallArtifact(shared, .{});
    fuse_step.dependOn(&fuse_install.step);
    fuse_step.dependOn(&fuse_shared_install.step);

    const fuse_test_run = b.addRunArtifact(fuse_test);
    const fuse_test_step = b.step("fuse-test", "Run the UFS userspace FUSE integration tests");
    fuse_test_step.dependOn(&fuse_test_run.step);

    const perf_compare_run = b.addRunArtifact(perf_compare);
    const perf_compare_step = b.step("perf-compare", "Run the UFS performance comparison suite");
    perf_compare_step.dependOn(&perf_compare_run.step);

    const linux = addDriverStub(b, target, optimize, ufs_module, "ufs_linux", "drivers/linux/main.zig");
    const windows = addDriverStub(b, target, optimize, ufs_module, "ufs_windows", "drivers/windows/main.zig");
    const macos = addDriverStub(b, target, optimize, ufs_module, "ufs_macos", "drivers/macos/main.zig");
    const uefi = addDriverStub(b, target, optimize, ufs_module, "ufs_uefi", "drivers/uefi/main.zig");
    const linux_driver_step = b.step("linux-driver", "Build the Linux driver scaffold");
    linux_driver_step.dependOn(&linux.step);
    const windows_driver_step = b.step("windows-driver", "Build the Windows driver scaffold");
    windows_driver_step.dependOn(&windows.step);
    const macos_driver_step = b.step("macos-driver", "Build the macOS driver scaffold");
    macos_driver_step.dependOn(&macos.step);
    const uefi_driver_step = b.step("uefi-driver", "Build the UEFI driver scaffold");
    uefi_driver_step.dependOn(&uefi.step);

    const drivers = b.step("drivers", "Build available driver scaffolding");
    drivers.dependOn(&fuse_install.step);
    drivers.dependOn(&fuse_shared_install.step);
    drivers.dependOn(&linux.step);
    drivers.dependOn(&windows.step);
    drivers.dependOn(&macos.step);
    drivers.dependOn(&uefi.step);
}

fn addTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ufs_module: *std.Build.Module,
    source: []const u8,
    step_name: []const u8,
    description: []const u8,
) *std.Build.Step.Compile {
    const test_step = b.addTest(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
    });
    test_step.root_module.addImport("ufs", ufs_module);
    test_step.root_module.addIncludePath(b.path("src"));
    const step = b.step(step_name, description);
    const run = b.addRunArtifact(test_step);
    step.dependOn(&run.step);
    return test_step;
}

fn addExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ufs_module: *std.Build.Module,
    name: []const u8,
    source: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("ufs", ufs_module);
    exe.root_module.addIncludePath(b.path("src"));
    b.installArtifact(exe);
    return exe;
}

fn addDriverStub(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ufs_module: *std.Build.Module,
    name: []const u8,
    source: []const u8,
) *std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = name,
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addImport("ufs", ufs_module);
    lib.root_module.addIncludePath(b.path("src"));
    return lib;
}
