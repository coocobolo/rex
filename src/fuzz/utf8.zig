//! UTF-8 fuzz target: any bytes through `InputEngine`, the decoder,
//! grapheme clustering and width lookup that `Terminal.feed` uses for
//! printable text, with ASCII handled as `Terminal` does.
//!
//! Invariants, against `refDecode`, a slow decoder written from Unicode
//! table 3-7 and the maximal-subpart practice (Unicode 17, section 3.9):
//!   - no panic or safety check;
//!   - every code point written is a Unicode scalar value;
//!   - the written code points are the reference decoding in order,
//!     less the ones the engine documents dropping (a lone zero-width
//!     or control code point, and marks past a 16-code-point cluster);
//!   - ASCII is never dropped, and U+FFFD appears exactly as often as
//!     in the reference unless a cluster overflowed.

const std = @import("std");
const testing = std.testing;

const harness = @import("harness.zig");
const Source = harness.Source;
const InputEngine = @import("../term/InputEngine.zig");
const CellKind = @import("../term/cell.zig").Kind;

const replacement = InputEngine.replacement_char;

/// Collects everything the engine writes as one code point stream.
const Sink = struct {
    cps: [harness.max_input]u21 = undefined,
    len: usize = 0,
    /// A cluster reached the engine's 16-code-point cap, so it may have
    /// dropped marks.
    overflowed: bool = false,

    fn push(self: *Sink, cp: u21) void {
        self.cps[self.len] = cp;
        self.len += 1;
    }

    pub fn putCharKind(self: *Sink, cp: u21, kind: CellKind) void {
        _ = kind;
        self.push(cp);
    }
    pub fn putChar(self: *Sink, cp: u21) void {
        self.push(cp);
    }
    pub fn putGrapheme(self: *Sink, cps: []const u21, kind: CellKind) !void {
        _ = kind;
        if (cps.len >= 16) self.overflowed = true;
        for (cps) |cp| self.push(cp);
    }
    pub fn attachCombining(self: *Sink, cp: u21) void {
        self.push(cp);
    }
};

/// Second byte range for each lead byte (Unicode table 3-7), or null
/// for a byte that cannot start a sequence.
fn leadRange(b: u8) ?struct { len: u3, lo: u8, hi: u8 } {
    return switch (b) {
        0xC2...0xDF => .{ .len = 2, .lo = 0x80, .hi = 0xBF },
        0xE0 => .{ .len = 3, .lo = 0xA0, .hi = 0xBF },
        0xE1...0xEC, 0xEE, 0xEF => .{ .len = 3, .lo = 0x80, .hi = 0xBF },
        0xED => .{ .len = 3, .lo = 0x80, .hi = 0x9F },
        0xF0 => .{ .len = 4, .lo = 0x90, .hi = 0xBF },
        0xF1...0xF3 => .{ .len = 4, .lo = 0x80, .hi = 0xBF },
        0xF4 => .{ .len = 4, .lo = 0x80, .hi = 0x8F },
        else => null,
    };
}

/// Decodes `bytes` into `out`, one U+FFFD per maximal subpart of an
/// ill-formed sequence, and returns the code point count.
fn refDecode(bytes: []const u8, out: []u21) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b < 0x80) {
            out[n] = b;
            n += 1;
            i += 1;
            continue;
        }
        const lead = leadRange(b) orelse {
            out[n] = replacement;
            n += 1;
            i += 1;
            continue;
        };
        var cp: u21 = b & (@as(u8, 0x7F) >> lead.len);
        var j = i + 1;
        var k: usize = 1;
        while (k < lead.len and j < bytes.len) : ({
            j += 1;
            k += 1;
        }) {
            const c = bytes[j];
            const lo: u8 = if (k == 1) lead.lo else 0x80;
            const hi: u8 = if (k == 1) lead.hi else 0xBF;
            if (c < lo or c > hi) break;
            cp = (cp << 6) | (c & 0x3F);
        }
        out[n] = if (k == lead.len) cp else replacement;
        n += 1;
        i = j;
    }
    return n;
}

fn isScalar(cp: u21) bool {
    return cp <= 0x10FFFF and !(cp >= 0xD800 and cp <= 0xDFFF);
}

var input_buf: [harness.max_input]u8 = undefined;
var want_buf: [harness.max_input]u21 = undefined;

fn run(src: *Source) !void {
    var len: usize = 0;
    while (len < input_buf.len) {
        const piece = src.chunk("bytes", input_buf[len..]);
        std.mem.copyForwards(u8, input_buf[len..][0..piece.len], piece);
        len += piece.len;
        if (src.done("more bytes", 3)) break;
    }
    const bytes = input_buf[0..len];

    var engine: InputEngine = .init(if (src.chance("ambiguous", 3, 1)) .wide else .narrow);
    var sink: Sink = .{};
    for (bytes) |b| {
        if (b < 0x80) {
            engine.abortSequence(&sink);
            engine.flush(&sink);
            sink.putChar(b);
        } else {
            engine.feedByte(&sink, b);
        }
    }
    engine.finish(&sink);

    const want = want_buf[0..refDecode(bytes, &want_buf)];
    const got = sink.cps[0..sink.len];

    var want_fffd: usize = 0;
    var got_fffd: usize = 0;
    var w: usize = 0;
    for (got) |cp| {
        try testing.expect(isScalar(cp));
        if (cp == replacement) got_fffd += 1;
        // Skip what the engine may drop; ASCII it never drops.
        while (w < want.len and want[w] != cp) : (w += 1) {
            try testing.expect(want[w] >= 0x80);
            if (want[w] == replacement) want_fffd += 1;
        }
        try testing.expect(w < want.len); // `got` is a subsequence of `want`
        if (cp == replacement) want_fffd += 1;
        w += 1;
    }
    for (want[w..]) |cp| {
        try testing.expect(cp >= 0x80);
        if (cp == replacement) want_fffd += 1;
    }
    if (!sink.overflowed) try testing.expectEqual(want_fffd, got_fffd);
}

const seeds = [_][]const u8{
    "plain ascii",
    "caf\xc3\xa9 na\xc3\xafve",
    "e\xcc\x81\xcc\x82\xcc\x83\xcc\x84",
    "\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb",
    "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\xf0\x9f\x87\xac",
    "\xe4\xb8\x80\xea\xb0\x80\xe1\x84\x80\xe1\x85\xa1\xe1\x86\xa8",
    "\xc0\xaf\xc1\xbf\xe0\x80\xaf\xed\xa0\x80\xed\xbf\xbf\xf4\x90\x80\x80\xf5\xff",
    "\xe2\x82 \xf0\x9f\x91 \xc3",
    "\x80\x81\xbf\xfe\xff",
    "\xd8\x80\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb",
    "\xe2\x9d\xa4\xef\xb8\x8f \xe2\x9d\xa4\xef\xb8\x8e",
    "\xc2\xad\xe2\x80\x8b\xe2\x80\x8c\xef\xbb\xbf",
};

const regressions = [_][]const u8{};

test "fuzz utf8" {
    try harness.fuzz(run, &seeds, &regressions);
}

test "fuzz utf8: seeded mutations" {
    try harness.seeded(run, &seeds, 0x0078_F8F8);
}
