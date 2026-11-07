//! Builds the active config: a base config with the system file and then
//! the user file applied, each on top of the previous. Startup and reload
//! both go through `load`, so they layer the files the same way.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.config);

const Config = @import("Config.zig");
const types = @import("types.zig");
const merge = @import("merge.zig");
const dirs = @import("../dirs/root.zig");

/// The files to apply, in order. Paths are borrowed for the duration of
/// `load` and kept in the `Layer`s, so they must outlive the result.
pub const Sources = struct {
    system: []const u8 = merge.system_config_path,
    /// Null when no user file applies (no path could be resolved).
    user: ?[]const u8,
};

/// What happened to one config file.
pub const Layer = struct {
    path: []const u8,
    /// The file existed and was read.
    found: bool = false,
    /// Parse problems, plus an error entry when the file couldn't be read.
    diags: types.Diagnostics = .{},
};

pub const Loaded = struct {
    config: Config,
    /// Owns what `config` points to beyond the base config's static data
    /// (font path, merged keymap). Freed by `deinit`, or moved into the
    /// owner of `config`.
    arena: std.heap.ArenaAllocator,
    system: Layer,
    user: ?Layer,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }

    /// Whether any file existed.
    pub fn foundAny(self: *const Loaded) bool {
        return self.system.found or (if (self.user) |u| u.found else false);
    }

    /// Diagnostics of all files together.
    pub fn diagnosticCount(self: *const Loaded) usize {
        return self.system.diags.count + (if (self.user) |u| u.diags.count else 0);
    }

    /// The first error of any file, system file first.
    pub fn firstError(self: *const Loaded) ?*const types.Diagnostic {
        if (firstErrorIn(&self.system.diags)) |d| return d;
        if (self.user) |*u| return firstErrorIn(&u.diags);
        return null;
    }
};

fn firstErrorIn(diags: *const types.Diagnostics) ?*const types.Diagnostic {
    for (diags.items[0..diags.count]) |*d| {
        if (d.severity == .err) return d;
    }
    return null;
}

/// Applies the files in `sources` to a copy of `base`. Files with errors
/// are still applied as far as they parsed; callers decide whether to use
/// the result (`Loaded.firstError`). The caller owns the result and frees
/// it with `deinit` unless it keeps the arena.
pub fn load(gpa: Allocator, base: *const Config, sources: Sources) Allocator.Error!Loaded {
    var loaded: Loaded = .{
        .config = base.*,
        .arena = .init(gpa),
        .system = .{ .path = sources.system },
        .user = if (sources.user) |p| .{ .path = p } else null,
    };
    errdefer loaded.arena.deinit();

    try applyLayer(&loaded.config, &loaded.system, loaded.arena.allocator());
    if (loaded.user) |*user| try applyLayer(&loaded.config, user, loaded.arena.allocator());
    return loaded;
}

fn applyLayer(config: *Config, layer: *Layer, arena: Allocator) Allocator.Error!void {
    var file: types.FileConfig = .{};
    layer.found = merge.loadFile(layer.path, &file, &layer.diags) catch |err| {
        // Reported as an error diagnostic (banner, `rex config validate`);
        // the log line is for runs without a window.
        log.warn("cannot read config file {s}: {s}", .{ layer.path, @errorName(err) });
        layer.diags.err(0, 0, "cannot read {s}: {s}", .{ std.fs.path.basename(layer.path), @errorName(err) });
        return;
    };
    if (layer.found) try merge.applyFileConfig(config, &file, arena);
}

/// The user config file, `<config dir>/config`, for `app_name`, resolved
/// from `$XDG_CONFIG_HOME` or `$HOME`. The caller owns the returned path.
pub fn userPathFromEnviron(gpa: Allocator, environ: *const std.process.Environ, app_name: []const u8) ![]u8 {
    const home_dir = try environ.getAlloc(gpa, "HOME");
    defer gpa.free(home_dir);
    var envmap = try environ.createMap(gpa);
    defer envmap.deinit();
    var app_dirs = try dirs.Application.resolve(gpa, app_name, home_dir, &envmap);
    defer app_dirs.deinit(gpa);
    return merge.resolveUserConfigPath(gpa, &app_dirs);
}
