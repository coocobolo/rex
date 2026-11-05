//! Select Graphic Rendition (SGR / CSI Ps ... m)
//!
//! Parses a CSI SGR sequence and applies the resulting attributes to `attr`.
//! Supported attributes include standard SGR codes, 256-color palettes (both
//! semicolon and colon formats), true color RGB specifications (including
//! color-space variants), underline color styling (Kitty protocol), and
//! underline style sub-parameters.
//!
//! Sub-parameters of a code that takes none are skipped, so `CSI 99:1:0 m`
//! does not reset the pen through the trailing 0.

const std = @import("std");

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

            // Underline colour (kitty and VTE extension, widely supported)
            58 => i = parseExtColor(palette, attr, params, i, n, .underline),
            59 => attr.underline_color = .default,

            else => {}, // unknown; silently ignore
        }

        // Skip sub-parameters the code did not consume, such as a stray
        // `:0` after an unknown code, so they are not read as codes.
        while (i + 1 < n and params[i + 1].separator == .sub_parameter) i += 1;
    }
}

/// Parse an extended colour (38, 48 or 58) starting at index `i`.
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
    const set = struct {
        fn set(p: *Palette, a: *Attr, t: ColorTarget, color: Color) void {
            switch (t) {
                .fg => a.fg = p.intern(color),
                .bg => a.bg = p.intern(color),
                // Kept as a Color, not a palette slot: see Attr.underline_color.
                .underline => a.underline_color = color,
            }
        }
    }.set;
    switch (kind) {
        2 => {
            // Detect ECMA-48 5-param form: 38:2:cs:r:g:b
            // vs xterm 4-param form: 38:2:r:g:b or 38;2;r;g;b
            const has_color_space = index + 5 < count and
                params[index + 2].separator == .sub_parameter and
                params[index + 5].separator == .sub_parameter;

            if (has_color_space) {
                // 38:2:cs:r:g:b, skip the color space at i+2
                if (index + 5 >= count) return index + 1;
                const r: u8 = @truncate(params[index + 3].value);
                const g: u8 = @truncate(params[index + 4].value);
                const b: u8 = @truncate(params[index + 5].value);
                set(palette, attr, target, .{ .rgb = .{ .r = r, .g = g, .b = b } });
                return index + 5;
            } else {
                // 38:2:r:g:b or 38;2;r;g;b
                if (index + 4 >= count) return index + 1;
                const r: u8 = @truncate(params[index + 2].value);
                const g: u8 = @truncate(params[index + 3].value);
                const b: u8 = @truncate(params[index + 4].value);
                set(palette, attr, target, .{ .rgb = .{ .r = r, .g = g, .b = b } });
                return index + 4;
            }
        },
        5 => {
            // 256-colour: kind + n = 2 extra values
            if (index + 2 >= count) return index + 1; // malformed; skip kind only
            const n: u8 = @intCast(@min(params[index + 2].value, 255));
            set(palette, attr, target, .{ .indexed = n });
            return index + 2; // last consumed index
        },
        else => return index + 1, // unknown kind; skip kind only
    }
}
