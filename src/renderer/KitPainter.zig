//! Draws a laid-out UI kit tree (ADR 0009): every box becomes a rounded
//! rectangle and every text a run of glyphs, all in one instanced draw
//! call in the order of the node array, so later nodes cover earlier ones
//! whatever their kind.
//!
//! Glyphs come from a `KitFont` and are packed into the terminal's gray
//! atlas texture through `Atlas.upload`; the painter keeps its own cache of
//! where each one sits, because the atlas's cache is keyed by the terminal's
//! faces. When the atlas is invalidated or the display scale changes, call
//! `clearGlyphs`.
//!
//! Nothing here allocates. A view with more instances than `capacity`, or
//! more distinct non-ASCII glyphs than the cache holds, gets an error and
//! the caller decides; nothing is dropped silently.

const KitPainter = @This();

const std = @import("std");

const gl = @import("gl.zig");
const Shader = @import("Shader.zig");
const Atlas = @import("Atlas.zig");
const KitFont = @import("../freetype/KitFont.zig");
const Color = @import("../kit/Theme.zig").Color;
const text = @import("../kit/text.zig");
const tree_zig = @import("../kit/tree.zig");
const Tree = tree_zig.Tree;
const layout = @import("../kit/layout.zig");

const log = std.log.scoped(.kit_painter);

pub const Kind = enum(u32) { box = 0, glyph = 1 };

/// One box or glyph, as the shader reads it (`shaders/kit.vert`).
pub const Instance = extern struct {
    /// x, y, width, height in physical pixels.
    rect: [4]f32,
    /// Box fill or glyph color.
    fill: Color,
    /// Box border color.
    border: Color = .transparent,
    /// Box: corner radius and border width. Glyph: its atlas x and y.
    params: [2]f32,
    kind: Kind,
    /// Left, top, right and bottom in physical pixels: the shader drops
    /// what falls outside. `no_clip` for none.
    clip: Clip = no_clip,
};

pub const Clip = [4]i16;
pub const no_clip: Clip = .{ std.math.minInt(i16), std.math.minInt(i16), std.math.maxInt(i16), std.math.maxInt(i16) };

/// Clipping boxes nested inside each other that one tree can hold.
pub const clip_depth_max = 8;

/// Most instances one frame can hold: a full settings page of text is a
/// few hundred glyphs.
pub const capacity = 2048;

const style_count = text.Style.count;
/// Distinct glyphs outside ASCII the painter remembers.
const extra_capacity = 256;

const ExtraGlyph = struct {
    style: text.Style,
    codepoint: u21,
    metric: Atlas.Metric,
};

/// Distinct icons, by code point and size, the painter remembers.
const icon_capacity = 32;

const IconGlyph = struct {
    codepoint: u21,
    size: u8,
    metric: Atlas.Metric,
};

pub const Error = error{ OutOfInstances, GlyphCacheFull, ClipTooDeep };

shader: Shader,
vao: gl.GLuint,
vbo: gl.GLuint,

instances: [capacity]Instance = undefined,
len: u32 = 0,

/// Where each ASCII glyph sits in the atlas, per style.
ascii: [style_count][128]?Atlas.Metric = @splat(@splat(null)),
extra: [extra_capacity]ExtraGlyph = undefined,
extra_len: u32 = 0,
icons: [icon_capacity]IconGlyph = undefined,
icons_len: u32 = 0,

/// Needs a current GL context.
pub fn init() Shader.Error!KitPainter {
    var self: KitPainter = .{
        .shader = try Shader.init(@embedFile("shaders/kit.vert"), @embedFile("shaders/kit.frag")),
        .vao = 0,
        .vbo = 0,
    };
    gl.genVertexArrays(1, &self.vao);
    gl.genBuffers(1, &self.vbo);
    gl.bindVertexArray(self.vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, self.vbo);
    gl.bufferData(gl.ARRAY_BUFFER, capacity * @sizeOf(Instance), null, gl.DYNAMIC_DRAW);

    const stride: gl.GLsizei = @sizeOf(Instance);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 4, gl.FLOAT, gl.FALSE, stride, offsetPointer("rect"));
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 4, gl.UNSIGNED_BYTE, gl.TRUE, stride, offsetPointer("fill"));
    gl.enableVertexAttribArray(2);
    gl.vertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, gl.TRUE, stride, offsetPointer("border"));
    gl.enableVertexAttribArray(3);
    gl.vertexAttribPointer(3, 2, gl.FLOAT, gl.FALSE, stride, offsetPointer("params"));
    gl.enableVertexAttribArray(4);
    gl.vertexAttribIPointer(4, 1, gl.UNSIGNED_INT, stride, offsetPointer("kind"));
    gl.enableVertexAttribArray(5);
    gl.vertexAttribIPointer(5, 4, gl.SHORT, stride, offsetPointer("clip"));
    inline for (0..6) |location| gl.vertexAttribDivisor(location, 1);

    gl.bindVertexArray(0);
    gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    return self;
}

fn offsetPointer(comptime field: []const u8) ?*const anyopaque {
    return @ptrFromInt(@offsetOf(Instance, field));
}

pub fn deinit(self: *KitPainter) void {
    gl.deleteVertexArrays(1, &self.vao);
    gl.deleteBuffers(1, &self.vbo);
    self.shader.deinit();
    self.* = undefined;
}

/// Forgets where glyphs sit. Call after `Atlas.invalidate` and after
/// `KitFont.setScale`: both leave the remembered positions wrong.
pub fn clearGlyphs(self: *KitPainter) void {
    self.ascii = @splat(@splat(null));
    self.extra_len = 0;
    self.icons_len = 0;
}

/// Starts a frame with no instances.
pub fn begin(self: *KitPainter) void {
    self.len = 0;
}

/// Appends the instances of a laid-out `tree`, at the scale of `font`.
/// Trees painted later are drawn on top. What a clipping box
/// (`Box.overflow`) cuts away is dropped by the shader, and an instance
/// it cuts away entirely is not appended.
pub fn paint(self: *KitPainter, tree: *const Tree, font: *KitFont, atlas: *Atlas) Error!void {
    const scale = font.scale;
    // The clipping boxes around the current node: where each one's
    // descendants end, and its cut intersected with those outside it.
    var clips: [clip_depth_max]struct { end: tree_zig.Index, clip: Clip } = undefined;
    var depth: usize = 0;
    for (tree.items(), 0..) |*node, node_index| {
        while (depth > 0 and node_index >= clips[depth - 1].end) depth -= 1;
        const clip = if (depth > 0) clips[depth - 1].clip else no_clip;
        if (node.box.overflow == .clip) {
            if (depth == clip_depth_max) return error.ClipTooDeep;
            clips[depth] = .{ .end = node.end, .clip = intersect(clip, clipOf(layout.snap(node.rect, scale))) };
            depth += 1;
        }
        switch (node.content) {
            .box => {
                const box = node.box;
                const stroke = if (box.border.a == 0) 0 else layout.strokePixels(box.border_width, scale);
                if (box.fill.a == 0 and stroke == 0) continue;
                const rect = layout.snap(node.rect, scale);
                try self.push(.{
                    .rect = pixels(rect),
                    .fill = box.fill,
                    .border = box.border,
                    .params = .{ @as(f32, @floatFromInt(box.radius)) * scale, @floatFromInt(stroke) },
                    .kind = .box,
                    .clip = clip,
                });
            },
            .icon => |icon| {
                const metric = self.iconGlyph(icon.codepoint, icon.size, font, atlas) catch |err| switch (err) {
                    error.GlyphCacheFull => return error.GlyphCacheFull,
                    // An icon that cannot be rasterized or packed is left
                    // out; the text beside it still reads.
                    else => {
                        log.warn("icon U+{X:0>4} at {d} px: {t}", .{ icon.codepoint, icon.size, err });
                        continue;
                    },
                };
                if (metric.width == 0 or metric.height == 0) continue;
                // The bitmap centered in the node, on whole pixels.
                const rect = layout.snap(node.rect, scale);
                try self.push(.{
                    .rect = .{
                        @floatFromInt(rect.x + @divFloor(rect.w - @as(i32, metric.width), 2)),
                        @floatFromInt(rect.y + @divFloor(rect.h - @as(i32, metric.height), 2)),
                        @floatFromInt(metric.width),
                        @floatFromInt(metric.height),
                    },
                    .fill = icon.color,
                    .params = .{ @floatFromInt(metric.atlas_x), @floatFromInt(metric.atlas_y) },
                    .kind = .glyph,
                    .clip = clip,
                });
            },
            .text => |t| {
                const line_height: f32 = @floatFromInt(t.style.metrics().line_height);
                for (tree.lines.slice(t.first_line, t.line_count), 0..) |line, index| {
                    const top = (node.rect.y + line_height * @as(f32, @floatFromInt(index))) * scale;
                    try self.paintLine(t.bytes[line.start..line.end], t.style, t.figures, t.color, node.rect.x * scale, @round(top + font.baseline(t.style)), clip, font, atlas);
                }
            },
        }
    }
}

fn clipOf(rect: layout.PixelRect) Clip {
    return .{
        std.math.lossyCast(i16, rect.x),
        std.math.lossyCast(i16, rect.y),
        std.math.lossyCast(i16, rect.x + rect.w),
        std.math.lossyCast(i16, rect.y + rect.h),
    };
}

fn intersect(a: Clip, b: Clip) Clip {
    return .{ @max(a[0], b[0]), @max(a[1], b[1]), @min(a[2], b[2]), @min(a[3], b[3]) };
}

fn pixels(rect: layout.PixelRect) [4]f32 {
    return .{ @floatFromInt(rect.x), @floatFromInt(rect.y), @floatFromInt(rect.w), @floatFromInt(rect.h) };
}

fn paintLine(self: *KitPainter, bytes: []const u8, style: text.Style, figures: text.Figures, color: Color, left: f32, baseline: f32, clip: Clip, font: *KitFont, atlas: *Atlas) Error!void {
    // Same split as `KitFont.width`: proportional text with no tracking
    // never enters the digit-cell path.
    if (figures == .proportional and style.metrics().tracking == 0) {
        var pen = left;
        var previous: ?u21 = null;
        var codepoints: text.Codepoints = .init(bytes);
        while (codepoints.next()) |codepoint| {
            if (previous) |before| pen += font.kern(style, before, codepoint);
            previous = codepoint;
            defer pen += font.advance(style, codepoint);
            try self.paintGlyph(style, codepoint, color, pen, baseline, clip, font, atlas);
        }
        return;
    }
    var pen = left;
    var previous: ?u21 = null;
    var codepoints: text.Codepoints = .init(bytes);
    while (codepoints.next()) |codepoint| {
        const moved = font.step(style, figures, previous, codepoint);
        previous = codepoint;
        pen += moved.before;
        defer pen += moved.after;
        try self.paintGlyph(style, codepoint, color, pen, baseline, clip, font, atlas);
    }
}

fn paintGlyph(self: *KitPainter, style: text.Style, codepoint: u21, color: Color, pen: f32, baseline: f32, clip: Clip, font: *KitFont, atlas: *Atlas) Error!void {
    const metric = self.glyph(style, codepoint, font, atlas) catch |err| switch (err) {
        error.GlyphCacheFull => return error.GlyphCacheFull,
        // A glyph that cannot be rasterized or packed leaves a gap of
        // its advance; the text around it still reads.
        else => {
            log.warn("glyph U+{X:0>4} in {t}: {t}", .{ codepoint, style, err });
            return;
        },
    };
    if (metric.width == 0 or metric.height == 0) return;
    try self.push(.{
        // Each glyph sits on a whole pixel: its bitmap was rasterized
        // for one, and a fractional position would blur it.
        .rect = .{
            @round(pen) + @as(f32, @floatFromInt(metric.bearing_x)),
            baseline - @as(f32, @floatFromInt(metric.bearing_y)),
            @floatFromInt(metric.width),
            @floatFromInt(metric.height),
        },
        .fill = color,
        .params = .{ @floatFromInt(metric.atlas_x), @floatFromInt(metric.atlas_y) },
        .kind = .glyph,
        .clip = clip,
    });
}

/// Appends `instance`, unless its clip cuts it away entirely.
fn push(self: *KitPainter, instance: Instance) error{OutOfInstances}!void {
    const clip = instance.clip;
    const r = instance.rect;
    if (r[0] >= @as(f32, @floatFromInt(clip[2])) or r[1] >= @as(f32, @floatFromInt(clip[3])) or
        r[0] + r[2] <= @as(f32, @floatFromInt(clip[0])) or r[1] + r[3] <= @as(f32, @floatFromInt(clip[1]))) return;
    if (self.len == capacity) return error.OutOfInstances;
    self.instances[self.len] = instance;
    self.len += 1;
}

/// Where `codepoint` in `style` sits in the atlas, rasterizing and packing
/// it on first use.
fn glyph(self: *KitPainter, style: text.Style, codepoint: u21, font: *KitFont, atlas: *Atlas) !Atlas.Metric {
    if (codepoint < 128) {
        const slot = &self.ascii[@intFromEnum(style)][codepoint];
        if (slot.*) |metric| return metric;
        const metric = try atlas.upload(try font.rasterize(style, codepoint));
        slot.* = metric;
        return metric;
    }
    for (self.extra[0..self.extra_len]) |entry| {
        if (entry.codepoint == codepoint and entry.style == style) return entry.metric;
    }
    if (self.extra_len == extra_capacity) return error.GlyphCacheFull;
    const metric = try atlas.upload(try font.rasterize(style, codepoint));
    self.extra[self.extra_len] = .{ .style = style, .codepoint = codepoint, .metric = metric };
    self.extra_len += 1;
    return metric;
}

/// Where the icon `codepoint` at `size` logical pixels sits in the atlas,
/// rasterizing and packing it on first use.
fn iconGlyph(self: *KitPainter, codepoint: u21, size: u8, font: *KitFont, atlas: *Atlas) !Atlas.Metric {
    for (self.icons[0..self.icons_len]) |entry| {
        if (entry.codepoint == codepoint and entry.size == size) return entry.metric;
    }
    if (self.icons_len == icon_capacity) return error.GlyphCacheFull;
    const metric = try atlas.upload(try font.rasterizeIcon(codepoint, size));
    self.icons[self.icons_len] = .{ .codepoint = codepoint, .size = size, .metric = metric };
    self.icons_len += 1;
    return metric;
}

/// Draws the frame's instances into the bound framebuffer, which is
/// `width` by `height` pixels, blending with straight alpha.
pub fn draw(self: *const KitPainter, atlas: *const Atlas, width: f32, height: f32) void {
    if (self.len == 0) return;
    gl.enable(gl.BLEND);
    gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);

    gl.bindBuffer(gl.ARRAY_BUFFER, self.vbo);
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, @intCast(@as(usize, self.len) * @sizeOf(Instance)), &self.instances);
    gl.bindBuffer(gl.ARRAY_BUFFER, 0);

    self.shader.use();
    self.shader.set2f("u_fb", width, height);
    self.shader.set2f("u_atlas", @floatFromInt(atlas.width), @floatFromInt(atlas.height));
    self.shader.set1i("u_atlas_gray", 0);
    atlas.bindTextures(gl.TEXTURE0, gl.TEXTURE1);

    gl.bindVertexArray(self.vao);
    gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(self.len));
    gl.bindVertexArray(0);
    self.shader.unbind();
}
