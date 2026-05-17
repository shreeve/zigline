//! zigline — build configuration.
//!
//! Usage:
//!   zig build                Build the library + examples
//!   zig build test           Run unit tests
//!   zig build test-pty       Run PTY-driven integration tests
//!   zig build run-minimal    Build and run the minimal example

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =========================================================================
    // zg — Unicode grapheme + display width data (SPEC §3.6).
    // =========================================================================

    const zg = b.dependency("zg", .{
        .target = target,
        .optimize = optimize,
    });
    const graphemes_mod = zg.module("Graphemes");
    const display_width_mod = zg.module("DisplayWidth");

    // =========================================================================
    // Library module
    // =========================================================================

    const lib_mod = b.addModule("zigline", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.linkSystemLibrary("c", .{});
    lib_mod.addImport("Graphemes", graphemes_mod);
    lib_mod.addImport("DisplayWidth", display_width_mod);

    // =========================================================================
    // Examples
    // =========================================================================

    addExample(b, target, optimize, lib_mod, "minimal");
    addExample(b, target, optimize, lib_mod, "with_history");
    addExample(b, target, optimize, lib_mod, "with_completion");
    addExample(b, target, optimize, lib_mod, "with_completion_menu");
    addExample(b, target, optimize, lib_mod, "with_highlight");
    addExample(b, target, optimize, lib_mod, "with_custom_action");
    addExample(b, target, optimize, lib_mod, "with_hint");
    addExample(b, target, optimize, lib_mod, "with_history_search");
    addExample(b, target, optimize, lib_mod, "with_print_above");

    // =========================================================================
    // Unit tests (per-module test blocks under src/)
    // =========================================================================

    const test_step = b.step("test", "Run unit + PTY tests");

    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_mod.linkSystemLibrary("c", .{});
    unit_mod.addImport("Graphemes", graphemes_mod);
    unit_mod.addImport("DisplayWidth", display_width_mod);

    const unit_tests = b.addTest(.{ .root_module = unit_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    const test_unit_step = b.step("test-unit", "Run unit tests only");
    test_unit_step.dependOn(&run_unit_tests.step);

    // =========================================================================
    // PTY-driven integration tests
    // =========================================================================

    const pty_mod = b.createModule(.{
        .root_source_file = b.path("tests/pty_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    pty_mod.linkSystemLibrary("c", .{});
    pty_mod.addImport("zigline", lib_mod);

    const pty_tests = b.addTest(.{ .root_module = pty_mod });
    const run_pty_tests = b.addRunArtifact(pty_tests);
    // PTY tests exec the built `minimal` example, so the install step
    // (which produces `zig-out/bin/minimal`) has to run first.
    run_pty_tests.step.dependOn(b.getInstallStep());

    const test_pty_step = b.step("test-pty", "Run PTY-driven REPL tests");
    test_pty_step.dependOn(&run_pty_tests.step);

    test_step.dependOn(&run_pty_tests.step);
}

fn addExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    comptime name: []const u8,
) void {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("examples/" ++ name ++ ".zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.linkSystemLibrary("c", .{});
    exe_mod.addImport("zigline", lib_mod);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = exe_mod,
    });

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run-" ++ name, "Build and run the " ++ name ++ " example");
    run_step.dependOn(&run_cmd.step);
}
