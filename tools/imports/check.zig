//! Fails when a file reaches a folder it must not depend on through its
//! `@import`s, followed file by file. Used to keep the tool windows' host
//! free of the terminal (ADR 0009 point 8).
//!
//! Usage: check <root.zig> <forbidden folder>...
//!
//! The scan is textual and conservative: every `@import` of a `.zig` path
//! outside a comment counts, including those in `test` blocks, which the
//! compiler would not analyze for the binary. Module imports (`"std"`,
//! `"glfw"`) are not followed.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const root_arg = args.next() orelse return usage();
    var forbidden: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| try forbidden.append(arena, try std.fs.path.resolve(arena, &.{arg}));
    if (forbidden.items.len == 0) return usage();

    const root = try std.fs.path.resolve(arena, &.{root_arg});
    // Each file reached, mapped to the file that imported it first.
    var parents: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    try parents.put(arena, root, null);
    try queue.append(arena, root);

    var reached: usize = 0;
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        const path = queue.items[next];
        if (isInside(path, forbidden.items)) {
            // Reported, and not followed: what it imports is reached
            // through it.
            reportChain(path, &parents);
            reached += 1;
            continue;
        }
        const source = try readFile(io, arena, path);
        const dir = std.fs.path.dirname(path) orelse ".";
        var it: Imports = .{ .source = source };
        while (it.next()) |target| {
            if (!std.mem.endsWith(u8, target, ".zig")) continue;
            const resolved = try std.fs.path.resolve(arena, &.{ dir, target });
            const entry = try parents.getOrPut(arena, resolved);
            if (entry.found_existing) continue;
            entry.value_ptr.* = path;
            try queue.append(arena, resolved);
        }
    }
    if (reached > 0) std.process.exit(1);
}

fn isInside(path: []const u8, dirs: []const []const u8) bool {
    for (dirs) |dir| {
        if (std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == std.fs.path.sep) return true;
    }
    return false;
}

fn usage() void {
    std.log.err("usage: check <root.zig> <forbidden folder>...", .{});
    std.process.exit(2);
}

fn reportChain(path: []const u8, parents: *const std.StringHashMapUnmanaged(?[]const u8)) void {
    std.log.err("{s} is reached by:", .{path});
    var current: ?[]const u8 = parents.get(path).?;
    while (current) |file| : (current = parents.get(file).?) {
        std.log.err("  {s}", .{file});
    }
}

/// The string literals of the `@import`s in `source` that are not in a
/// line comment.
const Imports = struct {
    source: []const u8,
    index: usize = 0,

    const needle = "@import(\"";

    fn next(self: *Imports) ?[]const u8 {
        while (std.mem.indexOfPos(u8, self.source, self.index, needle)) |at| {
            const start = at + needle.len;
            const end = std.mem.indexOfScalarPos(u8, self.source, start, '"') orelse return null;
            self.index = end + 1;
            const line_start = if (std.mem.lastIndexOfScalar(u8, self.source[0..at], '\n')) |nl| nl + 1 else 0;
            if (std.mem.indexOf(u8, self.source[line_start..at], "//") != null) continue;
            return self.source[start..end];
        }
        return null;
    }
};

fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
    defer file.close(io);
    const len = try file.length(io);
    const buf = try gpa.alloc(u8, len);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n != len) return error.ShortRead;
    return buf;
}

test Imports {
    var it: Imports = .{ .source =
        \\const a = @import("a.zig");
        \\// const b = @import("b.zig");
        \\const std = @import("std");
        \\    _ = @import("c.zig"); // @import("d.zig")
    };
    try std.testing.expectEqualStrings("a.zig", it.next().?);
    try std.testing.expectEqualStrings("std", it.next().?);
    try std.testing.expectEqualStrings("c.zig", it.next().?);
    try std.testing.expectEqual(null, it.next());
}
