const default_version = "4.5";

// Default emscripten verison for web builds. Matches version used by Godot.
const godot_emscripten_version = "4.0.20";

pub fn build(b: *Build) void {
    //
    // Options
    //

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "godot", "Which version of Godot to generate bindings for [default: `" ++ default_version ++ "`]") orelse default_version;
    const precision = b.option([]const u8, "precision", "Floating point precision, either `float` or `double` [default: `float`]") orelse "float";
    const architecture = b.option([]const u8, "arch", "32") orelse "64";

    const fetch_godot = b.option(bool, "fetch-godot", "Download Godot binaries for integration tests") orelse false;

    //
    // Steps
    //

    const build_bindgen_step = b.step("build-bindgen", "Build the gdzig_bindgen executable");
    const run_bindgen_step = b.step("run-bindgen", "Run bindgen to generate builtin/class code");

    const check_step = b.step("check", "Check the build without installing artifacts");
    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    const test_step = b.step("test", "Run unit tests");
    const test_integration_step = b.step("test-integration", "Run integration tests");

    //
    // Dependencies
    //

    const casez = b.dependency("casez", .{});
    const oopz = b.dependency("oopz", .{});

    // Always use latest interface header (defines all function pointers)
    const latest_headers = godot.headers(b, default_version);
    // Use requested version for API (classes/methods available)
    const api_headers = godot.headers(b, version);

    //
    // GDExtension
    //

    const gdextension_translate = b.addTranslateC(.{
        .link_libc = true,
        .optimize = optimize,
        .target = target,
        .root_source_file = latest_headers.path(b, "gdextension_interface.h"),
    });

    const gdextension_mod = b.createModule(.{
        .root_source_file = gdextension_translate.getOutput(),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });

    //
    // Common
    //

    const gdzig_common_mod = b.addModule("common", .{
        .root_source_file = b.path("gdzig_common/gdzig_common.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "casez", .module = casez.module("casez") },
        },
    });

    //
    // Bindings
    //

    const bindgen = generateBindings(b, .{
        .version = version,
        .precision = precision,
        .architecture = architecture,
        .api_headers = api_headers,
        .optimize = optimize,
    });

    const bindgen_install = b.addInstallArtifact(bindgen.exe, .{});

    const bindings_install = b.addInstallDirectory(.{
        .source_dir = bindgen.output,
        .install_dir = .{ .custom = "../" },
        .install_subdir = "gdzig",
    });

    //
    // Library
    //

    const gdzig_files = b.addWriteFiles();
    const gdzig_combined = gdzig_files.addCopyDirectory(b.path("gdzig"), "gdzig", .{
        .exclude_extensions = &.{".mixin.zig"},
    });
    _ = gdzig_files.addCopyDirectory(bindgen.output, "gdzig", .{});

    const gdzig_options = b.addOptions();
    gdzig_options.addOption([]const u8, "architecture", architecture);
    gdzig_options.addOption([]const u8, "precision", precision);

    const gdzig_mod = b.addModule("gdzig", .{
        .root_source_file = gdzig_combined.path(b, "gdzig.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = gdzig_options.createModule() },
            .{ .name = "casez", .module = casez.module("casez") },
            .{ .name = "gdextension", .module = gdextension_mod },
            .{ .name = "common", .module = gdzig_common_mod },
            .{ .name = "oopz", .module = oopz.module("oopz") },
        },
    });
    gdzig_mod.addImport("gdzig", gdzig_mod);

    const gdzig_lib = b.addLibrary(.{
        .name = "gdzig",
        .root_module = gdzig_mod,
        .linkage = .static,
        .use_llvm = true,
    });

    //
    // Tests
    //

    const tests_bindgen = b.addTest(.{ .root_module = bindgen.mod });
    const tests_gdzig = b.addTest(.{ .root_module = gdzig_mod });
    const tests_bindgen_run = b.addRunArtifact(tests_bindgen);
    const tests_gdzig_run = b.addRunArtifact(tests_gdzig);

    if (fetch_godot) {
        if (godot.executable(b, b.graph.host, version)) |godot_exe| {
            const tests = gdzig_test.addTestCases(b, .{
                .root_dir = b.path("tests"),
                .godot_exe = godot_exe,
                .gdzig = gdzig_mod,
                .target = target,
                .optimize = optimize,
            });
            test_integration_step.dependOn(&tests.step);
        }
    }

    //
    // Docs
    //

    const docs_install = b.addInstallDirectory(.{
        .source_dir = gdzig_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    //
    // Step dependencies
    //

    build_bindgen_step.dependOn(&bindgen_install.step);
    run_bindgen_step.dependOn(&bindings_install.step);
    docs_step.dependOn(&docs_install.step);
    check_step.dependOn(&gdzig_lib.step);
    test_step.dependOn(&tests_bindgen_run.step);
    test_step.dependOn(&tests_gdzig_run.step);
    test_step.dependOn(test_integration_step);

    //
    // Default build
    //

    b.default_step.dependOn(&gdzig_lib.step);
    b.installArtifact(bindgen.exe);
    b.installDirectory(.{
        .source_dir = gdzig_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.installDirectory(.{
        .source_dir = latest_headers,
        .install_dir = .prefix,
        .install_subdir = "vendor",
    });
}

pub const CreateGdzigModuleOptions = struct {
    /// This could either be a generated file, in which case the module
    /// contains exactly one file, or it could be a path to the root source
    /// file of directory of files which constitute the module.
    /// If `null`, it means this module is made up of only `link_objects`.
    root_source_file: ?LazyPath = null,

    /// The table of other modules that this module can access via `@import`.
    /// Imports are allowed to be cyclical, so this table can be added to after
    /// the `Module` is created via `addImport`.
    imports: []const Import = &.{},

    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.OptimizeMode = null,

    /// `true` requires a compilation that includes this Module to link libc.
    /// `false` causes a build failure if a compilation that includes this Module would link libc.
    /// `null` neither requires nor prevents libc from being linked.
    link_libc: ?bool = null,
    /// `true` requires a compilation that includes this Module to link libc++.
    /// `false` causes a build failure if a compilation that includes this Module would link libc++.
    /// `null` neither requires nor prevents libc++ from being linked.
    link_libcpp: ?bool = null,
    single_threaded: ?bool = null,
    strip: ?bool = null,
    unwind_tables: ?std.builtin.UnwindTables = null,
    dwarf_format: ?std.dwarf.Format = null,
    code_model: std.builtin.CodeModel = .default,
    stack_protector: ?bool = null,
    stack_check: ?bool = null,
    sanitize_c: ?std.zig.SanitizeC = null,
    sanitize_thread: ?bool = null,
    fuzz: ?bool = null,
    /// Whether to emit machine code that integrates with Valgrind.
    valgrind: ?bool = null,
    /// Position Independent Code
    pic: ?bool = null,
    red_zone: ?bool = null,
    /// Whether to omit the stack frame pointer. Frees up a register and makes it
    /// more difficult to obtain stack traces. Has target-dependent effects.
    omit_frame_pointer: ?bool = null,
    error_tracing: ?bool = null,
    no_builtin: ?bool = null,

    /// Which version of Godot to generate bindings for [default: `4.5.1`]
    godot_version: ?[]const u8 = null,
    /// Path to the `godot` executable. When `null`, it will resolve to `godot_version`.
    godot_exe: ?LazyPath = null,
};

pub fn createModule(b: *Build, options: CreateGdzigModuleOptions) *Module {
    var target: ?std.Build.ResolvedTarget = options.target;

    var pic = options.pic;
    // Set required atomics and bulk_memory features for threaded web target
    if (target) |*t| if (t.result.cpu.arch.isWasm()) {
        pic = true;
        if (!(options.single_threaded orelse true)) {
            t.query.cpu_features_add.addFeature(@intFromEnum(std.Target.wasm.Feature.atomics));
            t.query.cpu_features_add.addFeature(@intFromEnum(std.Target.wasm.Feature.bulk_memory));
        }
    };

    // Dependencies
    const gdzig = b.dependency("gdzig", .{
        .target = target,
        .optimize = options.optimize,
        .godot = options.godot_version,
    });

    // Imports
    var imports = ArrayList(Import).initCapacity(b.allocator, options.imports.len + 1) catch @panic("OOM");
    imports.appendAssumeCapacity(.{
        .name = "gdzig",
        .module = gdzig.module("gdzig"),
    });
    for (options.imports) |import| {
        imports.appendAssumeCapacity(import);
    }

    // Module
    const mod = b.createModule(.{
        .root_source_file = options.root_source_file,
        .imports = imports.toOwnedSlice(b.allocator) catch @panic("OOM"),
        .target = target,
        .optimize = options.optimize,
        .link_libc = options.link_libc,
        .single_threaded = options.single_threaded,
        .strip = options.strip,
        .unwind_tables = options.unwind_tables,
        .dwarf_format = options.dwarf_format,
        .code_model = options.code_model,
        .stack_protector = options.stack_protector,
        .stack_check = options.stack_check,
        .sanitize_c = options.sanitize_c,
        .sanitize_thread = options.sanitize_thread,
        .fuzz = options.fuzz,
        .valgrind = options.valgrind,
        .pic = pic,
        .red_zone = options.red_zone,
        .omit_frame_pointer = options.omit_frame_pointer,
        .error_tracing = options.error_tracing,
        .no_builtin = options.no_builtin,
    });

    return mod;
}

pub const AddGdzigLibraryOptions = struct {
    linkage: std.builtin.LinkMode = .dynamic,
    name: []const u8,
    root_module: *Module,
    install_dir: []const u8,
    version: ?std.SemanticVersion = null,
    max_rss: usize = 0,
    use_llvm: ?bool = true,
    use_lld: ?bool = null,
    zig_lib_dir: ?LazyPath = null,
    /// Embed a `.manifest` file in the compilation if the object format supports it.
    /// https://learn.microsoft.com/en-us/windows/win32/sbscs/manifest-files-reference
    /// Manifest files must have the extension `.manifest`.
    /// Can be set regardless of target. The `.manifest` file will be ignored
    /// if the target object format does not support embedded manifests.
    win32_manifest: ?LazyPath = null,
    emsdk_path: ?LazyPath = null,
    emsdk_version: []const u8 = godot_emscripten_version,
    /// Additional options to pass to emcc for web builds.
    emcc_options: []const []const u8 = &.{},
};

pub fn addLibrary(b: *Build, options: AddGdzigLibraryOptions) struct { *Step.Compile, *Step } {
    const lib = b.addLibrary(.{
        .linkage = options.linkage,
        .name = options.name,
        .root_module = options.root_module,
        .version = options.version,
        .max_rss = options.max_rss,
        .use_llvm = options.use_llvm,
        .use_lld = options.use_lld,
        .zig_lib_dir = options.zig_lib_dir,
        .win32_manifest = options.win32_manifest,
    });

    var install_step: ?*Step = null;

    if (options.root_module.resolved_target) |target| if (target.result.os.tag == .emscripten) {
        const optimize = options.root_module.optimize orelse b.standardOptimizeOption(.{});
        const emsdk_path = if (options.emsdk_path) |p| p else blk: {
            // If no emsdk is provided by user, use gdzig emsdk lazy dependency.
            const gdzig_dep = b.dependency("gdzig", .{});
            const emsdk_dep = gdzig_dep.builder.lazyDependency("emsdk", .{}) orelse std.process.exit(0);
            break :blk emsdk_dep.path("");
        };
        const output_name = b.fmt("lib{s}.wasm", .{lib.name});

        lib.linkage = .static; // build static library to be linked with emcc

        // if (opt.root_module.resolved_target) |target| {
        //     if (target.result.os.tag != .emscripten or target.result.cpu.arch != .wasm32) {
        //         std.log.err("Unsupported target for building emscripten, must be wasm32-emscripten", .{});
        //         b.invalid_user_input = true;
        //         std.process.exit(1);
        //     }
        // } else {
        //     std.log.err("Module has unresolved target", .{});
        //     b.invalid_user_input = true;
        //     std.process.exit(1);
        // }
        // opt.root_module.strip = false;

        const install_emsdk = emsdkInstall(b, emsdk_path, options.emsdk_version);
        const activate_emsdk = emsdkActivate(b, emsdk_path, options.emsdk_version);
        activate_emsdk.step.dependOn(&install_emsdk.step);
        lib.step.dependOn(&activate_emsdk.step);
        lib.addSystemIncludePath(emsdk_path.path(b, "upstream/emscripten/cache/sysroot/include"));

        const run_emcc = runEmcc(b, emsdk_path);
        run_emcc.step.dependOn(&lib.step);

        for (lib.getCompileDependencies(false)) |dep| {
            if (dep.isStaticLibrary()) {
                run_emcc.addArtifactArg(dep);
            }
        }

        run_emcc.addArgs(&.{
            "-sSIDE_MODULE=1",
            "-sWASM_BIGINT",
            "-sSUPPORT_LONGJMP='wasm'",

            // Note: for emscripten <=4.0.13 "-sUSE_OFFSET_CONVERTER" is required for @returnAddress
        });

        run_emcc.addArgs(switch (optimize) {
            .Debug => &.{
                "-O0",
                "-g3", // preserve debug information
                "-fsanitize=undefined", // clang undefined behavior detection
            },
            .ReleaseSafe => &.{
                "-O3",
                "-fsanitize=undefined", // clang undefined behavior detection
                "-fsanitize-minimal-runtime", // use minimal runtime for UBSan
            },
            .ReleaseFast => &.{"-O3"},
            .ReleaseSmall => &.{"-Oz"},
        });

        if (optimize != .Debug) {
            run_emcc.addArgs(&.{
                "-flto", // link time optimization
                // reduce javascript size using closure compiler
                "--closure",
                "1",
            });
        }

        if (!(options.root_module.single_threaded orelse true)) {
            run_emcc.addArg("-sUSE_PTHREADS=1");
        }

        run_emcc.addArgs(options.emcc_options);

        run_emcc.addArg("-o");
        const wasm_lib = run_emcc.addOutputFileArg(output_name);

        install_step = &b.addInstallFileWithDir(
            wasm_lib,
            .{ .custom = options.install_dir },
            output_name,
        ).step;

        install_step.?.dependOn(&run_emcc.step);
    };

    return .{ lib, if (install_step) |s| s else &b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = options.install_dir } } }).step };
}

// pub const EmscriptenOptions = struct {
//     name: []const u8,
//     root_module: *Build.Module,
//     emsdk_path: ?Build.LazyPath = null,
//     threads: bool = false,
//     emsdk_version: []const u8 = godot_emscripten_version,
// };

// /// Helper for building Gdextension for web. Returns path to wasm library.
// pub fn buildWeb(b: *Build, opt: EmscriptenOptions) Build.LazyPath {
//     const emsdk_path = if (opt.emsdk_path) |p| p else blk: {
//         // If no emsdk is provided by user, use gdzig emsdk lazy dependency.
//         const gdzig_dep = b.dependencyFromBuildZig(@This(), .{});
//         const emsdk_dep = gdzig_dep.builder.lazyDependency("emsdk", .{}) orelse std.process.exit(0);
//         break :blk emsdk_dep.path("");
//     };

//     if (opt.root_module.resolved_target) |target| {
//         if (target.result.os.tag != .emscripten or target.result.cpu.arch != .wasm32) {
//             std.log.err("Unsupported target for building emscripten, must be wasm32-emscripten", .{});
//             b.invalid_user_input = true;
//             std.process.exit(1);
//         }
//     } else {
//         std.log.err("Module has unresolved target", .{});
//         b.invalid_user_input = true;
//         std.process.exit(1);
//     }
//     opt.root_module.strip = false;
//     const lib = b.addLibrary(.{
//         .linkage = .static,
//         .name = opt.name,
//         .root_module = opt.root_module,
//     });

//     const install_emsdk = emsdkInstall(b, emsdk_path, opt.emsdk_version);
//     const activate_emsdk = emsdkActivate(b, emsdk_path, opt.emsdk_version);
//     activate_emsdk.step.dependOn(&install_emsdk.step);
//     lib.step.dependOn(&activate_emsdk.step);
//     lib.addSystemIncludePath(emsdk_path.path(b, "upstream/emscripten/cache/sysroot/include"));
// }

fn runEmsdk(b: *Build, emsdk_path: Build.LazyPath) *Build.Step.Run {
    const emsdk_script = if (b.graph.host.result.os.tag == .windows) "emsdk.bat" else "emsdk";
    return b.addSystemCommand(&.{emsdk_path.path(b, emsdk_script).getPath(b)});
}

fn emsdkInstall(b: *Build, emsdk_path: Build.LazyPath, version: []const u8) *Build.Step.Run {
    const run_emsdk_install = runEmsdk(b, emsdk_path);
    run_emsdk_install.addArgs(&.{ "install", version });
    return run_emsdk_install;
}

fn emsdkActivate(b: *Build, emsdk_path: Build.LazyPath, version: []const u8) *Build.Step.Run {
    const run_emsdk_activate = runEmsdk(b, emsdk_path);
    run_emsdk_activate.addArgs(&.{ "activate", version });
    return run_emsdk_activate;
}

fn runEmcc(b: *Build, emsdk_path: Build.LazyPath) *Build.Step.Run {
    return b.addSystemCommand(&.{emsdk_path.path(b, "upstream/emscripten/emcc").getPath(b)});
}

const BindGenOptions = struct {
    version: []const u8 = default_version,
    precision: []const u8 = "float",
    architecture: []const u8 = "64",
    api_headers: Build.LazyPath,
    optimize: ?OptimizeMode = null,
};

const BindGenArtifacts = struct {
    mod: *Build.Module,
    exe: *Build.Step.Compile,
    run: *Build.Step.Run,
    output: LazyPath,
};

// Generate bindings on the host target
fn generateBindings(b: *Build, opt: BindGenOptions) BindGenArtifacts {
    const target = b.graph.host;
    const optimize = opt.optimize orelse b.standardOptimizeOption(.{});

    //
    // Dependencies
    //

    const bbcodez = b.dependency("bbcodez", .{
        .target = target,
        .optimize = optimize,
    });
    const casez = b.dependency("casez", .{
        .target = target,
        .optimize = optimize,
    });
    const temp = b.dependency("temp", .{
        .target = target,
        .optimize = optimize,
    });

    // Always use latest interface header (defines all function pointers)
    const latest_headers = godot.headers(b, default_version);
    // Use requested version for API (classes/methods available)
    const api_headers = godot.headers(b, opt.version);

    //
    // GDExtension
    //

    const gdextension_translate = b.addTranslateC(.{
        .link_libc = true,
        .optimize = optimize,
        .target = target,
        .root_source_file = latest_headers.path(b, "gdextension_interface.h"),
    });

    const gdextension_mod = b.createModule(.{
        .root_source_file = gdextension_translate.getOutput(),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });

    //
    // Common
    //

    const gdzig_common_mod = b.addModule("common", .{
        .root_source_file = b.path("gdzig_common/gdzig_common.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "casez", .module = casez.module("casez") },
        },
    });

    //
    // Bindgen
    //

    const bindgen_options = b.addOptions();
    bindgen_options.addOption([]const u8, "architecture", opt.architecture);
    bindgen_options.addOption([]const u8, "precision", opt.precision);
    bindgen_options.addOptionPath("headers", latest_headers);

    const bindgen_mod = b.addModule("gdzig_bindgen", .{
        .target = b.graph.host,
        .optimize = optimize,
        .root_source_file = b.path("gdzig_bindgen/main.zig"),
        .link_libc = true,
        .imports = &.{
            .{ .name = "bbcodez", .module = bbcodez.module("bbcodez") },
            .{ .name = "build_options", .module = bindgen_options.createModule() },
            .{ .name = "casez", .module = casez.module("casez") },
            .{ .name = "gdextension", .module = gdextension_mod },
            .{ .name = "common", .module = gdzig_common_mod },
            .{ .name = "temp", .module = temp.module("temp") },
        },
    });

    const bindgen_exe = b.addExecutable(.{
        .name = "gdzig-bindgen",
        .root_module = bindgen_mod,
    });

    //
    // Bindings
    //

    const bindings_files = b.addWriteFiles();
    const bindings_mixins = bindings_files.addCopyDirectory(b.path("gdzig"), "input", .{
        .include_extensions = &.{".mixin.zig"},
    });

    const bindings_run = b.addRunArtifact(bindgen_exe);
    bindings_run.expectExitCode(0);
    bindings_run.addFileArg(latest_headers.path(b, "gdextension_interface.h"));
    bindings_run.addFileArg(api_headers.path(b, "extension_api.json"));
    bindings_run.addDirectoryArg(bindings_mixins);

    const bindings_output = bindings_run.addOutputDirectoryArg("bindings");
    bindings_run.addArg(opt.precision);
    bindings_run.addArg(opt.architecture);
    bindings_run.addArg(if (b.verbose) "verbose" else "quiet");

    return .{
        .mod = bindgen_mod,
        .exe = bindgen_exe,
        .run = bindings_run,
        .output = bindings_output,
    };
}

const std = @import("std");
const ArrayList = std.ArrayList;
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Module = Build.Module;
const Import = Module.Import;
const OptimizeMode = std.builtin.OptimizeMode;
const Step = std.Build.Step;
const gdzig_test = @import("gdzig_test/build.zig");

const godot = @import("godot");
