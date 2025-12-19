const project_lib_path = "../project/lib";

pub fn build(b: *Build) !void {
    // Options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const godot_version = b.option([]const u8, "godot", "Which version of Godot to generate bindings for [default: `4.5.1`]") orelse "4.5.1";
    const single_threaded = b.option(bool, "threads", "Target single threaded build [default: false]") orelse false;
    const godot_exe = godot.executable(b, b.graph.host, godot_version) orelse return;

    // Module
    const mod = gdzig.createModule(b, .{
        .root_source_file = b.path("src/example.zig"),
        .target = target,
        .optimize = optimize,
        .godot_version = godot_version,
        .godot_exe = godot_exe,
        .single_threaded = single_threaded,
    });

    // Library
    _, const install_step = gdzig.addLibrary(b, .{
        .name = "example",
        .root_module = mod,
        .install_dir = project_lib_path,
    });

    // Install
    b.default_step.dependOn(install_step);

    // Run
    const run = Build.Step.Run.create(b, "run godot");
    run.addFileArg(godot_exe);
    run.addArg("--path");
    run.addDirectoryArg(b.path("./project"));
    run.step.dependOn(install_step);

    const run_step = b.step("run", "Run with Godot");
    run_step.dependOn(&run.step);
}

const std = @import("std");
const Build = std.Build;

const godot = @import("godot");
const gdzig = @import("gdzig");
