//! Terminal state: both screens, modes, the parser and the reply queue.
//! It does no I/O and must not import renderer/.

const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.target.cpu.arch.endian();

const Parser = @import("../vt/parser.zig").Parser;
const Parameter = @import("../vt/parser.zig").Parameter;

const Palette = @import("Palette.zig").Palette;
const Theme = @import("../color/Theme.zig");
const Cell = @import("cell.zig").Cell;
const Color = @import("cell.zig").Color;
const CellKind = @import("cell.zig").Kind;
const Rgb = Color.Rgb;
const Frame = @import("Frame.zig").Frame;

const Charset = @import("cell.zig").Charset;
const Screen = @import("screen.zig").Screen;
const dispatcher = @import("dispatcher.zig");
const sgr = @import("sgr.zig");

const flag_set = @import("../flag_set.zig");
const wc = @import("../unicode/wcwidth.zig");
const utf8 = @import("../unicode/utf8.zig");

const InputEngine = @import("InputEngine.zig");
const Key = @import("../input/key.zig").Key;
const Modifiers = @import("../input/key.zig").Modifiers;
const key_encoder = @import("../input/encode.zig");
pub const Clipboard = @import("Clipboard.zig");
pub const Title = @import("Title.zig");

pub const max_title_len = Title.max_len;
pub const max_answerback_len = 32;
/// Longest TERM value XTGETTCAP can report (`TermName`).
pub const max_term_name_len = 64;

const log = std.log.scoped(.term);

pub const ScreenBuffer = enum { primary, alternate };

/// A colour slot that OSC 10-19 can set or query. The tag value is the
/// OSC code (xterm ctlseqs, "Operating System Commands").
pub const DynamicColor = enum(u8) {
    fg = 10,
    bg = 11,
    cursor = 12,
    selection_bg = 17,
    selection_fg = 19,
};

/// A 0-based cell position. Replies that report one add 1, since the
/// wire format is 1-based.
pub const CellPosition = struct { row: u16, col: u16 };

/// One reply to the host, as a value. `Terminal.reply` encodes it in the
/// current C1 format and queues it through `Events.Response`, so every
/// reply shares one overflow policy: queued whole or dropped whole.
pub const Reply = union(enum) {
    /// ENQ: the configured answerback string, sent as is.
    answerback: []const u8,
    /// DA1 (CSI c), also sent for DECID (ESC Z) as xterm does: VT220 with
    /// ANSI colour (22) and clipboard access (52), which OSC 52 writes
    /// provide (#83).
    primary_attributes,
    /// DA2 (CSI > c): CSI > 1 ; 0 ; 0 c.
    secondary_attributes,
    /// DSR 5, operating status: CSI 0 n, meaning no malfunction.
    status_ok,
    /// CPR (DSR 6). Under DECOM the row counts from the top margin.
    cursor_position: CellPosition,
    /// DECXCPR (CSI ? 6 n): as CPR, with the DEC private marker and, at
    /// level 4, the page number 1 (xterm, VT420).
    dec_cursor_position: CellPosition,
    /// XTVERSION (CSI > q): DCS > | name version ST.
    xtversion,
    /// DECRQSS reply to a request Rex answers: DCS 1 $ r Pt ST, where Pt
    /// is the control that sets the requested state (xterm's `1` for
    /// valid; the VT420 manual uses the opposite digits).
    status_string: []const u8,
    /// DECRQSS reply to an unknown or unsupported request: DCS 0 $ r ST.
    status_string_invalid,
    /// DECRPM for an ANSI mode, answering DECRQM (CSI Ps $ p):
    /// CSI Ps ; Pm $ y.
    mode_report: ModeState,
    /// DECRPM for a DEC private mode, answering DECRQM (CSI ? Ps $ p):
    /// CSI ? Ps ; Pm $ y.
    dec_mode_report: ModeState,
    /// OSC 4 query reply, with the palette's 8-bit channels.
    palette_color: struct { index: u8, rgb: Rgb },
    /// OSC 10-19 query reply. Each 8-bit channel is widened to 16 bits
    /// by repeating the byte, as xterm does.
    dynamic_color: struct { slot: DynamicColor, rgb: Rgb },
    /// SGR mouse report (mode 1006): CSI < Pb ; Px ; Py M or m.
    mouse_sgr: struct { code: u8, at: CellPosition, press: bool },
    /// X10/normal mouse report: CSI M Cb Cx Cy, each byte offset by 32.
    /// Positions past `mouse_x10_max` cannot be encoded.
    mouse_x10: struct { code: u8, at: CellPosition },

    /// Largest 0-based row or column the X10 encoding can carry: the
    /// byte is 32 + 1 + position and must fit in a u8.
    pub const mouse_x10_max: u16 = 255 - 32 - 1;

    pub const ModeState = struct { mode: u16, state: DecModeReport };
};

/// A mode's state as DECRPM reports it (VT510): the reply's Ps value.
pub const DecModeReport = enum(u3) {
    not_recognized = 0,
    set = 1,
    reset = 2,
    permanently_set = 3,
    permanently_reset = 4,

    pub fn of(is_set: bool) DecModeReport {
        return if (is_set) .set else .reset;
    }
};

/// Terminal-wide modes. They survive screen switches and DECSC.
pub const Mode = struct {
    /// DECCKM (CSI ? 1 h): application cursor keys.
    cursor_keys: bool = false,
    /// LNM (CSI 20 h): LF, VT and FF also do CR.
    linefeed: bool = false,
    /// DECKPAM (ESC =) and DECKPNM (ESC >): application keypad.
    keypad_app: bool = false,
    /// DECARM (CSI ? 8 h): key auto-repeat.
    auto_repeat: bool = true,
    /// Which mouse events are reported. Only one tracking mode is active.
    mouse_tracking: MouseTracking = .off,
    /// SGR mouse encoding (CSI ? 1006 h / l).
    mouse_sgr: bool = false,
    /// Bracketed paste (CSI ? 2004 h).
    bracketed_paste: bool = false,
    /// Focus in and out reports (CSI ? 1004 h).
    focus_events: bool = false,
    /// Synchronized output (CSI ? 2026 h).
    synchronized_output: bool = false,
    /// xterm modifyOtherKeys level (CSI > 4 ; Pv m).
    modify_other_keys: key_encoder.ModifyOtherKeys = .off,
    /// Alternate scroll (CSI ? 1007 h): on the alternate screen, with mouse
    /// reporting off, the wheel sends cursor up and down keys instead of
    /// scrolling. On by default, unlike xterm's `alternateScroll`
    /// resource (default false), so full-screen programs scroll as before.
    alt_scroll: bool = true,
    /// DECCOLM (CSI ? 3 h): 132 columns.
    column_132: bool = false,
    /// CSI ? 40 h: allow DECCOLM to switch columns.
    allow_column_132: bool = true,

    const Self = @This();

    /// True when any mouse tracking mode is on.
    pub fn isMouseReporting(mode: *const Self) bool {
        return mode.mouse_tracking != .off;
    }
};

/// Mouse tracking modes (xterm ctlseqs, "Mouse Tracking"). Setting one
/// replaces the current one, and resetting any of them turns tracking
/// off, as xterm does.
pub const MouseTracking = enum {
    off,
    /// Mode 9: button presses only, without modifiers.
    x10,
    /// Mode 1000: presses, releases and wheel, with modifiers.
    normal,
    /// Mode 1002: as normal, plus motion while a button is held.
    button_motion,
    /// Mode 1003: as normal, plus all motion.
    any_motion,

    /// True when wheel events go to the host instead of scrolling.
    pub fn reportsWheel(tracking: MouseTracking) bool {
        return switch (tracking) {
            .normal, .button_motion, .any_motion => true,
            .off, .x10 => false,
        };
    }

    /// True when mouse motion events may be reported to the host.
    pub fn reportsMotion(tracking: MouseTracking) bool {
        return switch (tracking) {
            .button_motion, .any_motion => true,
            .off, .x10, .normal => false,
        };
    }
};

/// A mouse button, numbered as xterm reports it.
pub const MouseButton = enum(u2) {
    left = 0,
    middle = 1,
    right = 2,
};

/// The mouse buttons held down, so motion reports can name the one
/// being dragged.
pub const HeldButtons = struct {
    mask: u3 = 0,
    last: ?MouseButton = null,

    /// Records a press of `button`.
    pub fn press(self: *HeldButtons, button: MouseButton) void {
        self.mask |= bit(button);
        self.last = button;
    }

    /// Records a release of `button`.
    pub fn release(self: *HeldButtons, button: MouseButton) void {
        self.mask &= ~bit(button);
        if (self.last == button) self.last = null;
    }

    /// True while `button` is held.
    pub fn isHeld(self: HeldButtons, button: MouseButton) bool {
        return self.mask & bit(button) != 0;
    }

    /// The button a motion report names: the last one pressed while it
    /// is held, else the lowest held, else null.
    pub fn dragged(self: HeldButtons) ?MouseButton {
        if (self.last) |button| return button;
        if (self.mask == 0) return null;
        return @enumFromInt(@ctz(self.mask));
    }

    fn bit(button: MouseButton) u3 {
        return @as(u3, 1) << @intFromEnum(button);
    }
};

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
    /// Most decoded bytes one OSC 52 write can hold; a larger write is
    /// dropped whole (ADR 0006). Allocated once in `Terminal.create`.
    max_clipboard_bytes: usize = 1 << 20,

    /// 4096 ring rows, a power of two.
    pub const compact = Option{
        .max_rows = 200,
        .max_cols = 80,
        .max_scrollback = 3896,
    };

    /// 8192 ring rows, a power of two.
    pub const standard = Option{
        .max_rows = 500,
        .max_cols = 120,
        .max_scrollback = 7692,
    };

    /// 16384 ring rows, a power of two.
    pub const heavy = Option{
        .max_rows = 1000,
        .max_cols = 200,
        .max_scrollback = 15384,
    };

    /// An option with at least `min_scrollback` lines, grown so the ring
    /// fills a power of two.
    pub fn optimized(max_rows: usize, max_cols: usize, min_scrollback: usize) Option {
        const target_logical = max_rows + min_scrollback;
        const ring_rows = std.math.ceilPowerOfTwo(usize, target_logical) catch target_logical;

        return .{
            .max_rows = max_rows,
            .max_cols = max_cols,
            .max_scrollback = ring_rows -| max_rows,
        };
    }
};

/// Bounded reply queue, in query order. A reply is queued whole or
/// dropped whole and counted, never truncated.
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

    /// A writer over the free space, for a reply built in place. Queue
    /// what it wrote with `commit`; a write that fails leaves the queue
    /// as it was.
    pub fn writer(self: *Response) std.Io.Writer {
        return .fixed(self.buf[self.len..]);
    }

    /// Queues what `w`, from `writer`, wrote as one reply.
    pub fn commit(self: *Response, w: *const std.Io.Writer) void {
        std.debug.assert(self.len + w.end <= capacity);
        self.len += w.end;
    }

    /// The queued replies, oldest first. Valid until the next write
    /// or `clear`.
    pub fn slice(self: *const Response) []const u8 {
        return self.buf[0..self.len];
    }

    /// True when no reply is queued.
    pub fn isEmpty(self: *const Response) bool {
        return self.len == 0;
    }

    /// Empties the queue after the host has written it. Keeps
    /// `dropped`.
    pub fn clear(self: *Response) void {
        self.len = 0;
    }
};

/// What a `feed` asks the caller to do. Coalesced host signals inspected
/// by the caller on each update.
/// Strongly typed bit flags for terminal emulation protocol events.
/// Bits 0 through 5 hold protocol events. Bit 8 indicates a pending resize payload.
pub const EventBits = packed struct(u32) {
    bell: bool = false,
    title: bool = false,
    icon_name: bool = false,
    cursor_color: bool = false,
    selection_reset: bool = false,
    hard_reset: bool = false,
    _pad_host: u2 = 0,
    resize: bool = false,
    /// An OSC 52 request is pending; take it with `takeClipboard`.
    clipboard: bool = false,
    _pad: u22 = 0,
};

pub const EventSet = flag_set.IntegerSet(EventBits);

comptime {
    std.debug.assert(@sizeOf(EventSet) == 4);
}

/// Side-effects reported by the terminal across byte streams.
pub const Events = struct {
    flags: EventSet = .empty,
    resize: Resize = .{ .rows = 0, .cols = 0 },

    pub const Resize = struct { rows: u16, cols: u16 };
    pub const Field = std.meta.FieldEnum(EventBits);

    /// Sets an event flag.
    pub inline fn set(self: *Events, comptime field: Field) void {
        self.flags.insert(field);
    }

    /// True if an event flag is set.
    pub inline fn has(self: Events, comptime field: Field) bool {
        return self.flags.has(field);
    }

    /// Returns the underlying bitfield struct.
    pub inline fn bits(self: Events) EventBits {
        return self.flags.bits;
    }

    /// True when any event flag is set.
    pub inline fn any(self: Events) bool {
        return self.flags.any();
    }

    /// Clears every event.
    pub inline fn clear(self: *Events) void {
        self.* = .{};
    }

    /// Returns the resize payload if the resize flag is set.
    pub inline fn getResize(self: Events) ?Resize {
        return if (self.has(.resize)) self.resize else null;
    }
};

comptime {
    std.debug.assert(@sizeOf(Events) == 8);
    std.debug.assert(@alignOf(Events) == 4);
}

/// Operating level set by DECSCL (VT510). The tag is the DECSCL
/// parameter.
pub const ConformanceLevel = enum(u8) {
    /// VT100, 7-bit controls only.
    level1 = 61,
    /// VT200.
    level2 = 62,
    /// VT300.
    level3 = 63,
    /// VT400. Accepted, with no level 4 features yet.
    level4 = 64,
};

/// How replies send C1 controls: S7C1T (ESC SP F) or S8C1T (ESC SP G).
pub const ControlFormat = enum(u8) {
    /// As ESC plus a 7-bit byte.
    s7c1t,
    /// As one 8-bit byte.
    s8c1t,
};

pub const Encoding = InputEngine.Encoding;

/// A control that opens or closes a reply sequence.
pub const SequenceType = enum(u2) {
    // zig fmt: off
    st  = 0, csi = 1, dcs = 2, osc = 3,
    const count = 4;
    // zig fmt: on
};

/// Each `SequenceType` in each `ControlFormat`.
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

/// The bytes for `target` in `c1_mode`.
pub fn seqIntroducer(comptime target: SequenceType, c1_mode: ControlFormat) []const u8 {
    return sequence_table[@intFromEnum(c1_mode)][@intFromEnum(target)];
}

/// A TERM value, copied, for XTGETTCAP `TN`. It holds no pointers, so it
/// can cross threads and outlive the config it came from.
pub const TermName = struct {
    buf: [max_term_name_len]u8 = undefined,
    len: u8 = 0,

    comptime {
        std.debug.assert(max_term_name_len <= std.math.maxInt(u8));
    }

    /// No name: XTGETTCAP treats `TN` as unknown.
    pub const empty: TermName = .{};

    /// Copies `name`. A name longer than `max_term_name_len` is refused,
    /// not cut, so `TN` is never answered with a wrong name.
    pub fn init(name: []const u8) error{TermNameTooLong}!TermName {
        if (name.len > max_term_name_len) return error.TermNameTooLong;
        var result: TermName = .{ .len = @intCast(name.len) };
        @memcpy(result.buf[0..name.len], name);
        return result;
    }

    pub fn slice(self: *const TermName) []const u8 {
        return self.buf[0..self.len];
    }
};

/// A capability XTGETTCAP can report: a fixed value, or a key, whose
/// value is what the key encoder sends for it in the current modes.
const Termcap = union(enum) {
    colors,
    rgb,
    name,
    key: struct { key: Key, mods: Modifiers = .none },
};

/// Key capabilities by their terminfo and termcap names, from xterm's
/// table (`xtermcap.c`), for the keys Rex has. Left out, so reported as
/// unknown: F13 and up, Help, Find, Select, Clear and Undo, which `Key`
/// lacks, and `kent` and the keypad names (`kp1`, `kpADD`, ...), which
/// xterm 390 reports as unknown too.
const key_caps = [_]struct { names: []const []const u8, key: Key, shift: bool = false }{
    .{ .names = &.{ "khome", "kh" }, .key = .home },
    .{ .names = &.{ "kend", "@7" }, .key = .end },
    .{ .names = &.{ "kcub1", "kl" }, .key = .left },
    .{ .names = &.{ "kcuf1", "kr" }, .key = .right },
    .{ .names = &.{ "kcuu1", "ku" }, .key = .up },
    .{ .names = &.{ "kcud1", "kd" }, .key = .down },
    .{ .names = &.{ "kind", "kF" }, .key = .down, .shift = true },
    .{ .names = &.{ "kri", "kR" }, .key = .up, .shift = true },
    .{ .names = &.{ "kf1", "k1" }, .key = .f1 },
    .{ .names = &.{ "kf2", "k2" }, .key = .f2 },
    .{ .names = &.{ "kf3", "k3" }, .key = .f3 },
    .{ .names = &.{ "kf4", "k4" }, .key = .f4 },
    .{ .names = &.{ "kf5", "k5" }, .key = .f5 },
    .{ .names = &.{ "kf6", "k6" }, .key = .f6 },
    .{ .names = &.{ "kf7", "k7" }, .key = .f7 },
    .{ .names = &.{ "kf8", "k8" }, .key = .f8 },
    .{ .names = &.{ "kf9", "k9" }, .key = .f9 },
    .{ .names = &.{ "kf10", "k;" }, .key = .f10 },
    .{ .names = &.{ "kf11", "F1" }, .key = .f11 },
    .{ .names = &.{ "kf12", "F2" }, .key = .f12 },
    .{ .names = &.{ "kcbt", "kB" }, .key = .tab, .shift = true },
    .{ .names = &.{ "kdch1", "kD" }, .key = .delete },
    .{ .names = &.{ "kich1", "kI" }, .key = .insert },
    .{ .names = &.{ "knp", "kN" }, .key = .page_down },
    .{ .names = &.{ "kpp", "kP" }, .key = .page_up },
    .{ .names = &.{ "kbs", "kb" }, .key = .backspace },
    // Termcap names of shifted keys; their terminfo names are in
    // `modified_key_caps`.
    .{ .names = &.{"#2"}, .key = .home, .shift = true },
    .{ .names = &.{"*7"}, .key = .end, .shift = true },
    .{ .names = &.{"#4"}, .key = .left, .shift = true },
    .{ .names = &.{"%i"}, .key = .right, .shift = true },
    .{ .names = &.{"%c"}, .key = .page_down, .shift = true },
    .{ .names = &.{"%e"}, .key = .page_up, .shift = true },
};

/// ncurses' names for modified keys (xterm's `DGRP`): the bare name is
/// the key with Shift, and a suffix 3 to 8 is xterm's modifier parameter
/// (1 + Shift + 2 Alt + 4 Ctrl), so `kDN5` is Ctrl+Down.
const modified_key_caps = [_]struct { []const u8, Key }{
    .{ "kDN", .down },     .{ "kLFT", .left },  .{ "kRIT", .right },
    .{ "kUP", .up },       .{ "kDC", .delete }, .{ "kEND", .end },
    .{ "kHOM", .home },    .{ "kIC", .insert }, .{ "kNXT", .page_down },
    .{ "kPRV", .page_up },
};

const TermcapEntry = struct { []const u8, Termcap };

const termcap_entries = blk: {
    var names: usize = 5;
    for (key_caps) |cap| names += cap.names.len;
    names += modified_key_caps.len * 7;

    var entries: [names]TermcapEntry = undefined;
    entries[0..5].* = .{
        .{ "Co", .colors }, .{ "colors", .colors }, .{ "RGB", .rgb },
        .{ "TN", .name },   .{ "name", .name },
    };
    var n: usize = 5;
    for (key_caps) |cap| for (cap.names) |name| {
        entries[n] = .{ name, .{ .key = .{ .key = cap.key, .mods = .{ .shift = cap.shift } } } };
        n += 1;
    };
    for (modified_key_caps) |cap| for (2..9) |param| {
        const bits = param - 1;
        const name = if (param == 2) cap[0] else cap[0] ++ .{'0' + param};
        entries[n] = .{ name, .{ .key = .{ .key = cap[1], .mods = .{
            .shift = bits & 1 != 0,
            .alt = bits & 2 != 0,
            .ctrl = bits & 4 != 0,
        } } } };
        n += 1;
    };
    std.debug.assert(n == names);
    break :blk entries;
};

/// The longest capability name, which sizes `parseTermcapName`'s buffer.
const max_termcap_name_len = blk: {
    var max: usize = 0;
    for (termcap_entries) |entry| max = @max(max, entry[0].len);
    break :blk max;
};

/// Termcap and terminfo names for each `Termcap`, as in xterm's table
/// (`xtermcap.c`).
const termcap_names: std.StaticStringMap(Termcap) = .initComptime(termcap_entries);

/// The first name of an XTGETTCAP request: `hex`, the run of hex digits
/// xterm consumes (`xstrings.c` x_decode_hex), echoed as received, and the
/// capability it names. `cap` is null when the digits are odd in number,
/// the run ends on something other than `;` or the end of the request,
/// or the name is not one Rex answers.
const TermcapName = struct { hex: []const u8, cap: ?Termcap };

fn parseTermcapName(request: []const u8) TermcapName {
    var end: usize = 0;
    while (end < request.len and std.ascii.isHex(request[end])) end += 1;
    const hex = request[0..end];
    const terminated = end == request.len or request[end] == ';';
    var buf: [max_termcap_name_len]u8 = undefined;
    if (!terminated or hex.len == 0 or hex.len % 2 != 0 or hex.len / 2 > buf.len) {
        return .{ .hex = hex, .cap = null };
    }
    const name = std.fmt.hexToBytes(&buf, hex) catch unreachable; // even, hex, fits
    return .{ .hex = hex, .cap = termcap_names.get(name) };
}

/// A terminal: feed it pty output, then read `active()` and `events`.
///
/// It allocates only in `create` and does no I/O. It holds no pointers
/// into itself, so it can be moved. Both screens share one type, so the
/// alternate screen carries scrollback it never uses.
///
///   var t = try Terminal(opt).create(alloc);
///   defer t.destroy(alloc);
///   t.feed(chunk);
pub fn Terminal(comptime option: Option) type {
    return struct {
        const Self = @This();

        pub const ScreenType = Screen(option);
        pub const FrameType = Frame(option);

        primary: ScreenType,
        alternate: ScreenType,

        /// The screen that receives output. Read it through `active`.
        active_buffer: ScreenBuffer = .primary,
        mode: Mode = .{},

        /// The window title (OSC 0 and 2), the icon name (OSC 1) and the
        /// titles XTWINOPS 22 saved for 23 to restore.
        title: Title = .{},
        /// ENQ reply, set by the user. RIS keeps it.
        answerback: [max_answerback_len]u8 = std.mem.zeroes([max_answerback_len]u8),
        answerback_len: u8 = 0,
        /// The TERM value the shell started with, reported by XTGETTCAP
        /// `TN`. Set by the host; RIS keeps it.
        term_name: TermName = .empty,

        parser: Parser(Self, .{}),
        events: Events = .{},
        response: Response = .{},
        conformance_level: ConformanceLevel = .level3,
        control_format: ControlFormat = .s7c1t,

        /// Where the bytes of the OSC in progress go: `osc_buf`, or, once
        /// it starts with `52;`, the clipboard decoder.
        osc_mode: enum { collect, clipboard } = .collect,
        /// OSC 52 decoding and the pending clipboard request.
        clipboard: Clipboard,
        /// The OSC string being collected. One longer than the buffer is dropped.
        osc_buf: [1024]u8 = undefined,
        osc_len: usize = 0,
        osc_overflow: bool = false,

        /// The DCS string being collected. One longer than the buffer is dropped.
        dcs_buf: [1024]u8 = undefined,
        dcs_len: usize = 0,
        dcs_overflow: bool = false,
        dcs_kind: enum { unknown, decrqss, xtgettcap, sixel } = .unknown,

        /// UTF-8 decoding, grapheme clustering and widths for text.
        input: InputEngine = .init(option.ambiguous_width),

        /// Colours set by OSC 12, 17 and 19. Null means the default.
        cursor_color: ?Color.Rgb = null,
        selection_foreground: ?Color.Rgb = null,
        selection_background: ?Color.Rgb = null,
        /// The 256 colors and the default foreground and background, shared
        /// by both screens as in xterm (one `Acolors` per terminal, #69).
        palette: Palette = .empty,

        pub const ColorTarget = DynamicColor;

        /// Allocates both screens and the clipboard buffer. Release with
        /// `destroy`.
        pub fn create(alloc: std.mem.Allocator) !Self {
            var primary: ScreenType = try .create(alloc);
            errdefer primary.destroy(alloc);
            var alternate: ScreenType = try .create(alloc);
            errdefer alternate.destroy(alloc);

            return .{
                .primary = primary,
                .alternate = alternate,
                .clipboard = try .init(alloc, option.max_clipboard_bytes),
                .parser = .{},
                .events = .{},
            };
        }

        /// Frees both screens and the clipboard buffer. `alloc` must be the
        /// one `create` used.
        pub fn destroy(self: *Self, alloc: std.mem.Allocator) void {
            self.primary.destroy(alloc);
            self.alternate.destroy(alloc);
            self.clipboard.deinit(alloc);
            self.* = undefined;
        }

        /// The screen that output currently goes to.
        pub inline fn active(self: *Self) *ScreenType {
            return switch (self.active_buffer) {
                .primary => &self.primary,
                .alternate => &self.alternate,
            };
        }

        /// Feeds pty output. A chunk may end anywhere, even inside a
        /// sequence or a UTF-8 character; call `end` when the stream ends.
        pub fn feed(self: *Self, bytes: []const u8) void {
            // A sequence in `bytes` can change the path (ESC % G, ESC % @,
            // S7C1T, S8C1T, DECSCL). Each path returns as soon as that
            // happens, so the rest of the chunk takes the new path and the
            // result never depends on where a read split the stream.
            var rest = bytes;
            while (rest.len > 0) {
                const n = switch (self.feedPath()) {
                    .utf8 => self.feedUtf8(rest),
                    // Every byte in 8-bit Latin-1 is already a code point or
                    // a C1 control, so high bytes go straight to the parser.
                    .latin1_c1 => self.feedLatin1(rest, .c1),
                    .latin1_ignore => self.feedLatin1(rest, .ignore),
                    .latin1_strip => self.feedLatin1(rest, .strip),
                };
                std.debug.assert(n > 0);
                rest = rest[n..];
            }

            self.active().bump();
        }

        const FeedPath = enum { utf8, latin1_c1, latin1_ignore, latin1_strip };

        /// How `feed` routes bytes in the current encoding and control mode.
        fn feedPath(self: *const Self) FeedPath {
            return switch (self.input.encoding) {
                .utf8 => .utf8,
                .latin1 => switch (self.control_format) {
                    .s8c1t => .latin1_c1,
                    .s7c1t => switch (self.conformance_level) {
                        .level1 => .latin1_strip,
                        else => .latin1_ignore,
                    },
                },
            };
        }

        /// Feeds a prefix of `bytes` in a Latin-1 path and returns its
        /// length: all of it, or up to where a sequence changed the path.
        /// ASCII runs, which every path treats alike, go to the parser
        /// whole; the path is checked again before the high bytes after
        /// each one.
        ///
        /// High bytes per policy:
        ///   - `.c1`: to the parser, 0x80-0x9F as C1 controls.
        ///   - `.ignore`: C1s are dropped, not masked, so "A\x9CB" prints
        ///     "AB" with no invisible byte dispatched; 0xA0-0xFF print.
        ///   - `.strip`: masked to 7 bits (VT100). A masked byte can be ESC,
        ///     so these go one at a time.
        fn feedLatin1(self: *Self, bytes: []const u8, comptime policy: enum { c1, ignore, strip }) usize {
            // TODO! If latin1 ever matters for throughput, the scanUntil engine
            // applies to both runs. Until that need exists, scalar is fine for
            // a compat path.
            const path = self.feedPath();
            var i: usize = 0;
            while (i < bytes.len) {
                var ascii_end = i;
                while (ascii_end < bytes.len and bytes[ascii_end] < 0x80) ascii_end += 1;
                if (ascii_end > i) {
                    self.parser.feedBytes(self, bytes[i..ascii_end]);
                    i = ascii_end;
                    if (self.feedPath() != path) return i;
                }

                var high_end = i;
                while (high_end < bytes.len and bytes[high_end] >= 0x80) high_end += 1;
                switch (policy) {
                    .c1 => self.parser.feedBytes(self, bytes[i..high_end]),
                    .ignore => {
                        var start = i;
                        for (bytes[i..high_end], i..) |b, j| if (b <= 0x9F) {
                            if (start < j) self.parser.feedBytes(self, bytes[start..j]);
                            start = j + 1;
                        };
                        if (start < high_end) self.parser.feedBytes(self, bytes[start..high_end]);
                    },
                    .strip => while (i < high_end) {
                        self.parser.feedBytes(self, &.{bytes[i] & 0x7F});
                        i += 1;
                        if (self.feedPath() != path) return i;
                    },
                }
                i = high_end;
                if (self.feedPath() != path) return i;
            }
            return i;
        }

        /// Feeds a chunk, not necessarily the end of the stream.
        /// Call end() only when the stream actually ends.
        /// Returns how many bytes it took: all of them, or up to where ESC % @
        /// switched to Latin-1.
        fn feedUtf8(self: *Self, bytes: []const u8) usize {
            var i: usize = 0;
            while (i < bytes.len) {
                if (self.input.encoding != .utf8) return i;
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
            return i;
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

        /// Ends the stream: a partial UTF-8 character becomes U+FFFD and
        /// the pending cluster is drawn.
        pub fn end(self: *Self) void {
            self.input.finish(self.active());
            self.active().bump();
        }

        // Parser callbacks, from here to `unhook`.

        pub inline fn printByte(self: *Self, byte: u8) void {
            self.active().putChar(byte);
        }

        pub inline fn print(self: *Self, bytes: []const u8) void {
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
            self.osc_mode = .collect;
            self.osc_len = 0;
            self.osc_overflow = false;
        }

        pub fn oscPut(self: *Self, byte: u8) void {
            switch (self.osc_mode) {
                .clipboard => return self.clipboard.put(&.{byte}),
                .collect => {},
            }
            if (self.osc_overflow) return;

            if (self.osc_len == self.osc_buf.len) {
                self.osc_overflow = true;
                return;
            }

            self.osc_buf[self.osc_len] = byte;
            self.osc_len += 1;

            if (self.osc_len == osc52_prefix.len and std.mem.eql(u8, self.osc_buf[0..self.osc_len], osc52_prefix)) {
                self.osc_mode = .clipboard;
                self.clipboard.begin();
            }
        }

        /// OSC 52 data goes to the clipboard decoder instead of `osc_buf`.
        const osc52_prefix = "52;";

        pub fn oscPutSlice(self: *Self, bytes: []const u8) void {
            var rest = bytes;
            // The first bytes decide whether this is OSC 52.
            while (self.osc_mode == .collect and self.osc_len < osc52_prefix.len and rest.len > 0) {
                self.oscPut(rest[0]);
                rest = rest[1..];
            }
            if (rest.len == 0) return;
            switch (self.osc_mode) {
                .clipboard => return self.clipboard.put(rest),
                .collect => self.oscCollect(rest),
            }
        }

        fn oscCollect(self: *Self, bytes: []const u8) void {
            if (self.osc_overflow) return;

            const remaining = self.osc_buf.len - self.osc_len;
            const n = @min(bytes.len, remaining);

            @memcpy(self.osc_buf[self.osc_len..][0..n], bytes[0..n]);
            self.osc_len += n;

            if (n < bytes.len) self.osc_overflow = true;
        }

        pub fn oscEnd(self: *Self) void {
            switch (self.osc_mode) {
                .clipboard => {
                    self.osc_mode = .collect;
                    self.osc_len = 0;
                    if (self.clipboard.end()) self.events.set(.clipboard);
                    return;
                },
                .collect => {},
            }
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
            } else if (intermediates.len == 1 and intermediates[0] == '+' and final == 'q') {
                self.dcs_kind = .xtgettcap; // XTGETTCAP; request termcap/terminfo string
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
                    .decrqss => self.requestStatusString(self.dcs_buf[0..self.dcs_len]),
                    .xtgettcap => self.requestTermcap(self.dcs_buf[0..self.dcs_len]),
                    .sixel => {}, // FIXME dispatcher.Dcs.sixel(option, self, data),
                    .unknown => {},
                }
            }

            self.dcs_kind = .unknown;
            self.dcs_len = 0;
            self.dcs_overflow = false;
        }

        /// The pending OSC 52 request and, for a write, its data, valid
        /// until the next OSC 52. Leaves no request pending.
        pub fn takeClipboard(self: *Self) struct { Clipboard.Request, []const u8 } {
            return self.clipboard.take();
        }

        /// Sets the ENQ reply, cut to `max_answerback_len` bytes on a
        /// UTF-8 boundary.
        pub fn setAnswerback(self: *Self, s: []const u8) void {
            const len = utf8.truncateLen(s, max_answerback_len);
            @memcpy(self.answerback[0..len], s[0..len]);
            self.answerback_len = @intCast(len);
        }

        /// Sets the name XTGETTCAP reports for `TN` and `name`: the TERM
        /// value the shell was started with.
        pub fn setTermName(self: *Self, name: TermName) void {
            self.term_name = name;
        }

        /// The ENQ reply. Valid until the next `setAnswerback`.
        pub fn getAnswerback(self: *const Self) []const u8 {
            return self.answerback[0..self.answerback_len];
        }

        /// DECSCUSR (CSI Ps SP q): sets the active screen's cursor shape.
        /// 1 to 6 are block, underline and bar, each blinking then steady.
        /// 0 is a blinking block; other values reset the shape.
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

        /// DECSTR (CSI ! p), as xterm does it (`charproc.c` ReallyReset).
        /// It resets DECCKM, the keypad mode, modifyOtherKeys, the OSC 4
        /// colors and the active screen's state (`Screen.softReset`).
        /// Other modes, mouse tracking included, survive.
        pub fn softReset(self: *Self) void {
            self.mode.cursor_keys = false;
            self.mode.keypad_app = false;
            self.mode.modify_other_keys = .off;
            self.palette.resetAllIndexed();
            self.active().softReset();
        }

        /// RIS (ESC c): back to the power-on state, on both screens.
        /// Pending events are replaced by `hard_reset` and
        /// `selection_reset`. The answerback is a user setting, so it is
        /// kept.
        pub fn hardReset(self: *Self) void {
            self.active_buffer = .primary;

            self.parser = .{};
            self.mode = .{};
            self.conformance_level = .level3;
            self.control_format = .s7c1t;

            self.input.reset();

            self.title.reset();

            self.cursor_color = null;
            self.selection_foreground = null;
            self.selection_background = null;
            self.palette.reset();

            self.alternate.hardReset();
            self.primary.hardReset();

            self.events.clear();
            self.response.clear();
            self.events.set(.hard_reset);
            self.events.set(.selection_reset);
        }

        /// Makes the other screen active and carries the terminal-wide
        /// state over to it. In xterm only the cells and the DECSC slot
        /// belong to a buffer (`charproc.c` SwitchBufs, `cursor.c`
        /// CursorSave); modes, the cursor with its pen, shape and
        /// charsets, the margins and the tab stops stay. Rex keeps them in
        /// each `Screen`, so the inactive screen's copies are stale until
        /// the next switch (#69; moving them to `Terminal` is #77).
        fn switchScreen(self: *Self, to_alt: bool) void {
            const target: ScreenBuffer = if (to_alt) .alternate else .primary;
            if (self.active_buffer == target) return;
            const from = self.active();
            self.active_buffer = target;
            const to = self.active();

            // `resize` sizes both screens alike, so the cursor and margins fit.
            std.debug.assert(from.active_rows == to.active_rows and from.active_cols == to.active_cols);
            to.mode = from.mode;
            to.cursor = from.cursor;
            to.scroll_top = from.scroll_top;
            to.scroll_bottom = from.scroll_bottom;
            to.tab_stops = from.tab_stops;
            to.charset_is_identity = from.charset_is_identity;
            // The pen's IDs point into the other screen's style table.
            to.internPen();

            // OSC 10-19 colors and the palette belong to the terminal.
            to.dirty_rows = .full;
            self.events.set(.selection_reset);
        }

        /// SM (CSI h) and RM (CSI l). Unknown modes are ignored.
        pub fn setMode(self: *Self, mode: u16, set: bool) void {
            switch (mode) {
                4 => self.active().mode.insert = set,
                20 => self.mode.linefeed = set,
                else => {},
            }
        }

        /// The state of ANSI mode `mode`, as DECRPM reports it. IRM and
        /// LNM are real state; the rest follow xterm (`misc.c`
        /// do_ansi_rqm), with KAM and SRM fixed because Rex never locks
        /// the keyboard or echoes locally.
        pub fn ansiModeReport(self: *Self, mode: u16) DecModeReport {
            return switch (mode) {
                4 => .of(self.active().mode.insert), // IRM
                20 => .of(self.mode.linefeed), // LNM
                3 => .reset, // CRM
                1, 2, 5, 7, 10, 11, 13...19 => .permanently_reset, // GATM, KAM, SRTM, VEM, HEM, PUM, FEAM..EBM
                12 => .permanently_set, // SRM: no local echo
                else => .not_recognized,
            };
        }

        /// The state of DEC private mode `mode`, as DECRPM reports it.
        /// Modes without stored state are `.not_recognized`.
        pub fn decModeReport(self: *Self, mode: u16) DecModeReport {
            const screen_mode = self.active().mode;
            return switch (mode) {
                12 => .of(self.active().cursor.style.blink() == .on), // cursor blink, from DECSCUSR or ?12
                1 => .of(self.mode.cursor_keys), // DECCKM
                3 => .of(self.mode.column_132), // DECCOLM
                5 => .of(screen_mode.reverse_video), // DECSCNM
                6 => .of(self.active().cursor.origin), // DECOM
                7 => .of(screen_mode.auto_wrap), // DECAWM
                8 => .of(self.mode.auto_repeat), // DECARM
                25 => .of(screen_mode.cursor_visibility), // DECTCEM
                40 => .of(self.mode.allow_column_132),
                45 => .of(screen_mode.reverse_wrap),
                47, 1047, 1049 => .of(self.active_buffer == .alternate),
                1004 => .of(self.mode.focus_events),
                1007 => .of(self.mode.alt_scroll),
                1048 => .of(self.active().saved_cursor.saved),
                9 => .of(self.mode.mouse_tracking == .x10),
                1000 => .of(self.mode.mouse_tracking == .normal),
                1002 => .of(self.mode.mouse_tracking == .button_motion),
                1003 => .of(self.mode.mouse_tracking == .any_motion),
                1006 => .of(self.mode.mouse_sgr),
                2004 => .of(self.mode.bracketed_paste),
                2026 => .of(self.mode.synchronized_output),
                else => .not_recognized,
            };
        }

        /// XTMODKEYS for modifyOtherKeys (CSI > 4 ; Pv m): sets the level,
        /// or resets it to 0 when `level` is null (Pv omitted), as xterm
        /// does (`charproc.c` CASE_SET_MOD_FKEYS). Levels above 2 are
        /// ignored: the key encoder supports 0 to 2.
        pub fn setModifyOtherKeys(self: *Self, level: ?u16) void {
            self.mode.modify_other_keys = std.enums.fromInt(key_encoder.ModifyOtherKeys, level orelse 0) orelse return;
        }

        /// DECSET (CSI ? h) and DECRST (CSI ? l). Unknown modes are
        /// ignored.
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
                    self.events.set(.resize);
                    self.events.resize = .{ .rows = self.active().active_rows, .cols = new_cols };
                },
                5 => {
                    self.active().mode.reverse_video = set;
                    self.active().dirty_rows = .full;
                    self.active().bump();
                },
                6 => self.setDecom(set), // DECOM, origin mode
                7 => self.active().mode.auto_wrap = set, // DECAWM
                45 => self.active().mode.reverse_wrap = set, // xterm reverse wraparound
                8 => self.mode.auto_repeat = set, // DECARM
                9 => self.setMouseTracking(.x10, set),
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

                1000 => self.setMouseTracking(.normal, set),
                1002 => self.setMouseTracking(.button_motion, set),
                1003 => self.setMouseTracking(.any_motion, set),

                1004 => self.mode.focus_events = set, // focus in/out
                1006 => self.mode.mouse_sgr = set, // SGR mouse encoding
                1007 => self.mode.alt_scroll = set, // alternate scroll

                // Save or restore the cursor, on the active screen (xterm
                // `charproc.c` srm_SAVE_CURSOR); 1049 does it with the
                // screen switch.
                1048 => if (set) self.active().saveCursor() else self.active().restoreCursor(),

                // Alternate screen; xterm clears it when leaving, not when
                // entering (ctlseqs, `charproc.c` srm_OPT_ALTBUF).
                1047 => {
                    switch (set) {
                        true => self.switchScreen(true),
                        false => {
                            if (self.active_buffer == .alternate) self.alternate.clearForAltScreen();
                            self.switchScreen(false);
                        },
                    }

                    self.active().bump();
                },

                // Alternate screen with save/restore cursor (xterm 1049):
                // 1048 and 1047 combined, clearing on entry.
                1049 => {
                    switch (set) {
                        true => {
                            self.primary.saveCursor();
                            self.switchScreen(true);
                            self.alternate.clearForAltScreen();
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

        /// DECSCL (CSI Pl ; Pc " p): sets the level (61 to 64) and, above
        /// level 1, the C1 format (1 is 7-bit, anything else 8-bit). It soft
        /// resets. Other levels are ignored.
        pub fn decscl(self: *Self, level: u16, param: u16) void {
            self.conformance_level = switch (level) {
                61 => .level1,
                62 => .level2,
                63 => .level3,
                64 => .level4,
                else => return, // unknown level, DECSCL ignores OOR params
            };

            // Normalized here so feed() can route on control_format alone.
            self.control_format = if (self.conformance_level == .level1 or param == 1)
                .s7c1t
            else
                .s8c1t;

            self.softReset(); // DECSCL implies soft reset (DECSTR effects)
        }

        /// DECOM: sets origin mode and homes the cursor.
        fn setDecom(self: *Self, set: bool) void {
            self.active().cursor.origin = set;
            self.active().cursorPos(0, 0);
        }

        fn setMouseTracking(self: *Self, tracking: MouseTracking, set: bool) void {
            self.mode.mouse_tracking = if (set) tracking else .off;
        }

        /// Takes pending host events and clears them internally in one step.
        pub fn takeEvents(self: *Self) Events {
            const ev = self.events;
            self.events = .{};
            return ev;
        }

        /// Copies every queued reply into `out` and empties the queue.
        /// `out` holds the queue's whole capacity, so nothing is cut or
        /// left behind. Returns the number of bytes copied.
        pub fn drainReplies(self: *Self, out: *[Response.capacity]u8) usize {
            const n = self.response.len;
            @memcpy(out[0..n], self.response.buf[0..n]);
            self.response.clear();
            return n;
        }

        /// Returns how many replies were dropped whole because the queue was
        /// full, since the last call, and resets the count. The host reports
        /// it: a dropped reply leaves the program waiting for an answer.
        pub fn takeDroppedReplies(self: *Self) u32 {
            const n = self.response.dropped;
            self.response.dropped = 0;
            return n;
        }

        /// True when replies are queued for the PTY.
        pub fn hasReplies(self: *const Self) bool {
            return !self.response.isEmpty();
        }

        /// Takes a pure, self-contained viewport snapshot into `target`.
        ///
        /// Returns `true` if changes were copied, or `false` if `target` is
        /// already up to date with the terminal's visible viewport.
        ///
        /// Viewport rows are normalized to row 0 (so scrollback offsets are
        /// resolved at snapshot time). Screen dirty rows are drained and
        /// reset to `.empty`.
        /// Adds the clusters of `cells` to the frame's table. Returns false
        /// if any did not fit.
        fn addGraphemes(target: *FrameType, scr: *const ScreenType, cells: []const Cell) bool {
            var all = true;
            for (cells) |c| {
                if (!c.kind.isGrapheme()) continue;
                const cps = scr.getGrapheme(c.codepoint) orelse continue;
                if (!target.addGrapheme(c.codepoint, cps)) all = false;
            }
            return all;
        }

        pub fn snapshot(self: *Self, target: *FrameType) bool {
            const scr = self.active();
            const max_cols = option.max_cols;
            const current_cursor_color: ?[3]u8 = if (self.cursor_color) |c| .{ c.r, c.g, c.b } else null;
            const scr_viewport_offset: u32 = if (comptime option.max_scrollback > 0) scr.viewport_offset else 0;
            const scr_scrollback_used: u32 = if (comptime option.max_scrollback > 0) scr.scrollback_used else 0;
            const is_at_bottom = if (comptime option.max_scrollback > 0) scr.isAt(.bottom) else true;
            const expected_cursor_visible = scr.mode.cursor_visibility and is_at_bottom;

            const is_alt = self.active_buffer == .alternate;
            const unchanged = target.generation != 0 and
                target.generation == scr.generation and
                target.is_alternate == is_alt and
                target.viewport_offset == scr_viewport_offset and
                target.active_rows == scr.active_rows and
                target.active_cols == scr.active_cols and
                target.reverse_video == scr.mode.reverse_video and
                target.cursor.visible == expected_cursor_visible and
                target.cursor.row == scr.cursor.row and
                target.cursor.col == scr.cursor.col and
                target.cursor.style == scr.cursor.style and
                std.meta.eql(target.cursor_color, current_cursor_color);

            if (unchanged and scr.dirty_rows.count() == 0) {
                return false;
            }

            const needs_full = target.generation == 0 or
                target.is_alternate != is_alt or
                target.viewport_offset != scr_viewport_offset or
                target.active_rows != scr.active_rows or
                target.active_cols != scr.active_cols or
                target.reverse_video != scr.mode.reverse_video or
                scr.dirty_rows.count() >= scr.active_rows;

            if (needs_full) {
                target.grapheme_count = 0;
                target.dirty_rows.setRangeValue(.{ .start = 0, .end = scr.active_rows }, true);
                if (scr.active_rows < option.max_rows) {
                    target.dirty_rows.setRangeValue(.{ .start = scr.active_rows, .end = option.max_rows }, false);
                }

                var r: usize = 0;
                while (r < scr.active_rows) : (r += 1) {
                    const src_row = scr.displayRow(r);
                    const dst_row = target.cells[r * max_cols ..];
                    @memcpy(dst_row[0..scr.active_cols], src_row[0..scr.active_cols]);
                    if (scr.active_cols < max_cols) {
                        @memset(dst_row[scr.active_cols..max_cols], Cell{});
                    }
                    // Beyond the table's capacity a cluster draws as missing.
                    _ = addGraphemes(target, scr, src_row[0..scr.active_cols]);
                }
            } else {
                var table_full = false;
                target.dirty_rows = scr.dirty_rows;
                var it = scr.dirty_rows.iterator(.{});
                while (it.next()) |r| {
                    if (r >= scr.active_rows) continue;
                    const src_row = scr.displayRow(r);
                    const dst_row = target.cells[r * max_cols ..];
                    @memcpy(dst_row[0..scr.active_cols], src_row[0..scr.active_cols]);
                    if (scr.active_cols < max_cols) {
                        @memset(dst_row[scr.active_cols..max_cols], Cell{});
                    }
                    if (!addGraphemes(target, scr, src_row[0..scr.active_cols])) table_full = true;
                }
                // The table keeps clusters of rows since overwritten. When it
                // fills, start over from what is on screen now (#67).
                if (table_full) {
                    target.grapheme_count = 0;
                    for (0..scr.active_rows) |r| {
                        _ = addGraphemes(target, scr, target.cells[r * max_cols ..][0..scr.active_cols]);
                    }
                }
            }

            scr.dirty_rows = .empty;

            target.active_rows = scr.active_rows;
            target.active_cols = scr.active_cols;
            target.generation = scr.generation;
            target.seq +%= 1;
            target.palette = self.palette;
            // IDs stay valid while referenced, so the frame needs the table
            // only when it changed or the screen did (ADR 0005).
            if (needs_full or target.style_generation != scr.styles.generation) {
                target.copyStyles(scr.styles.entries[0..scr.styles.high], scr.styles.generation);
            }
            target.reverse_video = scr.mode.reverse_video;
            target.is_alternate = is_alt;
            target.scrollback_used = scr_scrollback_used;
            target.viewport_offset = scr_viewport_offset;
            target.total_lines_scrolled = scr.total_lines_scrolled;
            target.cursor = .{
                .row = scr.cursor.row,
                .col = scr.cursor.col,
                .style = scr.cursor.style,
                .visible = expected_cursor_visible,
            };
            target.cursor_color = current_cursor_color;
            target.selection_foreground = if (self.selection_foreground) |c| .{ c.r, c.g, c.b } else null;
            target.selection_background = if (self.selection_background) |c| .{ c.r, c.g, c.b } else null;

            return true;
        }

        /// Queues `r` in the current C1 format. When it does not fit, it
        /// is dropped whole and counted in `response.dropped`.
        pub fn reply(self: *Self, r: Reply) void {
            switch (r) {
                .answerback => |bytes| self.response.append(bytes),
                .primary_attributes => self.replyFmt(.csi, "?62;22;52c", .{}),
                .secondary_attributes => self.replyFmt(.csi, ">1;0;0c", .{}),
                .status_ok => self.replyFmt(.csi, "0n", .{}),
                .cursor_position => |at| self.replyFmt(.csi, "{d};{d}R", .{ @as(u32, at.row) + 1, @as(u32, at.col) + 1 }),
                .dec_cursor_position => |at| switch (self.conformance_level) {
                    .level4 => self.replyFmt(.csi, "?{d};{d};1R", .{ @as(u32, at.row) + 1, @as(u32, at.col) + 1 }),
                    else => self.replyFmt(.csi, "?{d};{d}R", .{ @as(u32, at.row) + 1, @as(u32, at.col) + 1 }),
                },
                .xtversion => self.replyFmt(.dcs, ">|{s} {s}", .{ option.name, option.version }),
                .status_string => |pt| self.replyFmt(.dcs, "1$r{s}", .{pt}),
                .status_string_invalid => self.replyFmt(.dcs, "0$r", .{}),
                .mode_report => |m| self.replyFmt(.csi, "{d};{d}$y", .{ m.mode, @intFromEnum(m.state) }),
                .dec_mode_report => |m| self.replyFmt(.csi, "?{d};{d}$y", .{ m.mode, @intFromEnum(m.state) }),
                .palette_color => |c| self.replyFmt(.osc, "4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}", .{ c.index, c.rgb.r, c.rgb.g, c.rgb.b }),
                .dynamic_color => |c| self.replyFmt(.osc, "{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}", .{
                    @intFromEnum(c.slot),
                    @as(u16, c.rgb.r) * 257,
                    @as(u16, c.rgb.g) * 257,
                    @as(u16, c.rgb.b) * 257,
                }),
                .mouse_sgr => |m| self.replyFmt(.csi, "<{d};{d};{d}{c}", .{
                    m.code,
                    @as(u32, m.at.col) + 1,
                    @as(u32, m.at.row) + 1,
                    @as(u8, if (m.press) 'M' else 'm'),
                }),
                .mouse_x10 => |m| {
                    // Drop what the encoding cannot carry rather than send
                    // a wrapped, wrong byte.
                    if (m.code > 255 - 32) return;
                    if (m.at.col > Reply.mouse_x10_max or m.at.row > Reply.mouse_x10_max) return;
                    self.replyFmt(.csi, "M{c}{c}{c}", .{
                        m.code + 32,
                        @as(u8, @intCast(m.at.col + 1 + 32)),
                        @as(u8, @intCast(m.at.row + 1 + 32)),
                    });
                },
            }
        }

        /// Formats one reply: the `intro` introducer, `fmt` with `args`,
        /// then ST for string replies (DCS, OSC).
        fn replyFmt(self: *Self, comptime intro: SequenceType, comptime fmt: []const u8, args: anytype) void {
            const c1 = self.control_format;
            const st = switch (intro) {
                .dcs, .osc => seqIntroducer(.st, c1),
                .csi, .st => "",
            };
            self.response.print("{s}" ++ fmt ++ "{s}", .{seqIntroducer(intro, c1)} ++ args ++ .{st});
        }

        /// DECRQSS (DCS $ q Pt ST): replies with the control that sets the
        /// state `request` names, as xterm does (`misc.c` do_dcs), for SGR
        /// (`m`), DECSCUSR (` q`), DECSTBM (`r`), DECSCL (`" p`) and DECSCA
        /// (`" q`). Anything else, DECSCL at level 1 included (xterm sends
        /// nothing there), gets the invalid reply.
        fn requestStatusString(self: *Self, request: []const u8) void {
            // The longest reply, an SGR with every attribute and three RGB
            // colors, is under 100 bytes.
            var buf: [160]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            const valid = self.writeStatusString(&w, request) catch unreachable;
            if (valid) self.reply(.{ .status_string = w.buffered() }) else self.reply(.status_string_invalid);
        }

        fn writeStatusString(self: *Self, w: *std.Io.Writer, request: []const u8) std.Io.Writer.Error!bool {
            const screen = self.active();
            if (std.mem.eql(u8, request, "m")) {
                try sgr.format(w, screen.cursor.attr);
            } else if (std.mem.eql(u8, request, " q")) {
                try w.print("{d}", .{@as(u8, @intFromEnum(screen.cursor.style)) + 1});
            } else if (std.mem.eql(u8, request, "r")) {
                try w.print("{d};{d}", .{ @as(u32, screen.scroll_top) + 1, @as(u32, screen.scroll_bottom) + 1 });
            } else if (std.mem.eql(u8, request, "\"p")) {
                if (self.conformance_level == .level1) return false;
                const seven_bit: u8 = if (self.control_format == .s7c1t) 1 else 0;
                try w.print("{d};{d}", .{ @intFromEnum(self.conformance_level), seven_bit });
            } else if (std.mem.eql(u8, request, "\"q")) {
                try w.writeAll("0"); // no protected attribute (DECSCA)
            } else {
                return false;
            }
            try w.writeAll(request);
            return true;
        }

        /// XTGETTCAP (DCS + q Pt ST): replies with the value of each
        /// hex-encoded name in `Pt`, separated by `;`, as xterm does
        /// (`misc.c` do_dcs): `DCS 1 + r name=value;... ST`, names echoed
        /// as received and values hex-encoded. The leading digit is 0 when
        /// the first name is unknown; the first unknown name is echoed
        /// without a value and ends the list. Rex answers `Co`/`colors`,
        /// `RGB`, `TN`/`name` and the key capabilities in `key_caps` and
        /// `modified_key_caps`. A key's value is what the key encoder
        /// sends for it in the current modes, which is how xterm answers
        /// (a synthesized key press through `Input`); a key that sends
        /// nothing has an empty value. A reply longer than the
        /// response queue is dropped and counted.
        fn requestTermcap(self: *Self, request: []const u8) void {
            var w = self.response.writer();
            if (self.writeTermcap(&w, request)) |_| {
                self.response.commit(&w);
            } else |_| {
                self.response.dropped +|= 1;
            }
        }

        fn writeTermcap(self: *const Self, w: *std.Io.Writer, request: []const u8) std.Io.Writer.Error!void {
            var rest = request;
            var key_buf: [key_encoder.max_len]u8 = undefined;
            var name = parseTermcapName(rest);
            var value = self.termcapValue(name.cap, &key_buf);
            try w.writeAll(seqIntroducer(.dcs, self.control_format));
            try w.writeAll(if (value != null) "1+r" else "0+r");
            while (rest.len > 0 and name.hex.len > 0) {
                try w.writeAll(name.hex);
                const bytes = value orelse break;
                try w.writeByte('=');
                for (bytes) |b| try w.print("{X:0>2}", .{b});
                // A known name ends the request or is followed by `;`.
                rest = rest[name.hex.len..];
                if (rest.len == 0) break;
                try w.writeByte(';');
                rest = rest[1..];
                name = parseTermcapName(rest);
                value = self.termcapValue(name.cap, &key_buf);
            }
            try w.writeAll(seqIntroducer(.st, self.control_format));
        }

        /// The plain value of `cap`, or null when Rex has none to report.
        /// The value of `cap`, or null when Rex has none. A key's value
        /// is written to `key_buf`.
        fn termcapValue(self: *const Self, cap: ?Termcap, key_buf: *[key_encoder.max_len]u8) ?[]const u8 {
            return switch (cap orelse return null) {
                .colors => "256",
                .rgb => "8", // direct colour, 8 bits per channel
                .name => if (self.term_name.len == 0) null else self.term_name.slice(),
                .key => |chord| key_encoder.encode(chord.key, chord.mods, self.keyModes(), key_buf),
            };
        }

        /// The modes the key encoder needs, as a key press would see
        /// them now.
        fn keyModes(self: *const Self) key_encoder.Modes {
            return .{
                .modify_other_keys = self.mode.modify_other_keys,
                .cursor_keys = self.mode.cursor_keys,
                .keypad_app = self.mode.keypad_app,
                .eight_bit_controls = self.control_format == .s8c1t,
            };
        }

        /// Queues the XTVERSION reply.
        pub fn xtversion(self: *Self) void {
            self.reply(.xtversion);
        }

        /// Resizes both screens to `rows` by `cols`, each clamped to at
        /// least 1 and at most `max_rows`/`max_cols` (`reflowBuffer` ignores
        /// larger sizes, so the primary would keep its old size).
        pub fn resize(self: *Self, rows: u16, cols: u16) void {
            const r: u16 = @intCast(std.math.clamp(rows, 1, option.max_rows));
            const c: u16 = @intCast(std.math.clamp(cols, 1, option.max_cols));

            if (c != self.primary.active_cols) self.primary.reflowBuffer(r, c);
            // `reflowBuffer` does nothing without scrollback, so the primary
            // would keep its old width while the pty gets the new one.
            if (self.primary.active_rows != r or self.primary.active_cols != c) {
                self.primary.setActive(r, c);
            }

            self.alternate.setActive(r, c);
        }

        /// Sets the title (OSC 0 and 2), cut to `max_title_len` bytes on
        /// a UTF-8 boundary.
        pub fn setTitle(self: *Self, title: []const u8) void {
            self.title.set(title);
            self.events.set(.title);
        }

        /// Sets the icon name (OSC 1), cut to `max_title_len` bytes on a
        /// UTF-8 boundary.
        pub fn setIconName(self: *Self, name: []const u8) void {
            self.title.setIconName(name);
            self.events.set(.icon_name);
        }

        /// XTWINOPS 22 (CSI 22 ; Ps t): saves `part` of the title and icon
        /// name on the title stack.
        pub fn pushTitle(self: *Self, part: Title.Part) void {
            self.title.push(part);
        }

        /// XTWINOPS 23 (CSI 23 ; Ps t): restores `part` from the title
        /// stack, setting the `title` and `icon_name` events for the parts
        /// it restored. Does nothing when the stack is empty.
        pub fn popTitle(self: *Self, part: Title.Part) void {
            const restored = self.title.pop(part);
            if (restored.title) self.events.set(.title);
            if (restored.icon_name) self.events.set(.icon_name);
        }

        /// The title. Valid until the next `setTitle`, `popTitle` or
        /// `hardReset`.
        pub fn getTitle(self: *const Self) []const u8 {
            return self.title.get();
        }

        /// The icon name. Valid until the next `setIconName`, `popTitle`
        /// or `hardReset`.
        pub fn getIconName(self: *const Self) []const u8 {
            return self.title.getIconName();
        }

        /// OSC 4 (n ; spec pairs): sets each palette entry, or replies
        /// with it when spec is "?". Parsing stops at the first bad index.
        pub fn setPaletteColor(self: *Self, data: []const u8) void {
            var rest = data;

            while (rest.len > 0) {
                const semi1 = std.mem.indexOfScalar(u8, rest, ';') orelse break;
                const idx = std.fmt.parseInt(u8, std.mem.trim(u8, rest[0..semi1], " "), 10) catch break;
                rest = rest[semi1 + 1 ..];

                const semi2 = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
                const spec = std.mem.trim(u8, rest[0..semi2], " ");
                rest = if (semi2 < rest.len) rest[semi2 + 1 ..] else "";

                if (std.mem.eql(u8, spec, "?")) {
                    const color = self.palette.getIndexed(idx);
                    self.reply(.{ .palette_color = .{ .index = idx, .rgb = color } });
                } else if (Rgb.parseSpec(spec)) |c| {
                    self.palette.setIndexed(idx, c);
                }
            }
        }

        /// Queues a mouse report in the active tracking mode and encoding.
        /// When off, it queues nothing. X10 mode sends only presses of buttons
        /// 0 to 2, while the caller filters motion by mode.
        pub fn sendMouse(self: *Self, col: u16, row: u16, button: u8, mods: u8, press: bool) void {
            const mode = self.mode;
            const code = switch (mode.mouse_tracking) {
                .off => return,
                .x10 => if (press and button <= 2) button else return,
                .normal, .button_motion, .any_motion => button | mods,
            };

            const at: CellPosition = .{ .row = row, .col = col };
            if (mode.mouse_sgr) {
                self.reply(.{ .mouse_sgr = .{ .code = code, .at = at, .press = press } });
                return;
            }

            // X10/normal encoding has no release button: 3 means "released".
            if (col >= option.max_cols or row >= option.max_rows) return;
            self.reply(.{ .mouse_x10 = .{ .code = if (press) code else 3, .at = at } });
        }

        /// Queues a motion report at `col`, `row`. Mode 1002 reports only
        /// while `held` is set, mode 1003 always; other modes queue
        /// nothing. The caller reports each cell once.
        pub fn sendMouseMotion(self: *Self, col: u16, row: u16, held: ?MouseButton, mods: u8) void {
            switch (self.mode.mouse_tracking) {
                .button_motion => if (held == null) return,
                .any_motion => {},
                .off, .x10, .normal => return,
            }
            // xterm ctlseqs: motion adds 32 to the button code, and 3
            // stands for no button.
            const button: u8 = if (held) |b| @intFromEnum(b) else 3;
            self.sendMouse(col, row, button + mouse_motion_flag, mods, true);
        }

        /// Added to a button code in a motion report.
        pub const mouse_motion_flag: u8 = 32;

        /// OSC 10 to 19: sets the `target` colour from `data`, or replies
        /// with it when `data` is "?".
        pub fn setOrQueryColor(self: *Self, data: []const u8, comptime target: ColorTarget) void {
            const spec = std.mem.trim(u8, data, " ");

            if (std.mem.eql(u8, data, "?")) {
                const color: Rgb = switch (target) {
                    .fg => self.palette.get(.foreground),
                    .bg => self.palette.get(.background),
                    .selection_bg => self.selection_background orelse self.palette.builtin_selection_background,
                    .selection_fg => self.selection_foreground orelse self.palette.builtin_selection_foreground,
                    .cursor => self.cursor_color orelse self.palette.get(.foreground),
                };

                self.reply(.{ .dynamic_color = .{ .slot = target, .rgb = color } });
            } else if (Rgb.parseSpec(spec)) |color| {
                switch (target) {
                    .fg => self.palette.set(.foreground, color),
                    .bg => self.palette.set(.background, color),
                    .cursor => self.cursor_color = color,
                    .selection_bg => self.selection_background = color,
                    .selection_fg => self.selection_foreground = color,
                }
            }
        }

        /// Applies `theme` to the palette.
        pub fn setTheme(self: *Self, theme: Theme) void {
            self.palette.setTheme(theme);
        }

        /// OSC 104: resets each listed palette entry, or all of them when
        /// `data` is empty. Bad entries are skipped.
        pub fn resetPaletteColor(self: *Self, data: []const u8) void {
            if (std.mem.trim(u8, data, " ").len == 0) {
                self.palette.resetAllIndexed();
                return;
            }
            var it = std.mem.splitScalar(u8, data, ';');
            while (it.next()) |field| {
                const idx = std.fmt.parseInt(u8, std.mem.trim(u8, field, " "), 10) catch continue;
                self.palette.resetIndexed(idx);
            }
        }
    };
}
