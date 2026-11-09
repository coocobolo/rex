const std = @import("std");
const rex = @import("rex");

pub const std_options: std.Options = .{
    .log_level = .debug,
};

/// The built-in defaults; config files apply on top of them.
const config = rex.config.default;

/// Terminal limits for the screen types, which App reads at compile
/// time. Set them in config.terminal.
pub const rex_terminal_option = config.terminal;

pub fn main(init: std.process.Init) !void {
    // Short-lived work that runs once (argument handling, the config
    // subcommands) uses the process arena. The app itself allocates and
    // frees for as long as it runs, so it gets the general purpose
    // allocator: with the arena, its frees would never return memory.
    const arena = init.arena.allocator();
    const environ = init.minimal.environ;

    var args = init.minimal.args.iterate();
    const argv0 = args.next() orelse "rex";

    var custom_config_path: ?[]const u8 = null;
    var subcmd: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            subcmd = "help";
            break;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            custom_config_path = args.next() orelse {
                printStderr("Error: --config requires a file path argument\n");
                std.process.exit(1);
            };
        } else {
            subcmd = arg;
            break;
        }
    }

    if (subcmd) |sc| {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
        const out = &stdout_writer.interface;
        runCommand(init, arena, &environ, &args, sc, custom_config_path, out) catch |err| switch (err) {
            // stdout closed early, e.g. `rex config defaults | head`: the
            // reader has what it wanted, so this isn't a failure.
            error.WriteFailed => if (isBrokenPipe(stdout_writer.err)) return else return err,
            else => return err,
        };
        out.flush() catch |err| if (!isBrokenPipe(stdout_writer.err)) return err;
        return;
    }

    var app: rex.App = try .init(init.gpa, init.io, &environ, argv0, &config, custom_config_path);
    defer app.deinit(init.gpa);

    try app.run();
}

fn runCommand(
    init: std.process.Init,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ,
    args: *std.process.Args.Iterator,
    sc: []const u8,
    custom_config_path: ?[]const u8,
    out: *std.Io.Writer,
) !void {
    if (std.mem.eql(u8, sc, "help")) {
        try out.writeAll(help);
    } else if (std.mem.eql(u8, sc, "wellbeing")) {
        const home_dir = try environ.getAlloc(arena, "HOME");
        defer arena.free(home_dir);
        var envmap = try environ.createMap(arena);
        defer envmap.deinit();
        var dirs = try rex.dirs.Application.resolve(
            arena,
            rex_terminal_option.name,
            home_dir,
            &envmap,
        );
        defer dirs.deinit(arena);

        var wb = rex.builtin.wellbeing.Wellbeing.init(config.wellbeing);

        if (args.next()) |action| {
            if (std.mem.eql(u8, action, "clear")) {
                const now_s: i64 = @intCast(std.Io.Clock.Timestamp.now(init.io, .real).raw.toSeconds());
                wb.purgeHistory(init.io, dirs.state, now_s) catch |err| {
                    std.log.err("cannot delete wellbeing state in {s}: {t}", .{ wb.stateDir(dirs.state), err });
                    return err;
                };
                try out.writeAll("Wellbeing history purged.\n");
                return;
            }
        }

        wb.loadState(init.io, dirs.state) catch |err| {
            std.log.err("cannot read wellbeing state in {s}: {t}", .{ wb.stateDir(dirs.state), err });
            return err;
        };

        var buf: [2048]u8 = undefined;
        const card = wb.renderDashboard(&buf);
        try out.writeAll(card);
        return;
    } else if (std.mem.eql(u8, sc, "config")) {
        const action = args.next() orelse "locate";
        if (std.mem.eql(u8, action, "locate")) {
            try configLocate(init.io, arena, environ, out);
        } else if (std.mem.eql(u8, action, "defaults")) {
            try out.writeAll(rex.config.default_text);
        } else if (std.mem.eql(u8, action, "validate")) {
            try configValidate(init.io, arena, environ, args.next() orelse custom_config_path, out);
        } else {
            printStderr("Unknown config command. Available: locate, defaults, validate\n");
            std.process.exit(1);
        }
    } else {
        printStderr("Unknown command. See rex --help\n");
        std.process.exit(1);
    }
}

fn isBrokenPipe(err: ?std.Io.File.Writer.Error) bool {
    const e = err orelse return false;
    return e == error.BrokenPipe;
}

fn printStderr(msg: []const u8) void {
    _ = std.posix.system.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
}

const help =
    \\Rex - a GPU-accelerated terminal emulator
    \\
    \\Usage:
    \\  rex [-c <path>]              Start Rex
    \\  rex wellbeing [clear]        Show the wellbeing dashboard, or clear its history
    \\  rex config locate            Show where the config files are
    \\  rex config defaults          Print every setting with its default
    \\  rex config validate [<path>] Check a config file (default: the user file)
    \\
    \\Options:
    \\  -c, --config <path>          Use this file instead of the user config file
    \\  -h, --help                   Show this help
    \\
    \\Key bindings: see [keybinds] in `rex config defaults`.
    \\
;

fn configLocate(io: std.Io, arena: std.mem.Allocator, environ: *const std.process.Environ, out: *std.Io.Writer) !void {
    const user_path = try rex.config.paths.userFromEnviron(arena, environ, rex_terminal_option.name);
    const system_path = rex.config.paths.system;
    try out.print("System config: {s} [{s}]\n", .{ system_path, if (exists(io, system_path)) "found" else "not found" });
    try out.print("User config:   {s} [{s}]\n", .{ user_path, if (exists(io, user_path)) "found" else "not found" });
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Prints every problem of the file at `explicit_path`, or of the user file,
/// applied on this build's defaults. Exits 1 if it has errors.
fn configValidate(io: std.Io, arena: std.mem.Allocator, environ: *const std.process.Environ, explicit_path: ?[]const u8, out: *std.Io.Writer) !void {
    const path = explicit_path orelse try rex.config.paths.userFromEnviron(arena, environ, rex_terminal_option.name);
    const home: ?[]const u8 = environ.getAlloc(arena, "HOME") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };

    var loaded = try rex.config.Loaded.load(arena, io, &config, home, &.{.file(path)});
    defer loaded.deinit(arena);
    if (!loaded.found()) {
        try out.print("{s}: not found; Rex uses its built-in defaults\n", .{path});
        return;
    }
    try loaded.writeDiagnostics(out, .{ .source_line = true });
    const counts = loaded.counts();
    if (counts.errors > 0) {
        try out.print("{s}: {d} error{s}, {d} warning{s}\n", .{ path, counts.errors, plural(counts.errors), counts.warnings, plural(counts.warnings) });
        try out.flush();
        std.process.exit(1);
    }
    if (counts.warnings > 0) {
        try out.print("{s}: valid with {d} warning{s}\n", .{ path, counts.warnings, plural(counts.warnings) });
    } else {
        try out.print("{s}: valid\n", .{path});
    }
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}
