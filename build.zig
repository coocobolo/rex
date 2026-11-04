const std = @import("std");

pub fn build(b: *std.Build) !void {
    // var query = b.standardTargetOptions(.{}).query;
    // query.cpu_features_sub = std.Target.x86.featureSet(&.{.bmi2});

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const requested_platform = b.option(
        GlfwResolver.Platform,
        "glfw-platform",
        "windowing backend API",
    ) orelse .x11;

    const glfw_dep = b.dependency("glfw", .{});
    const glfw_lib = b.addLibrary(.{
        .name = "glfw",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    glfw_lib.root_module.addIncludePath(glfw_dep.path("src"));
    glfw_lib.root_module.addIncludePath(glfw_dep.path("include"));

    GlfwResolver.add(glfw_lib, glfw_dep, target, requested_platform);

    switch (target.result.os.tag) {
        .linux => {},
        else => @panic("Unsupported GLFW platform"),
    }

    const glad_dep = b.dependency("glad", .{});
    const glad_lib = b.addLibrary(.{
        .name = "glad",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    glad_lib.root_module.addCSourceFile(.{ .file = glad_dep.path("src/glad.c") });
    glad_lib.root_module.addIncludePath(glad_dep.path("include"));

    // const miniaudio_dep = b.dependency("miniaudio", .{});
    // const miniaudio = b.addLibrary(.{
    //     .name = "miniaudio",
    //     .linkage = .static,
    //     .root_module = b.createModule(.{
    //         .target = target,
    //         .optimize = optimize,
    //         .link_libc = true,
    //     }),
    // });
    // miniaudio.root_module.addCSourceFile(.{
    //     .file = miniaudio_dep.path("miniaudio.c"),
    //     .flags = &.{
    //         // "-DMA_NO_RUNTIME_LINKING", // optional: disable dlopen
    //         "-DMA_ENABLE_VORBIS",
    //     },
    // });
    // miniaudio.root_module.addIncludePath(miniaudio_dep.path(""));

    const freetype_dep = b.dependency("freetype", .{});
    const freetype_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "freetype",
        .root_module = b.createModule(.{
            .target = target,
            .link_libc = true, // freetype needs libc (malloc, memcpy, file I/O, etc.)
            .optimize = optimize,
        }),
    });
    freetype_lib.root_module.addCSourceFiles(.{
        .root = freetype_dep.path(""),
        .files = &freetype_base_srcs, // mirrors CMakeLists.txt's BASE_SRCS list (only includes whats needed)
        .flags = &.{
            "-DFT2_BUILD_LIBRARY",
            "-DFT_CONFIG_OPTION_USE_PNG",
            "-DFT_CONFIG_OPTION_USE_ZLIB",
        },
    });
    freetype_lib.root_module.addIncludePath(freetype_dep.path("include"));
    freetype_lib.root_module.addIncludePath(
        freetype_dep.path("src"),
    );

    const termio_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    termio_c.defineCMacro("_FORTIFY_SOURCE", "0");
    termio_c.defineCMacro("_XOPEN_SOURCE", "800");

    const c_mod = termio_c.createModule();

    // Core library module
    const mod = b.addModule("rex", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
        },
    });

    mod.addIncludePath(freetype_dep.path("include"));
    mod.linkLibrary(freetype_lib);

    // FreeType is built with:
    //   FT_CONFIG_OPTION_USE_ZLIB
    //   FT_CONFIG_OPTION_USE_PNG
    // Therefore its final consumer must link these system libraries.
    mod.linkSystemLibrary("z", .{});
    mod.linkSystemLibrary("png", .{});

    // mod.addIncludePath(miniaudio_dep.path(""));
    // mod.linkLibrary(miniaudio);

    mod.addIncludePath(glad_dep.path("include"));
    mod.linkLibrary(glad_lib);

    mod.addIncludePath(glfw_dep.path("include"));
    mod.linkLibrary(glfw_lib);

    // FIXME! this should aligned with glfw option -Dglfw-platform?
    if (target.result.os.tag == .linux) {
        mod.linkSystemLibrary("X11", .{});
        mod.linkSystemLibrary("Xrandr", .{});
        mod.linkSystemLibrary("Xi", .{});
        mod.linkSystemLibrary("Xcursor", .{});
        mod.linkSystemLibrary("Xinerama", .{});
        mod.linkSystemLibrary("GL", .{});
        mod.linkSystemLibrary("EGL", .{});
        mod.linkSystemLibrary("dl", .{});
        mod.linkSystemLibrary("m", .{});
        mod.linkSystemLibrary("pthread", .{});
        mod.linkSystemLibrary("X11", .{});
        // Install the X11 extension development headers on your system, e.g. on Ubuntu/Debian:
        // sudo apt install libxcursor-dev libxrandr-dev libxinerama-dev libxi-dev libx11-dev libxext-dev
    } else {
        @panic("unimplemented glfw extension link library headers");
    }

    // Executable
    const exe = b.addExecutable(.{
        .name = "rex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rex", .module = mod },
            },
            .strip = false, // TODO delete for testing only
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    b.installFile(
        "assets/rex.desktop",
        "share/applications/rex.desktop",
    );

    b.installDirectory(.{
        .source_dir = b.path("assets/icons/hicolor"),
        .install_dir = .{ .custom = "share/icons" },
        .install_subdir = "hicolor",
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const strip = b.option(
        bool,
        "strip",
        "Strip debug information from executables",
    ) orelse false;

    const bench = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .imports = &.{
                .{ .name = "rex", .module = mod },
            },
            .target = target,
            .strip = strip,
            .optimize = optimize,
        }),
    });

    b.installArtifact(bench);

    const bench_step = b.step(
        "bench",
        "Build the benchmark",
    );

    bench_step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests. Optimize follows -Doptimize, which defaults to Debug.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only tests whose name contains this (repeatable)",
    ) orelse b.args orelse &.{};
    const slow_tests = b.option(
        bool,
        "slow",
        "Also run slow exhaustive tests",
    ) orelse false;

    const test_options = b.addOptions();
    test_options.addOption(bool, "slow", slow_tests);
    const test_options_mod = test_options.createModule();

    // How tests are organised (see CONTRIBUTING.md, "Tests"):
    //   - Tests live in `<name>_test.zig` next to the code they test.
    //   - Each folder's root.zig lists its test files in a `test {}` block.
    //     Adding a test file is one line there.
    //   - `zig build test` builds src/root.zig, which reaches every folder
    //     root, so each test runs exactly once.
    //   - `zig build test-<suite>` runs one folder alone: a small binary
    //     with no app, renderer or C code, rebuilt in well under a second.
    //     Adding a suite is one row in `suites`.
    //   - `-Dtest-filter=<substr>` (repeatable) and `-Dslow` apply to all.
    const suites = .{
        // name, root, links libc
        .{ "term", "src/term_tests.zig", false }, // term/root.zig; see file
        .{ "vt", "src/vt/root.zig", false },
        .{ "unicode", "src/unicode/root.zig", true }, // vs libc wcwidth
    };
    inline for (suites) |suite| {
        const suite_tests = b.addTest(.{
            .name = "test-" ++ suite[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(suite[1]),
                .target = target,
                .optimize = optimize,
                .link_libc = suite[2],
                .imports = &.{
                    .{ .name = "test_options", .module = test_options_mod },
                },
            }),
            .filters = test_filters,
        });
        const step = b.step("test-" ++ suite[0], "Run the " ++ suite[0] ++ " tests");
        step.dependOn(&b.addRunArtifact(suite_tests).step);
    }

    mod.addImport("test_options", test_options_mod);
    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters = test_filters,
    });
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // Code generation
    const gen_x11_colors = b.addExecutable(
        .{
            .name = "gen_x11_colors",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/gen_x11_colors.zig"),
                .optimize = optimize,
                .target = target,
            }),
        },
    );

    const run_gen_x11_colors = b.addRunArtifact(gen_x11_colors);
    run_gen_x11_colors.addFileArg(b.path("tools/rgb.txt"));
    const x11_colors_source = run_gen_x11_colors.captureStdOut(.{});

    const update_x11_colors = b.addUpdateSourceFiles();
    update_x11_colors.addCopyFileToSource(x11_colors_source, "src/color/x11.zig");

    {
        const gen_step = b.step("gen-x11-colors", "Regenerate x11 color table from rgb.txt");
        gen_step.dependOn(&update_x11_colors.step);
    }

    // Regenerates src/term/nfc_table.zig from tools/UnicodeData.txt.
    // Run manually after updating UnicodeData.txt, then commit the result.

    const gen_nfc = b.addExecutable(.{
        .name = "gen_nfc_table",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_nfc_table.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });

    const run_gen_nfc = b.addRunArtifact(gen_nfc);
    run_gen_nfc.addFileArg(b.path("tools/UnicodeData.txt"));
    const nfc_source = run_gen_nfc.captureStdOut(.{});

    const update_nfc = b.addUpdateSourceFiles();
    update_nfc.addCopyFileToSource(nfc_source, "src/term/nfc_table.zig");

    {
        const gen_step = b.step("gen-nfc", "Regenerate src/term/nfc_table.zig from UnicodeData.txt");
        gen_step.dependOn(&update_nfc.step);
    }
}

const freetype_base_srcs = [_][]const u8{
    "src/autofit/autofit.c",
    "src/base/ftbase.c",
    "src/base/ftbbox.c",
    "src/base/ftbdf.c",
    "src/base/ftbitmap.c",
    "src/base/ftcid.c",
    "src/base/ftfstype.c",
    "src/base/ftgasp.c",
    "src/base/ftglyph.c",
    "src/base/ftgxval.c",
    "src/base/ftinit.c",
    "src/base/ftmm.c",
    "src/base/ftotval.c",
    "src/base/ftpatent.c",
    "src/base/ftpfr.c",
    "src/base/ftstroke.c",
    "src/base/ftsynth.c",
    "src/base/fttype1.c",
    "src/base/ftwinfnt.c",

    "src/bdf/bdf.c",
    "src/bzip2/ftbzip2.c",
    "src/cache/ftcache.c",
    "src/cff/cff.c",
    "src/cid/type1cid.c",
    "src/gzip/ftgzip.c",
    "src/lzw/ftlzw.c",
    "src/pcf/pcf.c",
    "src/pfr/pfr.c",
    "src/psaux/psaux.c",
    "src/pshinter/pshinter.c",
    "src/psnames/psnames.c",
    "src/raster/raster.c",
    "src/sdf/sdf.c",
    "src/sfnt/sfnt.c",
    "src/smooth/smooth.c",
    "src/svg/svg.c",
    "src/truetype/truetype.c",
    "src/type1/type1.c",
    "src/type42/type42.c",
    "src/winfonts/winfnt.c",

    "src/base/ftdebug.c",
    "src/base/ftsystem.c",
};

const glfw_common_srcs = [_][]const u8{
    "src/context.c",
    "src/init.c",
    "src/input.c",
    "src/monitor.c",
    "src/vulkan.c",
    "src/window.c",
};

const GlfwResolver = struct {
    const Platform = enum {
        win32,
        cocoa,
        wayland,
        x11,
    };

    fn mustValidate(target: std.Build.ResolvedTarget, platform: Platform) void {
        switch (platform) {
            .win32 => if (target.result.os.tag != .windows) @panic("glfw-platform=win32 requires a Windows target"),
            .cocoa => if (target.result.os.tag != .macos) @panic("glfw-platform=cocoa requires a macOS target"),
            .wayland, .x11 => if (target.result.os.tag != .linux) @panic("X11 and Wayland require a Linux target"),
        }
    }

    fn add(
        compile: *std.Build.Step.Compile,
        dep: *std.Build.Dependency,
        target: std.Build.ResolvedTarget,
        platform: Platform,
    ) void {
        mustValidate(target, platform);

        compile.root_module.addIncludePath(dep.path("src"));
        compile.root_module.addIncludePath(dep.path("include"));

        switch (platform) {
            .x11 => addX11(compile.root_module, dep.path("")),
            else => @panic("unsupported GLFW target os"),
        }
    }

    // FIXME need reading more about Zig build equivalent to
    // the generate_wayland_protocol macro in src/CMakeLists.txt
    // runs wayland-scanner twice per protocol XML file to produce
    // two generated C artifacts that GLFW's Wayland backend.
    fn addWayland(module: *std.Build.Module, root: ?std.Build.LazyPath) void {
        module.addCSourceFiles(.{
            .root = root,
            .flags = &.{"-D_GLFW_WAYLAND"},
            .files = &[_][]const u8{} ++ glfw_common_srcs ++ &[_][]const u8{
                "src/egl_context.c",
                "src/osmesa_context.c",
                "src/null_init.c",
                "src/null_monitor.c",
                "src/null_window.c",
                "src/null_joystick.c",
                "src/posix_time.c",
                "src/posix_thread.c",
                "src/posix_module.c",
                "src/wl_init.c",
                "src/wl_monitor.c",
                "src/wl_window.c",
                "src/linux_joystick.c",
                "src/posix_poll.c",
            },
        });
    }

    fn addCocoa(module: *std.Build.Module, root: ?std.Build.LazyPath) void {
        _ = module;
        _ = root;
        @panic("not implemented!");
    }

    fn addWin32(module: *std.Build.Module, root: ?std.Build.LazyPath) void {
        _ = module;
        _ = root;
        @panic("not implemented!");
    }

    fn addX11(module: *std.Build.Module, root: ?std.Build.LazyPath) void {
        module.addCSourceFiles(.{
            .root = root,
            .flags = &.{"-D_GLFW_X11"},
            .files = &[_][]const u8{} ++ glfw_common_srcs ++ &[_][]const u8{
                "src/x11_init.c",
                "src/x11_monitor.c",
                "src/x11_window.c",
                "src/xkb_unicode.c",
                "src/posix_time.c",
                "src/posix_thread.c",
                "src/glx_context.c",
                "src/egl_context.c",
                "src/osmesa_context.c",
                "src/linux_joystick.c",
            },
        });
    }
};
