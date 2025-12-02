pub fn build(b: *Build) !void {
    const opt: Options = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .godot_path = b.option([]const u8, "godot", "Path to Godot engine binary [default: `godot`]") orelse "godot",
        .precision = b.option([]const u8, "precision", "Floating point precision, either `float` or `double` [default: `float`]") orelse "float",
        .architecture = b.option([]const u8, "arch", "32") orelse "64",
        .headers = blk: {
            const input = b.option([]const u8, "headers", "Where to source Godot header files. [options: GENERATED, VENDORED, DEPENDENCY, <dir_path>] [default: GENERATED]") orelse "GENERATED";
            const normalized = std.ascii.allocLowerString(b.allocator, input) catch unreachable;
            const tag = std.meta.stringToEnum(Tag(HeadersSource), normalized);
            break :blk if (tag) |t| switch (t) {
                .dependency => .dependency,
                .generated => .generated,
                .vendored => .vendored,
                // edge case if the user uses the literal path "custom"
                .custom => .{ .custom = b.path("custom") },
            } else if (normalized.len == 0)
                .generated
            else
                .{ .custom = b.path(normalized) };
        },
    };

    // Targets
    const bbcodez = buildBbcodez(b);
    const case = buildCase(b);
    const oopz = buildOopz(b);
    const temp = buildTemp(b);

    const headers = installHeaders(b, opt);

    const gdextension = buildGdExtension(b, opt, headers.header);
    const gdzig_bindgen = buildBindgen(b, opt);
    const generated = buildGenerated(b, opt, gdzig_bindgen.exe, headers.root);

    const gdzig = buildGdzig(b, opt, generated.output);
    const docs = buildDocs(b, gdzig.lib);
    const tests = buildTests(b, gdzig.mod, gdzig_bindgen.mod);

    // Dependencies
    gdzig_bindgen.mod.addImport("bbcodez", bbcodez.mod);
    gdzig_bindgen.mod.addImport("case", case.mod);
    gdzig_bindgen.mod.addImport("gdextension", gdextension.mod);
    gdzig_bindgen.mod.addImport("temp", temp.mod);

    gdzig.mod.addImport("gdextension", gdextension.mod);
    gdzig.mod.addImport("oopz", oopz.mod);
    gdzig.mod.addImport("case", case.mod);

    // Steps
    b.step("bindgen", "Build the gdzig_bindgen executable").dependOn(&gdzig_bindgen.install.step);
    b.step("generated", "Run bindgen to generate builtin/class code").dependOn(&generated.install.step);
    b.step("docs", "Install docs into zig-out/docs").dependOn(docs.step);

    const test_ = b.step("test", "Run tests");
    test_.dependOn(&tests.bindgen.step);
    test_.dependOn(&tests.module.step);

    // Install
    b.installArtifact(gdzig_bindgen.exe);
    b.installArtifact(gdzig.lib);
}

const HeadersSource = union(enum) {
    dependency: void,
    vendored: void,
    generated: void,
    custom: Build.LazyPath,
};

const Options = struct {
    target: Target,
    optimize: Optimize,
    godot_path: []const u8,
    precision: []const u8,
    architecture: []const u8,
    headers: HeadersSource,
};

const GdzDependency = struct {
    dep: *Dependency,
    mod: *Module,
};

// Dependency: bbcodez
fn buildBbcodez(
    b: *Build,
) GdzDependency {
    const dep = b.dependency("bbcodez", .{});
    const mod = dep.module("bbcodez");

    return .{ .dep = dep, .mod = mod };
}

// Dependency: case
fn buildCase(
    b: *Build,
) GdzDependency {
    const dep = b.dependency("case", .{});
    const mod = dep.module("case");

    return .{ .dep = dep, .mod = mod };
}

// Dependency: oopz
fn buildOopz(
    b: *Build,
) GdzDependency {
    const dep = b.dependency("oopz", .{});
    const mod = dep.module("oopz");

    return .{ .dep = dep, .mod = mod };
}

// Dependency: temp
fn buildTemp(
    b: *Build,
) GdzDependency {
    const dep = b.dependency("temp", .{});
    const mod = dep.module("temp");

    return .{ .dep = dep, .mod = mod };
}

// GDExtension Headers
fn installHeaders(
    b: *Build,
    opt: Options,
) struct {
    root: Build.LazyPath,
    api: Build.LazyPath,
    header: Build.LazyPath,
} {
    const files = b.addWriteFiles();
    const out = switch (opt.headers) {
        .dependency => b.dependency("godot_cpp", .{}).path("gdextension"),
        .generated => blk: {
            const tmp = b.addWriteFiles();
            const out = tmp.getDirectory();
            const dump = b.addSystemCommand(&.{
                opt.godot_path,
                "--dump-extension-api-with-docs",
                "--dump-gdextension-interface",
                "--headless",
            });
            dump.setCwd(out);
            _ = dump.captureStdOut();
            _ = dump.captureStdErr();
            files.step.dependOn(&dump.step);
            break :blk out;
        },
        .vendored => b.path("vendor"),
        .custom => |root| root,
    };

    return .{
        .root = files.getDirectory(),
        .api = files.addCopyFile(out.path(b, "extension_api.json"), "extension_api.json"),
        .header = files.addCopyFile(out.path(b, "gdextension_interface.h"), "gdextension_interface.h"),
    };
}

// GDExtension
fn buildGdExtension(
    b: *Build,
    opt: Options,
    header: Build.LazyPath,
) struct {
    mod: *Module,
    source: *Step.TranslateC,
} {
    const source = b.addTranslateC(.{
        .link_libc = true,
        .optimize = opt.optimize,
        .target = opt.target,
        .root_source_file = header,
    });

    const mod = b.createModule(.{
        .root_source_file = source.getOutput(),
        .optimize = opt.optimize,
        .target = opt.target,
        .link_libc = true,
    });

    return .{
        .mod = mod,
        .source = source,
    };
}

// Binding Generator
fn buildBindgen(
    b: *Build,
    opt: Options,
) struct {
    install: *Step.InstallArtifact,
    mod: *Module,
    exe: *Step.Compile,
} {
    const mod = b.addModule("gdzig_bindgen", .{
        .target = if (opt.target.result.cpu.arch.isWasm()) b.graph.host else opt.target,
        .optimize = opt.optimize,
        .root_source_file = b.path("gdzig_bindgen/main.zig"),
        .link_libc = true,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "architecture", opt.architecture);
    options.addOption([]const u8, "precision", opt.precision);
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "gdzig-bindgen",
        .root_module = mod,
    });

    const install = b.addInstallArtifact(exe, .{});

    return .{ .install = install, .mod = mod, .exe = exe };
}

// Bindgen
fn buildGenerated(
    b: *Build,
    opt: Options,
    bindgen: *Step.Compile,
    headers: Build.LazyPath,
) struct {
    run: *Step.Run,
    install: *Step.InstallDir,
    output: Build.LazyPath,
} {
    const files = b.addWriteFiles();
    const input = files.addCopyDirectory(b.path("gdzig"), "input", .{
        .include_extensions = &.{".mixin.zig"},
    });

    const run = b.addRunArtifact(bindgen);
    run.expectExitCode(0);

    run.addDirectoryArg(headers);
    run.addDirectoryArg(input);
    const output = run.addOutputDirectoryArg("generated");
    run.addArg(opt.precision);
    run.addArg(opt.architecture);
    run.addArg(if (b.verbose) "verbose" else "quiet");

    const install = b.addInstallDirectory(.{
        .source_dir = output,
        .install_dir = .{ .custom = "../" },
        .install_subdir = "gdzig",
    });

    return .{ .install = install, .run = run, .output = output };
}

// gdzig
fn buildGdzig(
    b: *Build,
    opt: Options,
    generated: Build.LazyPath,
) struct {
    lib: *Step.Compile,
    mod: *Module,
} {
    const files = b.addWriteFiles();
    const combined = files.addCopyDirectory(b.path("gdzig"), "gdzig", .{
        .exclude_extensions = &.{".mixin.zig"},
    });
    _ = files.addCopyDirectory(generated, "gdzig", .{});

    const mod = b.addModule("gdzig", .{
        .root_source_file = combined.path(b, "gdzig.zig"),
        .target = opt.target,
        .optimize = opt.optimize,
    });

    const lib = b.addLibrary(.{
        .name = "gdzig",
        .root_module = mod,
        .linkage = .static,
        .use_llvm = true,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "architecture", opt.architecture);
    options.addOption([]const u8, "precision", opt.precision);
    mod.addOptions("build_options", options);

    return .{ .lib = lib, .mod = mod };
}

// Tests
fn buildTests(
    b: *Build,
    godot_module: *Module,
    bindgen_module: *Module,
) struct {
    bindgen: *Step.Run,
    module: *Step.Run,
} {
    const bindgen_tests = b.addTest(.{
        .root_module = bindgen_module,
    });
    const module_tests = b.addTest(.{
        .root_module = godot_module,
    });

    const bindgen_run = b.addRunArtifact(bindgen_tests);
    const module_run = b.addRunArtifact(module_tests);

    return .{
        .bindgen = bindgen_run,
        .module = module_run,
    };
}

// Docs
fn buildDocs(
    b: *Build,
    lib: *Step.Compile,
) struct {
    step: *Step,
} {
    const install = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    return .{
        .step = &install.step,
    };
}

fn runEmsdk(b: *Build, emsdk_dep: *Dependency) *Build.Step.Run {
    const emsdk_script = if (b.graph.host.result.os.tag == .windows) "emsdk.bat" else "emsdk";
    return b.addSystemCommand(&.{emsdk_dep.path(emsdk_script).getPath(b)});
}

fn emsdkRequiresInstall(b: *Build, emsdk_dep: *Dependency) bool {
    const em = emsdk_dep.path(".emscripten");
    std.fs.accessAbsolute(em.getPath(b), .{}) catch |err| switch (err) {
        .FileNotFound => return true,
        else => false,
    };
}

fn emsdkInstall(b: *Build, emsdk_dep: *Dependency) *Build.Step.Run {
    const run_emsdk_install = runEmsdk(b, emsdk_dep);
    run_emsdk_install.addArgs(&.{ "install", "latest" }); // TODO: option for specific version?
    return run_emsdk_install;
}

fn emsdkActivate(b: *Build, emsdk_dep: *Dependency) *Build.Step.Run {
    const run_emsdk_activate = runEmsdk(b, emsdk_dep);
    run_emsdk_activate.addArgs(&.{ "activate", "latest" }); // // TODO: option for specific version?
    return run_emsdk_activate;
}

fn runEmcc(b: *Build, emsdk_path: Build.LazyPath) *Build.Step.Run {
    return b.addSystemCommand(&.{emsdk_path.path(b, "upstream/emscripten/emcc").getPath(b)});
}

pub const EmscriptenOptions = struct {
    name: []const u8,
    root_module: *Build.Module,
    emsdk: union(enum) {
        path: Build.LazyPath,
        dep: *Build.Dependency,
    },
    threads: bool = false,
};

pub fn buildWeb(b: *Build, opt: EmscriptenOptions) Build.LazyPath {
    const optimize = opt.root_module.optimize orelse b.standardOptimizeOption(.{});
    const emsdk_path = switch (opt.emsdk) {
        .path => |p| p,
        .dep => |d| d.path(""),
    };

    if (opt.root_module.resolved_target) |target| {
        if (target.result.os.tag != .emscripten or target.result.cpu.arch != .wasm32) {
            std.log.err("Unsupported target for building emscripten, must be wasm32-emscripten", .{});
            std.process.exit(1);
        }
    } else {
        std.log.err("Module has unknown target", .{}); // TODO better log
        std.process.exit(1);
    }

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = opt.name,
        .root_module = opt.root_module,
        // .link
    });
    lib.addSystemIncludePath(emsdk_path.join(b.allocator, "upstream/emscripten/cache/sysroot/include") catch @panic("OOM"));

    const run_emcc = runEmcc(b, emsdk_path);
    for (lib.getCompileDependencies(false)) |dep| {
        if (dep.isStaticLibrary()) { // TODO: check if lib vs check if static lib?
            run_emcc.addArtifactArg(dep);
        }
    }

    run_emcc.addArgs(&.{
        "-sSIDE_MODULE=1",
        "-sWASM_BIGINT",
        "-sSUPPORT_LONGJMP='wasm'",

        // Required for @returnAddress
        // Option removed in emscripten 4.0.14
        "-sUSE_OFFSET_CONVERTER",

        // TODO: remove
        // "-sMIN_WEBGL_VERSION=2",
        // "-sFULL_ES3", // Currently required by zigglgen
    });

    run_emcc.addArgs(switch (optimize) {
        .Debug => &.{
            "-O0", // no optimizations
            "-g", // preserve debug information
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

    if (opt.threads) {
        run_emcc.addArg("-sUSE_PTHREADS=1");
    }

    run_emcc.addArg("-o");
    const output = run_emcc.addOutputFileArg(b.fmt("{s}.wasm", .{lib.name}));
    return output;
}

const std = @import("std");
const Build = std.Build;
const Dependency = std.Build.Dependency;
const Module = std.Build.Module;
const Optimize = std.builtin.OptimizeMode;
const Step = std.Build.Step;
const Tag = std.meta.Tag;
const Target = std.Build.ResolvedTarget;
