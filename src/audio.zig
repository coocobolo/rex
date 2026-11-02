const Audio = @This();

const std = @import("std");
const log = std.log.scoped(.audio);
const ma = @cImport(@cInclude("miniaudio.h"));

engine: *ma.ma_engine,
ok: bool,

pub fn init(gpa: std.mem.Allocator) Audio {
    var self: Audio = .{ .engine = undefined, .ok = false };
    self.engine = gpa.create(ma.ma_engine) catch return self;
    const config = ma.ma_engine_config_init();
    const result = ma.ma_engine_init(&config, self.engine);
    if (result != ma.MA_SUCCESS) {
        log.warn("failed to initialize miniaudio engine: {d}", .{result});
        gpa.destroy(self.engine);
        return self;
    }
    self.ok = true;
    return self;
}

pub fn deinit(self: *Audio, gpa: std.mem.Allocator) void {
    if (self.ok) {
        ma.ma_engine_uninit(self.engine);
        gpa.destroy(self.engine);
        self.ok = false;
    }
}

/// Play a sound file by absolute or relative path.
/// Non-fatal: logs and returns on failure.
pub fn play(self: *Audio, path: [:0]const u8) void {
    if (!self.ok) return;
    log.debug("playing sound: {s}", .{path});
    const result = ma.ma_engine_play_sound(self.engine, path.ptr, null);
    if (result != ma.MA_SUCCESS) {
        log.warn("ma_engine_play_sound failed: {d}", .{result});
    }
}

/// Play a sound from an in-memory buffer (e.g. @embedFile).
pub fn playEmbedded(self: *Audio, io: std.Io, data: []const u8) void {
    if (!self.ok) return;

    var config = ma.ma_decoder_config_init_default();
    var decoder: ma.ma_decoder = undefined;
    if (ma.ma_decoder_init_memory(data.ptr, data.len, &config, &decoder) != ma.MA_SUCCESS) {
        log.warn("ma_decoder_init_memory failed", .{});
        return;
    }
    defer _ = ma.ma_decoder_uninit(&decoder);

    var sound: ma.ma_sound = undefined;
    var sound_config = ma.ma_sound_config_init();
    sound_config.pDataSource = &decoder;
    sound_config.flags = ma.MA_SOUND_FLAG_DECODE | ma.MA_SOUND_FLAG_NO_SPATIALIZATION;

    if (ma.ma_sound_init_ex(self.engine, &sound_config, &sound) != ma.MA_SUCCESS) {
        log.warn("ma_sound_init_ex failed", .{});
        return;
    }
    defer ma.ma_sound_uninit(&sound);

    _ = ma.ma_sound_start(&sound);

    // Wait for the sound to finish before the decoder goes out of scope
    while (ma.ma_sound_is_playing(&sound) == ma.MA_TRUE) {
        io.sleep(.fromMilliseconds(10), .real) catch {};
    }
}
