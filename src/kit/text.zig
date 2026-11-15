//! Text in the UI kit: the type scale, the interface layout uses to
//! measure text, and line wrapping.
//!
//! The kit does not know fonts. A `Measurer` gives the width of a run of
//! bytes in a style; the renderer provides one backed by the UI font, and
//! tests provide a fake. Text is laid out left to right from glyph
//! advances, with no shaping (ADR 0009).

const std = @import("std");

/// The type scale. Sizes are fixed logical pixels and do not follow the
/// system font size.
pub const Style = enum(u8) {
    /// 12 / 16, medium: key caps, captions.
    xs,
    /// 14 / 20, regular: body text and descriptions.
    sm,
    /// 14 / 20, medium: buttons, toast titles.
    sm_medium,
    /// 16 / 24, regular: settings body.
    base,
    /// 18 / 28, semibold: dialog titles.
    lg_semibold,
    /// 24 / 32, semibold: card values.
    xl_semibold,
    /// 36 / 42, semibold, tracking −1: compact display values.
    display_sm,
    /// 44 / 52, semibold, tracking −1: medium display values.
    display_md,
    /// 56 / 64, semibold, tracking −1: the compact timer.
    xxl_semibold,
    /// 80 / 88, semibold, tracking −2: the timer.
    xxxl_semibold,

    pub const count = @typeInfo(Style).@"enum".fields.len;

    pub const Metrics = struct {
        /// Font size.
        size: u8,
        /// Distance between baselines.
        line_height: u8,
        /// Weight on the font's `wght` axis.
        weight: u16,
        /// Extra logical pixels between glyphs. Negative tightens.
        tracking: i8 = 0,
    };

    pub fn metrics(self: Style) Metrics {
        return switch (self) {
            .xs => .{ .size = 12, .line_height = 16, .weight = 500 },
            .sm => .{ .size = 14, .line_height = 20, .weight = 400 },
            .sm_medium => .{ .size = 14, .line_height = 20, .weight = 500 },
            .base => .{ .size = 16, .line_height = 24, .weight = 400 },
            .lg_semibold => .{ .size = 18, .line_height = 28, .weight = 600 },
            .xl_semibold => .{ .size = 24, .line_height = 32, .weight = 600 },
            .display_sm => .{ .size = 36, .line_height = 42, .weight = 600, .tracking = -1 },
            .display_md => .{ .size = 44, .line_height = 52, .weight = 600, .tracking = -1 },
            .xxl_semibold => .{ .size = 56, .line_height = 64, .weight = 600, .tracking = -1 },
            .xxxl_semibold => .{ .size = 80, .line_height = 88, .weight = 600, .tracking = -2 },
        };
    }
};

/// How digits are spaced.
pub const Figures = enum(u1) {
    /// The font's advances and pair kerning.
    proportional,
    /// Each ASCII digit is centered in one cell, the ceil of the widest
    /// digit advance. Anything else keeps its own advance, and a digit
    /// is not kerned.
    tabular,
};

/// Measures text for layout. `context` is the implementation's own state,
/// which it may change (a font caches what it looks up) and which must
/// outlive every call; the kit never frees it. A function pointer instead
/// of a generic parameter, so the kit compiles once and depends on no font
/// code.
pub const Measurer = struct {
    context: *anyopaque,
    widthFn: *const fn (context: *anyopaque, bytes: []const u8, style: Style, figures: Figures) f32,

    /// Width in logical pixels of `bytes` set on one line in `style`.
    pub fn width(self: Measurer, bytes: []const u8, style: Style, figures: Figures) f32 {
        return self.widthFn(self.context, bytes, style, figures);
    }
};

/// The code points of UTF-8 text, for measuring and painting. A byte that
/// does not start a valid sequence yields U+FFFD and is skipped alone, so
/// text from a program (a title, a path) can never stall or trap the UI.
pub const Codepoints = struct {
    bytes: []const u8,
    index: usize = 0,

    pub const replacement: u21 = 0xFFFD;

    pub fn init(bytes: []const u8) Codepoints {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Codepoints) ?u21 {
        if (self.index >= self.bytes.len) return null;
        const decoded = decodeCodepoint(self.bytes[self.index..]);
        self.index += decoded.len;
        return decoded.codepoint;
    }
};

fn decodeCodepoint(rest: []const u8) struct { codepoint: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch return .{ .codepoint = Codepoints.replacement, .len = 1 };
    if (len > rest.len) return .{ .codepoint = Codepoints.replacement, .len = 1 };
    const codepoint = std.unicode.utf8Decode(rest[0..len]) catch return .{ .codepoint = Codepoints.replacement, .len = 1 };
    return .{ .codepoint = codepoint, .len = len };
}

pub const ellipsis_codepoint: u21 = 0x2026;
pub const ellipsis_bytes = "\u{2026}";

/// How many of the first `max` bytes of `bytes` to keep so that no UTF-8
/// sequence is cut in two, for copying text into a fixed buffer.
pub fn cut(bytes: []const u8, max: usize) usize {
    if (bytes.len <= max) return bytes.len;
    var end = max;
    while (end > 0 and bytes[end] & 0xC0 == 0x80) end -= 1;
    return end;
}

/// One line of a wrapped text: a byte range of the text and its width.
/// The range excludes the space or line feed the line was broken at.
pub const Line = struct {
    start: u32,
    end: u32,
    width: f32,
};

/// Fixed storage for the lines of every text in one view.
pub const Lines = struct {
    buffer: []Line,
    len: u32 = 0,

    pub fn init(buffer: []Line) Lines {
        return .{ .buffer = buffer };
    }

    pub fn slice(self: *const Lines, first: u32, count: u32) []const Line {
        return self.buffer[first..][0..count];
    }

    fn append(self: *Lines, line: Line) error{OutOfLines}!void {
        if (self.len == self.buffer.len) return error.OutOfLines;
        self.buffer[self.len] = line;
        self.len += 1;
    }
};

/// Breaks `bytes` into lines no wider than `max_width` and appends them to
/// `lines`, returning how many. Breaks at spaces and at line feeds; a word
/// wider than `max_width` gets a line of its own and overflows it, since
/// breaking inside a word needs more than byte widths. An empty text is one
/// empty line, so it still takes a line's height.
pub fn wrap(measurer: Measurer, bytes: []const u8, style: Style, figures: Figures, max_width: f32, lines: *Lines) error{OutOfLines}!u32 {
    const first = lines.len;
    var line_start: usize = 0;
    // End of the last word that fits on the current line.
    var line_end: usize = 0;
    var i: usize = 0;
    while (i <= bytes.len) {
        // A word ends at a space, a line feed or the end of the text.
        const word_end = std.mem.indexOfAnyPos(u8, bytes, i, " \n") orelse bytes.len;
        const fits = measurer.width(bytes[line_start..word_end], style, figures) <= max_width;
        if (!fits and line_end > line_start) {
            try lines.append(.{
                .start = @intCast(line_start),
                .end = @intCast(line_end),
                .width = measurer.width(bytes[line_start..line_end], style, figures),
            });
            line_start = i;
        }
        line_end = word_end;
        if (word_end == bytes.len or bytes[word_end] == '\n') {
            try lines.append(.{
                .start = @intCast(line_start),
                .end = @intCast(line_end),
                .width = measurer.width(bytes[line_start..line_end], style, figures),
            });
            line_start = word_end + 1;
            line_end = line_start;
        }
        i = word_end + 1;
    }
    return lines.len - first;
}

/// Width of the widest explicit line (split only on `\n`).
pub fn maxLineWidth(measurer: Measurer, bytes: []const u8, style: Style, figures: Figures) f32 {
    var widest: f32 = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| widest = @max(widest, measurer.width(line, style, figures));
    return widest;
}

/// Splits `bytes` only at `\n` without wrapping at spaces or `max_width`.
pub fn wrapNone(measurer: Measurer, bytes: []const u8, style: Style, figures: Figures, lines: *Lines) error{OutOfLines}!u32 {
    const first = lines.len;
    var start: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |segment| {
        const end = start + segment.len;
        try lines.append(.{
            .start = @intCast(start),
            .end = @intCast(end),
            .width = measurer.width(segment, style, figures),
        });
        start = end + 1;
    }
    return lines.len - first;
}

/// Fits a single line within `max_width`, truncating at a UTF-8 codepoint boundary
/// with `"…"` if `bytes` exceeds `max_width` or contains `\n`. Emits an empty line
/// when not even `"…"` fits inside `max_width`.
pub fn wrapEllipsis(measurer: Measurer, bytes: []const u8, style: Style, figures: Figures, max_width: f32, lines: *Lines) error{OutOfLines}!u32 {
    const nl = std.mem.indexOfScalar(u8, bytes, '\n');
    const slice = bytes[0 .. nl orelse bytes.len];
    const full_w = measurer.width(slice, style, figures);
    if (nl == null and full_w <= max_width) {
        try lines.append(.{ .start = 0, .end = @intCast(slice.len), .width = full_w });
        return 1;
    }

    const ellipsis_w = measurer.width(ellipsis_bytes, style, figures);
    const budget = max_width - ellipsis_w;
    if (budget < 0 or (ellipsis_w == 0 and max_width <= 0)) {
        try lines.append(.{ .start = 0, .end = 0, .width = 0 });
        return 1;
    }

    const prefix_end = fitPrefix(measurer, slice, style, figures, budget);
    const prefix_w = if (prefix_end == 0) 0 else measurer.width(slice[0..prefix_end], style, figures);
    try lines.append(.{
        .start = 0,
        .end = @intCast(prefix_end),
        .width = prefix_w + ellipsis_w,
    });
    return 1;
}

fn fitPrefix(measurer: Measurer, slice: []const u8, style: Style, figures: Figures, budget: f32) usize {
    if (slice.len == 0 or budget <= 0) return 0;
    if (measurer.width(slice, style, figures) <= budget) return slice.len;
    var lo: usize = 0;
    var hi: usize = slice.len - 1;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        const bound = cut(slice, mid);
        if (bound <= lo) {
            const next = lo + decodeCodepoint(slice[lo..]).len;
            if (next > hi) break;
            if (measurer.width(slice[0..next], style, figures) <= budget) {
                lo = next;
            } else {
                break;
            }
        } else if (measurer.width(slice[0..bound], style, figures) <= budget) {
            lo = bound;
        } else {
            hi = bound - 1;
        }
    }
    return lo;
}
