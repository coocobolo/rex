const std = @import("std");
const Io = std.Io;

pub const magic: u32 = 0x57454C4C; // "WELL"
pub const version: u32 = 1;

pub const max_history_days: usize = 14;
pub const max_top_apps: usize = 8;
pub const max_comm_len: usize = 16;

pub const AppUsage = extern struct {
    name: [max_comm_len]u8 = @splat(0),
    seconds: u32 = 0,

    pub fn getName(self: *const AppUsage) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..len];
    }

    pub fn setName(self: *AppUsage, str: []const u8) void {
        @memset(&self.name, 0);
        const len: usize = @min(str.len, max_comm_len);
        @memcpy(self.name[0..len], str[0..len]);
    }
};

pub const DayRecord = extern struct {
    day: u32 = 0, // Days since Unix epoch
    active_screen_s: u32 = 0,
    focus_s: u32 = 0,
    break_s: u32 = 0,
    tasks_completed: u16 = 0,
    eyesight_breaks: u16 = 0,
    movement_breaks: u16 = 0,
    hydration_count: u16 = 0,
    top_apps: [max_top_apps]AppUsage = [_]AppUsage{.{}} ** max_top_apps,

    pub fn addAppTime(self: *DayRecord, comm: []const u8, seconds: u32) void {
        if (comm.len == 0) return;
        const target_len: usize = @min(comm.len, max_comm_len);
        const target = comm[0..target_len];

        // Search for existing app slot
        for (&self.top_apps) |*app| {
            if (std.mem.eql(u8, app.getName(), target)) {
                app.seconds +|= seconds;
                return;
            }
        }

        // Search for empty slot
        for (&self.top_apps) |*app| {
            if (app.seconds == 0 or app.name[0] == 0) {
                app.setName(target);
                app.seconds = seconds;
                return;
            }
        }

        // If table full, replace the slot with the lowest recorded seconds if greater
        var min_idx: usize = 0;
        var min_secs: u32 = self.top_apps[0].seconds;
        for (self.top_apps[1..], 1..) |app, idx| {
            if (app.seconds < min_secs) {
                min_secs = app.seconds;
                min_idx = idx;
            }
        }
        if (seconds > min_secs) {
            self.top_apps[min_idx].setName(target);
            self.top_apps[min_idx].seconds = seconds;
        }
    }
};

pub const PersistentData = extern struct {
    magic: u32 = magic,
    version: u32 = version,

    // Statistics
    tasks_completed: u32 = 0,
    long_breaks_taken: u32 = 0,
    sessions: u32 = 0,
    current_streak: u32 = 0,
    best_streak: u32 = 0,
    last_task_day: u32 = 0,

    // Aggregates
    total_active_screen_s: u64 = 0,
    total_focus_s: u64 = 0,
    total_eyesight_breaks: u32 = 0,
    total_movement_breaks: u32 = 0,

    // Focus session snapshot
    focus_phase: u8 = 0,
    tasks_in_cycle: u8 = 0,
    _pad0: [6]u8 = @splat(0),
    focus_remaining_ms: u64 = 0,

    // Active Day and History
    history_count: u32 = 0,
    history: [max_history_days]DayRecord = [_]DayRecord{.{}} ** max_history_days,
    today: DayRecord = .{},

    // Future-proof alignment padding
    _pad: [64]u8 = @splat(0),

    pub const empty: PersistentData = .{};
};

const data_size = @sizeOf(PersistentData);

pub fn save(
    io: Io,
    data: *const PersistentData,
    state_dir: []const u8,
    filename: []const u8,
) !void {
    const dir = try std.Io.Dir.createDirPathOpen(.cwd(), io, state_dir, .{});
    defer dir.close(io);

    const file = try dir.createFile(io, filename, .{ .truncate = true });
    defer file.close(io);

    try file.writePositionalAll(io, std.mem.asBytes(data), 0);
}

pub fn load(
    io: Io,
    state_dir: []const u8,
    filename: []const u8,
) PersistentData {
    const dir = std.Io.Dir.openDir(.cwd(), io, state_dir, .{}) catch return .empty;
    defer dir.close(io);

    const file = dir.openFile(io, filename, .{ .mode = .read_only }) catch return .empty;
    defer file.close(io);

    var data: PersistentData = undefined;
    const n = file.readPositionalAll(io, std.mem.asBytes(&data), 0) catch return .empty;
    if (n != data_size or data.magic != magic or data.version != version) {
        return .empty;
    }

    return data;
}

pub fn purge(
    io: Io,
    state_dir: []const u8,
    filename: []const u8,
) !void {
    const dir = std.Io.Dir.openDir(.cwd(), io, state_dir, .{}) catch return;
    defer dir.close(io);

    dir.deleteFile(io, filename) catch {};
}
