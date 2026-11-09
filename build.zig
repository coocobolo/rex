const std = @import("std");

pub fn build(b: *std.Build) !void {
    // var query = b.standardTargetOptions(.{}).query;
    // query.cpu_features_sub = std.Target.x86.featureSet(&.{.bmi2});

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    GlfwResolver.add(glfw_lib, glfw_dep, target);

    switch (target.result.os.tag) {
        .linux => {},
        else => @panic("Unsupported GLFW platform"),
    }

    // glad 0.1.36, gl 4.5 compatibility, vendored: the generator only
    // serves its zips from temporary URLs.
    const glad_dir = b.path("vendor/glad");
    const glad_lib = b.addLibrary(.{
        .name = "glad",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    glad_lib.root_module.addCSourceFile(.{ .file = glad_dir.path(b, "src/glad.c") });
    glad_lib.root_module.addIncludePath(glad_dir.path(b, "include"));

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

    // The GLFW C API as `@import("glfw")`. The only GLFW translation in
    // the tree, so the window and input code share one set of types.
    const glfw_c = b.addTranslateC(.{
        .root_source_file = b.path("src/glfw.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    glfw_c.addIncludePath(glfw_dep.path("include"));
    const glfw_mod = glfw_c.createModule();

    // Core library module
    // Only the rex module links native code; the fuzz module must not need it.
    const mod = b.addModule("rex", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
            .{ .name = "glfw", .module = glfw_mod },
        },
    });
    mod.addIncludePath(freetype_dep.path("include"));
    mod.linkLibrary(freetype_lib);
    // FreeType is built with FT_CONFIG_OPTION_USE_ZLIB and
    // FT_CONFIG_OPTION_USE_PNG, so its final consumer links both.
    mod.linkSystemLibrary("z", .{});
    mod.linkSystemLibrary("png", .{});
    mod.addIncludePath(glad_dir.path(b, "include"));
    mod.linkLibrary(glad_lib);
    mod.addIncludePath(glfw_dep.path("include"));
    mod.linkLibrary(glfw_lib);
    mod.linkSystemLibrary("m", .{});

    // Per-stage input latency tracing (src/driver/latency_trace.zig). Off,
    // the hooks compile to nothing.
    const trace_latency = b.option(
        bool,
        "trace-latency",
        "Record per-stage input latency and write it as CSV on exit",
    ) orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "trace_latency", trace_latency);
    mod.addImport("build_options", build_options.createModule());

    if (target.result.os.tag == .linux) {
        // dlopen and pthread_* are part of libc from glibc 2.34 on, so
        // neither libdl nor libpthread is linked; older glibc can't link Rex.
        const min_glibc: std.SemanticVersion = .{ .major = 2, .minor = 34, .patch = 0 };
        if (target.result.isGnuLibC()) {
            const glibc = target.result.os.versionRange().gnuLibCVersion().?;
            if (glibc.order(min_glibc) == .lt) {
                std.debug.panic(
                    "Rex needs glibc {f} or later (dlopen and pthread in libc); the target has {f}",
                    .{ min_glibc, glibc },
                );
            }
        }

        // No X11 library is linked: GLFW loads its X11 libraries at
        // runtime, and so does the bell (renderer/Window.zig, Xlib).
        // Building GLFW's X11 and Wayland backends needs their development
        // headers and wayland-scanner (GLFW loads the libraries itself at
        // runtime); FreeType uses libpng and zlib. On Debian/Ubuntu:
        // sudo apt install libx11-dev libxcursor-dev libxrandr-dev libxinerama-dev libxi-dev libxext-dev \
        //     libwayland-dev libwayland-bin libxkbcommon-dev libpng-dev zlib1g-dev
        // Everything else a contributor needs: CONTRIBUTING.md, "Development setup".
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
        .source_dir = b.path("assets/icons_v2/hicolor"),
        .install_dir = .{ .custom = "share/icons" },
        .install_subdir = "hicolor",
    });

    // Built-in faces land in `<prefix>/share/rex/fonts`, beside `bin/rex`.
    // Google Sans Code and the Noto Sans italics are zig-fetched packages.
    // The hash is the bytes. The check below requires each package's OFL.txt
    // to name the same copyright as its fonts. Noto Color Emoji is
    // the test fixture, installed from testdata so the tests and the prefix
    // share one copy.
    const sans = b.dependency("google_sans_code", .{});
    const noto = b.dependency("noto_sans", .{});
    const font_paths = b.addOptions();
    font_paths.addOption([]const u8, "noto_sans_italic", noto.path("NotoSans/hinted/ttf/NotoSans-Italic.ttf").getPath(b));
    font_paths.addOption([]const u8, "noto_sans_bold_italic", noto.path("NotoSans/hinted/ttf/NotoSans-BoldItalic.ttf").getPath(b));
    mod.addImport("font_paths", font_paths.createModule());
    const font_dir: std.Build.InstallDir = .{ .custom = "share/rex/fonts" };
    const installed = .{
        .{ "variable/GoogleSansCode[wght].ttf", "GoogleSansCode[wght].ttf" },
        .{ "variable/GoogleSansCode-Italic[wght].ttf", "GoogleSansCode-Italic[wght].ttf" },
        .{ "OFL.txt", "OFL-GoogleSansCode.txt" },
    };
    inline for (installed) |item| {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(sans.path(item[0]), font_dir, item[1]).step);
    }
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("testdata/font/NotoColorEmoji.ttf"), font_dir, "NotoColorEmoji.ttf").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("testdata/font/OFL-NotoColorEmoji.txt"), font_dir, "OFL-NotoColorEmoji.txt").step);

    const check_font = b.addExecutable(.{
        .name = "check-font-license",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fonts/check.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const check_run = b.addRunArtifact(check_font);
    check_run.addArg("--");
    check_run.addFileArg(sans.path("OFL.txt"));
    check_run.addFileArg(sans.path("variable/GoogleSansCode[wght].ttf"));
    check_run.addFileArg(sans.path("variable/GoogleSansCode-Italic[wght].ttf"));
    check_run.addArg("--");
    check_run.addFileArg(noto.path("OFL.txt"));
    check_run.addFileArg(noto.path("NotoSans/hinted/ttf/NotoSans-Italic.ttf"));
    check_run.addFileArg(noto.path("NotoSans/hinted/ttf/NotoSans-BoldItalic.ttf"));
    check_run.addArg("--");
    check_run.addFileArg(b.path("testdata/font/OFL-NotoSansMono.txt"));
    check_run.addFileArg(b.path("testdata/font/NotoSansMono-Regular.ttf"));
    check_run.addFileArg(b.path("testdata/font/NotoSansMono-Bold.ttf"));
    check_run.addArg("--");
    check_run.addFileArg(b.path("testdata/font/OFL-NotoColorEmoji.txt"));
    check_run.addFileArg(b.path("testdata/font/NotoColorEmoji.ttf"));
    b.getInstallStep().dependOn(&check_run.step);
    b.step("check-fonts", "Check each font's copyright against its OFL file").dependOn(&check_run.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const strip = b.option(
        bool,
        "strip",
        "Strip debug information from executables",
    ) orelse false;

    // Benchmarks (see bench/main.zig and scripts/README.md):
    //   - One suite per folder in bench/cases/, registered in
    //     bench/cases/root.zig. Adding a suite is a folder, a row there
    //     and a row in `bench_suites` below.
    //   - `zig build bench` runs every suite; `zig build bench-<suite>`
    //     runs one. Benchmark flags go after `--`, e.g.
    //     `zig build bench-term -Doptimize=ReleaseFast -- --filter reflow`.
    //   - Numbers are only meaningful with -Doptimize=ReleaseFast; the
    //     binary warns on Debug. scripts/perf-bench.sh pins a CPU and
    //     records baselines on top of the installed zig-out/bin/benchmark.
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

    const bench_install = b.addInstallArtifact(bench, .{});
    const bench_step = b.step("benchmark", "Build and install the benchmark executable");
    bench_step.dependOn(&bench_install.step);

    const install_bench = b.option(
        bool,
        "install-bench",
        "Install the benchmark executable during default install",
    ) orelse false;
    if (install_bench) {
        b.installArtifact(bench);
    }

    const bench_suites = .{ "vt", "term" };
    const bench_all = b.step("bench", "Run every benchmark suite (flags after --)");
    bench_all.dependOn(benchRun(b, bench, null));
    inline for (bench_suites) |name| {
        const step = b.step("bench-" ++ name, "Run the " ++ name ++ " benchmark suite (flags after --)");
        step.dependOn(benchRun(b, bench, name));
    }

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
    // --fuzz needs LLVM: the self-hosted x86_64 backend emits no
    // coverage instrumentation, so the fuzzer has nothing to steer by.
    const llvm = b.option(
        bool,
        "llvm",
        "Build the tests with LLVM (needed for --fuzz)",
    ) orelse false;
    // kcov finds no source lines in the self-hosted backend's debug
    // info, so -Dcoverage builds with LLVM too.
    const coverage = b.option(
        bool,
        "coverage",
        "Run the tests under kcov; reports in kcov-out/<binary>/",
    ) orelse false;
    const tests: Tests = .{
        .b = b,
        .filters = test_filters,
        .llvm = llvm or coverage,
        .coverage = coverage,
    };

    const test_options = b.addOptions();
    test_options.addOption(bool, "slow", slow_tests);
    const test_options_mod = test_options.createModule();

    // UCD conformance data for tests, as `@import("ucd_test_data")`.
    // The .txt files sit outside src/, so they are copied next to a
    // generated root that embeds them.
    const ucd = "tools/ucd/" ++ comptime std.mem.trim(u8, @embedFile("tools/ucd/VERSION"), " \n") ++ "/";
    const ucd_files = b.addWriteFiles();
    _ = ucd_files.addCopyFile(b.path(ucd ++ "GraphemeBreakTest.txt"), "GraphemeBreakTest.txt");
    const ucd_test_data = b.createModule(.{
        .root_source_file = ucd_files.add("root.zig",
            \\pub const grapheme_break_test = @embedFile("GraphemeBreakTest.txt");
            \\
        ),
    });
    const test_imports: []const std.Build.Module.Import = &.{
        .{ .name = "test_options", .module = test_options_mod },
        .{ .name = "ucd_test_data", .module = ucd_test_data },
    };

    // How tests are organised (see CONTRIBUTING.md, "Tests"):
    //   - Tests live in `<name>_test.zig` next to the code they test.
    //   - Each folder's root.zig lists its test files in a `test {}` block.
    //     Adding a test file is one line there.
    //   - `zig build test` builds src/root.zig, which reaches every folder
    //     root, so each test runs exactly once.
    //   - `zig build test-<suite>` runs one folder alone: a small binary
    //     with no app, renderer or C code, rebuilt in well under a second.
    //     Adding a suite is one row in `suites`.
    //   - Every binary uses tools/test_runner.zig through `Tests`, and
    //     `-Dtest-filter`, `-Dslow`, `-Dllvm` and `-Dcoverage` apply to all.
    const suites = .{
        // name, root
        .{ "term", "src/term_tests.zig" }, // term/root.zig; see file
        .{ "vt", "src/vt/root.zig" },
        .{ "unicode", "src/unicode/root.zig" },
    };
    inline for (suites) |suite| {
        const suite_tests = tests.add("test-" ++ suite[0], b.createModule(.{
            .root_source_file = b.path(suite[1]),
            .target = target,
            .optimize = optimize,
            .imports = test_imports,
        }), test_filters);
        const step = b.step("test-" ++ suite[0], "Run the " ++ suite[0] ++ " tests");
        step.dependOn(tests.run(suite_tests));
    }

    for (test_imports) |import| mod.addImport(import.name, import.module);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(tests.run(tests.add("test-rex", mod, test_filters)));
    test_step.dependOn(tests.run(tests.add("test-exe", exe.root_module, test_filters)));
    // `test` doesn't run the benchmark, but it compiles it, so a change the
    // benchmark cases depend on can't break `perf-bench.sh` unnoticed.
    test_step.dependOn(&bench.step);

    // Fuzzing (see CONTRIBUTING.md, "Fuzzing"):
    //   - One target per file in src/fuzz/, each built on
    //     src/fuzz/harness.zig. Adding one is a row in `fuzz_targets`.
    //   - `zig build fuzz` runs every target's seeds, saved regressions
    //     and seeded mutations (also part of `zig build test`);
    //     `zig build fuzz-<name>` runs one target.
    //   - Add `--fuzz -Dllvm` to fuzz until stopped, or `--fuzz=<runs>`.
    const fuzz_targets = .{ "config", "grapheme", "parser", "strings", "terminal", "utf8", "wcwidth" };
    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("src/fuzz_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = test_imports,
    });
    // No native dependencies: what the targets reach (term, vt, unicode,
    // config) must not need C, GLFW, FreeType or GL, inline tests
    // included. The unfiltered `fuzz` step in `zig build test` enforces it.
    const fuzz_all = b.step("fuzz", "Run every fuzz target (--fuzz -Dllvm to fuzz)");
    fuzz_all.dependOn(tests.run(tests.add("fuzz", fuzz_module, test_filters)));
    inline for (fuzz_targets) |name| {
        const fuzz_one = tests.add("fuzz-" ++ name, fuzz_module, &.{"fuzz " ++ name});
        const step = b.step("fuzz-" ++ name, "Run the " ++ name ++ " fuzz target (--fuzz -Dllvm to fuzz)");
        step.dependOn(tests.run(fuzz_one));
    }

    // Code generation (see CONTRIBUTING.md, "Generated code").
    //
    // Each generator in tools/gen/ is run as `<gen> <out.zig> <inputs>...`,
    // logs what it reads and writes, and its output is copied into src/. Run one with
    // `zig build gen-<name>` or all with `zig build gen`, then commit the
    // result. UCD inputs live in tools/ucd/<version>/, picked by
    // tools/ucd/VERSION. Adding a table is one row here.
    const generators = .{
        // name, output, inputs
        .{ "wcwidth-table", "src/unicode/wcwidth_table.zig", .{ ucd ++ "EastAsianWidth.txt", ucd ++ "UnicodeData.txt", ucd ++ "emoji-data.txt" } },
        .{ "wcwidth-expected", "src/unicode/wcwidth_expected.zig", .{ ucd ++ "DerivedGeneralCategory.txt", ucd ++ "EastAsianWidth.txt", ucd ++ "emoji-data.txt" } },
        .{ "grapheme-table", "src/term/grapheme_table.zig", .{ ucd ++ "GraphemeBreakProperty.txt", ucd ++ "emoji-data.txt" } },
        .{ "x11-colors", "src/color/x11.zig", .{"tools/x11/rgb.txt"} },
    };
    const gen_all = b.step("gen", "Regenerate every generated table");
    inline for (generators) |g| {
        // tools/gen/<name with _>.zig
        const exe_name = comptime blk: {
            var n: [g[0].len]u8 = g[0][0..g[0].len].*;
            std.mem.replaceScalar(u8, &n, '-', '_');
            break :blk n;
        };
        const gen_exe = b.addExecutable(.{
            .name = "gen-" ++ g[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/gen/" ++ exe_name ++ ".zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
            }),
        });
        const run_gen = b.addRunArtifact(gen_exe);
        run_gen.stdio = .inherit; // show the generator's read/write log
        const out = run_gen.addOutputFileArg(std.fs.path.basename(g[1]));
        inline for (g[2]) |input| run_gen.addFileArg(b.path(input));
        const update = b.addUpdateSourceFiles();
        update.addCopyFileToSource(out, g[1]);
        const step = b.step("gen-" ++ g[0], "Regenerate " ++ g[1]);
        step.dependOn(&update.step);
        gen_all.dependOn(&update.step);
    }
}

/// The step that runs the benchmark binary: every suite when `suite` is
/// null, else only that one. Runs from the build root so suites can read
/// their testdata by relative path, and always reruns (timings are the
/// output, not a cacheable artifact).
fn benchRun(b: *std.Build, bench: *std.Build.Step.Compile, comptime suite: ?[]const u8) *std.Build.Step {
    const run = b.addRunArtifact(bench);
    run.setCwd(b.path("."));
    run.stdio = .inherit;
    run.has_side_effects = true;
    if (suite) |name| run.addArg("--suite=" ++ name);
    if (b.args) |args| run.addArgs(args);
    return &run.step;
}

/// How every test binary is built and run, so the suites, the
/// aggregate `test` step and the fuzz steps cannot drift apart.
const Tests = struct {
    b: *std.Build,
    /// -Dtest-filter.
    filters: []const []const u8,
    /// -Dllvm, implied by -Dcoverage.
    llvm: bool,
    /// -Dcoverage.
    coverage: bool,

    /// A test binary named `name` for `root_module` that keeps only the
    /// tests whose name contains one of `filters`.
    fn add(
        t: Tests,
        name: []const u8,
        root_module: *std.Build.Module,
        filters: []const []const u8,
    ) *std.Build.Step.Compile {
        return t.b.addTest(.{
            .name = name,
            .root_module = root_module,
            .filters = filters,
            .use_llvm = if (t.llvm) true else null,
            // Zig 0.16.0's stock runner breaks --fuzz; see tools/test_runner.zig.
            .test_runner = .{ .path = t.b.path("tools/test_runner.zig"), .mode = .server },
        });
    }

    /// The step that runs `compile`: directly, or with -Dcoverage under
    /// kcov (on PATH), writing kcov-out/<name>/index.html for src/.
    fn run(t: Tests, compile: *std.Build.Step.Compile) *std.Build.Step {
        const b = t.b;
        if (!t.coverage) return &b.addRunArtifact(compile).step;
        const kcov = b.addSystemCommand(&.{
            "kcov",
            b.fmt("--include-path={s}", .{b.pathFromRoot("src")}),
            b.pathFromRoot(b.fmt("kcov-out/{s}", .{compile.name})),
        });
        kcov.addArtifactArg(compile);
        kcov.has_side_effects = true; // always rerun so the report is current
        // kcov creates only the last directory of its output path.
        kcov.step.dependOn(&b.addSystemCommand(&.{ "mkdir", "-p", b.pathFromRoot("kcov-out") }).step);
        return &kcov.step;
    }
};

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

/// Sources every GLFW build compiles, whatever the backend
/// (src/CMakeLists.txt, add_library(glfw ...), GLFW 3.5.1).
const glfw_common_srcs = [_][]const u8{
    "src/context.c",
    "src/init.c",
    "src/input.c",
    "src/monitor.c",
    "src/platform.c",
    "src/vulkan.c",
    "src/window.c",
    "src/egl_context.c",
    "src/osmesa_context.c",
    "src/null_init.c",
    "src/null_monitor.c",
    "src/null_window.c",
    "src/null_joystick.c",
};

/// Time, thread and module code shared by every backend on a Unix
/// that isn't macOS, icludiing the null backend.
const glfw_posix_srcs = [_][]const u8{
    "src/posix_module.c",
    "src/posix_time.c",
    "src/posix_thread.c",
};

/// Shared by the X11 and Wayland backends on Linux.
const glfw_linux_srcs = [_][]const u8{
    "src/linux_joystick.c",
    "src/posix_poll.c",
};

const glfw_wayland_protocols = &[_][]const u8{
    "wayland",
    "viewporter",
    "xdg-shell",
    "idle-inhibit-unstable-v1",
    "pointer-constraints-unstable-v1",
    "relative-pointer-unstable-v1",
    "fractional-scale-v1",
    "xdg-activation-v1",
    "xdg-decoration-unstable-v1",
};

const GlfwResolver = struct {
    /// Runs wayland-scanner as GLFW's CMake does and returns one directory
    /// holding the 18 generated headers, under the names GLFW's sources
    /// include (wl_init.c, wl_window.c, wl_monitor.c).
    fn generateWaylandProtocols(b: *std.Build, dep: *std.Build.Dependency) std.Build.LazyPath {
        const out = b.addWriteFiles();
        inline for (glfw_wayland_protocols) |name| {
            const xml = dep.path("deps/wayland/" ++ name ++ ".xml");

            inline for (.{
                .{ "client-header", "-client-protocol.h" },
                .{ "private-code", "-client-protocol-code.h" },
            }) |kind| {
                const scanner = b.addSystemCommand(&.{ "wayland-scanner", kind[0] });
                scanner.addFileArg(xml);
                const file = name ++ kind[1];
                _ = out.addCopyFile(scanner.addOutputFileArg(file), file);
            }
        }

        return out.getDirectory();
    }

    fn add(
        compile: *std.Build.Step.Compile,
        dep: *std.Build.Dependency,
        target: std.Build.ResolvedTarget,
    ) void {
        compile.root_module.addIncludePath(dep.path("src"));
        compile.root_module.addIncludePath(dep.path("include"));

        const root = dep.path("");
        switch (target.result.os.tag) {
            .linux => {
                compile.root_module.addIncludePath(generateWaylandProtocols(compile.step.owner, dep));
                compile.root_module.addCSourceFiles(
                    .{
                        .root = root,
                        .flags = &.{ "-D_GLFW_X11", "-D_GLFW_WAYLAND", "-DHAVE_MEMFD_CREATE" },
                        .files = &[_][]const u8{} ++ glfw_common_srcs ++
                            glfw_posix_srcs ++ glfw_linux_srcs ++
                            &[_][]const u8{
                                // wayland
                                "src/wl_init.c",
                                "src/wl_monitor.c",
                                "src/wl_window.c",
                                // X11
                                "src/x11_init.c",
                                "src/x11_monitor.c",
                                "src/x11_window.c",
                                "src/xkb_unicode.c",
                                "src/glx_context.c",
                            },
                    },
                );
            },

            else => @panic("unsupported GLFW target os"),
        }
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
};
