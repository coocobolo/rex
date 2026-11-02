pub const ScrollbarGeometry = struct {
    // All values in pixels, y=0 at top

    track_x: f32,
    track_y: f32 = 0,
    track_w: f32,
    track_h: f32,

    thumb_y: f32,
    thumb_h: f32,

    pub fn compute(
        fb_w: f32,
        fb_h: f32,
        active_rows: u32,
        scrollback_used: u32,
        viewport_offset: u32,
        bar_width: f32,
    ) ScrollbarGeometry {
        const total_rows = active_rows + scrollback_used;
        const thumb_h_ratio =
            @as(f32, @floatFromInt(active_rows)) / @as(f32, @floatFromInt(total_rows));
        const thumb_top_ratio =
            @as(f32, @floatFromInt(scrollback_used - viewport_offset)) / @as(f32, @floatFromInt(total_rows));

        const thumb_h = @max(thumb_h_ratio * fb_h, 8.0); // min 8px
        const thumb_y = thumb_top_ratio * fb_h;
        return .{
            .track_x = fb_w - bar_width,
            .track_w = bar_width,
            .track_h = fb_h,
            .thumb_y = thumb_y,
            .thumb_h = thumb_h,
        };
    }

    pub fn isVisible(scrollback_used: u32) bool {
        return scrollback_used > 0;
    }
};