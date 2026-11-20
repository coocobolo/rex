//! Maps the `[decoration]` and `[hyperlink]` config sections into the one
//! `Decoration.Option` used by the frame builder and the renderer (ADR 0014).

const Config = @import("../config/Config.zig");
const Decoration = @import("Decoration.zig");

fn rgb(color: ?@import("../color/Rgb.zig").Rgb) ?[3]u8 {
    const c = color orelse return null;
    return .{ c.r, c.g, c.b };
}

/// Builds the shared decoration option from the current config.
pub fn build(config: *const Config) Decoration.Option {
    const opt = config.decoration;
    const link = config.hyperlink;
    return .{
        .underline = .{
            .offset = opt.underline_offset_px,
            .thickness = opt.underline_thickness_px,
            .thickness_scale = opt.underline_thickness_scale,
        },
        .double_gap = opt.double_gap_px,
        .curly = .{
            .amplitude = opt.curly_amplitude_px,
            .wavelength = opt.curly_wavelength_px,
        },
        .dotted = .{
            .length = opt.dot_length_px,
            .gap = opt.dot_gap_px,
        },
        .dashed = .{
            .length = opt.dash_length_px,
            .gap = opt.dash_gap_px,
        },
        .phase = opt.phase,
        .skip_ink = .{
            .enabled = opt.skip_ink,
            .styles = opt.skip_ink_styles,
            .threshold = opt.skip_ink_threshold,
            .gap = opt.skip_ink_gap,
            .min_segment = opt.skip_ink_min_segment,
        },
        .order = opt.order,
        .alpha = opt.alpha,
        .dim = opt.dim,
        .blink = opt.blink,
        .strikethrough = .{
            .offset = opt.strikethrough_offset_px,
            .thickness = opt.strikethrough_thickness_px,
        },
        .overline = .{
            .offset = opt.overline_offset_px,
            .thickness = opt.overline_thickness_px,
        },
        .color = .{
            .underline = rgb(opt.underline_color),
            .strikethrough = rgb(opt.strikethrough_color),
            .overline = rgb(opt.overline_color),
        },
        .link = .{
            .underline = link.underline,
            .style = @enumFromInt(@intFromEnum(link.underline_style)),
            .color = rgb(link.underline_color),
        },
    };
}
