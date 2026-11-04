//! The terminal: `Terminal(option)` owns the primary and alternate
//! screens, modes, palette and parser state, applies the actions the
//! dispatcher decodes, and queues replies for the pty.

const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.target.cpu.arch.endian();

const Parser = @import("../vt/parser.zig").Parser;
const Parameter = @import("../vt/parser.zig").Parameter;

const Palette = @import("Palette.zig").Palette;
const Theme = @import("Theme.zig");
const Color = @import("cell.zig").Color;
const CellKind = @import("cell.zig").Kind;
const Rgb = Color.Rgb;

const Charset = @import("cell.zig").Charset;
const CursorStyle = @import("cell.zig").CursorStyle;
const Screen = @import("screen.zig").Screen;
const dispatcher = @import("dispatcher.zig");

const wc = @import("../unicode/wcwidth.zig");

const InputEngine = @import("InputEngine.zig");

pub const max_title_len = 256;
pub const max_answerback_len = 32;

const log = std.log.scoped(.term);

pub const ScreenBuffer = enum { primary, alternate };

/// Terminal modes (ANSI + DEC private).
///
/// Stored here rather than on Screen because modes are terminal-level state:
/// they survive alternate-screen switches and are not saved/restored by DECSC.
pub const Mode = struct {
    // DECCKM  CSI ? 1 h/l, app vs normal cursor keys
    cursor_keys: bool = false,
    /// LNM — Line Feed / New Line Mode (CSI 20 h / CSI 20 l).
    /// When set, LF/VT/FF also perform CR.
    linefeed: bool = false,
    /// DECKPAM ESC = / ESC >
    keypad_app: bool = false,
    /// DECARM  CSI ? 8 h/l
    auto_repeat: bool = true,
    /// Mouse reporting modes (xterm extensions).
    mouse_x10: bool = false,
    mouse_normal: bool = false,
    mouse_button: bool = false,
    mouse_any: bool = false,
    mouse_sgr: bool = false,
    /// Bracketed paste mode (CSI ? 2004 h / l).
    bracketed_paste: bool = false,
    /// Focus event reporting (CSI ? 1004 h / l).
    focus_events: bool = false,
    /// Synchronized output (CSI ? 2026 h / l).
    synchronized_output: bool = false,
    /// xterm modifyOtherKeys (CSI > 4 ; Pv m). 0=off, 1=partial, 2=full.
    modify_other_keys: u2 = 0,

    alt_scroll: bool = false,

    /// DECCOLM  CSI ? 3 h/l
    column_132: bool = false,

    /// DECCOLM guard  CSI ? 40 h/l
    allow_column_132: bool = true,

    const Self = @This();

    pub fn isMouseReporting(mode: *const Self) bool {
        return mode.mouse_x10 or mode.mouse_button or mode.mouse_any;
    }
};

/// Mouse tracking modes are mutually exclusive.
/// Setting any one clears the others.
const MouseMode = enum { x10, normal, button, any };

pub const Option = struct {
    max_rows: usize,
    max_cols: usize,
    tab_width: usize = 8,
    max_scrollback: usize,
    /// Width of East Asian Ambiguous code points, for every path that
    /// places text on the grid. `.wide` suits CJK locales.
    ambiguous_width: wc.AmbiguousWidth = .narrow,
    name: []const u8 = "rex",
    version: []const u8 = "0.1.0",

    /// Total logcail rows = 4096 (Exact power of two, 0% waste).
    pub const compact = Option{
        .max_rows = 200,
        .max_cols = 80,
        .max_scrollback = 3896,
    };

    /// Total logical rows = 8,192 (Exact power of two, 0% waste)
    pub const standard = Option{
        .max_rows = 500,
        .max_cols = 120,
        .max_scrollback = 7692,
    };

    /// Total logical rows = 16,384 (Exact power of two, 0% waste)
    pub const heavy = Option{
        .max_rows = 1000,
        .max_cols = 200,
        .max_scrollback = 15384,
    };

    /// Automatically adjusts max_scrollback so the resulting ring buffer
    /// is 100% memory-efficient (no wasted power-of-two space).
    pub fn optimized(max_rows: usize, max_cols: usize, min_scrollback: usize) Option {
        const target_logical = max_rows + min_scrollback;
        const ring_rows = std.math.ceilPowerOfTwo(usize, target_logical) catch target_logical;

        return .{
            .max_rows = max_rows,
            .max_cols = max_cols,
            // Snap scollback up so it fills the power-of-two boundary perfectly
            .max_scrollback = ring_rows -| max_rows,
        };
    }
};

/// Events produced by `Terminal` after feed bytes.
///
/// Terminal is pure state, it has no access to I/O (i.e cannot ring a
/// bell or write to the fd itself). After each `feed` call, the caller
/// must checks these fields and acts on them, then flush the events.
pub const Events = struct {
    /// BEL (0x07) was received. Ring a bell or flash the window.
    bell: bool = false,

    /// OSC 0 or OSC 2 updated `title`.
    title: bool = false,

    /// OSC 1 updated `icon_name`
    icon_name: bool = false,

    cursor_color: bool = false, // OSC 12

    selection_reset: bool = false,

    hard_reset: bool = false,

    /// Replies to write back to the pty master: DA1, CPR, XTVERSION,
    /// colour queries and mouse reports. Write `slice()`, then `clear()`.
    response: Response = .{},

    /// `CSI 8 ; rows ; cols t` the application requested a terminal resize.
    /// The caller should resize the PTY and call `terminal.resize(rows, cols)`.
    resize: ?Resize = null,

    /// Bounded queue of replies for the pty, in the order the queries
    /// were parsed. Each write is one whole reply:
    /// it is queued entirely or dropped entirely and counted, so the
    /// host never sends a truncated sequence.
    pub const Response = struct {
        pub const capacity = 1024;

        buf: [capacity]u8 = undefined,
        len: usize = 0,
        /// Replies dropped because they did not fit whole.
        dropped: u32 = 0,

        /// Queues `bytes` as one reply, or drops it whole.
        pub fn append(self: *Response, bytes: []const u8) void {
            if (bytes.len > capacity - self.len) {
                self.dropped +|= 1;
                return;
            }
            @memcpy(self.buf[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }

        /// Queues `fmt` formatted with `args` as one reply, or drops it
        /// whole.
        pub fn print(self: *Response, comptime fmt: []const u8, args: anytype) void {
            const written = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch {
                self.dropped +|= 1;
                return;
            };
            self.len += written.len;
        }

        pub fn slice(self: *const Response) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn isEmpty(self: *const Response) bool {
            return self.len == 0;
        }

        /// Empties the queue after the host has written it. Keeps
        /// `dropped`.
        pub fn clear(self: *Response) void {
            self.len = 0;
        }
    };

    const Resize = struct { rows: u16, cols: u16 };

    /// Returns true if any event is pending.
    pub fn any(self: *const Events) bool {
        return self.bell or
            self.title or
            self.icon_name or
            self.cursor_color or
            self.response.len > 0 or
            self.resize != null;
    }

    /// Reset all events. Call after Tab has processed them.
    pub fn clear(self: *Events) void {
        self.* = .{};
    }
};

/// DEC terminal compatibility levels selected by DECSCL.
///
/// DECSCL selects the terminal's operating level for compatibility with
/// applications written for that level. It does not designate or map
/// character sets. The sequence also selects the representation of C1
/// controls and performs a soft reset.
///
/// Level values:
///   61  Level 1 — VT100
///   62  Level 2 — VT200
///   63  Level 3 — VT300
///   64  Level 4
///
/// For levels 2 and above, the separate control-format parameter selects
/// 7-bit controls (`1`) or 8-bit controls (`0` or `2`). Level 1 uses
/// 7-bit controls.
/// https://vt100.net/docs/vt510-rm/ANSI
pub const ConformanceLevel = enum(u8) {
    /// VT100, 7-bit controls only
    level1 = 61,
    /// VT200
    level2 = 62,
    /// VT300
    level3 = 63,
    /// VT400/VT510, (TODO! unimplemented/future)
    level4 = 64,
};

/// Controls whether the terminal sends 7-bit or 8-bit C1 control sequences format.
/// Set by S7C1T (ESC SP F) / S8C1T (ESC SP G) independently of conformance level.
pub const ControlFormat = enum(u8) {
    /// 7-bit format.
    s7c1t,
    /// 8-bit format; DECSCL 62;0 also maps here (0 ≡ 2)
    s8c1t,
};

pub const Encoding = InputEngine.Encoding;

pub const SequenceType = enum(u2) {
    // zig fmt: off
    st  = 0, csi = 1, dcs = 2, osc = 3,
    const count = 4;
    // zig fmt: on
};

pub const sequence_table: [2][SequenceType.count][]const u8 = blk: {
    const vt_fmt = [SequenceType.count][2][]const u8{
        .{ "\x9c", "\x1b\\" }, // st
        .{ "\x9b", "\x1b[" }, // csi
        .{ "\x90", "\x1bP" }, // dcs
        .{ "\x9d", "\x1b]" }, // osc
    };

    var t: [2][SequenceType.count][]const u8 = undefined;
    for (0..SequenceType.count) |s| {
        t[@intFromEnum(ControlFormat.s7c1t)][s] = vt_fmt[s][1]; // 7-bit
        t[@intFromEnum(ControlFormat.s8c1t)][s] = vt_fmt[s][0]; // 8-bit
    }
    break :blk t;
};

pub fn seqIntroducer(comptime target: SequenceType, c1_mode: ControlFormat) []const u8 {
    return sequence_table[@intFromEnum(c1_mode)][@intFromEnum(target)];
}

/// VT/ANSI terminal state machine.
///
/// Owns primary/alternate screens, the VT parser, and terminal-wide modes.
/// Pure state only: no I/O, threads, or allocations after `init`.
/// The caller owns the PTY and feeds bytes via `feed`.
///
/// Both screens use the same `Screen(option)` type, so `active()` is a
/// branch-free select between two fields and every screen method is
/// compiled once. The alternate screen therefore allocates unused
/// scrollback by design, matching xterm, wezterm, and Alacritty.
///
/// `Terminal` holds no pointers into itself: the active screen is an
/// enum, resolved per call. It can be returned by value and moved freely;
/// the screens' cell storage is on the heap and does not move with it.
///
/// NOTE (future dapa)
/// If memory is a hard constraint (e.g. hundreds of simultaneous sessions),
/// replace `alternate` with `Screen(..., 0)` and dispatch once per `feed`
/// on `active_buffer`. See the `ActiveScreen` union pattern for that
/// approach.
///
/// Terminal modes live here instead of `Screen` because they persist across
/// alternate-screen switches. `DECOM` is stored on the cursor since DECSC
/// saves/restores it.
///
/// Usage:
///
///   var t = try Terminal(opt).create(alloc);
///   defer t.destroy(alloc);
///
///   t.feed(chunk);
///
///   const s = t.active();
///   for (0..s.active_rows) |r| {
///       const row = s.displayRow(r);
///   }
pub fn Terminal(comptime option: Option) type {
    // FIXME screen mode .alternate shouldn't has scrollback
    const ScreenType = Screen(option);

    return struct {
        const Self = @This();

        primary: ScreenType,
        alternate: ScreenType,

        /// Which of `primary` or `alternate` receives output; see `active`.
        active_buffer: ScreenBuffer = .primary,

        /// Terminal-level modes (survive alternate-screen switches).
        mode: Mode = .{},

        title: [max_title_len:0]u8 = std.mem.zeroes([max_title_len:0]u8),
        title_len: usize = 0,

        /// Icon name (OSC 1). Rarely used; stored separately from title.
        icon_name: [max_title_len:0]u8 = std.mem.zeroes([max_title_len:0]u8),
        icon_name_len: usize = 0,

        answerback: [max_answerback_len]u8 = std.mem.zeroes([max_answerback_len]u8),
        answerback_len: u8 = 0,

        parser: Parser(Self, .{}),
        events: Events,
        conformance_level: ConformanceLevel = .level3,
        control_format: ControlFormat = .s7c1t,

        // the osc will likely to be send to the events?
        osc_buf: [1024]u8 = undefined,
        osc_len: usize = 0,

        dcs_buf: [1024]u8 = undefined,
        dcs_len: usize = 0,
        dcs_kind: enum { unknown, decrqss, sixel } = .unknown,

        /// UTF-8 decoding, grapheme clustering and widths for printable text.
        input: InputEngine = .init(option.ambiguous_width),

        cursor_color: ?Color.Rgb = null,
        selection_foreground: ?Color.Rgb = null,
        selection_background: ?Color.Rgb = null,

        osc_overflow: bool = false,
        dcs_overflow: bool = false,

        pub const ColorTarget = enum {
            fg,
            bg,
            cursor,
            selection_fg,
            selection_bg,
        };

        /// Allocates both screens' cell storage. The returned value owns
        /// it; release with `destroy`.
        pub fn create(alloc: std.mem.Allocator) !Self {
            var primary: ScreenType = try .create(alloc);
            errdefer primary.destroy(alloc);

            return .{
                .primary = primary,
                .alternate = try .create(alloc),
                .parser = .{},
                .events = .{},
            };
        }

        pub fn destroy(self: *Self, alloc: std.mem.Allocator) void {
            self.primary.destroy(alloc);
            self.alternate.destroy(alloc);
            self.* = undefined;
        }

        /// The screen that output currently goes to.
        pub inline fn active(self: *Self) *ScreenType {
            return switch (self.active_buffer) {
                .primary => &self.primary,
                .alternate => &self.alternate,
            };
        }

        pub fn feed(self: *Self, bytes: []const u8) void {
            // encoding governs input byte into character decode; conformance_level
            // governs parser feature availability (an orthogonal axis).
            // utf8 + level1 /.sc7c1t is valid, input is still UTF-8, output-side
            // restrictions live in the sequence-emitting code, not here.
            switch (self.input.encoding) {
                .utf8 => self.feedUtf8(bytes),
                .latin1 => switch (self.control_format) {

                    // levels_*_8bit mode, means whole byte buffer is passed directly
                    // to the vt-parser, since every byte in 8-bit latin1 is already
                    // valid single code points.
                    .s8c1t => self.parser.feedBytes(self, bytes),
                    .s7c1t => switch (self.conformance_level) {
                        .level1 => self.feedLatin1(bytes, .strip),
                        else => self.feedLatin1(bytes, .ignore),
                    },
                },
            }

            self.active().bump();
        }

        fn feedLatin1(self: *Self, bytes: []const u8, comptime high_byte_policy: enum { ignore, strip }) void {
            // .ignore: C1s are dropped, not masked, runs split at each C1 so
            // "A\x9CB" prints "AB" with no invisible byte dispatched.
            if (high_byte_policy == .ignore) {
                // TODO! If latin1+7bit ever matters for throughput, the same scanUntil engine applies
                // non-payload = [0x80,0x9F] is one masked compare ((chunk -% 0x80) < 0x20
                // the same C1 idiom used in payloadEnd), giving chunk-sized skip over clean runs.
                // Until that need exists, scalar is fine for a compat path.
                var start: usize = 0;

                for (bytes, 0..) |b, i| {
                    // In s7c1t latin1: C1 controls (0x80–0x9F) have no defined meaning
                    // ignore them. 0xA0–0xFF are printable Latin-1; they go to the parser.
                    if (b >= 0x80 and b <= 0x9F) {
                        if (start < i) {
                            self.parser.feedBytes(self, bytes[start..i]);
                        }
                        start = i + 1;
                    }
                }

                if (start < bytes.len) {
                    self.parser.feedBytes(self, bytes[start..]);
                }
                return;
            }

            // `.strip`: copy and mask, since the input slice must not be modified.
            var scratch: [4096]u8 = undefined;
            var rest = bytes;

            while (rest.len > 0) {
                const n = @min(rest.len, scratch.len);
                stripInto(rest[0..n], scratch[0..n]);
                self.parser.feedBytes(self, scratch[0..n]);
                rest = rest[n..];
            }
        }

        /// Feeds a chunk, not necessarily the end of the stream.
        /// Call end() only when the stream actually ends.
        fn feedUtf8(self: *Self, bytes: []const u8) void {
            var i: usize = 0;
            while (i < bytes.len) {
                const n = self.input.asciiPrefixLen(bytes[i..]);

                // Fast path whole ascii run.
                if (n > 0) {
                    @branchHint(.likely);

                    // A pending cluster always predates whatever this run starts
                    // (a sequence, text, a control); it must land on screen before
                    // the parser acts on new bytes.
                    if (self.input.hasPendingCluster()) self.input.flush(self.active());

                    // The run is all-ASCII (< 0x80), so feedBytes'
                    // internal string-state no C1 can be present.
                    self.parser.feedBytes(self, bytes[i..][0..n]);
                    i += n;
                    continue;
                }

                // Fast path inside a string state, a run of high bytes are pure payload,
                // batch it straight to feedData, skipping the decoder entirely. This
                // bypass is still required, feedBytes applies table semantics where
                // (0x80...0x9F) abort, which is wrong for UTF-8 payload bytes.
                if (self.parser.inStringState()) {
                    @branchHint(.unlikely);

                    const j = i + self.input.highBytePrefixLen(bytes[i..]);
                    if (j == i) {
                        // Decoder is mid-sequence: this byte continues (or cuts)
                        // a codepoint that started before the string began, not
                        // string payload. ASCII must still reach the parser.
                        if (bytes[i] < 0x80)
                            self.feedUtf8Byte(bytes[i])
                        else
                            self.input.feedByte(self.active(), bytes[i]);
                        i += 1;
                        continue;
                    }

                    self.parser.feedData(self, bytes[i..j]);
                    i = j;
                    continue;
                }

                self.feedUtf8Byte(bytes[i]);
                i += 1;
            }
        }

        fn feedUtf8Byte(self: *Self, byte: u8) void {
            if (byte < 0x80) {
                // ASCII cannot continue an incomplete UTF-8 sequence.
                //
                // Treat the previous partial sequence as malformed,
                // then process this ASCII byte normally.
                // The cut sequence becomes U+FFFD, and it and any pending
                // cluster must land before the parser acts on this byte.
                self.input.abortSequence(self.active());
                self.input.flush(self.active());

                self.parser.feedBytes(self, &.{byte});
                return;
            }

            // A high byte arriving while the parser is inside a string state is a raw UTF-8
            // data byte for the string payload, not screen content. The decoder is necessarily
            // in `accept` here; the bypass caught the sequence's first byte before it could
            // accumulate. so no partial decode can exist.
            //
            // NOTE: unreachable from feedUtf8()'s main loop; its batch path intercepts high
            // bytes during string states before this function is called. Keep this branch as
            // the guard for any caller that reaches feedUtf8Byte directly;
            // do not delete it as "redundant".
            if (self.parser.inStringState()) {
                self.parser.feedData(self, &.{byte});
                return;
            }

            self.input.feedByte(self.active(), byte);
        }

        /// Ends the input stream (e.g. the PTY read returned 0 bytes):
        /// settles a partial UTF-8 sequence and flushes the pending cluster.
        pub fn end(self: *Self) void {
            self.input.finish(self.active());
            self.active().bump();
        }

        pub inline fn printByte(self: *Self, byte: u8) void {
            self.active().putChar(byte);
        }

        pub inline fn print(self: *Self, bytes: []const u8) void {
            // Requires self.active() (or whatever putChar's owner is) to expose a
            // bulk write. If putChar does per-cell bookkeeping (cursor advance,
            // dirty-row tracking, wrap handling), that logic needs to be hoisted
            // out of the per-byte call and applied once per batch, e.g.:
            //   self.active().putChars(bytes);
            // rather than looping putChar per byte here — looping here defeats
            // the whole point of batching (point 2 was specifically about
            // eliminating per-byte handler dispatch, not just per-byte table lookups).
            self.active().putChars(bytes);
        }

        pub inline fn execute(self: *Self, byte: u8) void {
            dispatcher.C0.dispatch(option, self, byte);
        }

        pub inline fn escDispatch(self: *Self, final: u8, intermediates: []const u8) void {
            dispatcher.Escape.dispatch(option, self, final, intermediates);
        }

        pub inline fn csiDispatch(self: *Self, final: u8, intermediates: []const u8, params: []const Parameter) void {
            dispatcher.Csi.dispatch(option, self, final, intermediates, params);
        }

        pub fn oscStart(self: *Self) void {
            self.osc_len = 0;
            self.osc_overflow = false;
        }

        pub fn oscPut(self: *Self, byte: u8) void {
            if (self.osc_overflow) return;

            if (self.osc_len == self.osc_buf.len) {
                self.osc_overflow = true;
                return;
            }

            self.osc_buf[self.osc_len] = byte;
            self.osc_len += 1;
        }

        pub fn oscPutSlice(self: *Self, bytes: []const u8) void {
            if (self.osc_overflow) return;

            const remaining = self.osc_buf.len - self.osc_len;
            const n = @min(bytes.len, remaining);

            @memcpy(self.osc_buf[self.osc_len..][0..n], bytes[0..n]);
            self.osc_len += n;

            if (n < bytes.len) self.osc_overflow = true;
        }

        pub fn oscEnd(self: *Self) void {
            if (self.osc_overflow) {
                self.osc_overflow = false;
                self.osc_len = 0;
                return;
            }

            const data = self.osc_buf[0..self.osc_len];
            const sep = std.mem.indexOfScalar(u8, data, ';') orelse {
                // No ';' treat entire string as code with no payload
                const code = std.fmt.parseInt(u16, data, 10) catch return;
                dispatcher.Osc.dispatch(option, self, code, "");
                return;
            };

            const code = std.fmt.parseInt(u16, data[0..sep], 10) catch return;
            const payload = data[sep + 1 ..];
            dispatcher.Osc.dispatch(option, self, code, payload);
        }

        pub fn hook(self: *Self, final: u8, intermediates: []const u8, params: []const Parameter) void {
            _ = params;
            // Identify the DCS type by intermediate + final
            if (intermediates.len == 1 and intermediates[0] == '$' and final == 'q') {
                self.dcs_kind = .decrqss; // DECRQSS; request status string
            } else if (final == 'q' and intermediates.len == 0) {
                self.dcs_kind = .sixel; // SIXEL graphics
            } else {
                self.dcs_kind = .unknown;
            }

            self.dcs_len = 0;
            self.dcs_overflow = false;
        }

        pub fn dcsPut(self: *Self, byte: u8) void {
            if (self.dcs_overflow) return;
            if (self.dcs_len == self.dcs_buf.len) {
                self.dcs_overflow = true;
                return;
            }

            self.dcs_buf[self.dcs_len] = byte;
            self.dcs_len += 1;
        }

        pub fn dcsPutSlice(self: *Self, bytes: []const u8) void {
            if (self.dcs_overflow) return;

            const remaining = self.dcs_buf.len - self.dcs_len;
            const n = @min(bytes.len, remaining);

            @memcpy(self.dcs_buf[self.dcs_len..][0..n], bytes[0..n]);
            self.dcs_len += n;
            if (n < bytes.len) self.dcs_overflow = true;
        }

        pub fn unhook(self: *Self) void {
            if (!self.dcs_overflow) {
                switch (self.dcs_kind) {
                    .decrqss => {}, // FIXME dispatcher.Dcs.decrqss(option, self, data),
                    .sixel => {}, // FIXME dispatcher.Dcs.sixel(option, self, data),
                    .unknown => {},
                }
            }

            self.dcs_kind = .unknown;
            self.dcs_len = 0;
            self.dcs_overflow = false;
        }

        pub fn setAnswerback(self: *Self, s: []const u8) void {
            const len = @min(s.len, max_answerback_len);
            @memcpy(self.answerback[0..len], s[0..len]);
            self.answerback_len = @intCast(len);
        }

        pub fn getAnswerback(self: *const Self) []const u8 {
            return self.answerback[0..self.answerback_len];
        }

        /// Set Cursor Style (DECSCUSR / CSI Ps SP q).
        ///
        /// Controls cursor shape and blink state. This is a terminal-level setting:
        /// it survives alternate-screen switches and is NOT saved/restored by DECSC.
        ///
        /// Ps = 0 or 1    blinking block (default)
        /// Ps = 2         steady block
        /// Ps = 3         blinking underline
        /// Ps = 4         steady underline
        /// Ps = 5         blinking bar (I-beam)
        /// Ps = 6         steady bar (I-beam)
        /// Any other      reset to default
        pub fn setCursorStyle(self: *Self, ps: u16) void {
            self.active().cursor.style = switch (ps) {
                0, 1 => .blinking_block,
                2 => .steady_block,
                3 => .blinking_underline,
                4 => .steady_underline,
                5 => .blinking_beam,
                6 => .steady_beam,
                else => .default,
            };
            self.active().markDirty(self.active().cursor.row);
        }

        /// Soft Terminal Reset (DECSTR / CSI ! p).
        ///
        /// Follows the VT510 DECSTR table (DEC STD 070): of the terminal
        /// modes it resets only DECCKM (normal) and DECNKM (numeric
        /// keypad, `keypad_app`); KAM has no state here. The screen items
        /// go to `Screen.softReset` on the active screen; the inactive
        /// screen is not touched. LNM, DECARM, mouse, paste, focus,
        /// synchronized output and modifyOtherKeys are not in the table
        /// and survive.
        pub fn softReset(self: *Self) void {
            self.mode.cursor_keys = false;
            self.mode.keypad_app = false;
            self.active().softReset();
        }

        /// Hard Terminal Reset (RIS / ESC c).
        ///
        /// Resets the entire terminal to power-on state:
        ///   - Both primary and alternate screens are fully reset via Screen.hardReset()
        ///     (cells cleared, modes reset, tab stops rebuilt, scrollback cleared)
        ///   - Primary becomes the active screen again
        ///   - All Terminal.Modes reset to struct defaults
        ///   - Title and icon name cleared
        ///   - Pending events cleared
        ///
        /// Answerback string is intentionally preserved, it is user configuration,
        /// not terminal state, and survives RIS in all major terminal emulators.
        pub fn hardReset(self: *Self) void {
            self.active_buffer = .primary;

            self.parser = .{};
            self.mode = .{};

            self.input.reset();

            self.title_len = 0;
            self.icon_name_len = 0;

            self.cursor_color = null;
            self.selection_foreground = null;
            self.selection_background = null;

            self.alternate.hardReset();
            self.primary.hardReset();

            self.events.clear();
            self.events.hard_reset = true;
            self.events.selection_reset = true;

            // self.answerback / self.answerback_len intentionally preserved
        }

        fn switchScreen(self: *Self, to_alt: bool) void {
            const target: ScreenBuffer = if (to_alt) .alternate else .primary;
            if (self.active_buffer == target) return;
            self.active_buffer = target;

            self.cursor_color = null;
            self.active().dirty_rows = .full;
            self.events.selection_reset = true;
        }

        /// ANSI mode set/reset (SM = CSI h, RM = CSI l).
        pub fn setMode(self: *Self, mode: u16, set: bool) void {
            switch (mode) {
                4 => self.active().mode.insert = set,
                20 => self.mode.linefeed = set,
                else => {},
            }
        }

        /// DEC private mode set/reset (DECSET = CSI ? h, DECRST = CSI ? l).
        pub fn setDecMode(self: *Self, mode: u16, set: bool) void {
            switch (mode) {
                1 => self.mode.cursor_keys = set, // DECCKM

                3 => { // DECCOLM 80/132 column mode
                    if (!self.mode.allow_column_132) return; // no-op
                    self.mode.column_132 = set;

                    const new_cols: u16 = if (set) 132 else 80;

                    // Resize both screens to the new column count
                    self.resize(self.active().active_rows, new_cols);

                    // DECCOLM always clears the screen and homes the cursor (VT spec)
                    self.active().eraseDisplay(2);
                    self.active().cursorPos(0, 0);

                    // Reset scroll region to full active area (setActive already does this,
                    // but be explicit since the spec requires it)
                    // done by setActive

                    // Notify app to update PTY winsize
                    self.events.resize = .{ .rows = self.active().active_rows, .cols = new_cols };
                },
                5 => {
                    self.active().mode.reverse_video = set;
                    self.active().dirty_rows = .full;
                    self.active().bump();
                },
                6 => self.setDecom(set), // DECOM — origin mode
                7 => self.active().mode.auto_wrap = set, // DECAWM
                8 => self.mode.auto_repeat = set, // DECARM
                9 => self.setMouseMode(.x10, set),
                12 => {
                    self.active().cursor.style = switch (self.active().cursor.style) {
                        .blinking_block, .steady_block => if (set) .blinking_block else .steady_block,
                        .blinking_underline, .steady_underline => if (set) .blinking_underline else .steady_underline,
                        .blinking_beam, .steady_beam => if (set) .blinking_beam else .steady_beam,
                    };
                    self.active().markDirty(self.active().cursor.row);
                },
                25 => {
                    self.active().mode.cursor_visibility = set; // DECTCEM
                    self.active().markDirty(self.active().cursor.row);
                },

                40 => self.mode.allow_column_132 = set,
                // Alternate screen (old xterm, no save/restore).
                47 => {
                    self.switchScreen(set);
                    self.active().bump();
                },

                // Mouse reporting; mutually exclusive tracking modes.
                1000 => self.setMouseMode(.x10, set),
                1002 => self.setMouseMode(.button, set),
                1003 => self.setMouseMode(.any, set),

                1004 => self.mode.focus_events = set, // focus in/out
                1006 => self.mode.mouse_sgr = set, // SGR mouse encoding

                1047 => {
                    switch (set) {
                        true => {
                            self.switchScreen(true);
                            const alt = &self.alternate;
                            alt.scroll_offset = 0;
                            alt.row_map_is_identity = true;
                            alt.cached_row_phys = std.math.maxInt(u16);
                            alt.mode = .{};
                            alt.cursor = .{};
                            alt.scroll_top = 0;
                            alt.scroll_bottom = @intCast(alt.active_rows - 1);
                            @memset(alt.cells[0 .. alt.active_rows * option.max_cols], .{});
                            @memset(alt.line_attrs[0..alt.active_rows], .normal);
                            alt.grapheme_table.clearRetainingCapacity();
                            alt.grapheme_reverse.clearRetainingCapacity();
                            alt.next_grapheme_id = 0x110000;
                            _ = alt.grapheme_arena.reset(.retain_capacity);
                            alt.ext_attrs.clearRetainingCapacity();
                            alt.url_table.clearRetainingCapacity();
                            alt.charset_is_identity = true;
                        },
                        false => self.switchScreen(false),
                    }

                    self.active().bump();
                },

                // Alternate screen with save/restore cursor (xterm 1049).
                1049 => {
                    switch (set) {
                        true => {
                            self.primary.saveCursor();
                            self.switchScreen(true);
                            const alt = &self.alternate;
                            // Reset ring buffer, must happen before any physRow-dependent ops
                            alt.scroll_offset = 0;
                            alt.row_map_is_identity = true;
                            alt.cached_row_phys = std.math.maxInt(u16);
                            // Reset cursor and scroll region
                            alt.cursor = .{};
                            alt.mode = .{};
                            alt.scroll_top = 0;
                            alt.scroll_bottom = @intCast(alt.active_rows - 1);

                            // Clear cells directly, no physRow dependency
                            @memset(alt.cells[0 .. alt.active_rows * option.max_cols], .{});
                            @memset(alt.line_attrs[0..alt.active_rows], .normal);

                            alt.grapheme_table.clearRetainingCapacity();
                            alt.grapheme_reverse.clearRetainingCapacity();
                            alt.next_grapheme_id = 0x110000;
                            _ = alt.grapheme_arena.reset(.retain_capacity);
                            alt.ext_attrs.clearRetainingCapacity();
                            alt.url_table.clearRetainingCapacity();
                            alt.charset_is_identity = true;

                            if (comptime option.max_scrollback > 0) {
                                alt.scrollback_used = 0;
                                alt.viewport_offset = 0;
                            }
                            // dirty_rows already set to .full by switchScreen
                        },
                        false => {
                            self.switchScreen(false);
                            self.primary.restoreCursor();
                        },
                    }
                    self.active().bump();
                },

                2004 => self.mode.bracketed_paste = set, // bracketed paste
                2026 => self.mode.synchronized_output = set, // sync output
                else => {},
            }
        }

        /// Applies DECSCL `level` is the first parameter (61–64), and `format` is
        /// the second (1 selects 7-bit controls; 0 or 2 selects 8-bit controls).
        ///
        /// Level 1 always uses 7-bit controls and ignores `format`. Invalid
        /// levels are ignored. This also applies the DECSCL soft reset.
        pub fn decscl(self: *Self, level: u16, param: u16) void {
            self.conformance_level = switch (level) {
                61 => .level1,
                62 => .level2,
                63 => .level3,
                64 => .level4,
                else => return, // unknown level, DECSCL ignores OOR params
            };

            // Level 1 is 7-bit-controls-only; the format parameter is ignored.
            // For levels 2+, DECSCL x;0 and x;2 select 8-bit controls, x;1
            // selects 7-bit. Normalizing here means feed() can dispatch on
            // control_format alone and never see an inconsistent pair.
            self.control_format = if (self.conformance_level == .level1 or param == 1)
                .s7c1t
            else
                .s8c1t;

            self.softReset(); // DECSCL implies soft reset (DECSTR effects)
        }

        /// DECOM change: update cursor.origin and move cursor to home.
        fn setDecom(self: *Self, set: bool) void {
            self.active().cursor.origin = set;
            self.active().cursorPos(0, 0);
        }

        fn setMouseMode(self: *Self, mode: MouseMode, set: bool) void {
            if (set) {
                self.mode.mouse_x10 = false;
                self.mode.mouse_normal = false;
                self.mode.mouse_button = false;
                self.mode.mouse_any = false;
                switch (mode) {
                    .x10 => self.mode.mouse_x10 = true,
                    .normal => self.mode.mouse_normal = true,
                    .button => self.mode.mouse_button = true,
                    .any => self.mode.mouse_any = true,
                }
            } else {
                switch (mode) {
                    .x10 => self.mode.mouse_x10 = false,
                    .normal => self.mode.mouse_normal = false,
                    .button => self.mode.mouse_button = false,
                    .any => self.mode.mouse_any = false,
                }
            }
        }

        /// Queues one reply: the `intro` introducer, `fmt` formatted with
        /// `args`, then ST for string replies (DCS, OSC), all in the
        /// current C1 format. The reply is queued whole or dropped whole.
        pub fn reply(self: *Self, comptime intro: SequenceType, comptime fmt: []const u8, args: anytype) void {
            const c1 = self.control_format;
            const st = switch (intro) {
                .dcs, .osc => seqIntroducer(.st, c1),
                .csi, .st => "",
            };
            self.events.response.print("{s}" ++ fmt ++ "{s}", .{seqIntroducer(intro, c1)} ++ args ++ .{st});
        }

        /// XTVERSION reply: `DCS > | name version ST`.
        pub fn xtversion(self: *Self) void {
            self.reply(.dcs, ">|{s} {s}", .{ option.name, option.version });
        }

        /// Resize both screens to `rows` × `cols`.
        ///
        /// Called by the Tab when the window is resized (SIGWINCH).
        /// Both screens are resized so the alternate screen has the correct
        /// dimensions when it becomes active. A zero-sized grid has nowhere
        /// for the cursor to be, so each side is at least 1.
        pub fn resize(self: *Self, rows: u16, cols: u16) void {
            const r = @max(rows, 1);
            const c = @max(cols, 1);
            self.primary.setActive(r, c);
            self.alternate.setActive(r, c);
        }

        /// Set the window title (OSC 0 / OSC 2).
        pub fn setTitle(self: *Self, title: []const u8) void {
            const len = @min(title.len, max_title_len);
            @memcpy(self.title[0..len], title[0..len]);
            self.title[len] = 0;
            self.title_len = len;
        }

        /// Set the icon name (OSC 1).
        pub fn setIconName(self: *Self, name: []const u8) void {
            const len = @min(name.len, max_title_len);
            @memcpy(self.icon_name[0..len], name[0..len]);
            self.icon_name[len] = 0;
            self.icon_name_len = len;
        }

        /// Returns the current title as a null-terminated slice.
        pub fn getTitle(self: *const Self) [:0]const u8 {
            return self.title[0..self.title_len :0];
        }

        /// Returns the current icon name as a null-terminated slice.
        pub fn getIconName(self: *const Self) [:0]const u8 {
            return self.icon_name[0..self.icon_name_len :0];
        }

        /// OSC 4 ; n ; spec [; n ; spec ...] ST
        ///
        /// If spec is "?" the terminal responds with the current color value.
        pub fn setPaletteColor(self: *Self, data: []const u8) void {
            var rest = data;

            while (rest.len > 0) {
                // Parse index
                const semi1 = std.mem.indexOfScalar(u8, rest, ';') orelse break;
                const idx = std.fmt.parseInt(u8, std.mem.trim(u8, rest[0..semi1], " "), 10) catch break;
                rest = rest[semi1 + 1 ..];

                // Parse spec (up to next ';' or end)
                const semi2 = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
                const spec = std.mem.trim(u8, rest[0..semi2], " ");
                rest = if (semi2 < rest.len) rest[semi2 + 1 ..] else "";

                if (std.mem.eql(u8, spec, "?")) {
                    const color = self.active().palette.getIndexed(idx);
                    self.reply(.osc, "4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}", .{ idx, color.r, color.g, color.b });
                } else if (Rgb.parseSpec(spec)) |c| {
                    self.active().palette.setIndexed(idx, c);
                }
            }
        }

        /// Queues a mouse report for the active tracking mode and encoding.
        /// Queues nothing when mouse reporting is off.
        pub fn sendMouse(self: *Self, col: u16, row: u16, button: u8, mods: u8, press: bool) void {
            const mode = self.mode;

            // check if any mouse mode is active
            if (!mode.mouse_x10 and !mode.mouse_button and !mode.mouse_any) return;

            // X10 mode: only button press (button 0-2) no release, no motion, no scroll.
            if (mode.mouse_x10 and (!press or button > 2)) return;

            const code = button | mods;

            // SGR: ESC [ < Pb ; Px ; Py M/m
            if (mode.mouse_sgr) {
                const final: u8 = if (press) 'M' else 'm';
                self.reply(.csi, "<{d};{d};{d}{c}", .{ code, col + 1, row + 1, final });
                return;
            }

            // otherwise, X10/normal: ESC [ M Cb Cx Cy (max 223 cols/rows)
            if (col >= option.max_cols or row >= option.max_rows) return;
            const cb = if (press) code + 32 else 3 + 32;
            const cx: u8 = @truncate(col + 1 + 32);
            const cy: u8 = @truncate(row + 1 + 32);

            self.reply(.csi, "M{c}{c}{c}", .{ cb, cx, cy });
        }

        pub fn setOrQueryColor(self: *Self, data: []const u8, comptime target: ColorTarget) void {
            const spec = std.mem.trim(u8, data, " ");

            if (std.mem.eql(u8, data, "?")) {
                // Query: respond with current color
                const osc_code: u8 = switch (target) {
                    .fg => 10,
                    .bg => 11,
                    .cursor => 12,
                    .selection_bg => 17,
                    .selection_fg => 19,
                };

                const color: Rgb = switch (target) {
                    .fg => self.active().palette.get(.foreground),
                    .bg => self.active().palette.get(.background),
                    .selection_bg => self.selection_background orelse .black,
                    .selection_fg => self.selection_foreground orelse .white,
                    .cursor => self.cursor_color orelse self.active().palette.get(.foreground),
                };

                // 8-bit channels widen to 16 bits by repeating the byte.
                self.reply(.osc, "{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}", .{
                    osc_code,
                    @as(u16, color.r) * 257,
                    @as(u16, color.g) * 257,
                    @as(u16, color.b) * 257,
                });
            } else if (Rgb.parseSpec(spec)) |color| {
                switch (target) {
                    .fg => self.active().palette.set(.foreground, color),
                    .bg => self.active().palette.set(.background, color),
                    .cursor => self.cursor_color = color,
                    .selection_bg => self.selection_background = color,
                    .selection_fg => self.selection_foreground = color,
                }
            }
        }

        /// OSC 104 [; n] ST — Reset palette color n, or all colors if no arg.
        pub fn resetPaletteColor(self: *Self, data: []const u8) void {
            const s = std.mem.trim(u8, data, " ");
            if (s.len == 0) {
                // No argument: reset all 256 colors to defaults
                self.active().palette.resetAllIndexed();
            } else {
                const idx = std.fmt.parseInt(u8, s, 10) catch return;
                self.active().palette.resetIndexed(idx);
            }
        }
    };
}

/// Vectorized `b & 0x7F` into `out` — both slices same length.
fn stripInto(slice: []const u8, out: []u8) void {
    var i: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |chunk_len| {
        const Chunk = @Vector(chunk_len, u8);
        const mask: Chunk = @splat(0x7F);
        while (i + chunk_len <= slice.len) : (i += chunk_len) {
            const chunk: Chunk = slice[i..][0..chunk_len].*;
            out[i..][0..chunk_len].* = chunk & mask;
        }
    }
    while (i < slice.len) : (i += 1) out[i] = slice[i] & 0x7F;
}
