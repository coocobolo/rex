//! The UI kit's design tokens: the named colors, radii, spacing and control
//! sizes every component is built from. Components name a token, never a
//! raw color. The colors follow shadcn/ui's neutral theme
//! (https://ui.shadcn.com/docs/theming, read 2026-11-12, converted from
//! oklch to sRGB); `success`, `warning` and `info` are additions for toast
//! types. Sizes are logical pixels.
//!
//! The theme is independent of the terminal's colors. Only its variant
//! follows the terminal: `variantFor` picks dark or light from how bright
//! the terminal background is.

const std = @import("std");

const Theme = @This();

/// An sRGB color with straight alpha.
pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    /// From `0xRRGGBB`, opaque.
    pub fn rgb(hex: u24) Color {
        return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex) };
    }

    /// The same color at `percent` opacity, 0 to 100.
    pub fn alpha(self: Color, percent: u8) Color {
        std.debug.assert(percent <= 100);
        var result = self;
        result.a = @intCast((@as(u32, percent) * 255 + 50) / 100);
        return result;
    }
};

/// Window background of a settings or dashboard window.
background: Color,
/// Text.
foreground: Color,
/// Raised panels.
card: Color,
/// Toasts, dialogs, menus.
popover: Color,
/// The main action.
primary: Color,
/// Text on `primary`.
primary_foreground: Color,
/// A secondary action.
secondary: Color,
/// Quiet fills, key caps.
muted: Color,
/// Descriptions and hints.
muted_foreground: Color,
/// A hovered row or item.
accent: Color,
/// A destructive action, errors.
destructive: Color,
/// Text on `destructive`.
destructive_foreground: Color,
/// Hairlines.
border: Color,
/// Control outlines.
input: Color,
/// The focus ring, drawn at `ring_opacity`.
ring: Color,
/// Toast icons.
success: Color,
warning: Color,
info: Color,
/// Behind a dialog.
scrim: Color,

pub const dark: Theme = .{
    .background = .rgb(0x0a0a0a),
    .foreground = .rgb(0xfafafa),
    .card = .rgb(0x171717),
    .popover = .rgb(0x171717),
    .primary = .rgb(0xe5e5e5),
    .primary_foreground = .rgb(0x171717),
    .secondary = .rgb(0x262626),
    .muted = .rgb(0x262626),
    .muted_foreground = .rgb(0xa1a1a1),
    .accent = .rgb(0x262626),
    .destructive = .rgb(0xff6467),
    .destructive_foreground = .rgb(0x171717),
    .border = Color.rgb(0xffffff).alpha(10),
    .input = Color.rgb(0xffffff).alpha(15),
    .ring = .rgb(0x737373),
    .success = .rgb(0x00bc7d),
    .warning = .rgb(0xfe9a00),
    .info = .rgb(0x2b7fff),
    .scrim = Color.rgb(0x000000).alpha(50),
};

pub const light: Theme = .{
    .background = .rgb(0xffffff),
    .foreground = .rgb(0x0a0a0a),
    .card = .rgb(0xffffff),
    .popover = .rgb(0xffffff),
    .primary = .rgb(0x171717),
    .primary_foreground = .rgb(0xfafafa),
    .secondary = .rgb(0xf5f5f5),
    .muted = .rgb(0xf5f5f5),
    .muted_foreground = .rgb(0x737373),
    .accent = .rgb(0xf5f5f5),
    .destructive = .rgb(0xe7000b),
    .destructive_foreground = .rgb(0xffffff),
    .border = .rgb(0xe5e5e5),
    .input = .rgb(0xe5e5e5),
    .ring = .rgb(0xa1a1a1),
    .success = .rgb(0x009966),
    .warning = .rgb(0xe17100),
    .info = .rgb(0x155dfc),
    .scrim = Color.rgb(0x000000).alpha(50),
};

/// Dialogs, toasts, cards. shadcn's radii plus 3 (maintainer, 2026-11-12).
pub const radius = 13;
/// Buttons, inputs.
pub const radius_md = 11;
/// Key caps, badges.
pub const radius_sm = 9;
/// Every outline. Painted at least one physical pixel wide.
pub const border_width = 1;
/// The focus ring, outside the border.
pub const ring_width = 3;
/// Opacity of the focus ring, in percent.
pub const ring_opacity = 50;
/// The step every padding and gap is a multiple of.
pub const space = 4;
/// Heights of small, default and large controls.
pub const control_sm = 32;
pub const control = 36;
pub const control_lg = 40;
/// Icon edge length.
pub const icon = 16;
/// How long a toast or dialog takes to enter or leave, in milliseconds.
pub const duration = 200;

pub const Variant = enum {
    dark,
    light,

    pub fn theme(self: Variant) *const Theme {
        return switch (self) {
            .dark => &dark,
            .light => &light,
        };
    }
};

/// The variant that reads well over `background`, an sRGB color: dark
/// below a relative luminance of 0.179, where black and white text
/// contrast equally with it (WCAG 2.x relative luminance), else light.
pub fn variantFor(background: [3]u8) Variant {
    return if (relativeLuminance(background) < 0.179) .dark else .light;
}

/// WCAG 2.x relative luminance of an sRGB color, 0 (black) to 1 (white).
/// https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
fn relativeLuminance(color: [3]u8) f32 {
    var linear: [3]f32 = undefined;
    for (color, &linear) |channel, *out| {
        const c = @as(f32, @floatFromInt(channel)) / 255.0;
        out.* = if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

test relativeLuminance {
    try std.testing.expectEqual(0, relativeLuminance(.{ 0, 0, 0 }));
    try std.testing.expectApproxEqAbs(1, relativeLuminance(.{ 255, 255, 255 }), 1e-4);
    // Mid gray #808080 is about 0.216.
    try std.testing.expectApproxEqAbs(0.2159, relativeLuminance(.{ 0x80, 0x80, 0x80 }), 1e-3);
}
