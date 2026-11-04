//! Text-stream decoder for the terminal: turns printable input bytes into
//! screen cells.
//!
//! Owns the UTF-8 decoder, the grapheme cluster in progress, and the
//! one-entry width cache. It knows nothing about the VT parser, modes or
//! `Terminal`; every method that writes cells takes a `sink`, normally the
//! active `Screen`.
//!
//! Boundary with `Terminal`: `Terminal.feed` owns the byte loop. ASCII runs
//! and C0 controls go to the parser, and string-state payload (OSC, DCS)
//! goes to `Parser.feedData`. Only high bytes (>= 0x80) that will print
//! reach `feedByte`. `Terminal` calls `flush` before handing the parser
//! anything that could act on the screen, so a pending cluster always lands
//! first.
//!
//! The sink must provide:
//!   - `putCharKind(cp: u21, kind: CellKind) void`
//!   - `putChar(cp: u21) void`
//!   - `putGrapheme(cps: []const u21, kind: CellKind) !void`
//!   - `attachCombining(cp: u21) void`, which appends a zero-width code
//!     point to the cell written last

const std = @import("std");

const CellKind = @import("cell.zig").Kind;
const grapheme = @import("grapheme.zig");
const Utf8Decoder = @import("../unicode/utf8.zig").Decoder;
const wc = @import("../unicode/wcwidth_v2.zig");

const log = std.log.scoped(.term);

const InputEngine = @This();

/// Character encoding used to interpret input bytes.
pub const Encoding = enum {
    /// Input is UTF-8 byte. Decode the byte stream into code points
    /// before applying terminal control semantics.
    ///
    /// ASCII bytes (0x00...0x7F) represent the corresponding code points.
    /// Bytes (0x80...0xBF) are continuation bytes and cannot appear alone.
    /// Valid multibyte sequences represent code points above U+007F.
    ///
    /// UTF-8 can encode C1 control code points. For example, `0xC2 0x9B`
    /// decodes to U+009B (CSI). A standalone `0x9B` byte is not CSI in
    /// UTF-8; it is an invalid UTF-8 byte.
    ///
    /// The input bytes must be interpreted according to UTF-8 rather than as
    /// single byte byte encoding (8-bit terminal controls).
    utf8,

    /// Interpret each input byte directly as the code point with the same value.
    /// In this encoding, bytes `0x80-0x9F` represent C1 controls.
    latin1,
};

encoding: Encoding = .utf8,
utf8_decoder: Utf8Decoder = .empty,

/// Code points of the cluster in progress; 16 is the max cluster length.
grapheme_buf: [16]u21 = undefined,
grapheme_len: u8 = 0,
/// Null when no cluster is in progress.
grapheme_breaker: ?grapheme.Breaker = null,

wcwidth_cp: u21 = 0,
wcwidth_width: wc.Width = .narrow,
wcwidth_ambiguous_width: wc.AmbiguousWidth = .narrow,

/// Returns an engine in its power-on state, using `ambiguous_width` for
/// East Asian Ambiguous code points.
pub fn init(ambiguous_width: wc.AmbiguousWidth) InputEngine {
    return .{ .wcwidth_ambiguous_width = ambiguous_width };
}

/// Returns to the power-on state (RIS). Drops any partial UTF-8 sequence
/// and pending cluster without writing them. The ambiguous-width setting
/// is configuration and is kept.
pub fn reset(self: *InputEngine) void {
    self.encoding = .utf8;
    self.utf8_decoder.reset();
    self.grapheme_len = 0;
    self.grapheme_breaker = null;
    self.wcwidth_cp = 0;
    self.wcwidth_width = .narrow;
}

/// Returns true while a UTF-8 sequence is partially decoded.
pub inline fn inSequence(self: *const InputEngine) bool {
    return self.utf8_decoder.state != Utf8Decoder.accept;
}

/// Returns true when a grapheme cluster is waiting to be written.
pub inline fn hasPendingCluster(self: *const InputEngine) bool {
    return self.grapheme_len > 0;
}

/// Length of the leading ASCII run in `bytes`; 0 while `inSequence()`.
pub inline fn asciiPrefixLen(self: *const InputEngine, bytes: []const u8) usize {
    return self.utf8_decoder.asciiPrefixLen(bytes);
}

/// Length of the leading run of high bytes in `bytes`; 0 while
/// `inSequence()`.
pub inline fn highBytePrefixLen(self: *const InputEngine, bytes: []const u8) usize {
    return self.utf8_decoder.highBytePrefixLen(bytes);
}

/// Replacement for each maximal subpart of an ill-formed sequence.
pub const replacement_char: u21 = 0xFFFD;

/// Ends a partially decoded UTF-8 sequence that a non-continuation byte
/// (ASCII, a control, ESC) has cut short, writing one U+FFFD for it to
/// `sink`. No-op when no sequence is in progress. The caller then
/// processes the cutting byte as a fresh start.
pub fn abortSequence(self: *InputEngine, sink: anytype) void {
    if (!self.inSequence()) return;
    self.utf8_decoder.reset();
    self.feedCodepoint(sink, replacement_char);
}

/// Feeds one high byte (>= 0x80) through the UTF-8 decoder and writes any
/// completed code point to `sink`.
///
/// Ill-formed input follows the Unicode "maximal subpart" practice
/// (Unicode 15, section 3.9): each maximal subpart becomes one U+FFFD.
/// When the DFA rejects a byte that cut a sequence short, that byte
/// is not part of the subpart and is decoded again as a fresh lead.
pub fn feedByte(self: *InputEngine, sink: anytype, byte: u8) void {
    std.debug.assert(byte >= 0x80);
    const was_mid = self.inSequence();
    switch (self.utf8_decoder.feed(byte)) {
        .ok => {}, // still accumulating a multibyte sequence
        .codepoint => |cp| self.feedCodepoint(sink, @intCast(cp)),
        .reject => {
            self.utf8_decoder.reset();
            self.feedCodepoint(sink, replacement_char);
            if (!was_mid) return; // bad lead byte: it is the whole subpart
            // Decoder is back in `accept`, so this cannot recurse again.
            switch (self.utf8_decoder.feed(byte)) {
                .ok => {},
                .codepoint => |cp| self.feedCodepoint(sink, @intCast(cp)),
                .reject => {
                    self.utf8_decoder.reset();
                    self.feedCodepoint(sink, replacement_char);
                },
            }
        },
    }
}

/// Writes the pending cluster to `sink` and ends it. Call before anything
/// that moves the cursor or otherwise acts on the screen.
pub fn flush(self: *InputEngine, sink: anytype) void {
    self.flushGrapheme(sink);
    self.grapheme_breaker = null;
}

/// Ends the stream: settles a partial UTF-8 sequence and flushes the
/// pending cluster to `sink`.
pub fn finish(self: *InputEngine, sink: anytype) void {
    if (self.encoding == .utf8) switch (self.utf8_decoder.finish()) {
        .ok => {},
        // Not produced by the current finish(); kept for exhaustiveness.
        .codepoint => |cp| self.feedCodepoint(sink, @intCast(cp)),
        // Incomplete trailing sequence: one U+FFFD, as abortSequence().
        .reject => self.feedCodepoint(sink, replacement_char),
    };
    self.flush(sink);
}

fn feedCodepoint(self: *InputEngine, sink: anytype, cp: u21) void {
    std.debug.assert(cp >= 0x80);

    // CJK Unified Ideographs: always wide, never combining.
    if (cp >= 0x4E00 and cp <= 0x9FFF) {
        self.flushGrapheme(sink);
        sink.putCharKind(cp, .wide_left);
        self.grapheme_breaker = null;
        return;
    }

    // Hangul syllables: always single-codepoint, wide.
    if (cp >= 0xAC00 and cp <= 0xD7A3) {
        self.flushGrapheme(sink);
        sink.putCharKind(cp, .wide_left);
        self.grapheme_breaker = null;
        return;
    }

    // Latin-1 Supplement letters and Latin Extended-A/B: narrow. A mark
    // that follows still attaches, through the zero-width path below.
    if (cp >= 0x00C0 and cp <= 0x024F) {
        self.flushGrapheme(sink);
        sink.putCharKind(cp, .narrow);
        self.grapheme_breaker = null;
        return;
    }

    // No cluster in progress: the base was written already (ASCII via the
    // parser, or a fast-path code point above), so a zero-width code point
    // extends that cell instead of starting a cluster of its own.
    if (self.grapheme_breaker == null and self.wcwidthCached(cp) == .zero) {
        sink.attachCombining(cp);
        return;
    }

    if (self.grapheme_breaker) |*gb| {
        if (gb.isBreak(cp)) {
            // Cluster boundary: flush the accumulated cluster, start a new one.
            self.flushGrapheme(sink);
            self.grapheme_buf[0] = cp;
            self.grapheme_len = 1;
            self.grapheme_breaker = grapheme.Breaker.init(cp);
        } else if (self.grapheme_len < self.grapheme_buf.len) {
            self.grapheme_buf[self.grapheme_len] = cp;
            self.grapheme_len += 1;
        }
        // else: cluster too long (malformed input), drop the extra code point.
        return;
    }

    // First code point of a new cluster.
    self.grapheme_buf[0] = cp;
    self.grapheme_len = 1;
    self.grapheme_breaker = grapheme.Breaker.init(cp);
}

inline fn wcwidthCached(self: *InputEngine, cp: u21) wc.Width {
    if (cp == self.wcwidth_cp) return self.wcwidth_width;
    const width = wc.wcwidth(cp, self.wcwidth_ambiguous_width);
    self.wcwidth_cp = cp;
    self.wcwidth_width = width;
    return width;
}

inline fn flushGrapheme(self: *InputEngine, sink: anytype) void {
    if (self.grapheme_len > 0) self.flushGraphemeImpl(sink);
}

fn flushGraphemeImpl(self: *InputEngine, sink: anytype) void {
    defer self.grapheme_len = 0;

    const cp = self.grapheme_buf[0];
    if (self.grapheme_len == 1) {
        switch (self.wcwidthCached(cp)) {
            .wide => sink.putCharKind(cp, .wide_left),
            .narrow => sink.putCharKind(cp, .narrow),
            // Standalone combining mark with no base (e.g. input starts
            // mid-stream). Policy: dropped. Alternative: draw it over a
            // synthetic space.
            .zero => {},
            // Table-driven Cc/Cf code points above U+007F can land here;
            // dropped.
            .control => {},
        }
        return;
    }

    const slice = self.grapheme_buf[0..self.grapheme_len];
    const base_kind: CellKind = switch (self.wcwidthCached(slice[0])) {
        .wide => .wide_left,
        .narrow => .narrow,
        // FIXME! pick an explicit fallback policy, don't let it fall through implicitly
        .zero, .control => .narrow,
    };
    sink.putGrapheme(slice, base_kind) catch |err| {
        log.warn("putGrapheme failed: {}", .{err});
        sink.putChar(cp);
    };
}
