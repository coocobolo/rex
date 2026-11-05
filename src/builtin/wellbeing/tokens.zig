const std = @import("std");
pub const ColorTokens = @import("../../color/Tokens.zig").Tokens;

/// Backward-compatible wrapper exposing static constants alongside the underlying type
pub const Tokens = struct {
    pub const bg = ColorTokens.dark.bg;
    pub const card = ColorTokens.dark.card;
    pub const card_opaque = ColorTokens.dark.card_opaque;
    pub const border = ColorTokens.dark.border;
    pub const border_subtle = ColorTokens.dark.border_subtle;
    pub const primary = ColorTokens.dark.primary;
    pub const secondary = ColorTokens.dark.secondary;
    pub const muted = ColorTokens.dark.muted;
    pub const accent = ColorTokens.dark.accent;
    pub const healthy = ColorTokens.dark.healthy;
    pub const warning = ColorTokens.dark.warning;
    pub const critical = ColorTokens.dark.critical;
    pub const info = ColorTokens.dark.info;

    pub const dark = ColorTokens.dark;
    pub const light = ColorTokens.light;
    pub const fromTheme = ColorTokens.fromTheme;
    pub const fromRgb = ColorTokens.fromRgb;
    pub const fromPalette = ColorTokens.fromPalette;
    pub const toF32Rgba = ColorTokens.toF32Rgba;
};

pub const toF32Rgba = ColorTokens.toF32Rgba;

pub const SemanticState = enum {
    healthy,
    warning,
    critical,
    info,

    pub fn color(self: SemanticState) [3]u8 {
        return switch (self) {
            .healthy => Tokens.healthy,
            .warning => Tokens.warning,
            .critical => Tokens.critical,
            .info => Tokens.info,
        };
    }
};
