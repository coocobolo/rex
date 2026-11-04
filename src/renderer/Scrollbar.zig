const Scrollbar = @This();

const std = @import("std");
const log = std.log.scoped(.scrollbar);

const gl = @import("gl.zig");
const Shader = @import("Shader.zig");
const Dimension = @import("dimension.zig").Dimension;

pub const State = struct {
    thumb_top_frac: f32, // 0.0–1.0
    thumb_height_frac: f32,
    at_live_view: bool,
    visibility: bool,

    pub const empty: State = .{
        .visibility = false,
        .at_live_view = false,
        .thumb_top_frac = 0,
        .thumb_height_frac = 0,
    };
};

pub const Option = struct {
    /// normal thumb width (px)
    width: f32 = 5.0,
    /// expanded width on hover
    hover_width: f32 = 8.0,
    /// gap from window right edge
    gap: f32 = 2.0,
    /// minimum thumb height (px)
    min_thumb_height: f32 = 20.0,
    /// corner radius (px)
    radius: f32 = 4.0,
    track_color: [4]f32 = .{ 0.05, 0.05, 0.05, 1.0 },
    thumb_color: [4]f32 = .{ 0.7, 0.7, 0.7, 0.85 },
    thumb_hover_color: [4]f32 = .{ 0.9, 0.9, 0.9, 0.95 },
    /// linear interpolation animation speed (0..1 per frame)
    lerp_speed: f32 = 0.009,
    /// hide when at live view
    auto_hide: bool = true,
    /// target alpha when hidden, applied only when auto_hide enabeled
    auto_hide_alpha: f32 = 0.25,
};

shader: Shader,
vao: gl.GLuint,
option: Option,

last_frame: Dimension(f32),
last_thumb_top_frac: f32,
last_thumb_height_frac: f32,

// Animation state
last_width: f32,
last_alpha: f32,

// States
hover: bool = false,
at_live_view: bool = false,

pub fn init(option: Option) !Scrollbar {
    const shader = try Shader.init(
        @embedFile("shaders/scrollbar.vert"),
        @embedFile("shaders/scrollbar.frag"),
    );

    var vao: gl.GLuint = 0;
    gl.genVertexArrays(1, &vao);

    return .{
        .option = option,
        .last_alpha = if (option.auto_hide) 0.0 else 1.0,
        .last_width = option.width,
        .last_frame = .{ .height = 0, .width = 0 },
        .last_thumb_height_frac = 1.0,
        .last_thumb_top_frac = 1.0,
        .shader = shader,
        .vao = vao,
    };
}

pub fn deinit(self: *Scrollbar) void {
    self.shader.deinit();
    gl.deleteVertexArrays(1, &self.vao);
    self.* = undefined;
}

/// Returns true while still animating (caller should set redraw the frame).
pub fn tick(self: *Scrollbar, dt_ms: u64) bool {
    const target_width: f32 = if (self.hover)
        self.option.hover_width
    else
        self.option.width;

    // always 0.0 at live view, even when hovering
    const target_alpha: f32 =
        if (self.option.auto_hide and self.at_live_view)
            self.option.auto_hide_alpha
        else
            1.0;

    // dt-normalized lerp: lerp_speed is fraction-per-ms
    const t = @min(1.0, @as(f32, @floatFromInt(dt_ms)) * self.option.lerp_speed);
    self.last_width += (target_width - self.last_width) * t;
    self.last_alpha += (target_alpha - self.last_alpha) * t;
    return @abs(self.last_width - target_width) > 0.01 or
        @abs(self.last_alpha - target_alpha) > 0.01;
}

fn drawRect(
    self: *const Scrollbar,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    frame_dimension: Dimension(f32),
    color: [4]f32,
) void {
    self.shader.set4f("u_rect", x, y, w, h);
    self.shader.set2f("u_fb", frame_dimension.width, frame_dimension.height);
    self.shader.set2f("u_size", w, h);
    self.shader.set1f("u_radius", @min(self.option.radius, w * 0.5, h * 0.5));
    self.shader.set4f("u_color", color[0], color[1], color[2], color[3] * self.last_alpha);
    gl.bindVertexArray(self.vao);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    gl.bindVertexArray(0);
}

pub fn upload(
    self: *Scrollbar,
    frame_dimension: Dimension(f32),
    thumb_top_frac: f32,
    thumb_height_frac: f32,
    at_live_view: bool,
) void {
    self.at_live_view = at_live_view;
    self.last_frame = frame_dimension;
    self.last_thumb_top_frac = thumb_top_frac;
    self.last_thumb_height_frac = thumb_height_frac;
}

pub fn draw(self: *const Scrollbar) void {
    if (self.last_alpha < 0.01) return;
    // NOTE scrollback_used == 0 guard removed — FrameBuilder sets
    // scrollbar.visible = false when scrollback_used == 0, so Renderer
    // never calls draw() in that case.

    const opt = self.option;
    const frame_dimension = self.last_frame;
    const thumb_top_frac = self.last_thumb_top_frac;
    const thumb_height_frac = self.last_thumb_height_frac;

    // bar_x recomputed from current_width (animated — can't cache in upload)
    const bar_x = frame_dimension.width - self.last_width - opt.gap;

    // Clamp still lives here, Scrollbar owns config.min_thumb_h, FrameBuilder doesn't
    const thumb_height = @max(frame_dimension.height * thumb_height_frac, opt.min_thumb_height);
    const thumb_y = (frame_dimension.height - thumb_height) * thumb_top_frac;

    self.shader.use();
    if (opt.track_color[3] > 0.0) {
        self.drawRect(
            bar_x,
            0,
            self.last_width,
            frame_dimension.height,
            frame_dimension,
            opt.track_color,
        );
    }

    const thumb_color = if (self.hover) opt.thumb_hover_color else opt.thumb_color;
    self.drawRect(
        bar_x,
        thumb_y,
        self.last_width,
        thumb_height,
        frame_dimension,
        thumb_color,
    );
    self.shader.unbind();
}

pub inline fn setHover(self: *Scrollbar, v: bool) bool {
    const changed = self.hover != v;
    self.hover = v;
    return changed;
}

// Deprecated, used by old renderer
pub fn drawV1(
    self: *const Scrollbar,
    fb_w: f32,
    fb_h: f32,
    active_rows: usize,
    scrollback_used: usize,
    viewport_offset: usize,
) void {
    if (self.last_alpha < 0.01) return; // fully hidden, skip draw
    if (scrollback_used == 0) return;

    const cfg = self.option;
    const total_rows = active_rows + scrollback_used;
    const bar_x = fb_w - self.last_width - cfg.gap;

    // Thumb height proportional to visible fraction
    const visible_frac = @as(f32, @floatFromInt(active_rows)) /
        @as(f32, @floatFromInt(total_rows));
    const thumb_h = @max(fb_h * visible_frac, cfg.min_thumb_height);

    // Thumb Y: viewport_offset=0 → bottom, max offset = top
    const scroll_frac = @as(f32, @floatFromInt(viewport_offset)) /
        @as(f32, @floatFromInt(scrollback_used));
    const thumb_y = (fb_h - thumb_h) * (1.0 - scroll_frac);

    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    self.shader.use();

    // Track (optional: set track_color alpha to 0 to hide)
    if (cfg.track_color[3] > 0.0) {
        self.drawRect(bar_x, 0, self.last_width, fb_h, fb_w, fb_h, cfg.track_color);
    }

    // Thumb
    const thumb_color = if (self.hover) cfg.thumb_hover_color else cfg.thumb_color;
    self.drawRect(bar_x, thumb_y, self.last_width, thumb_h, fb_w, fb_h, thumb_color);

    self.shader.unbind();
    gl.disable(gl.BLEND);
}
