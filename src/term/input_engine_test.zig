const std = @import("std");
const testing = std.testing;

const InputEngine = @import("InputEngine.zig");
const CellKind = @import("cell.zig").Kind;

/// Records what the engine writes, in order.
const FakeSink = struct {
    const Put = struct { cp: u21, kind: CellKind, len: usize = 1 };

    buf: [32]Put = undefined,
    len: usize = 0,

    fn puts(self: *const FakeSink) []const Put {
        return self.buf[0..self.len];
    }

    fn record(self: *FakeSink, put: Put) void {
        self.buf[self.len] = put;
        self.len += 1;
    }

    pub fn putCharKind(self: *FakeSink, cp: u21, kind: CellKind) void {
        self.record(.{ .cp = cp, .kind = kind });
    }

    pub fn putChar(self: *FakeSink, cp: u21) void {
        self.record(.{ .cp = cp, .kind = .narrow });
    }

    pub fn putChars(self: *FakeSink, bytes: []const u8) void {
        for (bytes) |b| self.putChar(b);
    }

    pub fn putGrapheme(self: *FakeSink, cps: []const u21, kind: CellKind) !void {
        self.record(.{ .cp = cps[0], .kind = kind, .len = cps.len });
    }
};

/// Mirrors `Terminal.feedUtf8` for printable text: ASCII flushes the
/// pending cluster and goes straight to the sink, as the parser's
/// `print` would; high bytes go through the engine.
fn feedText(engine: *InputEngine, sink: *FakeSink, bytes: []const u8) void {
    for (bytes) |b| {
        if (b < 0x80) {
            engine.abortSequence(sink);
            engine.flush(sink);
            sink.putChars(&.{b});
        } else {
            engine.feedByte(sink, b);
        }
    }
}

test "ascii run passes through" {
    var engine: InputEngine = .init(.narrow);
    var sink: FakeSink = .{};
    feedText(&engine, &sink, "hi!");
    try testing.expectEqual(@as(usize, 3), sink.len);
    try testing.expectEqual(@as(u21, 'h'), sink.puts()[0].cp);
    try testing.expectEqual(@as(u21, '!'), sink.puts()[2].cp);
}

test "2-byte utf-8 split across feeds" {
    var engine: InputEngine = .init(.narrow);
    var sink: FakeSink = .{};
    feedText(&engine, &sink, "\xC3");
    try testing.expect(engine.inSequence());
    try testing.expectEqual(@as(usize, 0), sink.len);
    feedText(&engine, &sink, "\xA9");
    try testing.expectEqual(@as(usize, 1), sink.len);
    try testing.expectEqual(FakeSink.Put{ .cp = 0xE9, .kind = .narrow }, sink.puts()[0]);
}

test "4-byte utf-8 split across feeds" {
    var engine: InputEngine = .init(.narrow);
    var sink: FakeSink = .{};
    feedText(&engine, &sink, "\xF0\x9F");
    feedText(&engine, &sink, "\x98\x80");
    // Held back as a pending cluster until the next boundary.
    try testing.expect(engine.hasPendingCluster());
    try testing.expectEqual(@as(usize, 0), sink.len);
    engine.finish(&sink);
    try testing.expectEqual(@as(usize, 1), sink.len);
    try testing.expectEqual(FakeSink.Put{ .cp = 0x1F600, .kind = .wide_left }, sink.puts()[0]);
}

fn expectCps(sink: *const FakeSink, want: []const u21) !void {
    try testing.expectEqual(want.len, sink.len);
    for (want, sink.puts()) |cp, put| try testing.expectEqual(cp, put.cp);
}

const fffd = InputEngine.replacement_char;

/// Feeds each chunk in turn, then ends the stream.
fn feedChunks(chunks: []const []const u8) FakeSink {
    var engine: InputEngine = .init(.narrow);
    var sink: FakeSink = .{};
    for (chunks) |c| feedText(&engine, &sink, c);
    engine.finish(&sink);
    return sink;
}

test "invalid utf-8: cut sequence and bad lead become u+fffd" {
    const sink = feedChunks(&.{"\xC3A\xFFB"});
    try expectCps(&sink, &.{ fffd, 'A', fffd, 'B' });
}

test "invalid utf-8: lead cut by ascii" {
    const sink = feedChunks(&.{"\xC3\x41"});
    try expectCps(&sink, &.{ fffd, 'A' });
}

test "invalid utf-8: overlong C0 AF is two subparts" {
    const sink = feedChunks(&.{"\xC0\xAF"});
    try expectCps(&sink, &.{ fffd, fffd });
}

test "invalid utf-8: surrogate ED A0 80 is three subparts" {
    const sink = feedChunks(&.{"\xED\xA0\x80"});
    try expectCps(&sink, &.{ fffd, fffd, fffd });
}

test "invalid utf-8: above U+10FFFF F4 90 80 80 is four subparts" {
    const sink = feedChunks(&.{"\xF4\x90\x80\x80"});
    try expectCps(&sink, &.{ fffd, fffd, fffd, fffd });
}

test "invalid utf-8: valid prefix then bad continuation" {
    // E2 82 is a valid prefix of U+20AC; 41 cuts it: one U+FFFD.
    const sink = feedChunks(&.{"\xE2\x82\x41"});
    try expectCps(&sink, &.{ fffd, 'A' });
}

test "invalid utf-8: split across feeds" {
    var sink = feedChunks(&.{ "\xED", "\xA0\x80" });
    try expectCps(&sink, &.{ fffd, fffd, fffd });
    sink = feedChunks(&.{ "\xF0\x9F", "A" });
    try expectCps(&sink, &.{ fffd, 'A' });
    sink = feedChunks(&.{ "\xF0\x9F\x98", "\xF0\x9F\x98\x80" });
    try expectCps(&sink, &.{ fffd, 0x1F600 });
}

test "invalid utf-8: truncated at end of stream" {
    const sink = feedChunks(&.{"\xE4\xB8"});
    try expectCps(&sink, &.{fffd});
}

test "wide cjk" {
    var engine: InputEngine = .init(.narrow);
    var sink: FakeSink = .{};
    feedText(&engine, &sink, "\xE4\xB8\xAD"); // U+4E2D
    try testing.expectEqual(@as(usize, 1), sink.len);
    try testing.expectEqual(FakeSink.Put{ .cp = 0x4E2D, .kind = .wide_left }, sink.puts()[0]);
}

test "reset drops pending state" {
    var engine: InputEngine = .init(.wide);
    var sink: FakeSink = .{};
    feedText(&engine, &sink, "\xF0\x9F\x98\x80\xC3");
    engine.reset();
    try testing.expect(!engine.inSequence());
    try testing.expect(!engine.hasPendingCluster());
    try testing.expectEqual(@as(usize, 0), sink.len);
    try testing.expectEqual(.wide, engine.wcwidth_ambiguous_width);
}

test "combining mark composes with ascii base" {
    // M2 #5: `e` is printed before U+0301 arrives, so the mark starts its
    // own zero-width cluster and is dropped.
    if (true) return error.SkipZigTest;
    var engine: InputEngine = .init(.narrow);
    var sink: FakeSink = .{};
    feedText(&engine, &sink, "e\xCC\x81");
    engine.finish(&sink);
    try testing.expectEqual(@as(usize, 1), sink.len);
    try testing.expectEqual(@as(u21, 'e'), sink.puts()[0].cp);
    try testing.expectEqual(@as(usize, 2), sink.puts()[0].len);
}
