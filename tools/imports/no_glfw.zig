//! Fails when Zig source outside the GLFW backend imports the `glfw` module
//! or a backend file by path. The normal import checker follows `.zig` paths
//! but not module imports, so it cannot enforce this boundary on its own.
//!
//! Usage: no_glfw <src directory> <backend directory>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const src = args.next() orelse return usage();
    const backend = args.next() orelse return usage();
    if (args.next() != null) return usage();

    const backend_path = try std.fs.path.resolve(arena, &.{backend});
    var bad = std.ArrayList([]const u8).empty;
    try scan(io, arena, src, backend_path, &bad);
    if (bad.items.len == 0) return;
    for (bad.items) |path| std.log.err("{s} imports GLFW outside the backend", .{path});
    std.process.exit(1);
}

fn scan(io: std.Io, arena: std.mem.Allocator, dir_path: []const u8, backend: []const u8, bad: *std.ArrayList([]const u8)) !void {
    var dir = try std.Io.Dir.openDir(.cwd(), io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, "glfw") and
                std.mem.startsWith(u8, child, backend)) continue;
            try scan(io, arena, child, backend, bad);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            const source = try std.Io.Dir.readFileAlloc(.cwd(), io, child, arena, std.Io.Limit.limited(1024 * 1024));
            // The platform interface owns the backend import; only the rest
            // of the tree must stay clean of it.
            const marker = std.mem.indexOf(u8, child, "platform/");
            const interface = marker != null and
                std.mem.indexOfScalarPos(u8, child, marker.? + "platform/".len, '/') == null;
            if (forbidden(source, interface)) try bad.append(arena, child);
        }
    }
}

fn forbidden(source: []const u8, interface: bool) bool {
    const needle = "@import(\"";
    var rest = source;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        const start = at + needle.len;
        const end = std.mem.indexOfScalarPos(u8, rest, start, '"') orelse return false;
        const path = rest[start..end];
        if (std.mem.eql(u8, path, "glfw")) return true;
        if (std.mem.indexOf(u8, path, "glfw/") != null) {
            // The interface owns the backend import; the test root is only
            // test declarations registered from src/root.zig.
            if (interface or std.mem.eql(u8, path, "platform/glfw/root.zig")) {
                rest = rest[end + 1 ..];
                continue;
            }
            return true;
        }
        rest = rest[end + 1 ..];
    }
    return false;
}

fn usage() void {
    std.log.err("usage: no_glfw <src directory> <backend directory>", .{});
    std.process.exit(2);
}
