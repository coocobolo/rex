//! wcwidth fuzz target: code points through the width table lookup.
//!
//! Invariant: `lookup` agrees with the UCD oracle (wcwidth_oracle.zig)
//! for every code point outside its documented exceptions.

const std = @import("std");

const harness = @import("harness.zig");
const Source = harness.Source;
const oracle = @import("../unicode/wcwidth_oracle.zig");

fn run(src: *Source) !void {
    // First a whole code point, as the saved regressions encode it, then
    // three bytes per code point from the input.
    try oracle.check(src.range("code point", u21, 0, std.math.maxInt(u21)));
    var buf: [192]u8 = undefined;
    const bytes = src.chunk("code points", &buf);
    var i: usize = 0;
    while (i + 3 <= bytes.len) : (i += 3) {
        try oracle.check(@truncate(std.mem.readInt(u24, bytes[i..][0..3], .little)));
    }
}

/// Little-endian 24-bit code points: block edges and the exceptions.
const seeds = [_][]const u8{
    "\x00\x00\x00\x7f\x00\x00\xa0\x00\x00\xad\x00\x00",
    "\x00\x03\x00\x6f\x03\x00\x0d\x20\x00\x0f\xfe\x00",
    "\x00\x4e\x00\xff\x9f\x00\x00\xac\x00\xa3\xd7\x00",
    "\xe6\xf1\x01\xff\xf1\x01\x00\xf6\x01\x00\xe0\x00",
    "\x00\xd8\x00\xff\xdf\x00\xff\xff\x10\x00\x00\x11",
};

const regressions = [_][]const u8{
    @embedFile("testdata/wcwidth/crash-630ff0a4f49ee617.bin"),
    @embedFile("testdata/wcwidth/crash-8185a9074f803ffc.bin"),
};

test "fuzz wcwidth" {
    try harness.fuzz(run, &seeds, &regressions);
}

test "fuzz wcwidth: seeded mutations" {
    try harness.seeded(run, &seeds, 0x3C3C_0011);
}
