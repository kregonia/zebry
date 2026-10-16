const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const with_atspi = b.option(bool, "atspi", "Include native accessibility support") orelse true;
    const options = b.addOptions();
    options.addOption(bool, "atspi", with_atspi);

    // ────────────── Executable ──────────────
    const exe = b.addExecutable(.{
        .name = "zebry",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = optimize != .Debug,
        }),
    });

    // AT-SPI2 is called through generated Zig ABI declarations. No project C
    // source or C headers are compiled during a normal build.
    exe.root_module.addOptions("build_options", options);
    if (with_atspi) linkLibraries(exe.root_module);

    b.installArtifact(exe);
    b.installBinFile("scripts/setup-accessibility.py", "zebry-setup-accessibility");

    // ────────────── Run step ──────────────
    const run_step = b.step("run", "Run zebry");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ────────────── Test step ──────────────
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addOptions("build_options", options);
    if (with_atspi) linkLibraries(test_module);
    const exe_tests = b.addTest(.{ .root_module = test_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

fn linkLibraries(module: *std.Build.Module) void {
    module.linkSystemLibrary("atspi-2", .{});
    module.linkSystemLibrary("glib-2.0", .{});
    module.linkSystemLibrary("gobject-2.0", .{});
}
