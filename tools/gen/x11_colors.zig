//! `zig build gen-x11-colors`: src/color/x11.zig from an X11 rgb.txt file.
//!
//! Usage: x11_colors <out.zig> <rgb.txt>
//!
//! The generated file contains data derived from the X11 color database
//! (`rgb.txt`) distributed with the X.Org rgb application.
//!
//! See THIRD_PARTY_NOTICES/xorg-rgb.txt.COPYING for the applicable
//! upstream copyright and license notices.
//!
//! Upstream source:
//! https://gitlab.freedesktop.org/xorg/app/rgb/-/blob/2b2019cabfe5697f54fde2f95c5d00395909458f/rgb.txt
//!
//! A local copy may be available at:
//!  $ find /usr -name rgb.txt 2>/dev/null

const std = @import("std");
const ucd = @import("ucd.zig");

const gen_name = "x11-colors";
const usage_args = "<out.zig> <rgb.txt>";

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]
    const out_path = args.next() orelse ucd.usage(gen_name, usage_args);
    const source_path = args.next() orelse ucd.usage(gen_name, usage_args);

    const io = init.io;
    const allocator = init.arena.allocator();
    const content = try ucd.readFile(io, allocator, gen_name, source_path);

    var stdout_buf: [4096]u8 = undefined;
    var writer = (try ucd.createFile(io, out_path)).writer(io, &stdout_buf);
    defer writer.flush() catch {};

    try ucd.writeHeader(&writer.interface, gen_name, "X11 rgb.txt", .{});
    const count = try parse(&writer.interface, allocator, content);
    ucd.log(gen_name, "wrote {s}: {d} colors", .{ std.fs.path.basename(out_path), count });
}

fn parse(writer: *std.Io.Writer, gpa: std.mem.Allocator, content: []const u8) !usize {
    var count: usize = 0;
    var seen: std.StringHashMap(void) = .init(gpa);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit();
    }

    try writer.writeAll(
        \\//! This file contains generated data derived from the X11 color database
        \\//! (rgb.txt), distributed with the X.Org rgb application. The applicable
        \\//! upstream copyright and license notices are reproduced below.
        \\//!
        \\//! Upstream project:
        \\//! https://gitlab.freedesktop.org/xorg/app/rgb
        \\//!
        \\//! Upstream revision:
        \\//! 2b2019cabfe5697f54fde2f95c5d00395909458f
        \\//!
        \\//! Upstream license notices:
        \\//! https://gitlab.freedesktop.org/xorg/app/rgb/-/blob/2b2019cabfe5697f54fde2f95c5d00395909458f/COPYING
        \\//!
        \\//! Source:
        \\//! https://gitlab.freedesktop.org/xorg/app/rgb/-/blob/2b2019cabfe5697f54fde2f95c5d00395909458f/rgb.txt
        \\//!
        \\//! Upstream Copyright and License Notices
        \\//! --------------------------------------
        \\//! Copyright 1985, 1989, 1998  The Open Group
        \\//!
        \\//! Permission to use, copy, modify, distribute, and sell this software and its
        \\//! documentation for any purpose is hereby granted without fee, provided that
        \\//! the above copyright notice appear in all copies and that both that
        \\//! copyright notice and this permission notice appear in supporting
        \\//! documentation.
        \\//!
        \\//! The above copyright notice and this permission notice shall be included
        \\//! in all copies or substantial portions of the Software.
        \\//!
        \\//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
        \\//! OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
        \\//! MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
        \\//! IN NO EVENT SHALL THE OPEN GROUP BE LIABLE FOR ANY CLAIM, DAMAGES OR
        \\//! OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
        \\//! ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
        \\//! OTHER DEALINGS IN THE SOFTWARE.
        \\//!
        \\//! Except as contained in this notice, the name of The Open Group shall
        \\//! not be used in advertising or otherwise to promote the sale, use or
        \\//! other dealings in this Software without prior written authorization
        \\//! from The Open Group.
        \\//!
        \\//! Copyright (c) 1994, 2008, Oracle and/or its affiliates.
        \\//!
        \\//! Permission is hereby granted, free of charge, to any person obtaining a
        \\//! copy of this software and associated documentation files (the "Software"),
        \\//! to deal in the Software without restriction, including without limitation
        \\//! the rights to use, copy, modify, merge, publish, distribute, sublicense,
        \\//! and/or sell copies of the Software, and to permit persons to whom the
        \\//! Software is furnished to do so, subject to the following conditions:
        \\//!
        \\//! The above copyright notice and this permission notice (including the next
        \\//! paragraph) shall be included in all copies or substantial portions of the
        \\//! Software.
        \\//!
        \\//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        \\//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        \\//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
        \\//! THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        \\//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
        \\//! FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
        \\//! DEALINGS IN THE SOFTWARE.
        \\//!
        \\//! Regenerate with `zig build gen-x11-colors` (tools/x11/rgb.txt).
        \\//!
        \\//! The generator emits lowercase keys. Both forms "ghost white"
        \\//! and "ghostwhite" are retained as separate entries.
        \\
        \\const std = @import("std");
        \\const Rgb = @import("Rgb.zig");
        \\
        \\pub const colors_map = std.StaticStringMap(Rgb).initComptime(&.{
        \\
    );

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '!') continue;

        // rgb.txt format: "R  G  B\t\tColor Name"
        var tok = std.mem.tokenizeAny(u8, t, " \t");
        const r = std.fmt.parseInt(u8, tok.next() orelse continue, 10) catch continue;
        const g = std.fmt.parseInt(u8, tok.next() orelse continue, 10) catch continue;
        const b = std.fmt.parseInt(u8, tok.next() orelse continue, 10) catch continue;
        const name = std.mem.trim(u8, tok.rest(), " \t");
        if (name.len == 0) continue;

        const lower = try std.ascii.allocLowerString(gpa, name);
        const gop = try seen.getOrPut(lower);
        if (gop.found_existing) {
            gpa.free(lower);
            continue;
        }

        count += 1;
        try writer.print(
            "    .{{ \"{s}\", Rgb{{ .r = {d}, .g = {d}, .b = {d} }} }},\n",
            .{ lower, r, g, b },
        );
    }

    try writer.writeAll("});\n");

    try writer.writeAll(
        \\
        \\/// Lookup: lowercase only, no space stripping
        \\pub fn fromName(name: []const u8) ?Rgb {
        \\    var buf: [64]u8 = undefined;
        \\    if (name.len > buf.len) return null;
        \\    const lower = std.ascii.lowerString(&buf, name);
        \\    return colors_map.get(lower);
        \\}
        \\
    );
    return count;
}
