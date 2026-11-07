const std = @import("std");
const rex = @import("rex");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

pub const std_options: std.Options = .{
    .log_level = .debug,
};
const log = std.log.scoped(.main);

const font_config: rex.FreeType.FontConfig = .{
    .width = 0,
    .height = 20,
    .min_size = 6,
    .max_size = 196,
    .font = .{
        .family = .{
            // .static = .{
            //     .regular = "/home/ozy/.local/share/fonts/JetBrainsMono/JetBrainsMonoNerdFontMono-Regular.ttf",
            //     .bold = "/home/ozy/.local/share/fonts/JetBrainsMono/JetBrainsMonoNerdFontMono-Bold.ttf",
            //     .italic = "/home/ozy/.local/share/fonts/JetBrainsMono/JetBrainsMonoNerdFontMono-Italic.ttf",
            //     .bold_italic = "/home/ozy/.local/share/fonts/JetBrainsMono/JetBrainsMonoNerdFontMono-BoldItalic.ttf",
            // },
            // .static = .{
            //     .regular = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
            //     .bold = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
            //     .italic = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Oblique.ttf",
            //     .bold_italic = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-BoldOblique.ttf",
            // },
            .variable = .{
                .upright = "/home/ozy/.local/share/fonts/GoogleSansCode-VariableFont_MONO,wght.ttf",
                .italic = "/home/ozy/.local/share/fonts/GoogleSansCode-Italic-VariableFont_MONO,wght.ttf",
                .bold_weight = 550,
                .regular_weight = 400,
            },
        },
        // .emoji = .static("/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf"),
        .emoji = .static("/home/ozy/.local/share/fonts/JetBrainsMono/JetBrainsMonoNerdFontMono-Regular.ttf"),
        .fallbacks = &.{
            // General Latin/Greek/Cyrillic and lots of symbols
            .static("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
            // CJK
            .static("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"),
            // Symbols
            .static("/usr/share/fonts/truetype/noto/NotoSansSymbols-Regular.ttf"),
            .static("/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf"),

            // Math
            .static("/usr/share/fonts/truetype/noto/NotoSansMath-Regular.ttf"),
            // Historical / niche scripts
            .static("/usr/share/fonts/truetype/noto/NotoSansRunic-Regular.ttf"),

            .static("/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf"),

            // Scripts
            // .static("/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf"),
            // .static("/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf"),
            // .static("/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf"),
            // .static("/usr/share/fonts/truetype/noto/NotoSansBengali-Regular.ttf"),
            // .static("/usr/share/fonts/truetype/noto/NotoSansTamil-Regular.ttf"),
            // .static("/usr/share/fonts/truetype/noto/NotoSansTelugu-Regular.ttf"),
            // .static("/usr/share/fonts/truetype/noto/NotoSansThai-Regular.ttf"),
        },
    },
};

const prod_wellbeing_option: rex.builtin.wellbeing.Option = .{
    .enabled = true,
    .focus = .{
        .task_ms = 25 * std.time.ms_per_min,
        .short_break_ms = 5 * std.time.ms_per_min,
        .long_break_ms = 15 * std.time.ms_per_min,
        .tasks_before_long_break = 4,
        .timer_mode = .countdown,
        .transition_mode = .manual,
        .mute_notifications_in_task = true,
        .rotate_break_prompts = true,
        .lock_input_on_break = false, // Set to true if you want strict break enforcement
        .show_break_animation = true,
    },
    .screen_time = .{
        .daily_limit_minutes = 480, // 8-hour daily limit
        .grayscale_on_limit = true,
        .grayscale_transition_s = 60, // Smooth 1-minute fade into grayscale
        .idle_threshold_s = 180, // 3-minute idle threshold pauses tracking
        .proc_sample_interval_s = 5,
        .track_foreground_apps = true,
        .lock_input_on_limit = false,
        .show_limit_animation = false,
    },
    .eyesight = .{
        .enabled = true,
        .interval_minutes = 20, // 20-20-20 rule
        .duration_s = 20,
        .lock_input = false,
        .show_animation = true,
        .animation = .pulse_dim,
        .prompt = "Look at an object 20 feet away for 20 seconds.",
    },
    .movement = .{
        .enabled = true,
        .interval_minutes = 50,
        .duration_s = 60,
        .lock_input = false,
        .show_animation = true,
        .animation = .warm_glow,
        .prompt = "Time to stand up, stretch your back, and move.",
    },
    .routines = .{
        .hydration_interval_minutes = 45,
        .hydration_prompt = "Stay hydrated: drink some fresh water.",
        .posture_interval_minutes = 30,
        .posture_prompt = "Check posture: roll shoulders back and align neck.",
        .lock_input = false,
        .show_animation = false,
    },
    .winddown = .{
        .enabled = false,
        .start_hour = 0, // 9:00 PM
        .start_minute = 0,
        .end_hour = 23, // 7:00 AM
        .end_minute = 0,
        .warmth_factor = 0.85,
        .mute_audio_bell = false,
        .prompt = "Wind-down time. Time to wrap up work for today.",
    },
    .privacy = .{
        .strict_local = true,
        .track_foreground_apps = true,
    },
};

const scrollbar_option = rex.renderer.Scrollbar.Option{
    // .auto_hide_alpha = 0.4,
    // .width = 12,
    .auto_hide_alpha = 0,
    .auto_hide = true,
    // .radius = 6.0,
    // .hover_width = 12,
    // .track_color = .{ 15, 16, 1, 1 },
    // .thumb_color = .{ 59, 128, 0, 1 },
    // .thumb_hover_color = .{ 59, 128, 0, 1 },
};

const selection_option = rex.renderer.Selection.Option{
    .border_color = .{ 0.16, 0.16, 0.16, 0.8 },
    .border_style = .unified,
    .border_width = 0.75,
    .fill_color = .{ 0.2, 0.2, 0.2, 0.50 },
    .radius = 4.0,
};

// Every field defaults to the font's own lines, see Decoration.Option.
const decoration_option = rex.renderer.Decoration.Option{};

const background_option = rex.renderer.Background.Option{
    .alpha = 0.98,
};

const cursor_option = rex.renderer.Cursor.Option{
    .alpha = 1.0,
    .hollow_border_width = 3.0,
    .radius = 4.0,
};

const card_option = rex.renderer.Card.Option{
    .corner_radius = 8.0,
    .border_width = 1.0,
    .border_shape = .rounded,
};

const toast_option = rex.ui.Toast.Option{
    .enabled = true,
    .position = .top_right,
    .border_style = .semantic,
    .duration_ms = 5000,
    .min_width = 32,
    .max_width = 48,
    .margin_cols = 2,
    .margin_rows = 1,
};

const banner_option = rex.ui.Banner.Option{
    .enabled = true,
    .style = .floating,
    .position = .top_center,
    .border_style = .semantic,
    .corner_radius = 8.0,
    .border_width = 1.0,
    .min_width = 36,
    .max_width = 72,
    .margin_cols = 2,
    .margin_rows = 1,
};

const icon_option = rex.ui.Icon.Option{
    .style = .unicode,
};

const modal_option = rex.ui.Modal.Option{
    .width = 46,
    .dim_alpha = 10,
    .close_on_outside_click = true,
    .default_focus = .confirm,
    .icon_style = .unicode,
};

pub const BracketPair = struct { open: u21, close: u21 };

/// Terminal limits for the screen types, which App reads at compile
/// time. Set them in config.terminal.
pub const rex_terminal_option = config.terminal;

const config: rex.config.Config = .{
    .blink = .{ .half_period = 500, .rapid_half_period = 250 },
    .font = font_config,
    .keymap = rex.input.default_keymap,
    .termio = .{
        .argv = &.{ "/bin/bash", null },
        .envp = &.{
            // "SHELL=/bin/bash",
            // "TERM=xterm-256color",
            // "LANG=en_GB.UTF-8",
            // "TERMINFO=/usr/share/terminfo",
            // "COLORTERM=truecolor",
            // "HOME=/home/ozy",
            // "XDG_SESSION_DESKTOP=ubuntu",
            // "XDG_RUNTIME_DIR=/run/user/1000",
        },
        .o_flags = .{ .NONBLOCK = true, .ASYNC = false },
        .cwd = "/home/ozy/.project/rex",
    },
    .theme = .graphite,
    .wellbeing = prod_wellbeing_option,
    .window = .{
        .background = background_option,
        .cursor = cursor_option,
        .decoration = decoration_option,
        .scrollbar = scrollbar_option,
        .selection = selection_option,
        .card = card_option,
        .toast = toast_option,
        .banner = banner_option,
        .icon = icon_option,
        .modal = modal_option,
        .confirm_quit = true,
        .bell = .on,
    },
    .environments = &.{
        .{ .key = "SHELL", .value = "/bin/bash" },
        .{ .key = "TERM", .value = "xterm-256color" },
        .{ .key = "LANG", .value = "en_GB.UTF-8" },
        .{ .key = "TERMINFO", .value = "/usr/share/terminfo" },
        .{ .key = "COLORTERM", .value = "truecolor" },
    },
    .threading = .{ .mode = .multi },
    .selection = .{
        .classifier = .{
            .extra_word_chars = &.{ '-', '/', '~', '.', '@' },
        },
    },
};

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        // stdout closed early, e.g. `rex config dump-default | head`:
        // the reader has what it wanted, so this isn't a failure.
        error.BrokenPipe => return,
        else => return err,
    };
}

fn run(init: std.process.Init) !void {
    // Short-lived work that runs once (argument handling, the config
    // subcommands) uses the process arena. The app itself allocates and
    // frees for as long as it runs, so it gets the general purpose
    // allocator: with the arena, its frees would never return memory.
    const allocator = init.arena.allocator();
    const environ = init.minimal.environ;

    var args = init.minimal.args.iterate();
    const argv0 = args.next() orelse "rex";

    var custom_config_path: ?[]const u8 = null;
    var subcmd: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            custom_config_path = args.next() orelse {
                printStderr("Error: --config requires a file path argument\n");
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--dump-default") or std.mem.eql(u8, arg, "dump-default")) {
            try rex.config.dumpDefaultConfig(stdout);
            return;
        } else if (subcmd == null) {
            subcmd = arg;
            break;
        }
    }

    if (subcmd) |sc| {
        if (std.mem.eql(u8, sc, "wellbeing")) {
            const home_dir = try environ.getAlloc(allocator, "HOME");
            defer allocator.free(home_dir);
            var envmap = try environ.createMap(allocator);
            defer envmap.deinit();
            var dirs = try rex.dirs.Application.resolve(
                allocator,
                rex_terminal_option.name,
                home_dir,
                &envmap,
            );
            defer dirs.deinit(allocator);

            var wb = rex.builtin.wellbeing.Wellbeing.init(prod_wellbeing_option);
            wb.loadState(init.io, dirs.state);

            if (args.next()) |action| {
                if (std.mem.eql(u8, action, "clear")) {
                    try wb.purgeHistory(init.io, dirs.state);
                    printStdout("Wellbeing history purged.\n");
                    return;
                }
            }

            var buf: [2048]u8 = undefined;
            const card = wb.renderDashboard(&buf);
            printStdout(card);
            return;
        } else if (std.mem.eql(u8, sc, "config")) {
            const config_action = args.next() orelse "locate";
            if (std.mem.eql(u8, config_action, "locate")) {
                try handleConfigLocate(allocator, &environ);
                return;
            } else if (std.mem.eql(u8, config_action, "dump-default")) {
                try rex.config.dumpDefaultConfig(stdout);
                return;
            } else if (std.mem.eql(u8, config_action, "validate") or std.mem.eql(u8, config_action, "check")) {
                const target_path = args.next() orelse custom_config_path;
                try handleConfigValidate(allocator, &environ, target_path);
                return;
            } else if (std.mem.eql(u8, config_action, "merge")) {
                try handleConfigMerge(&args);
                return;
            } else if (std.mem.eql(u8, config_action, "migrate")) {
                try handleConfigMigrate(allocator, &environ, &args, custom_config_path);
                return;
            } else {
                printStderr("Unknown config command. Available: locate, dump-default, validate, merge, migrate\n");
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, sc, "merge-config")) {
            try handleConfigMerge(&args);
            return;
        } else if (std.mem.eql(u8, sc, "migrate-config")) {
            try handleConfigMigrate(allocator, &environ, &args, custom_config_path);
            return;
        } else if (std.mem.eql(u8, sc, "check-config")) {
            const target_path = args.next() orelse custom_config_path;
            try handleConfigValidate(allocator, &environ, target_path);
            return;
        } else if (std.mem.eql(u8, sc, "dump-default") or std.mem.eql(u8, sc, "--dump-default")) {
            try rex.config.dumpDefaultConfig(stdout);
            return;
        }
    }

    var app: rex.App = try .init(init.gpa, init.io, &environ, argv0, &config, custom_config_path);
    defer app.deinit(init.gpa);

    try app.run();
}

/// Output of the CLI commands.
const stdout: rex.config.FdWriter = .{ .fd = std.posix.STDOUT_FILENO };

fn printStdout(msg: []const u8) void {
    stdout.writeAll(msg) catch {};
}

fn printStderr(msg: []const u8) void {
    _ = std.posix.system.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
}

fn fileExists(path: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const fd = std.posix.openat(std.posix.AT.FDCWD, path_buf[0..path.len :0], .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return false;
    _ = std.posix.system.close(fd);
    return true;
}

fn printHelp() void {
    printStdout(
        \\Rex - High-Performance GPU-Accelerated Terminal Emulator
        \\
        \\Usage:
        \\  rex [options]
        \\  rex wellbeing [clear]
        \\  rex config locate
        \\  rex config dump-default
        \\  rex config validate [<path>]
        \\  rex config merge <base_file> <override_file> [-o <out_path>]
        \\  rex config migrate [<source_config>] [-o <out_path>] [-i|--in-place]
        \\  rex check-config [<path>]
        \\  rex merge-config <base_file> <override_file> [-o <out_path>]
        \\  rex migrate-config [<source_config>] [-o <out_path>] [-i|--in-place]
        \\
        \\Options:
        \\  -c, --config <path>    Load configuration from custom path
        \\  --dump-default         Print default configuration template to stdout and exit
        \\  -h, --help             Display this help message and exit
        \\
        \\Hotkeys:
        \\  Ctrl+Shift+R           Live reload configuration without dropping terminal session
        \\  Ctrl+Shift+W           Toggle Digital Wellbeing overlay dashboard
        \\  Ctrl+Shift+D           Dismiss active wellbeing alert
        \\  Ctrl+Shift+P           Toggle focus timer
        \\
    );
}

fn handleConfigLocate(allocator: std.mem.Allocator, environ: *const std.process.Environ) !void {
    const user_path = try rex.config.userPathFromEnviron(allocator, environ, rex_terminal_option.name);
    defer allocator.free(user_path);

    try stdout.print("System config: {s} [{s}]\n", .{
        rex.config.system_config_path,
        if (fileExists(rex.config.system_config_path)) "found" else "not found",
    });
    try stdout.print("User config:   {s} [{s}]\n", .{
        user_path,
        if (fileExists(user_path)) "found" else "not found",
    });
}

fn handleConfigValidate(allocator: std.mem.Allocator, environ: *const std.process.Environ, explicit_path: ?[]const u8) !void {
    const resolved_path = if (explicit_path) |p|
        try allocator.dupe(u8, p)
    else
        try rex.config.userPathFromEnviron(allocator, environ, rex_terminal_option.name);
    defer allocator.free(resolved_path);

    if (!fileExists(resolved_path)) {
        try stdout.print("Configuration file not found: {s}\n(system will use built-in defaults)\n", .{resolved_path});
        return;
    }

    var file_cfg = rex.config.FileConfig{};
    var diags = rex.config.Diagnostics{};

    const loaded = rex.config.loadFile(resolved_path, &file_cfg, &diags) catch |err| {
        try stdout.print("Failed to read configuration file: {}\n", .{err});
        std.process.exit(1);
    };

    if (!loaded) {
        try stdout.print("Configuration file not found: {s}\n", .{resolved_path});
        return;
    }

    if (diags.hasErrors()) {
        try stdout.print("Validation failed for {s}:\n", .{resolved_path});
        for (diags.items[0..diags.count]) |*diag| {
            const prefix = if (diag.severity == .err) "ERROR" else "WARN";
            try stdout.print("  [{s}] line {d}:{d}: {s}\n", .{ prefix, diag.line, diag.col, diag.message() });
        }
        std.process.exit(1);
    } else if (diags.count > 0) {
        try stdout.print("Configuration valid with warnings for {s}:\n", .{resolved_path});
        for (diags.items[0..diags.count]) |*diag| {
            try stdout.print("  [WARN] line {d}:{d}: {s}\n", .{ diag.line, diag.col, diag.message() });
        }
    } else {
        try stdout.print("✓ Configuration is valid: {s}\n", .{resolved_path});
    }
}

fn handleConfigMerge(args: anytype) !void {
    const base_path = args.next() orelse {
        printStderr("Error: config merge requires <base_file> and <override_file>\nUsage: rex config merge <base_file> <override_file> [-o <out_path>]\n");
        std.process.exit(1);
    };
    const override_path = args.next() orelse {
        printStderr("Error: config merge requires <base_file> and <override_file>\nUsage: rex config merge <base_file> <override_file> [-o <out_path>]\n");
        std.process.exit(1);
    };

    var out_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out_path = args.next() orelse {
                printStderr("Error: -o/--output requires a file path\n");
                std.process.exit(1);
            };
        } else {
            printStderr("Error: unrecognized argument for config merge: ");
            printStderr(arg);
            printStderr("\n");
            std.process.exit(1);
        }
    }

    var diags = rex.config.Diagnostics{};
    const ok = rex.config.mergeFiles(base_path, override_path, out_path, stdout, &diags) catch |err| {
        if (err == error.BrokenPipe) return err;
        printStderr("Error: failed to merge configurations: ");
        var err_buf: [64]u8 = undefined;
        const err_str = std.fmt.bufPrint(&err_buf, "{}\n", .{err}) catch "unknown error\n";
        printStderr(err_str);
        std.process.exit(1);
    };

    if (!ok) {
        printStderr("Error: could not read configuration files\n");
        std.process.exit(1);
    }
}

fn handleConfigMigrate(allocator: std.mem.Allocator, environ: *const std.process.Environ, args: anytype, custom_config_path: ?[]const u8) !void {
    var src_path: ?[]const u8 = custom_config_path;
    var out_path: ?[]const u8 = null;
    var in_place: bool = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--in-place")) {
            in_place = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            out_path = args.next() orelse {
                printStderr("Error: -o/--output requires a file path\n");
                std.process.exit(1);
            };
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            src_path = arg;
        } else {
            printStderr("Error: unrecognized argument for config migrate: ");
            printStderr(arg);
            printStderr("\n");
            std.process.exit(1);
        }
    }

    if (in_place and out_path != null) {
        printStderr("Error: cannot combine --in-place (-i) and --output (-o)\n");
        std.process.exit(1);
    }

    const path = if (src_path) |p|
        try allocator.dupe(u8, p)
    else
        try rex.config.userPathFromEnviron(allocator, environ, rex_terminal_option.name);
    defer allocator.free(path);

    var diags = rex.config.Diagnostics{};
    const ok = rex.config.migrateConfigFile(path, out_path, in_place, stdout, &diags) catch |err| {
        if (err == error.BrokenPipe) return err;
        printStderr("Error: configuration migration failed: ");
        var err_buf: [64]u8 = undefined;
        const err_str = std.fmt.bufPrint(&err_buf, "{}\n", .{err}) catch "unknown error\n";
        printStderr(err_str);
        std.process.exit(1);
    };

    if (!ok) {
        printStderr("Error: configuration file not found: ");
        printStderr(path);
        printStderr("\n");
        std.process.exit(1);
    }
}
