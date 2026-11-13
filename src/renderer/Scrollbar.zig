const Scrollbar = @This();

const std = @import("std");

const window_config = @import("../config/window.zig");
const log = std.log.scoped(.scrollbar);

const gl = @import("gl.zig");
const Shader = @import("Shader.zig");
const Dimension = @import("dimension.zig").Dimension;

pub const State = struct {
    /// Thumb position along its travel: 0 at the top (oldest line),
    /// 1 at the bottom (live view).
    thumb_top_frac: f32,
    /// Visible rows over all rows, 0 to 1.
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

/// Where the thumb sits and how much of the track it fills, as
/// fractions of the track, for a screen's scrollback state.
pub const Fractions = struct {
    /// 0 at the top (oldest line), 1 at the bottom (live view).
    top: f32,
    /// Visible rows over all rows, 0 to 1.
    height: f32,

    /// Fractions for `active_rows` visible rows above `scrollback_used`
    /// scrollback rows, scrolled `viewport_offset` rows back. With no
    /// rows at all the thumb fills the track. With no scrollback it
    /// sits at the bottom. An offset past the scrollback, which a
    /// resize can leave for a moment, is clamped.
    pub fn of(active_rows: u32, scrollback_used: u32, viewport_offset: u32) Fractions {
        const total = @as(u64, active_rows) + scrollback_used;
        if (total == 0) return .{ .top = 1.0, .height = 1.0 };
        const height = @as(f32, @floatFromInt(active_rows)) / @as(f32, @floatFromInt(total));
        if (scrollback_used == 0) return .{ .top = 1.0, .height = height };
        const offset = @min(viewport_offset, scrollback_used);
        const scroll = @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(scrollback_used));
        return .{ .top = 1.0 - scroll, .height = height };
    }

    /// The viewport offset that puts the thumb at `top`, in rows back
    /// from the live view, out of `scrollback_used`.
    pub fn viewportOffsetAt(top: f32, scrollback_used: u32) u32 {
        const back = 1.0 - std.math.clamp(top, 0.0, 1.0);
        const offset = @round(back * @as(f32, @floatFromInt(scrollback_used)));
        return @min(@as(u32, @intFromFloat(offset)), scrollback_used);
    }
};

/// The thumb's rectangle on a track, in pixels from the track's top.
pub const Thumb = struct {
    top: f32,
    height: f32,

    /// Places the thumb on a track `track_height` tall. It is
    /// `height_frac` of the track, but never shorter than `min_height`
    /// nor taller than the track, and sits `top_frac` of the way down
    /// what is left. Click and drag maths must use this too, so the
    /// area that responds is the one drawn.
    pub fn of(track_height: f32, top_frac: f32, height_frac: f32, min_height: f32) Thumb {
        const height = @min(@max(track_height * height_frac, min_height), track_height);
        return .{
            .height = height,
            .top = (track_height - height) * std.math.clamp(top_frac, 0.0, 1.0),
        };
    }

    /// How far the thumb's top can move on a track `track_height` tall.
    pub fn travel(self: Thumb, track_height: f32) f32 {
        return track_height - self.height;
    }

    /// The `top_frac` that puts this thumb's top at `top`, clamped to
    /// the track. A thumb that fills the track has no travel and stays
    /// at the bottom.
    pub fn topFracAt(self: Thumb, track_height: f32, top: f32) f32 {
        const travel_px = self.travel(track_height);
        if (travel_px <= 0) return 1.0;
        return std.math.clamp(top / travel_px, 0.0, 1.0);
    }
};

pub const Option = window_config.Scrollbar;

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

/// Advances the width and fade animations by `dt_ms`. Returns true
/// while they are still moving, so the caller should redraw.
pub fn tick(self: *Scrollbar, dt_ms: u64) bool {
    const target_width: f32 = if (self.hover)
        self.option.hover_width
    else
        self.option.width;

    // Fades to auto_hide_alpha at the live view, even when hovering.
    const target_alpha: f32 =
        if (self.option.auto_hide and self.at_live_view)
            self.option.auto_hide_alpha
        else
            1.0;

    // Lerp scaled by elapsed time: lerp_speed is a fraction per ms.
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
    // No scrollback_used == 0 guard: FrameBuilder hides the scrollbar
    // then, so draw is not called.

    const opt = self.option;
    const frame_dimension = self.last_frame;
    const thumb_top_frac = self.last_thumb_top_frac;
    const thumb_height_frac = self.last_thumb_height_frac;

    // The width animates, so bar_x cannot be cached in upload.
    const bar_x = frame_dimension.width - self.last_width - opt.gap;

    const thumb: Thumb = .of(frame_dimension.height, thumb_top_frac, thumb_height_frac, opt.min_thumb_height);

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
        thumb.top,
        self.last_width,
        thumb.height,
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
