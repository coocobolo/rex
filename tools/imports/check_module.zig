//! Fails when a module import or backend path appears outside its backend.
//! The module name, path fragment and exempt files come from build.zig, so
//! this checker is not tied to one platform backend.
//!
//! Usage: check-module <src dir> <backend dir> <module> <path fragment> <allowed file>...

const std = @import("std");
const imports = @import("imports");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const src = args.next() orelse return usage();
    const backend = args.next() orelse return usage();
    const module = args.next() orelse return usage();
    const fragment = args.next() orelse return usage();
    var allowed: std.ArrayList([]const u8) = .empty;
    while (args.next()) |path| try allowed.append(arena, try std.fs.path.resolve(arena, &.{path}));
    if (allowed.items.len == 0) return usage();

    const backend_path = try std.fs.path.resolve(arena, &.{backend});
    var bad: std.ArrayList([]const u8) = .empty;
    try scan(io, arena, src, backend_path, module, fragment, allowed.items, &bad);
    if (bad.items.len == 0) return;
    for (bad.items) |path| std.log.err("{s} imports {s} outside its backend", .{ path, module });
    std.process.exit(1);
}

fn scan(
    io: std.Io,
    arena: std.mem.Allocator,
    dir_path: []const u8,
    backend: []const u8,
    module: []const u8,
    fragment: []const u8,
    allowed: []const []const u8,
    bad: *std.ArrayList([]const u8),
) !void {
    var dir = try std.Io.Dir.openDir(.cwd(), io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        if (entry.kind == .directory) {
            const resolved = try std.fs.path.resolve(arena, &.{child});
            if (std.mem.eql(u8, resolved, backend)) continue;
            try scan(io, arena, child, backend, module, fragment, allowed, bad);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            const resolved = try std.fs.path.resolve(arena, &.{child});
            if (isAllowed(resolved, allowed)) continue;
            const source = try std.Io.Dir.readFileAlloc(.cwd(), io, child, arena, std.Io.Limit.limited(1024 * 1024));
            if (forbidden(source, module, fragment)) try bad.append(arena, resolved);
        }
    }
}

fn isAllowed(path: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| if (std.mem.eql(u8, path, candidate)) return true;
    return false;
}

fn forbidden(source: []const u8, module: []const u8, fragment: []const u8) bool {
    var it: imports.Imports = .{ .source = source };
    while (it.next()) |path| {
        if (std.mem.eql(u8, path, module)) return true;
        if (std.mem.indexOf(u8, path, fragment) != null) return true;
    }
    return false;
}

fn usage() void {
    std.log.err("usage: check-module <src dir> <backend dir> <module> <path fragment> <allowed file>...", .{});
    std.process.exit(2);
}
