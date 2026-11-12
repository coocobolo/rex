//! Text decorations: underline, strikethrough and overline, drawn in
//! their own pass from one instance per run of decorated cells.

const std = @import("std");

const Buffer = @import("buffer.zig").DecorationBuffer;
const gl = @import("gl.zig");
const Dimension = @import("dimension.zig").Dimension;
const Flags = @import("Frame.zig").Flags;
const InkMask = @import("InkMask.zig");
const UnderlineStyle = @import("../term/root.zig").cell.UnderlineStyle;
const Rasterizer = @import("../freetype/root.zig").Rasterizer;
const Shader = @import("Shader.zig");

pub const Decoration = @This();

/// One run of horizontally adjacent cells on a row that share the same
/// decorations and colors. The colors are resolved by the frame builder
/// and carry the dim alpha.
pub const Instance = extern struct {
    col: u16,
    row: u16,
    /// Number of columns the run covers.
    span: u16,
    underline: [4]u8,
    strikethrough: [4]u8,
    overline: [4]u8,
    flags: Flags,
    _pad: [1]u8 = .{0},

    /// True when `next` continues this run: the same row, starting where
    /// this run ends, with the same flags and colors.
    pub fn continuedBy(self: Instance, next: Instance) bool {
        return self.row == next.row and
            self.col + self.span == next.col and
            @as(u8, @bitCast(self.flags)) == @as(u8, @bitCast(next.flags)) and
            std.mem.eql(u8, &self.underline, &next.underline) and
            std.mem.eql(u8, &self.strikethrough, &next.strikethrough) and
            std.mem.eql(u8, &self.overline, &next.overline);
    }
};

comptime {
    std.debug.assert(20 == @sizeOf(Instance));
}

/// Appends `instance` to `runs`, or widens the last run when `instance`
/// continues it. `runs` must have room for one more instance.
pub fn appendRun(runs: *std.ArrayListUnmanaged(Instance), instance: Instance) void {
    if (runs.items.len > 0) {
        const last = &runs.items[runs.items.len - 1];
        if (last.continuedBy(instance)) {
            last.span += instance.span;
            return;
        }
    }
    runs.appendAssumeCapacity(instance);
}

/// Adjusts one decoration line. Pixels are measured down from the top
/// of the cell. Every field left at its default keeps the font's line.
pub const Line = struct {
    /// Top of the line, replacing the font's position. null keeps the
    /// font's position.
    y: ?f32 = null,

    /// Added to the position after `y`, positive moves the line down.
    /// Unlike `y` it keeps following the font when the size changes.
    offset: f32 = 0,

    /// Thickness, replacing the font's. null keeps the font's.
    thickness: ?f32 = null,

    /// Multiplies the thickness after `thickness`.
    thickness_scale: f32 = 1.0,

    /// Applies the adjustments to the font line `font`, then rounds and
    /// clamps the result into a cell `cell_height` pixels tall.
    pub fn resolve(self: Line, font: Rasterizer.Line, cell_height: u16) Rasterizer.Line {
        const top = (self.y orelse font.y) + self.offset;
        const thickness = (self.thickness orelse font.thickness) * self.thickness_scale;
        return .fit(top, thickness, cell_height);
    }
};

/// On and off lengths of a dotted or dashed underline, in pixels.
pub const Pattern = struct {
    /// Length of each dot or dash. null derives it from the cell width.
    length: ?f32 = null,
    /// Space after each dot or dash. null derives it from the cell width,
    /// or uses `length` when only that is set.
    gap: ?f32 = null,
};

/// Where dotted, dashed and curly patterns start.
pub const Phase = enum {
    /// From the left edge of the window, so a pattern lines up across
    /// rows and does not move when the run around it changes.
    grid,
    /// From the first cell of each run of decorated cells.
    run,
};

/// Breaks the underline where glyph ink crosses it, like the CSS
/// `text-decoration-skip-ink: auto` browsers apply by default.
pub const SkipInk = struct {
    enabled: bool = true,

    /// Clearance kept between the ink and the line, in pixels, both
    /// beside and above or below it. null uses the underline thickness.
    gap: ?f32 = null,

    /// Pieces of line shorter than this, in pixels, between two gaps are
    /// dropped too, so no specks are left between descenders. null uses
    /// twice the underline thickness. 0 keeps every piece.
    min_segment: ?f32 = null,

    /// Glyph coverage, 0.0 to 1.0, from which a pixel counts as ink.
    /// Lower values also skip the faint antialiased edges.
    threshold: f32 = 0.25,

    /// Underline styles that skip ink.
    styles: struct {
        single: bool = true,
        double: bool = true,
        curly: bool = true,
        dotted: bool = true,
        dashed: bool = true,
    } = .{},

    /// Bit `n` set when UnderlineStyle value `n` skips ink, as the
    /// shader reads it. 0 when skipping is off.
    pub fn styleBits(self: SkipInk) u32 {
        if (!self.enabled) return 0;
        var bits: u32 = 0;
        if (self.styles.single) bits |= 1 << @intFromEnum(UnderlineStyle.single);
        if (self.styles.double) bits |= 1 << @intFromEnum(UnderlineStyle.double);
        if (self.styles.curly) bits |= 1 << @intFromEnum(UnderlineStyle.curly);
        if (self.styles.dotted) bits |= 1 << @intFromEnum(UnderlineStyle.dotted);
        if (self.styles.dashed) bits |= 1 << @intFromEnum(UnderlineStyle.dashed);
        return bits;
    }
};

/// Whether decorations are drawn over or under the glyphs.
pub const Order = enum {
    /// Lines cross the glyphs, descenders do not hide the underline.
    over_text,
    /// Glyphs cover the lines, as in the background pass.
    under_text,
};

/// User settings for decorations. The defaults draw every line where
/// the font puts it, in the text color.
pub const Option = struct {
    underline: Line = .{},

    /// Gap between the two lines of a double underline, in pixels.
    /// null uses the underline thickness, narrowed down to 1 px when
    /// that keeps the upper line below the baseline, off the glyphs.
    double_gap: ?f32 = null,

    /// Curly underline, a sine wave centred on the underline.
    curly: struct {
        /// Height of a crest above the centre, in pixels. null uses one and
        /// a half underline thicknesses. The wave is kept inside the cell.
        amplitude: ?f32 = null,
        /// Length of one full wave, in pixels. null uses the cell width,
        /// one wave per cell.
        wavelength: ?f32 = null,
    } = .{},

    /// null fields fit whole dots into each cell, each as long as the
    /// space after it.
    dotted: Pattern = .{},

    /// null fields draw one dash per cell, half the cell long and
    /// centred in it.
    dashed: Pattern = .{},

    phase: Phase = .grid,

    skip_ink: SkipInk = .{},

    strikethrough: Line = .{},

    /// Fonts have no overline metric: by default it sits at the top of
    /// the cell, as thick as the resolved underline.
    overline: Line = .{},

    /// Fixed color for each kind of line. null draws it in the text
    /// color, after SGR 7, DECSCNM and the selection text color.
    color: struct {
        underline: ?[3]u8 = null,
        strikethrough: ?[3]u8 = null,
        overline: ?[3]u8 = null,
    } = .{},

    /// Opacity of every line, 0.0 to 1.0, on top of the dim alpha.
    alpha: f32 = 1.0,

    /// Lines of SGR 2 (dim) text are dimmed like the text.
    dim: bool = true,

    /// Lines of SGR 5 and 6 (blink) text blink with the text.
    blink: bool = true,

    order: Order = .over_text,
};

/// Where each decoration line sits, in whole pixels down from the top
/// of the cell, as the shaders read it.
pub const Metrics = struct {
    underline_y: f32,
    underline_thickness: f32,
    /// Top of the upper line of a double underline. The lower line is
    /// the underline itself.
    double_y: f32,
    /// Centre line and size of the curly underline wave.
    curly_y: f32,
    curly_amplitude: f32,
    curly_wavelength: f32,
    dot_length: f32,
    dot_gap: f32,
    dash_length: f32,
    dash_gap: f32,
    /// Whole pixels of clearance around ink, see SkipInk.gap.
    ink_gap: u32,
    /// Shortest piece of underline kept between ink, in whole pixels.
    ink_min_segment: u32,
    strikethrough_y: f32,
    strikethrough_thickness: f32,
    overline_y: f32,
    overline_thickness: f32,
    /// Baseline, down from the top of the cell. Ink above it does not
    /// break a line drawn below it, so glyphs resting on the baseline
    /// keep a double underline whole.
    baseline: f32,

    /// Resolves the font's lines through the user's `option`.
    pub fn resolve(font: Rasterizer.Metrics, option: Option) Metrics {
        const height = font.cell_height;
        const underline = option.underline.resolve(.{
            .y = font.underline_y,
            .thickness = font.underline_thickness,
        }, height);
        const strikethrough = option.strikethrough.resolve(.{
            .y = font.strikethrough_y,
            .thickness = font.strikethrough_thickness,
        }, height);
        const overline = option.overline.resolve(.{
            .y = 0,
            .thickness = underline.thickness,
        }, height);
        const cell_width: f32 = @floatFromInt(@max(font.cell_width, 1));
        const cell_height: f32 = @floatFromInt(@max(height, 1));
        const t = underline.thickness;

        // The wave and its thickness must fit in the cell: shrink the
        // amplitude to half the free height, then move the centre so the
        // troughs stay above the cell bottom.
        const reach_max = @max(0, (cell_height - t) * 0.5);
        const amplitude = std.math.clamp(option.curly.amplitude orelse t * 1.5, 0, reach_max);
        const reach = amplitude + t * 0.5;
        const curly_y = std.math.clamp(underline.y + t * 0.5, reach, cell_height - reach);

        const dots_per_cell = @max(1.0, @round(cell_width / (2.0 * t)));
        const dot_half = cell_width / dots_per_cell * 0.5;
        const dot = resolvePattern(option.dotted, dot_half, dot_half);
        const dash_length = @round(cell_width * 0.5);
        const dash = resolvePattern(option.dashed, dash_length, cell_width - dash_length);

        return .{
            .underline_y = underline.y,
            .underline_thickness = underline.thickness,
            .double_y = doubleY(underline, @floatFromInt(font.ascender), option.double_gap),
            .baseline = @floatFromInt(font.ascender),
            .curly_y = curly_y,
            .curly_amplitude = amplitude,
            .curly_wavelength = @max(2.0, option.curly.wavelength orelse cell_width),
            .dot_length = dot.length,
            .dot_gap = dot.gap,
            .dash_length = dash.length,
            .dash_gap = dash.gap,
            .ink_gap = wholePixels(option.skip_ink.gap orelse t),
            .ink_min_segment = wholePixels(option.skip_ink.min_segment orelse t * 2.0),
            .strikethrough_y = strikethrough.y,
            .strikethrough_thickness = strikethrough.thickness,
            .overline_y = overline.y,
            .overline_thickness = overline.thickness,
        };
    }

    /// Top of the upper line of a double underline: `gap` above the
    /// underline when set, else one underline thickness above it, moved
    /// down to the baseline when the cell leaves room for a 1 px gap.
    fn doubleY(underline: Rasterizer.Line, baseline: f32, gap: ?f32) f32 {
        const t = underline.thickness;
        if (gap) |g| return @max(0, underline.y - @round(@max(0, g)) - t);
        const upper = underline.y - 2 * t;
        if (upper >= baseline) return @max(0, upper);
        return @max(0, @max(upper, @min(baseline, underline.y - t - 1)));
    }

    /// The shader scans at most this many pixels each way for ink.
    pub const max_ink_scan = 64;

    fn wholePixels(px: f32) u32 {
        return @intFromFloat(std.math.clamp(@round(px), 0, max_ink_scan / 2));
    }

    const Resolved = struct { length: f32, gap: f32 };

    fn resolvePattern(pattern: Pattern, length: f32, gap: f32) Resolved {
        const on = @max(1.0, pattern.length orelse length);
        const off = @max(0.0, pattern.gap orelse (if (pattern.length != null) on else gap));
        return .{ .length = on, .gap = off };
    }

    /// Sets the `u_underline_*`, `u_double_y`, `u_curly_*`, `u_dot_*`,
    /// `u_dash_*`, `u_strikethrough_*` and `u_overline_*` uniforms on the
    /// bound `shader`.
    pub fn apply(self: Metrics, shader: Shader) void {
        shader.set1f("u_underline_y", self.underline_y);
        shader.set1f("u_underline_thickness", self.underline_thickness);
        shader.set1f("u_double_y", self.double_y);
        shader.set1f("u_curly_y", self.curly_y);
        shader.set1f("u_curly_amplitude", self.curly_amplitude);
        shader.set1f("u_curly_wavelength", self.curly_wavelength);
        shader.set1f("u_dot_length", self.dot_length);
        shader.set1f("u_dot_gap", self.dot_gap);
        shader.set1f("u_dash_length", self.dash_length);
        shader.set1f("u_dash_gap", self.dash_gap);
        shader.set1i("u_ink_gap", @intCast(self.ink_gap));
        shader.set1i("u_ink_min_segment", @intCast(self.ink_min_segment));
        shader.set1f("u_strikethrough_y", self.strikethrough_y);
        shader.set1f("u_strikethrough_thickness", self.strikethrough_thickness);
        shader.set1f("u_overline_y", self.overline_y);
        shader.set1f("u_overline_thickness", self.overline_thickness);
        shader.set1f("u_baseline", self.baseline);
    }
};

shader: Shader,
buffer: Buffer,
option: Option,

/// True when any run has an underline, the only line that skips ink.
pub fn anyUnderline(instances: []const Instance) bool {
    for (instances) |run| if (run.flags.underline != .none) return true;
    return false;
}

pub fn init(capacity: usize, option: Option) !Decoration {
    var shader: Shader = try .init(
        @embedFile("shaders/decoration.vert"),
        @embedFile("shaders/decoration.frag"),
    );
    errdefer shader.deinit();

    return .{
        .buffer = .init(capacity),
        .option = option,
        .shader = shader,
    };
}

pub fn deinit(self: *Decoration) void {
    self.shader.deinit();
    self.buffer.deinit();
    self.* = undefined;
}

pub fn upload(self: *Decoration, instances: []const Instance) void {
    if (instances.len > 0) self.buffer.upload(instances);
}

pub fn uploadRange(self: *Decoration, instances: []const Instance, offset: usize, count: usize) void {
    if (count > 0) self.buffer.uploadRange(instances, offset, count);
}

pub fn draw(
    self: *Decoration,
    instance_length: usize,
    dimension: struct {
        cell: Dimension(f32),
        frame: Dimension(f32),
    },
    metrics: Metrics,
    /// Glyph coverage of this frame, or null to draw through ink.
    ink_mask: ?*const InkMask,
    blink_on: bool,
    blink_rapid_on: bool,
) void {
    if (instance_length == 0) return;
    self.shader.use();
    self.shader.set2f("u_cell_size", dimension.cell.width, dimension.cell.height);
    self.shader.set2f("u_screen_size", dimension.frame.width, dimension.frame.height);
    self.shader.set1f("u_alpha", std.math.clamp(self.option.alpha, 0.0, 1.0));
    self.shader.set1i("u_blink_on", @intFromBool(blink_on));
    self.shader.set1i("u_blink_rapid_on", @intFromBool(blink_rapid_on));
    self.shader.set1i("u_phase_grid", @intFromBool(self.option.phase == .grid));
    if (ink_mask) |mask| {
        mask.bind(gl.TEXTURE2);
        self.shader.set1i("u_ink_mask", 2);
        self.shader.set1ui("u_skip_ink_styles", self.option.skip_ink.styleBits());
        self.shader.set1f("u_ink_threshold", self.option.skip_ink.threshold);
    } else {
        self.shader.set1ui("u_skip_ink_styles", 0);
    }
    metrics.apply(self.shader);
    self.buffer.draw(instance_length);
}
