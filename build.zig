const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build-time options (project root for in-app frame classification).
    const sentry_build_opts = b.addOptions();
    sentry_build_opts.addOption([]const u8, "sentry_project_root", b.pathFromRoot("."));

    // Shared wall-clock helpers (Zig 0.16 moved clocks into std.Io).
    const time_compat = b.createModule(.{
        .root_source_file = b.path("src/utils/time_compat.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Internal types module (shared by library root).
    const types = b.createModule(.{
        .root_source_file = b.path("src/Types.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "time_compat", .module = time_compat },
        },
    });

    // Primary contract: module `sentry_zig` for `b.dependency` + `addImport`.
    const mod = b.addModule("sentry_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "types", .module = types },
            .{ .name = "time_compat", .module = time_compat },
        },
    });
    mod.addOptions("sentry_build", sentry_build_opts);

    // types.utils points at the library root (stack_trace helpers).
    types.addImport("utils", mod);

    // Optional static library for non-module consumers.
    const lib = b.addLibrary(.{
        .name = "sentry_zig",
        .root_module = mod,
        .linkage = .static,
    });
    const install_lib = b.addInstallArtifact(lib, .{});
    const lib_step = b.step("lib", "Install static library artifact");
    lib_step.dependOn(&install_lib.step);
    b.getInstallStep().dependOn(&install_lib.step);

    // Examples
    addExample(b, target, optimize, mod, "panic_handler", "Panic handler example");
    addExample(b, target, optimize, mod, "capture_message", "Run the captureMessage demo");
    addExample(b, target, optimize, mod, "capture_error", "Run the captureError demo");

    const lib_unit_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

fn addExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sentry_mod: *std.Build.Module,
    name: []const u8,
    description: []const u8,
) void {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sentry_zig", .module = sentry_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = exe_mod,
    });

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const step = b.step(name, description);
    step.dependOn(&run_cmd.step);
}
