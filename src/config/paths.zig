//! Where config files live.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dirs = @import("../dirs/root.zig");

/// Applied before the user file.
pub const system = "/etc/rex/config";

/// The user file, `<config dir>/config`. The caller owns the returned path.
pub fn user(gpa: Allocator, app_dirs: *const dirs.Application) Allocator.Error![]u8 {
    return std.fs.path.join(gpa, &.{ app_dirs.config, "config" });
}

/// The user file for `app_name`, with the config directory resolved from
/// `$XDG_CONFIG_HOME` or `$HOME`. The caller owns the returned path.
pub fn userFromEnviron(gpa: Allocator, environ: *const std.process.Environ, app_name: []const u8) ![]u8 {
    const home_dir = try environ.getAlloc(gpa, "HOME");
    defer gpa.free(home_dir);
    var envmap = try environ.createMap(gpa);
    defer envmap.deinit();
    var app_dirs = try dirs.Application.resolve(gpa, app_name, home_dir, &envmap);
    defer app_dirs.deinit(gpa);
    return user(gpa, &app_dirs);
}
