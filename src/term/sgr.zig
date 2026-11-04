//! Select Graphic Rendition (SGR / CSI Ps ... m)
//! Parses a CSI SGR sequence and applies the resulting attributes to `attr`.
//!
//! Handles:
//!   1. Standard SGR codes (0–29, 30–37, 39, 40–47, 49, 90–97, 100–107)
//!   2. 256-color:  38;5;n   and  38:5:n
//!   3. True color: 38;2;r;g;b  and  38:2:r:g:b  (and 38:2::r:g:b with color space)
//!   4. Underline color: 58;2;r;g;b  and  58:5:n
//!   5. Underline style sub-params: 4:0–4:5

const std = @import("std");

// const ControlSequence = @import("parser.zig").ControlSequence;
// const Separator = @import("parser.zig").Separator;
const Parameter = @import("../vt/parser.zig").Parameter;

const Option = @import("term.zig").Option;
const Terminal = @import("term.zig").Terminal;
const Attr = @import("cell.zig").Attr;
const Color = @import("cell.zig").Color;
const Palette = @import("Palette.zig").Palette;

const ColorTarget = enum { fg, bg, underline };

/// Apply a CSI SGR sequence to `attr`.
/// `CSI m` (no params) and `CSI 0 m` both reset all attributes.
pub fn parse(comptime option: Option, term: *Terminal(option), params: []const Parameter) void {
    const n: usize = @intCast(params.len);
    const attr = &term.active().cursor.attr;

    // CSI m with no params = Normal/default (CSI 0 m).
    if (n == 0) {
        attr.* = .{};
        return;
    }

    const palette = &term.active().palette;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const code = params[i].value;

        switch (code) {
            0 => attr.* = .{},

            // Intensity / style
            1 => attr.flags.bold = true,
            2 => attr.flags.dim = true,
            3 => attr.flags.italic = true,
            4 => {
                if (i + 1 < n and params[i + 1].separator == .sub_parameter) {
                    i += 1;
                    attr.flags.underline = switch (params[i].value) {
                        0 => .none,
                        1 => .single,
                        2 => .double,
                        3 => .curly,
                        4 => .dotted,
                        5 => .dashed,
                        else => .single,
                    };
                } else {
                    attr.flags.underline = .single;
                }
            },

            5 => attr.flags.blink = true,
            6 => attr.flags.blink_rapid = true,
            7 => attr.flags.reverse = true,
            8 => attr.flags.invisible = true,
            9 => attr.flags.strikethrough = true,

            // Off codes
            21 => attr.flags.underline = .double, // legacy SGR 21 (double underline)
            22 => {
                // SGR 22 resets BOTH
                attr.flags.bold = false;
                attr.flags.dim = false;
            },
            23 => attr.flags.italic = false,
            24 => attr.flags.underline = .none,
            25 => {
                attr.flags.blink = false;
                attr.flags.blink_rapid = false;
            },
            26 => attr.flags.blink_rapid = false,
            27 => attr.flags.reverse = false,
            28 => attr.flags.invisible = false,
            29 => attr.flags.strikethrough = false,
            53 => attr.flags.overline = true,
            55 => attr.flags.overline = false,

            // Foreground colours
            30...37 => attr.fg = palette.intern(.{ .indexed = @intCast(code - 30) }),
            38 => i = parseExtColor(palette, attr, params, i, n, .fg),
            39 => attr.fg = Palette.default_base,

            // Background colours
            40...47 => attr.bg = palette.intern(.{ .indexed = @intCast(code - 40) }),
            48 => i = parseExtColor(palette, attr, params, i, n, .bg),
            49 => attr.bg = Palette.default_base,

            // Bright foreground (high-intensity, non-bold)
            90...97 => attr.fg = palette.intern(.{ .indexed = @intCast(code - 90 + 8) }),

            // Bright background
            100...107 => attr.bg = palette.intern(.{ .indexed = @intCast(code - 100 + 8) }),

            // FIXME requires parse parseExtColor accept a target {fg, bg, underline}
            // Underline colour (Kitty/VTE extension, widely supported)

            // 58 => i = parseExtColor(palette, attr, params, i, n, .underline),
            // 59 => attr.underline_color = Palette.default_idx,

            // selection sgr color
            // 17 => self.selection_bg = parseOscColor(param),
            // 19 => self.selection_fg = parseOscColor(param),
            // 117 => self.selection_bg = null,
            // 119 => self.selection_fg = null,

            else => {}, // unknown; silently ignore
        }
    }
}

/// Parse an extended colour (38 or 48) starting at index `i`.
/// Consumes the kind byte and its sub-parameters.
/// Returns the index of the LAST consumed value; the caller's `i += 1`
/// will then advance past it.
///
///   kind=2   RGB      38 ; 2 ; r ; g ; b   (consumes 4 extra values)
///   kind=5   256-col  38 ; 5 ; n           (consumes 2 extra values)
///
/// Both the colon form (38:2:r:g:b) and the semicolon form (38;2;r;g;b)
/// produce the same `values[]` layout, only the separators differ, and
/// we don't need to distinguish them here.
fn parseExtColor(
    palette: *Palette,
    attr: *Attr,
    params: []const Parameter,
    index: usize,
    count: usize,
    target: ColorTarget,
) usize {
    // Need at least one more value for the kind byte.
    if (index + 1 >= count) return index;

    const kind = params[index + 1].value;
    switch (kind) {
        2 => {
            // Detect ECMA-48 5-param form: 38:2:cs:r:g:b
            // vs xterm 4-param form: 38:2:r:g:b or 38;2;r;g;b
            const has_color_space = index + 5 < count and
                params[index + 2].separator == .sub_parameter and
                params[index + 5].separator == .sub_parameter;

            if (has_color_space) {
                // 38:2:cs:r:g:b — skip color space at i+2
                if (index + 5 >= count) return index + 1;
                const r: u8 = @truncate(params[index + 3].value);
                const g: u8 = @truncate(params[index + 4].value);
                const b: u8 = @truncate(params[index + 5].value);
                const color: Color = .{ .rgb = .{ .r = r, .g = g, .b = b } };
                // if (is_fg) attr.fg = palette.intern(color) else attr.bg = palette.intern(color);
                switch (target) {
                    .fg => attr.fg = palette.intern(color),
                    .bg => attr.bg = palette.intern(color),
                    // .underline => attr.flags.underline = palette.intern(color),
                    .underline => {},
                }
                return index + 5;
            } else {
                // 38:2:r:g:b or 38;2;r;g;b
                if (index + 4 >= count) return index + 1;
                const r: u8 = @truncate(params[index + 2].value);
                const g: u8 = @truncate(params[index + 3].value);
                const b: u8 = @truncate(params[index + 4].value);
                const color: Color = .{ .rgb = .{ .r = r, .g = g, .b = b } };
                // if (is_fg) attr.fg = palette.intern(color) else attr.bg = palette.intern(color);
                switch (target) {
                    .fg => attr.fg = palette.intern(color),
                    .bg => attr.bg = palette.intern(color),
                    // .underline => attr.flags.underline = palette.intern(color),
                    .underline => {},
                }
                return index + 4;
            }
        },
        5 => {
            // 256-colour: kind + n = 2 extra values
            if (index + 2 >= count) return index + 1; // malformed; skip kind only
            const n: u8 = @intCast(@min(params[index + 2].value, 255));
            const color: Color = .{ .indexed = n };
            // if (is_fg) attr.fg = palette.intern(color) else attr.bg = palette.intern(color);
            switch (target) {
                .fg => attr.fg = palette.intern(color),
                .bg => attr.bg = palette.intern(color),
                // .underline => attr.flags.underline = palette.intern(color),
                .underline => {},
            }
            return index + 2; // last consumed index
        },
        else => return index + 1, // unknown kind; skip kind only
    }
}
