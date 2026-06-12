const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    {
        const exe = b.addExecutable(.{
            .name = "AudioSwitch",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .win32_manifest = b.path("src/win32/audioswitch.manifest"),
        });
        exe.root_module.addWin32ResourceFile(.{
            .file = b.path("src/win32/audioswitch.rc"),
            // TODO: add include path if/when we use appicon to generate our .ico file
            // .include_paths = &.{ico.dirname()},
        });
        if (target.result.os.tag == .windows) {
            exe.subsystem = .Windows;
            if (b.lazyDependency("win32", .{})) |win32_dep| {
                exe.root_module.addImport("win32", win32_dep.module("win32"));
            }
            exe.root_module.addIncludePath(b.path("src/win32"));
            // exe.root_module.addCMacro("UNICODE", "");
            // exe.root_module.addCMacro("_UNICODE", "");
        }

        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);
        const run = b.addRunArtifact(exe);
        if (b.args) |a| run.addArgs(a);
        b.step("run", "").dependOn(&run.step);
    }

    const test_step = b.step("test", "");

    {
        const exe = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        if (target.result.os.tag == .windows) {
            if (b.lazyDependency("win32", .{})) |win32_dep| {
                exe.root_module.addImport("win32", win32_dep.module("win32"));
            }
            exe.root_module.addIncludePath(b.path("src/win32"));
        }
        const run = b.addRunArtifact(exe);
        test_step.dependOn(&run.step);
    }
}
