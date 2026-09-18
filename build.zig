const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(b.path("src"));
    module.addIncludePath(b.path("vendor/sokol"));
    module.addIncludePath(b.path("vendor/nuklear"));
    module.addCSourceFile(.{
        .file = b.path("src/sokol_impl.c"),
        .flags = if (target.result.os.tag.isDarwin()) &.{"-ObjC"} else &.{},
    });

    switch (target.result.os.tag) {
        .windows => {
            module.linkSystemLibrary("kernel32", .{});
            module.linkSystemLibrary("user32", .{});
            module.linkSystemLibrary("gdi32", .{});
            module.linkSystemLibrary("ole32", .{});
            module.linkSystemLibrary("d3d11", .{});
            module.linkSystemLibrary("dxgi", .{});
        },
        .macos => {
            module.linkFramework("QuartzCore", .{});
            module.linkFramework("Metal", .{});
            module.linkFramework("AppKit", .{});
            module.linkFramework("Foundation", .{});
        },
        .linux => {
            module.linkSystemLibrary("GL", .{});
            module.linkSystemLibrary("X11", .{});
            module.linkSystemLibrary("Xi", .{});
            module.linkSystemLibrary("Xcursor", .{});
            module.linkSystemLibrary("dl", .{});
            module.linkSystemLibrary("m", .{});
        },
        else => @panic("Plataforma no suportada: Windows, macOS o Linux"),
    }

    const exe = b.addExecutable(.{
        .name = "sx3downloader",
        .root_module = module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Executa SX3Downloader");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Executa les proves Zig");
    test_step.dependOn(&run_tests.step);
}
