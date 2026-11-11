//! Atomic keyboard key and shortcut chord primitive.
//!
//! Renders physical keycaps for single keys and multi-key chords such as
//! `Ctrl + Shift + P` or `Esc / Q`. Chords are tokenized in place without
//! allocation, modifier and special key names are normalized to either
//! readable text or compact Unicode symbols, and each keycap is emitted as a
//! single cache-aligned SDF card quad composed through `Box`. A cell-grid
//! bracket fallback (`[Esc]`) is provided for glyph-only rendering.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tokens = @import("../color/Tokens.zig").Tokens;
const Card = @import("../renderer/Card.zig");
const input = @import("../input/key.zig");
const Rect = @import("Rect.zig").Rect;
const Padding = @import("Rect.zig").Padding;
const Border = @import("Border.zig");
const Box = @import("Box.zig");
const Label = @import("Label.zig");
const Icon = @import("Icon.zig");
const Text = @import("Text.zig");
const hotspot_mod = @import("hotspot.zig");
const Table = hotspot_mod.Table;
const Action = hotspot_mod.Action;

pub const Kbd = @This();

pub const Style = enum {
    /// Raised keycap with a subtle surface fill and a normal border stroke.
    keycap,
    /// Flat ghost keycap with a subtle border and no surface fill.
    subtle,
    /// Borderless keycap with fully rounded ends and a subtle surface fill.
    pill,
    /// Plain text glyph brackets such as `[Esc]`.
    bracket,
    /// Accent-filled keycap with inverted text.
    solid,
};

pub const Mode = enum {
    sdf,
    glyph,
};

pub const SymbolMode = enum {
    /// Follows the active icon style: uses glyph symbols for .unicode and
    /// .nerd_font, and readable text names for .ascii (substituting compact
    /// ascii symbols when width is constrained).
    auto,
    /// Always forces symbols regardless of icon style.
    symbols,
    /// Always forces readable text names ("Ctrl", "Shift", "Enter", etc.).
    text,
};

pub const Option = struct {
    style: Style = .keycap,
    mode: Mode = .sdf,
    symbols: SymbolMode = .auto,
    icon_style: Icon.IconStyle = .auto,
    corner_radius: f32 = 4.0,
    border_width: f32 = 1.0,
    padding_h: u16 = 1,
    /// Margin between the keycap chord and accompanying text (such as hint labels).
    margin: u16 = 1,
    /// Optional explicit override for `margin`.
    text_margin: ?u16 = null,
    /// Margin between a leading prompt/prefix (e.g. ">") and the keycap chord.
    prefix_margin: u16 = 1,
    /// Outer horizontal margin around each individual keycap.
    margin_h: u16 = 0,
    /// Minimum width of each individual keycap in cell columns.
    min_width: u16 = 0,
    /// Draws each chord segment as its own keycap. When false the whole chord
    /// is drawn inside one keycap using the normalized names joined by connectors.
    segmented: bool = true,
    /// Blank columns on each side of a `+` or `/` connector between keycaps.
    connector_pad: u16 = 1,
    uppercase_letters: bool = true,
    bracket_open: []const u8 = "[",
    bracket_close: []const u8 = "]",
    pressed: bool = false,
    focused: bool = false,

    pub inline fn effectiveIconStyle(self: Option) Icon.IconStyle {
        return Icon.resolveStyle(self.icon_style);
    }

    pub inline fn effectiveTextMargin(self: Option) u16 {
        return self.text_margin orelse self.margin;
    }
};

pub const Request = struct {
    col: u16,
    row: u16,
    max_col: u16 = std.math.maxInt(u16),
    chord: []const u8,
    option: Option = .{},
    action: ?Action = null,
};

/// A single chord segment yielded by `ChordIterator`. The connector is the
/// separator byte that preceded this key, or zero for the first segment.
pub const Segment = struct {
    key: []const u8,
    connector: u8 = 0,
};

/// Zero-allocation tokenizer splitting a chord on `+` and `/`. A separator
/// byte that appears where a key is expected (for example the second `+` in
/// `ctrl++`) is treated as the key itself, so literal plus and slash keys
/// remain expressible.
pub const ChordIterator = struct {
    chord: []const u8,
    pos: usize = 0,
    pending_connector: u8 = 0,

    pub fn init(chord: []const u8) ChordIterator {
        return .{ .chord = chord };
    }

    pub fn next(self: *ChordIterator) ?Segment {
        while (self.pos < self.chord.len and isSpace(self.chord[self.pos])) self.pos += 1;
        if (self.pos >= self.chord.len) return null;

        const start = self.pos;
        // The first non-space byte always belongs to the key, even if it is a separator.
        self.pos += 1;
        while (self.pos < self.chord.len and !isSeparator(self.chord[self.pos])) self.pos += 1;

        const key = std.mem.trim(u8, self.chord[start..self.pos], " \t");
        const seg: Segment = .{ .key = key, .connector = self.pending_connector };

        self.pending_connector = 0;
        if (self.pos < self.chord.len) {
            self.pending_connector = self.chord[self.pos];
            self.pos += 1;
        }
        return seg;
    }

    inline fn isSeparator(b: u8) bool {
        return b == '+' or b == '/';
    }

    inline fn isSpace(b: u8) bool {
        return b == ' ' or b == '\t';
    }
};

const NameEntry = struct {
    aliases: []const []const u8,
    text: []const u8,
    unicode_symbol: []const u8,
    nerd_font_symbol: ?[]const u8 = null,
    ascii_symbol: ?[]const u8 = null,

    pub fn resolve(self: NameEntry, symbols: bool, style: Icon.IconStyle) []const u8 {
        if (!symbols) return self.text;
        return switch (style) {
            .ascii => self.ascii_symbol orelse self.text,
            .nerd_font => self.nerd_font_symbol orelse self.unicode_symbol,
            .unicode, .auto => self.unicode_symbol,
        };
    }
};

const name_table = [_]NameEntry{
    .{ .aliases = &.{ "ctrl", "control" }, .text = "Ctrl", .unicode_symbol = "⌃", .nerd_font_symbol = "⌃", .ascii_symbol = "^" },
    .{ .aliases = &.{ "alt", "opt", "option" }, .text = "Alt", .unicode_symbol = "⌥", .nerd_font_symbol = "⌥", .ascii_symbol = "Alt" },
    .{ .aliases = &.{"shift"}, .text = "Shift", .unicode_symbol = "⇧", .nerd_font_symbol = "⇧", .ascii_symbol = "^" },
    .{ .aliases = &.{ "super", "cmd", "command", "win", "meta" }, .text = "Cmd", .unicode_symbol = "⌘", .nerd_font_symbol = "\u{f17a}", .ascii_symbol = "Cmd" },
    .{ .aliases = &.{ "enter", "return", "ret" }, .text = "Enter", .unicode_symbol = "↵", .nerd_font_symbol = "\u{f48a}", .ascii_symbol = "Enter" },
    .{ .aliases = &.{ "esc", "escape" }, .text = "Esc", .unicode_symbol = "⎋", .nerd_font_symbol = "⎋", .ascii_symbol = "Esc" },
    .{ .aliases = &.{"tab"}, .text = "Tab", .unicode_symbol = "⇥", .nerd_font_symbol = "\u{f46a}", .ascii_symbol = "Tab" },
    .{ .aliases = &.{ "backspace", "bksp" }, .text = "Bksp", .unicode_symbol = "⌫", .nerd_font_symbol = "\u{f460}", .ascii_symbol = "Bksp" },
    .{ .aliases = &.{ "delete", "del" }, .text = "Del", .unicode_symbol = "⌦", .nerd_font_symbol = "⌦", .ascii_symbol = "Del" },
    .{ .aliases = &.{ "insert", "ins" }, .text = "Ins", .unicode_symbol = "Ins", .nerd_font_symbol = "Ins", .ascii_symbol = "Ins" },
    .{ .aliases = &.{"space"}, .text = "Space", .unicode_symbol = "␣", .nerd_font_symbol = "␣", .ascii_symbol = "Space" },
    .{ .aliases = &.{"up"}, .text = "Up", .unicode_symbol = "↑", .nerd_font_symbol = "\u{f062}", .ascii_symbol = "^" },
    .{ .aliases = &.{"down"}, .text = "Down", .unicode_symbol = "↓", .nerd_font_symbol = "\u{f063}", .ascii_symbol = "v" },
    .{ .aliases = &.{"left"}, .text = "Left", .unicode_symbol = "←", .nerd_font_symbol = "\u{f060}", .ascii_symbol = "<" },
    .{ .aliases = &.{"right"}, .text = "Right", .unicode_symbol = "→", .nerd_font_symbol = "\u{f061}", .ascii_symbol = ">" },
    .{ .aliases = &.{"home"}, .text = "Home", .unicode_symbol = "↖", .nerd_font_symbol = "↖", .ascii_symbol = "Home" },
    .{ .aliases = &.{"end"}, .text = "End", .unicode_symbol = "↘", .nerd_font_symbol = "↘", .ascii_symbol = "End" },
    .{ .aliases = &.{ "page_up", "pageup", "pgup" }, .text = "PgUp", .unicode_symbol = "⇞", .nerd_font_symbol = "⇞", .ascii_symbol = "PgUp" },
    .{ .aliases = &.{ "page_down", "pagedown", "pgdown", "pgdn" }, .text = "PgDn", .unicode_symbol = "⇟", .nerd_font_symbol = "⇟", .ascii_symbol = "PgDn" },
};

const upper_letters: [26][]const u8 = blk: {
    var out: [26][]const u8 = undefined;
    for (0..26) |i| out[i] = &[_]u8{'A' + @as(u8, @intCast(i))};
    break :blk out;
};

const function_keys = [_][]const u8{ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12" };

/// Maps a raw chord token to its display string according to the specified
/// IconStyle. Known modifier and special key aliases resolve to static text,
/// Unicode, or Nerd Font symbols, single ASCII letters are uppercased when
/// requested, function keys are normalized to `F<n>`, and any other token is
/// returned unchanged. The result never aliases a temporary.
pub fn normalizeWithStyle(token: []const u8, symbols: bool, uppercase_letters: bool, style: Icon.IconStyle) []const u8 {
    if (token.len == 0) return token;
    const resolved_style = Icon.resolveStyle(style);

    for (name_table) |entry| {
        for (entry.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(token, alias)) return entry.resolve(symbols, resolved_style);
        }
    }

    if (token.len == 1 and uppercase_letters) {
        const c = token[0];
        if (c >= 'a' and c <= 'z') return upper_letters[c - 'a'];
    }

    if (token.len >= 2 and token.len <= 3 and (token[0] == 'f' or token[0] == 'F')) {
        const n = std.fmt.parseInt(u8, token[1..], 10) catch 0;
        if (n >= 1 and n <= function_keys.len) return function_keys[n - 1];
    }

    return token;
}

/// Maps a raw chord token to its display string defaulting to Unicode symbols.
pub fn normalize(token: []const u8, symbols: bool, uppercase_letters: bool) []const u8 {
    return normalizeWithStyle(token, symbols, uppercase_letters, .unicode);
}

fn connectorWidth(opt: Option) u16 {
    return 1 + opt.connector_pad * 2;
}

/// Display width of a single keycap holding the already-normalized `label`.
pub fn measureKeycap(label: []const u8, opt: Option) u16 {
    const w = Text.measure(label);
    const content_w = if (usesBrackets(opt))
        Text.measure(opt.bracket_open) + w + Text.measure(opt.bracket_close)
    else
        w + opt.padding_h * 2;
    const key_w = @max(content_w, opt.min_width);
    return key_w + opt.margin_h * 2;
}

fn measureChordWith(chord: []const u8, opt: Option, symbols: bool) u16 {
    var it = ChordIterator.init(chord);
    var total: u16 = 0;
    var joined: u16 = 0;
    while (it.next()) |seg| {
        const name = normalizeWithStyle(seg.key, symbols, opt.uppercase_letters, opt.icon_style);
        const name_w = Text.measure(name);
        if (opt.segmented) {
            if (seg.connector != 0) total += connectorWidth(opt);
            total += measureKeycap(name, opt);
        } else {
            if (seg.connector != 0) joined += 1;
            joined += name_w;
        }
    }
    if (!opt.segmented) {
        if (joined == 0) return 0;
        if (usesBrackets(opt)) return Text.measure(opt.bracket_open) + joined + Text.measure(opt.bracket_close);
        return joined + opt.padding_h * 2;
    }
    return total;
}

fn resolveSymbols(chord: []const u8, opt: Option, avail: u16) bool {
    return switch (opt.symbols) {
        .text => false,
        .symbols => true,
        .auto => switch (opt.effectiveIconStyle()) {
            .nerd_font, .unicode => true,
            .ascii => measureChordWith(chord, opt, false) > avail,
            .auto => unreachable,
        },
    };
}

/// Display width of a complete chord using the option's symbol mode.
pub fn measureChord(chord: []const u8, opt: Option) u16 {
    const use_sym = resolveSymbols(chord, opt, std.math.maxInt(u16));
    return measureChordWith(chord, opt, use_sym);
}

/// Display width of a `prefix chord label` hint row as drawn by `renderHint`.
pub fn measureHint(prefix: ?[]const u8, chord: []const u8, label: []const u8, opt: Option) u16 {
    var w: u16 = 0;
    if (prefix) |p| {
        if (p.len > 0) w += Text.measure(p) + opt.prefix_margin;
    }
    w += measureChord(chord, opt);
    if (label.len > 0) w += opt.effectiveTextMargin() + Text.measure(label);
    return w;
}

inline fn usesBrackets(opt: Option) bool {
    return opt.style == .bracket or opt.mode == .glyph;
}

const Visual = struct {
    box: Box.Option,
    text_color: [3]u8,
    semantic_accent: ?[3]u8 = null,
};

fn resolveVisual(opt: Option, tokens: Tokens) Visual {
    const radius = opt.corner_radius;
    const inverted: [3]u8 = .{ tokens.bg[0], tokens.bg[1], tokens.bg[2] };

    if (opt.pressed or opt.style == .solid) {
        return .{
            .box = .{
                .surface = .custom,
                .bg_color = tokens.accent,
                .border = .{ .shape = .rounded, .radius = radius, .width = opt.border_width, .style = .none },
                .padding = Padding.horizontal(opt.padding_h),
            },
            .text_color = inverted,
        };
    }

    return switch (opt.style) {
        .keycap => .{
            .box = .{
                .surface = .subtle,
                .border = .{ .shape = .rounded, .radius = radius, .width = opt.border_width, .style = .normal },
                .padding = Padding.horizontal(opt.padding_h),
            },
            .text_color = tokens.primary,
        },
        .subtle => .{
            .box = .{
                .surface = .none,
                .border = .{ .shape = .rounded, .radius = radius, .width = opt.border_width, .style = .subtle },
                .padding = Padding.horizontal(opt.padding_h),
            },
            .text_color = tokens.secondary,
        },
        .pill => .{
            .box = .{
                .surface = .subtle,
                .border = .{ .shape = .pill, .width = opt.border_width, .style = .none },
                .padding = Padding.horizontal(opt.padding_h),
            },
            .text_color = tokens.primary,
        },
        .bracket, .solid => unreachable,
    };
}

fn drawKeycap(
    col: u16,
    row: u16,
    max_col: u16,
    label: []const u8,
    opt: Option,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Text.Drawer,
) u16 {
    if (col > max_col or label.len == 0) return 0;
    const avail = max_col - col + 1;
    const want = measureKeycap(label, opt);

    const m = opt.margin_h;
    if (usesBrackets(opt)) {
        const br_color = if (opt.focused or opt.pressed) tokens.accent else tokens.muted;
        const key_color = if (opt.focused or opt.pressed) tokens.accent else tokens.primary;
        var c = col + m;
        c += drawer.drawString(c, row, opt.bracket_open, br_color, 255, max_col);
        c += drawer.drawString(c, row, label, key_color, 255, max_col);
        c += drawer.drawString(c, row, opt.bracket_close, br_color, 255, max_col);
        c += m;
        return c - col;
    }

    const key_w = if (want > m * 2) want - m * 2 else want;
    const key_avail = if (avail > m * 2) avail - m * 2 else 0;
    const w = @min(key_w, key_avail);
    const visual = resolveVisual(opt, tokens);
    const inner = Box.render(
        .{
            .rect = .{ .col = col + m, .row = row, .width = w, .height = 1 },
            .option = visual.box,
            .focused = opt.focused and !opt.pressed,
        },
        tokens,
        null,
        card_buffer,
        drawer.allocator,
        drawer,
        null,
    );
    if (inner.width > 0) {
        _ = Label.render(.{ .col = inner.col, .row = row, .width = inner.width, .height = 1 }, label, .{
            .align_h = .center,
            .overflow = .clip,
            .color = visual.text_color,
        }, tokens, drawer);
    }
    return @min(want, avail);
}

/// Renders a single normalized key as one keycap and returns its width.
pub fn renderSingleKey(
    col: u16,
    row: u16,
    max_col: u16,
    key: []const u8,
    opt: Option,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Text.Drawer,
    hotspots: ?*Table,
    action: ?Action,
) u16 {
    const symbols = resolveSymbols(key, opt, max_col -| col + 1);
    const label = normalizeWithStyle(key, symbols, opt.uppercase_letters, opt.icon_style);
    const w = drawKeycap(col, row, max_col, label, opt, tokens, card_buffer, drawer);
    registerHotspot(hotspots, action, col, row, w);
    return w;
}

/// Renders a chord as segmented keycaps linked by `+` or `/` connectors, or as
/// a single unified keycap when segmentation is disabled. A single hotspot
/// covering the full drawn width is registered when an action is supplied.
pub fn renderChord(
    req: Request,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Text.Drawer,
    hotspots: ?*Table,
) u16 {
    if (req.col > req.max_col or req.chord.len == 0) return 0;
    const opt = req.option;
    const avail = req.max_col - req.col + 1;
    const symbols = resolveSymbols(req.chord, opt, avail);

    var c = req.col;
    if (opt.segmented) {
        var it = ChordIterator.init(req.chord);
        while (it.next()) |seg| {
            if (c > req.max_col) break;
            if (seg.connector != 0) {
                const conn_w = connectorWidth(opt);
                if (c + conn_w > req.max_col) break;
                _ = drawer.drawChar(c + opt.connector_pad, req.row, seg.connector, tokens.muted, 255);
                c += conn_w;
            }
            const label = normalizeWithStyle(seg.key, symbols, opt.uppercase_letters, opt.icon_style);
            c += drawKeycap(c, req.row, req.max_col, label, opt, tokens, card_buffer, drawer);
        }
    } else {
        var buf: [96]u8 = undefined;
        var len: usize = 0;
        var it = ChordIterator.init(req.chord);
        while (it.next()) |seg| {
            if (seg.connector != 0 and len < buf.len) {
                buf[len] = seg.connector;
                len += 1;
            }
            const name = normalizeWithStyle(seg.key, symbols, opt.uppercase_letters, opt.icon_style);
            const n = @min(name.len, buf.len - len);
            @memcpy(buf[len .. len + n], name[0..n]);
            len += n;
        }
        c += drawKeycap(c, req.row, req.max_col, buf[0..len], opt, tokens, card_buffer, drawer);
    }

    const w = c - req.col;
    registerHotspot(hotspots, req.action, req.col, req.row, w);
    return w;
}

/// Renders a keyboard hint row of the form `prefix chord label`, where the
/// optional prefix (such as a `>` focus marker) and the label are plain text
/// and the chord is drawn as keycaps. The whole row becomes one hotspot when
/// an action is supplied, and the drawn width is returned.
pub fn renderHint(
    col: u16,
    row: u16,
    max_col: u16,
    prefix: ?[]const u8,
    chord: []const u8,
    label: []const u8,
    opt: Option,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Text.Drawer,
    hotspots: ?*Table,
    action: ?Action,
) u16 {
    if (col > max_col) return 0;
    var c = col;

    if (prefix) |p| {
        if (p.len > 0) {
            const p_role: Label.Role = if (opt.focused) .accent else .muted;
            c += Label.renderAt(c, row, max_col, p, .{ .role = p_role, .overflow = .clip }, tokens, drawer);
            c += opt.prefix_margin;
        }
    }

    if (c <= max_col) {
        c += renderChord(.{ .col = c, .row = row, .max_col = max_col, .chord = chord, .option = opt }, tokens, card_buffer, drawer, null);
    }

    const tm = opt.effectiveTextMargin();
    if (label.len > 0 and c + tm <= max_col) {
        c += tm;
        const l_role: Label.Role = if (opt.focused) .primary else .muted;
        c += Label.renderAt(c, row, max_col, label, .{ .role = l_role }, tokens, drawer);
    }

    const w = c - col;
    registerHotspot(hotspots, action, col, row, w);
    return w;
}

/// Formats a native key and modifier set into a `Ctrl+Shift+P` style chord
/// inside `buf`, returning the written slice. Modifiers are emitted in the
/// canonical Ctrl, Alt, Shift, Cmd order.
pub fn formatNative(key: input.Key, mods: input.Modifiers, buf: []u8) []const u8 {
    var len: usize = 0;
    const append = struct {
        fn f(b: []u8, l: *usize, s: []const u8) void {
            const n = @min(s.len, b.len - l.*);
            @memcpy(b[l.* .. l.* + n], s[0..n]);
            l.* += n;
        }
    }.f;

    if (mods.ctrl) append(buf, &len, "ctrl+");
    if (mods.alt) append(buf, &len, "alt+");
    if (mods.shift) append(buf, &len, "shift+");
    if (mods.super) append(buf, &len, "super+");
    append(buf, &len, nativeKeyName(key));
    return buf[0..len];
}

fn nativeKeyName(key: input.Key) []const u8 {
    const v = @intFromEnum(key);
    if (v >= @intFromEnum(input.Key.a) and v <= @intFromEnum(input.Key.z)) {
        return upper_letters[v - @intFromEnum(input.Key.a)];
    }
    if (v >= @intFromEnum(input.Key.f1) and v <= @intFromEnum(input.Key.f12)) {
        return function_keys[v - @intFromEnum(input.Key.f1)];
    }
    if (v >= @intFromEnum(input.Key.num_0) and v <= @intFromEnum(input.Key.num_9)) {
        const digits = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
        return digits[v - @intFromEnum(input.Key.num_0)];
    }
    return switch (key) {
        .escape => "esc",
        .enter, .kp_enter => "enter",
        .tab => "tab",
        .backspace => "backspace",
        .insert => "insert",
        .delete => "delete",
        .left => "left",
        .right => "right",
        .up => "up",
        .down => "down",
        .page_up => "page_up",
        .page_down => "page_down",
        .home => "home",
        .end => "end",
        .space => "space",
        .minus => "-",
        .equal => "=",
        .left_bracket => "[",
        .right_bracket => "]",
        .backslash => "\\",
        .semicolon => ";",
        .apostrophe => "'",
        .comma => ",",
        .period => ".",
        // A bare slash would be read back as a chord separator, so it is spelled out.
        .slash => "Slash",
        .grave_accent => "`",
        else => "?",
    };
}

/// Renders a native key and modifier set as a chord. The chord text is
/// assembled in a fixed stack buffer, so no allocation occurs.
pub fn renderNative(
    col: u16,
    row: u16,
    max_col: u16,
    key: input.Key,
    mods: input.Modifiers,
    opt: Option,
    tokens: Tokens,
    card_buffer: *std.ArrayListUnmanaged(Card.Instance),
    drawer: Text.Drawer,
    hotspots: ?*Table,
    action: ?Action,
) u16 {
    var buf: [48]u8 = undefined;
    const chord = formatNative(key, mods, &buf);
    return renderChord(.{ .col = col, .row = row, .max_col = max_col, .chord = chord, .option = opt, .action = action }, tokens, card_buffer, drawer, hotspots);
}

fn registerHotspot(hotspots: ?*Table, action: ?Action, col: u16, row: u16, w: u16) void {
    if (w == 0) return;
    if (hotspots) |ht| {
        if (action) |act| ht.add(col, row, w, 1, act);
    }
}

test "Kbd: chord iterator splits on plus and slash with literal separators" {
    const testing = std.testing;

    var it = ChordIterator.init("Ctrl+Shift+P");
    try testing.expectEqualStrings("Ctrl", it.next().?.key);
    const s2 = it.next().?;
    try testing.expectEqualStrings("Shift", s2.key);
    try testing.expectEqual(@as(u8, '+'), s2.connector);
    try testing.expectEqualStrings("P", it.next().?.key);
    try testing.expect(it.next() == null);

    var it2 = ChordIterator.init("Esc / q");
    try testing.expectEqualStrings("Esc", it2.next().?.key);
    const q = it2.next().?;
    try testing.expectEqualStrings("q", q.key);
    try testing.expectEqual(@as(u8, '/'), q.connector);
    try testing.expect(it2.next() == null);

    var it3 = ChordIterator.init("ctrl++");
    try testing.expectEqualStrings("ctrl", it3.next().?.key);
    try testing.expectEqualStrings("+", it3.next().?.key);
    try testing.expect(it3.next() == null);

    var it4 = ChordIterator.init(">");
    try testing.expectEqualStrings(">", it4.next().?.key);
    try testing.expect(it4.next() == null);
}

test "Kbd: normalization of modifiers, letters, and function keys" {
    const testing = std.testing;

    try testing.expectEqualStrings("Ctrl", normalize("control", false, true));
    try testing.expectEqualStrings("⌃", normalize("ctrl", true, true));
    try testing.expectEqualStrings("⇧", normalize("SHIFT", true, true));
    try testing.expectEqualStrings("Esc", normalize("escape", false, true));
    try testing.expectEqualStrings("Q", normalize("q", false, true));
    try testing.expectEqualStrings("q", normalize("q", false, false));
    try testing.expectEqualStrings("F5", normalize("f5", false, true));
    try testing.expectEqualStrings("Enter / Y", normalize("Enter / Y", false, true));
    try testing.expectEqualStrings("1", normalize("1", false, true));
}

test "Kbd: icon style integration adapts modifier and key symbols" {
    const testing = std.testing;

    // Unicode style
    try testing.expectEqualStrings("⌃", normalizeWithStyle("ctrl", true, true, .unicode));
    try testing.expectEqualStrings("⇧", normalizeWithStyle("shift", true, true, .unicode));
    try testing.expectEqualStrings("⌘", normalizeWithStyle("cmd", true, true, .unicode));
    try testing.expectEqualStrings("↵", normalizeWithStyle("enter", true, true, .unicode));
    try testing.expectEqualStrings("↑", normalizeWithStyle("up", true, true, .unicode));

    // Nerd Font style
    try testing.expectEqualStrings("\u{f17a}", normalizeWithStyle("cmd", true, true, .nerd_font));
    try testing.expectEqualStrings("⇧", normalizeWithStyle("shift", true, true, .nerd_font));
    try testing.expectEqualStrings("\u{f48a}", normalizeWithStyle("enter", true, true, .nerd_font));
    try testing.expectEqualStrings("\u{f46a}", normalizeWithStyle("tab", true, true, .nerd_font));
    try testing.expectEqualStrings("\u{f460}", normalizeWithStyle("bksp", true, true, .nerd_font));

    // ASCII style (fallback to safe ASCII characters or names)
    try testing.expectEqualStrings("^", normalizeWithStyle("ctrl", true, true, .ascii));
    try testing.expectEqualStrings("^", normalizeWithStyle("shift", true, true, .ascii));
    try testing.expectEqualStrings("Cmd", normalizeWithStyle("cmd", true, true, .ascii));
    try testing.expectEqualStrings("Enter", normalizeWithStyle("enter", true, true, .ascii));
    try testing.expectEqualStrings("^", normalizeWithStyle("up", true, true, .ascii));
    try testing.expectEqualStrings("v", normalizeWithStyle("down", true, true, .ascii));
    try testing.expectEqualStrings("<", normalizeWithStyle("left", true, true, .ascii));
    try testing.expectEqualStrings(">", normalizeWithStyle("right", true, true, .ascii));

    // When symbols are false, icon_style doesn't change text representation
    try testing.expectEqualStrings("Ctrl", normalizeWithStyle("ctrl", false, true, .ascii));
    try testing.expectEqualStrings("Shift", normalizeWithStyle("shift", false, true, .nerd_font));
    try testing.expectEqualStrings("Cmd", normalizeWithStyle("cmd", false, true, .unicode));
}

test "Kbd: keycap and chord measurement" {
    const testing = std.testing;
    const opt: Option = .{};

    // " C " keycap with 1 column padding on each side.
    try testing.expectEqual(@as(u16, 3), measureKeycap("C", opt));
    // "[Esc]" in bracket style.
    try testing.expectEqual(@as(u16, 5), measureKeycap("Esc", .{ .style = .bracket }));

    // In default .auto symbol mode with .unicode icon style: " ⌃ " (3) + " + " (3) + " C " (3) = 9
    try testing.expectEqual(@as(u16, 9), measureChord("ctrl+c", opt));
    // In explicit .text mode: " Ctrl " (6) + " + " (3) + " C " (3) = 12
    try testing.expectEqual(@as(u16, 12), measureChord("ctrl+c", .{ .symbols = .text }));
    // In .ascii icon style with ample room: " Ctrl " (6) + " + " (3) + " C " (3) = 12
    try testing.expectEqual(@as(u16, 12), measureChord("ctrl+c", .{ .icon_style = .ascii }));
    // Compact connectors: 3 + 1 + 3 = 7
    try testing.expectEqual(@as(u16, 7), measureChord("ctrl+c", .{ .connector_pad = 0 }));
    // Symbols: " ⌃ " (3) + " + " (3) + " C " (3) = 9
    try testing.expectEqual(@as(u16, 9), measureChord("ctrl+c", .{ .symbols = .symbols }));
    // Unsegmented single keycap: " ⌃+C " = 5 (symbols) or " Ctrl+C " = 8 (text)
    try testing.expectEqual(@as(u16, 5), measureChord("ctrl+c", .{ .segmented = false }));
    try testing.expectEqual(@as(u16, 8), measureChord("ctrl+c", .{ .segmented = false, .symbols = .text }));

    // "> " (2) + chord (9) + " Copy" (5) = 16
    try testing.expectEqual(@as(u16, 16), measureHint(">", "ctrl+c", "Copy", opt));
}

test "Kbd: auto symbol mode adapts to icon style and available width" {
    const testing = std.testing;
    const ascii_opt: Option = .{ .symbols = .auto, .icon_style = .ascii };
    try testing.expect(!resolveSymbols("ctrl+shift+p", ascii_opt, 40));
    try testing.expect(resolveSymbols("ctrl+shift+p", ascii_opt, 10));

    const uni_opt: Option = .{ .symbols = .auto, .icon_style = .unicode };
    try testing.expect(resolveSymbols("ctrl+shift+p", uni_opt, 40));

    const nerd_opt: Option = .{ .symbols = .auto, .icon_style = .nerd_font };
    try testing.expect(resolveSymbols("ctrl+shift+p", nerd_opt, 40));
}

test "Kbd: margin, min_width, and hint spacing synchronization" {
    const testing = std.testing;

    // Default margin is 1
    const default_opt: Option = .{};
    try testing.expectEqual(@as(u16, 1), default_opt.effectiveTextMargin());
    try testing.expectEqual(@as(u16, 16), measureHint(">", "ctrl+c", "Copy", default_opt));

    // Custom text margin: 2 columns between chord and label text
    const wide_margin_opt: Option = .{ .margin = 2 };
    try testing.expectEqual(@as(u16, 2), wide_margin_opt.effectiveTextMargin());
    try testing.expectEqual(@as(u16, 17), measureHint(">", "ctrl+c", "Copy", wide_margin_opt));

    // Explicit text_margin overrides margin
    const override_opt: Option = .{ .margin = 1, .text_margin = 3 };
    try testing.expectEqual(@as(u16, 3), override_opt.effectiveTextMargin());
    try testing.expectEqual(@as(u16, 18), measureHint(">", "ctrl+c", "Copy", override_opt));

    // Custom prefix margin
    const prefix_opt: Option = .{ .prefix_margin = 2 };
    try testing.expectEqual(@as(u16, 17), measureHint(">", "ctrl+c", "Copy", prefix_opt));

    // min_width expands keycap width when content is narrower
    const min_w_opt: Option = .{ .min_width = 5 };
    // " C " with padding 1 is 3, expanded to min_width 5
    try testing.expectEqual(@as(u16, 5), measureKeycap("C", min_w_opt));

    // margin_h adds outer horizontal space around the keycap
    const margin_h_opt: Option = .{ .margin_h = 1 };
    // " C " (3) + margin_h * 2 (2) = 5
    try testing.expectEqual(@as(u16, 5), measureKeycap("C", margin_h_opt));
}

test "Kbd: native key formatting" {
    const testing = std.testing;
    var buf: [48]u8 = undefined;

    try testing.expectEqualStrings("ctrl+shift+P", formatNative(.p, .{ .ctrl = true, .shift = true }, &buf));
    try testing.expectEqualStrings("esc", formatNative(.escape, .{}, &buf));
    try testing.expectEqualStrings("alt+F4", formatNative(.f4, .{ .alt = true }, &buf));
    try testing.expectEqualStrings("super+Slash", formatNative(.slash, .{ .super = true }, &buf));
}

test "Kbd: visual resolution for pressed and solid keycaps inverts text" {
    const testing = std.testing;
    const tokens = Tokens.dark;
    const pressed = resolveVisual(.{ .pressed = true }, tokens);
    try testing.expectEqual(tokens.accent, pressed.box.bg_color.?);
    try testing.expectEqual([3]u8{ tokens.bg[0], tokens.bg[1], tokens.bg[2] }, pressed.text_color);

    const keycap = resolveVisual(.{}, tokens);
    try testing.expectEqual(Box.Surface.subtle, keycap.box.surface);
    try testing.expectEqual(Border.Style.normal, keycap.box.border.style);
}
