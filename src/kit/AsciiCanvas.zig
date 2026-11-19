//! Pure-Zig ASCII animation canvas, built-in procedural 3D/2D scenes, and
//! multi-frame UTF-8 ASCII file parser. Owns no I/O or OpenGL state and
//! performs zero heap allocations while rendering frames into its flat
//! 64-byte-aligned cell buffer.

const AsciiCanvas = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;

const Theme = @import("Theme.zig");
const Color = Theme.Color;

/// Maximum viewport columns this canvas holds.
pub const max_cols: u16 = 160;
/// Maximum viewport rows this canvas holds.
pub const max_rows: u16 = 80;
/// Total cells in the fixed flat canvas buffer.
pub const max_cells: usize = @as(usize, max_cols) * @as(usize, max_rows);

/// Flat row-major cell grid, 64-byte aligned (8 cells per cache line).
cells: [max_cells]Cell align(64) = @splat(.{}),
/// Active viewport width written by the most recent `render` call.
cols: u16 = 0,
/// Active viewport height written by the most recent `render` call.
rows: u16 = 0,
/// Number of non-empty cells written by the most recent `render` call.
non_empty: u32 = 0,

/// One rasterized cell in the canvas. `codepoint == 0` denotes an empty cell
/// skipped by the GPU overlay renderer.
pub const Cell = struct {
    codepoint: u21 = 0,
    fg: Color = .transparent,
};

/// Configured scene selection, shared with config and settings.
pub const Scene = enum(u8) {
    spin_3d,
    torus,
    breathe,
    wave,
    file,

    /// Maps a built-in scene to its procedural generator, or null for `.file`.
    pub fn toProcedural(self: Scene) ?Procedural {
        return switch (self) {
            .spin_3d => .spin_3d,
            .torus => .torus,
            .breathe => .breathe,
            .wave => .wave,
            .file => null,
        };
    }
};

/// Built-in procedural scene generators.
pub const Procedural = enum(u8) {
    spin_3d,
    torus,
    breathe,
    wave,
};

/// Cell aspect mode used by the overlay renderer and scene projection.
pub const CellAspect = enum(u8) {
    square,
    terminal,
};

/// Which wellbeing reminders display the fullscreen ASCII overlay.
pub const Trigger = enum(u8) {
    all,
    lock_only,
};

/// Theme-derived colors used to shade glyphs on the canvas.
pub const Palette = struct {
    fg: Color,
    accent: Color,
    muted: Color,

    pub fn fromTheme(theme: *const Theme, accent: Color) Palette {
        return .{
            .fg = theme.foreground,
            .accent = accent,
            .muted = theme.muted_foreground,
        };
    }
};

/// Render parameters for one animation frame.
pub const RenderOptions = struct {
    cols: u16,
    rows: u16,
    time_s: f32 = 0,
    progress: f32 = 0,
    aspect: CellAspect = .square,
    palette: Palette,
};

/// Resolved animation input rendered into the canvas.
pub const Source = union(enum) {
    procedural: Procedural,
    frames: *const Frames,
};

/// Pre-parsed multi-frame ASCII animation stored in two contiguous flat slices.
/// Owned by the caller; release with `deinit` using the same allocator.
pub const Frames = struct {
    meta: []const FrameMeta,
    codepoints: []const u21,
    fps: u8,

    pub const max_file_bytes: usize = 512 * 1024;
    pub const max_frames: u16 = 256;
    pub const default_fps: u8 = 12;
    pub const min_fps: u8 = 1;
    pub const max_fps: u8 = 60;

    pub const ParseError = error{
        EmptyAnimation,
        FileTooLarge,
        TooManyFrames,
        InvalidUtf8,
    } || Allocator.Error;

    pub const FrameMeta = struct {
        offset: u32,
        width: u16,
        height: u16,
    };

    /// Parses UTF-8 frame-delimited ASCII art into contiguous flat storage.
    /// An optional leading `# fps: <N>` line sets playback cadence; frames are
    /// separated by a `---` line or form-feed (`0x0c`) line.
    pub fn parse(allocator: Allocator, bytes: []const u8) ParseError!Frames {
        if (bytes.len > max_file_bytes) return error.FileTooLarge;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;

        var fps: u8 = default_fps;
        var body = bytes;
        if (parseFpsHeader(body)) |header| {
            fps = header.fps;
            body = header.rest;
        }

        // Pass 1: count frames and compute each frame's bounded dimensions.
        var frame_count: usize = 0;
        var total_codepoints: usize = 0;
        var has_visible_glyph = false;

        var scan = FrameSplitter.init(body);
        while (scan.next()) |raw_frame| {
            const dims = measureFrame(raw_frame);
            if (dims.height == 0) continue;
            if (frame_count >= max_frames) return error.TooManyFrames;
            if (dims.has_glyph) has_visible_glyph = true;
            frame_count += 1;
            total_codepoints += @as(usize, dims.width) * @as(usize, dims.height);
        }

        if (frame_count == 0 or !has_visible_glyph) return error.EmptyAnimation;

        const meta = try allocator.alloc(FrameMeta, frame_count);
        errdefer allocator.free(meta);

        const codepoints = try allocator.alloc(u21, total_codepoints);
        errdefer allocator.free(codepoints);
        @memset(codepoints, 0);

        // Pass 2: decode UTF-8 lines directly into the flat codepoint buffer.
        var frame_idx: usize = 0;
        var cursor: usize = 0;
        var fill = FrameSplitter.init(body);
        while (fill.next()) |raw_frame| {
            const dims = measureFrame(raw_frame);
            if (dims.height == 0) continue;

            meta[frame_idx] = .{
                .offset = @intCast(cursor),
                .width = dims.width,
                .height = dims.height,
            };
            const frame_cells = @as(usize, dims.width) * @as(usize, dims.height);
            decodeFrame(raw_frame, dims.width, dims.height, codepoints[cursor .. cursor + frame_cells]);
            cursor += frame_cells;
            frame_idx += 1;
        }

        assert(frame_idx == frame_count);
        assert(cursor == total_codepoints);

        return .{
            .meta = meta,
            .codepoints = codepoints,
            .fps = fps,
        };
    }

    pub fn deinit(self: *Frames, allocator: Allocator) void {
        allocator.free(self.codepoints);
        allocator.free(self.meta);
        self.* = undefined;
    }

    /// Returns the looping frame index for monotonic `time_s`.
    pub fn frameIndex(self: *const Frames, time_s: f32) usize {
        if (self.meta.len == 0) return 0;
        const safe_t = sanitizeNonNegative(time_s);
        const step: u64 = @intFromFloat(@floor(safe_t * @as(f32, @floatFromInt(self.fps))));
        return @intCast(step % self.meta.len);
    }

    pub fn frameCount(self: *const Frames) usize {
        return self.meta.len;
    }
};

pub const empty: AsciiCanvas = .{};

/// Resets active viewport dimensions and marks every cell empty.
pub fn clear(self: *AsciiCanvas) void {
    const active = @as(usize, self.cols) * @as(usize, self.rows);
    if (active > 0) {
        @memset(self.cells[0..active], .{});
    }
    self.cols = 0;
    self.rows = 0;
    self.non_empty = 0;
}

/// Returns the contiguous cells for `row` (`0 <= row < self.rows`).
pub fn rowSlice(self: *const AsciiCanvas, row: u16) []const Cell {
    assert(row < self.rows);
    const start = @as(usize, row) * @as(usize, self.cols);
    return self.cells[start .. start + @as(usize, self.cols)];
}

/// Returns the cell at `(col, row)` (`col < self.cols`, `row < self.rows`).
pub fn cellAt(self: *const AsciiCanvas, col: u16, row: u16) Cell {
    assert(col < self.cols);
    assert(row < self.rows);
    return self.cells[@as(usize, row) * @as(usize, self.cols) + @as(usize, col)];
}

/// Renders one frame of `source` into the flat cell buffer with zero
/// allocations. `cols` and `rows` are clamped to `max_cols` and `max_rows`.
pub fn render(self: *AsciiCanvas, source: Source, options: RenderOptions) void {
    const cols = @min(options.cols, max_cols);
    const rows = @min(options.rows, max_rows);
    self.cols = cols;
    self.rows = rows;
    self.non_empty = 0;
    if (cols == 0 or rows == 0) return;

    const safe_time = sanitizeFinite(options.time_s);
    const safe_progress = math.clamp(sanitizeFinite(options.progress), 0, 1);

    switch (source) {
        .procedural => |scene| self.renderProcedural(scene, cols, rows, safe_time, safe_progress, options.aspect, options.palette),
        .frames => |frames| self.renderFrames(frames, cols, rows, safe_time, options.palette),
    }
}

fn renderProcedural(
    self: *AsciiCanvas,
    scene: Procedural,
    cols: u16,
    rows: u16,
    time_s: f32,
    progress: f32,
    aspect: CellAspect,
    palette: Palette,
) void {
    const fcols: f32 = @floatFromInt(cols);
    const frows: f32 = @floatFromInt(rows);
    const cell_aspect: f32 = switch (aspect) {
        .square => 1.0,
        .terminal => 0.5,
    };
    const visual_w = fcols * cell_aspect;
    const scale = @max(1.0, @min(visual_w, frows)) * 0.5;
    const inv_scale = 1.0 / scale;
    const half_w = fcols * 0.5;
    const half_h = frows * 0.5;

    const spin = SpinBasis.init(time_s);
    const breathe_phase = computeBreatheRadius(time_s, progress);
    const bit_phase: u32 = @intFromFloat(@floor(sanitizeNonNegative(time_s) * 4.0));

    var count: u32 = 0;
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const ny = ((@as(f32, @floatFromInt(row)) + 0.5) - half_h) * inv_scale;
        const row_offset = @as(usize, row) * @as(usize, cols);
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const nx = ((@as(f32, @floatFromInt(col)) + 0.5) - half_w) * cell_aspect * inv_scale;
            const sample: Sample = switch (scene) {
                .spin_3d => sampleSpin3d(nx, ny, spin),
                .torus => sampleTorus(nx, ny, spin),
                .breathe => sampleBreathe(nx, ny, breathe_phase, time_s),
                .wave => sampleWave(nx, ny, time_s),
            };
            const cell = shadeCell(sample, col, row, bit_phase, palette);
            self.cells[row_offset + col] = cell;
            if (cell.codepoint != 0) count += 1;
        }
    }
    self.non_empty = count;
}

fn renderFrames(
    self: *AsciiCanvas,
    frames: *const Frames,
    cols: u16,
    rows: u16,
    time_s: f32,
    palette: Palette,
) void {
    const active = @as(usize, cols) * @as(usize, rows);
    @memset(self.cells[0..active], .{});
    if (frames.meta.len == 0) return;

    const meta = frames.meta[frames.frameIndex(time_s)];
    if (meta.width == 0 or meta.height == 0) return;

    const dst_x0: u16 = if (cols > meta.width) (cols - meta.width) / 2 else 0;
    const dst_y0: u16 = if (rows > meta.height) (rows - meta.height) / 2 else 0;
    const src_x0: u16 = if (meta.width > cols) (meta.width - cols) / 2 else 0;
    const src_y0: u16 = if (meta.height > rows) (meta.height - rows) / 2 else 0;
    const copy_w: u16 = @min(cols, meta.width);
    const copy_h: u16 = @min(rows, meta.height);

    var count: u32 = 0;
    var y: u16 = 0;
    while (y < copy_h) : (y += 1) {
        const src_row = @as(usize, meta.offset) + @as(usize, src_y0 + y) * @as(usize, meta.width) + @as(usize, src_x0);
        const dst_row = @as(usize, dst_y0 + y) * @as(usize, cols) + @as(usize, dst_x0);
        var x: u16 = 0;
        while (x < copy_w) : (x += 1) {
            const cp = frames.codepoints[src_row + x];
            if (cp == 0) continue;
            self.cells[dst_row + x] = .{
                .codepoint = cp,
                .fg = palette.fg,
            };
            count += 1;
        }
    }
    self.non_empty = count;
}

const Sample = struct {
    /// Normalized intensity in `0..1`; `0` renders empty.
    intensity: f32 = 0,
    /// Blend toward `palette.accent` in `0..1`.
    accent_mix: f32 = 0,
};

const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }

    fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    fn length(v: Vec3) f32 {
        return @sqrt(dot(v, v));
    }

    fn normalize(v: Vec3) Vec3 {
        const len = length(v);
        if (len <= 1e-6) return .{ .x = 0, .y = 0, .z = 1 };
        return scale(v, 1.0 / len);
    }
};

const SpinBasis = struct {
    cy: f32,
    sy: f32,
    cx: f32,
    sx: f32,
    cz: f32,
    sz: f32,

    fn init(time_s: f32) SpinBasis {
        const ay = time_s * 0.65;
        const ax = time_s * 0.42 + 0.48;
        const az = time_s * 0.23;
        return .{
            .cy = @cos(ay),
            .sy = @sin(ay),
            .cx = @cos(ax),
            .sx = @sin(ax),
            .cz = @cos(az),
            .sz = @sin(az),
        };
    }

    /// Rotates a world point into the shape's local space.
    fn toLocal(self: SpinBasis, p: Vec3) Vec3 {
        // Inverse Z -> X -> Y rotation.
        const x1 = p.x * self.cz + p.y * self.sz;
        const y1 = -p.x * self.sz + p.y * self.cz;
        const y2 = y1 * self.cx + p.z * self.sx;
        const z2 = -y1 * self.sx + p.z * self.cx;
        return .{
            .x = x1 * self.cy - z2 * self.sy,
            .y = y2,
            .z = x1 * self.sy + z2 * self.cy,
        };
    }
};

fn sdCapsule(p: Vec3, a: Vec3, b: Vec3, r: f32) f32 {
    const pa = Vec3.sub(p, a);
    const ba = Vec3.sub(b, a);
    const denom = Vec3.dot(ba, ba);
    const h = if (denom > 1e-6) math.clamp(Vec3.dot(pa, ba) / denom, 0.0, 1.0) else 0.0;
    return Vec3.length(Vec3.sub(pa, Vec3.scale(ba, h))) - r;
}

/// 3D six-arm rounded asterisk/jack SDF rotated into local space.
fn mapAsterisk(world_p: Vec3, basis: SpinBasis) f32 {
    const p = basis.toLocal(world_p);
    const arm_len: f32 = 0.72;
    const arm_r: f32 = 0.145;
    const d_x = sdCapsule(p, .{ .x = -arm_len, .y = 0, .z = 0 }, .{ .x = arm_len, .y = 0, .z = 0 }, arm_r);
    const d_y = sdCapsule(p, .{ .x = 0, .y = -arm_len, .z = 0 }, .{ .x = 0, .y = arm_len, .z = 0 }, arm_r);
    const d_z = sdCapsule(p, .{ .x = 0, .y = 0, .z = -arm_len }, .{ .x = 0, .y = 0, .z = arm_len }, arm_r);
    const diag: f32 = 0.56;
    const diag_r: f32 = 0.11;
    const d_d1 = sdCapsule(p, .{ .x = -diag, .y = -diag, .z = 0 }, .{ .x = diag, .y = diag, .z = 0 }, diag_r);
    const d_d2 = sdCapsule(p, .{ .x = -diag, .y = diag, .z = 0 }, .{ .x = diag, .y = -diag, .z = 0 }, diag_r);
    return @min(@min(@min(d_x, d_y), d_z), @min(d_d1, d_d2));
}

fn mapTorus(world_p: Vec3, basis: SpinBasis) f32 {
    const p = basis.toLocal(world_p);
    const major_r: f32 = 0.58;
    const minor_r: f32 = 0.22;
    const qx = @sqrt(p.x * p.x + p.z * p.z) - major_r;
    return @sqrt(qx * qx + p.y * p.y) - minor_r;
}

const light_dir = Vec3{ .x = -0.52, .y = -0.60, .z = -0.60 };

fn marchSdf(
    nx: f32,
    ny: f32,
    basis: SpinBasis,
    comptime mapFn: fn (Vec3, SpinBasis) f32,
) Sample {
    if (nx * nx + ny * ny > 1.35 * 1.35) return .{};

    const ro = Vec3{ .x = 0, .y = 0, .z = -2.35 };
    const rd = Vec3.normalize(.{ .x = nx * 0.72, .y = ny * 0.72, .z = 1.45 });

    var t: f32 = 0.0;
    var min_d: f32 = 1e9;
    var hit = false;
    var step: u8 = 0;
    while (step < 18) : (step += 1) {
        const p = Vec3.add(ro, Vec3.scale(rd, t));
        const d = mapFn(p, basis);
        if (d < min_d) min_d = d;
        if (d < 0.015) {
            hit = true;
            break;
        }
        t += d;
        if (t > 4.2) break;
    }

    if (!hit) {
        // Subtle `*` silhouette halo right outside the surface edge.
        if (min_d < 0.065) {
            const halo = 1.0 - (min_d / 0.065);
            return .{ .intensity = halo * 0.22, .accent_mix = 0 };
        }
        return .{};
    }

    const p = Vec3.add(ro, Vec3.scale(rd, t));
    const eps: f32 = 0.01;
    const k1 = Vec3{ .x = 1, .y = -1, .z = -1 };
    const k2 = Vec3{ .x = -1, .y = -1, .z = 1 };
    const k3 = Vec3{ .x = -1, .y = 1, .z = -1 };
    const k4 = Vec3{ .x = 1, .y = 1, .z = 1 };
    const g1 = Vec3.scale(k1, mapFn(Vec3.add(p, Vec3.scale(k1, eps)), basis));
    const g2 = Vec3.scale(k2, mapFn(Vec3.add(p, Vec3.scale(k2, eps)), basis));
    const g3 = Vec3.scale(k3, mapFn(Vec3.add(p, Vec3.scale(k3, eps)), basis));
    const g4 = Vec3.scale(k4, mapFn(Vec3.add(p, Vec3.scale(k4, eps)), basis));
    const normal = Vec3.normalize(Vec3.add(Vec3.add(g1, g2), Vec3.add(g3, g4)));

    const diffuse = @max(0.0, Vec3.dot(normal, light_dir));
    const facing = @max(0.0, -Vec3.dot(normal, rd));
    const intensity = math.clamp(0.18 + diffuse * 0.68 + facing * 0.22, 0.0, 1.0);
    return .{ .intensity = intensity, .accent_mix = 0 };
}

fn sampleSpin3d(nx: f32, ny: f32, basis: SpinBasis) Sample {
    return marchSdf(nx, ny, basis, mapAsterisk);
}

fn sampleTorus(nx: f32, ny: f32, basis: SpinBasis) Sample {
    return marchSdf(nx, ny, basis, mapTorus);
}

/// Computes a smooth 12-second inhale (4s) / hold (2s) / exhale (6s) envelope
/// in `0..1`, gently modulated by break `progress`.
fn computeBreatheRadius(time_s: f32, progress: f32) f32 {
    const cycle: f32 = 12.0;
    const phase = @mod(sanitizeNonNegative(time_s), cycle);
    const breath: f32 = if (phase < 4.0)
        smoothstep(0.0, 4.0, phase)
    else if (phase < 6.0)
        1.0
    else
        1.0 - smoothstep(6.0, 12.0, phase);
    return 0.28 + breath * 0.46 + progress * 0.04;
}

fn sampleBreathe(nx: f32, ny: f32, radius: f32, time_s: f32) Sample {
    const r = @sqrt(nx * nx + ny * ny);
    const ring_dist = @abs(r - radius);
    const core = if (r < radius) (1.0 - (r / @max(0.05, radius))) * 0.45 else 0.0;
    const ring = if (ring_dist < 0.22) 1.0 - (ring_dist / 0.22) else 0.0;
    const ripple_r = radius + 0.26;
    const ripple_dist = @abs(r - ripple_r);
    const ripple = if (ripple_dist < 0.09) (1.0 - ripple_dist / 0.09) * 0.35 else 0.0;
    const angle = math.atan2(ny, nx);
    const shimmer = 0.06 * @sin(angle * 6.0 + time_s * 0.9);
    const intensity = math.clamp(@max(@max(ring, core), ripple) + shimmer * ring, 0.0, 1.0);
    if (intensity < 0.10) return .{};
    const accent_mix = math.clamp((radius - 0.28) / 0.48, 0.0, 1.0) * ring;
    return .{ .intensity = intensity, .accent_mix = accent_mix };
}

fn sampleWave(nx: f32, ny: f32, time_s: f32) Sample {
    const r = @sqrt(nx * nx + ny * ny);
    const w1 = @sin(nx * 4.4 + time_s * 1.4);
    const w2 = @cos(ny * 3.8 - time_s * 1.1);
    const w3 = @sin(r * 6.5 - time_s * 2.0);
    const combined = (w1 + w2 + w3) / 3.0;
    const normalized = combined * 0.5 + 0.5;
    if (normalized < 0.42) return .{};
    const intensity = math.clamp((normalized - 0.42) / 0.58, 0.0, 1.0);
    return .{ .intensity = intensity, .accent_mix = intensity * 0.35 };
}

fn shadeCell(sample: Sample, col: u16, row: u16, bit_phase: u32, palette: Palette) Cell {
    if (sample.intensity < 0.12) return .{};

    // Five-tier monochrome character ramp: empty, '*', '0'/'1', '■', '█'.
    const cp: u21, const fg_weight: f32 = if (sample.intensity < 0.30)
        .{ '*', 0.35 }
    else if (sample.intensity < 0.54) blk: {
        const bit: u32 = (@as(u32, col) *% 3 +% @as(u32, row) *% 5 +% bit_phase) & 1;
        break :blk .{ if (bit == 0) @as(u21, '0') else @as(u21, '1'), 0.65 };
    } else if (sample.intensity < 0.78)
        .{ 0x25A0, 0.85 } // BLACK SQUARE (■)
    else
        .{ 0x2588, 1.0 }; // FULL BLOCK (█)

    const base = mixColor(palette.muted, palette.fg, fg_weight);
    const fg = mixColor(base, palette.accent, sample.accent_mix);
    return .{ .codepoint = cp, .fg = fg };
}

fn mixColor(a: Color, b: Color, t: f32) Color {
    const u = math.clamp(t, 0.0, 1.0);
    return .{
        .r = lerpU8(a.r, b.r, u),
        .g = lerpU8(a.g, b.g, u),
        .b = lerpU8(a.b, b.b, u),
        .a = lerpU8(a.a, b.a, u),
    };
}

fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const fa: f32 = @floatFromInt(a);
    const fb: f32 = @floatFromInt(b);
    return @intFromFloat(@round(fa + (fb - fa) * t));
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn sanitizeFinite(v: f32) f32 {
    return if (math.isFinite(v)) v else 0.0;
}

fn sanitizeNonNegative(v: f32) f32 {
    if (!math.isFinite(v) or v < 0.0) return 0.0;
    return v;
}

const FpsHeader = struct {
    fps: u8,
    rest: []const u8,
};

/// Parses an optional leading `# fps: <N>` directive on the first line.
fn parseFpsHeader(bytes: []const u8) ?FpsHeader {
    const nl = mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    const first_line = mem.trim(u8, bytes[0..nl], " \t\r");
    if (!mem.startsWith(u8, first_line, "#")) return null;
    const after_hash = mem.trimStart(u8, first_line[1..], " \t");
    if (!mem.startsWith(u8, after_hash, "fps:")) return null;
    const value_str = mem.trim(u8, after_hash["fps:".len..], " \t");
    const parsed = std.fmt.parseInt(u16, value_str, 10) catch return null;
    const clamped: u8 = @intCast(math.clamp(parsed, Frames.min_fps, Frames.max_fps));
    const rest = if (nl < bytes.len) bytes[nl + 1 ..] else "";
    return .{ .fps = clamped, .rest = rest };
}

/// Splits UTF-8 text into raw frame chunks on `---` or form-feed lines.
const FrameSplitter = struct {
    bytes: []const u8,
    pos: usize = 0,
    done: bool = false,

    fn init(bytes: []const u8) FrameSplitter {
        return .{ .bytes = bytes };
    }

    fn next(self: *FrameSplitter) ?[]const u8 {
        if (self.done) return null;
        if (self.pos >= self.bytes.len) {
            self.done = true;
            return null;
        }
        const start = self.pos;
        while (self.pos < self.bytes.len) {
            const line_start = self.pos;
            const nl = mem.indexOfScalarPos(u8, self.bytes, line_start, '\n') orelse self.bytes.len;
            const line_end = if (nl < self.bytes.len) nl + 1 else nl;
            const trimmed = mem.trim(u8, self.bytes[line_start..nl], " \t\r");
            if (isSeparatorLine(trimmed)) {
                self.pos = line_end;
                return self.bytes[start..line_start];
            }
            self.pos = line_end;
        }
        self.done = true;
        return self.bytes[start..self.bytes.len];
    }

    fn isSeparatorLine(trimmed: []const u8) bool {
        return mem.eql(u8, trimmed, "---") or mem.eql(u8, trimmed, "\x0c");
    }
};

const FrameDimensions = struct {
    width: u16,
    height: u16,
    has_glyph: bool,
};

fn measureFrame(raw_frame: []const u8) FrameDimensions {
    var height: u16 = 0;
    var width: u16 = 0;
    var has_glyph = false;

    // Trim a single trailing newline so a frame ending with `\n` does not count
    // an extra empty row.
    const body = if (raw_frame.len > 0 and raw_frame[raw_frame.len - 1] == '\n')
        raw_frame[0 .. raw_frame.len - 1]
    else
        raw_frame;
    if (body.len == 0) return .{ .width = 0, .height = 0, .has_glyph = false };

    var lines = mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        if (height >= max_rows) break;
        const line = mem.trimEnd(u8, raw_line, "\r");
        var col: u16 = 0;
        var it = std.unicode.Utf8View.initUnchecked(line).iterator();
        while (it.nextCodepoint()) |cp| {
            if (col >= max_cols) break;
            if (!isBlankCodepoint(cp)) has_glyph = true;
            col += 1;
        }
        if (col > width) width = col;
        height += 1;
    }

    return .{ .width = width, .height = height, .has_glyph = has_glyph };
}

fn decodeFrame(raw_frame: []const u8, width: u16, height: u16, dst: []u21) void {
    const body = if (raw_frame.len > 0 and raw_frame[raw_frame.len - 1] == '\n')
        raw_frame[0 .. raw_frame.len - 1]
    else
        raw_frame;

    var row: u16 = 0;
    var lines = mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        if (row >= height) break;
        const line = mem.trimEnd(u8, raw_line, "\r");
        const row_offset = @as(usize, row) * @as(usize, width);
        var col: u16 = 0;
        var it = std.unicode.Utf8View.initUnchecked(line).iterator();
        while (it.nextCodepoint()) |cp| {
            if (col >= width) break;
            dst[row_offset + col] = if (isBlankCodepoint(cp)) 0 else cp;
            col += 1;
        }
        row += 1;
    }
}

fn isBlankCodepoint(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp < 0x20;
}
