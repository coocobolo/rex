//! The wellbeing state file and the side files that let several Rex
//! processes (one per window) share it.
//!
//! `save` replaces the file atomically (temporary file plus rename), so a
//! reader always sees one complete version and needs no lock. Writers that
//! read, modify and write take `tryLockWrite` first. `acquirePresence` tells
//! a starting process whether any other one is alive. All locks are
//! `flock` locks (std `File.tryLock`), which the kernel releases when the
//! process exits, crashes included.
//!
//! No `fsync` before the rename: a power loss can lose the latest save,
//! or on some filesystems leave an empty file (ext4's default
//! `auto_da_alloc` flushes a file that replaces another by rename). The
//! data is statistics, and an fsync on the main thread would stall frames.

const std = @import("std");
const Io = std.Io;

pub const magic: u32 = 0x57454C4C; // "WELL"
/// Until the first release, a layout change bumps `version` and older files
/// are rejected (`error.InvalidStateFile`) instead of converted.
pub const version: u32 = 2;

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

/// How a focus phase is stored in `Timer.run`.
pub const Run = enum(u8) {
    /// `Timer.ms` is the time left.
    paused = 0,
    /// `Timer.ms` is the wall-clock time, in milliseconds since the epoch,
    /// at which the phase ends.
    running = 1,
    /// The phase ended and waits for the user; `Timer.ms` is unused.
    waiting = 2,
};

/// The shared focus timer. `phase` holds a `focus.Phase` and `run` a `Run`
/// as raw bytes, because the file may hold any value; readers validate them.
pub const Timer = extern struct {
    ms: i64 = 0,
    phase: u8 = 0,
    run: u8 = @intFromEnum(Run.paused),
    tasks_in_cycle: u8 = 0,
    reserved: [5]u8 = @splat(0),
};

/// Version 2 of the state file, written as raw bytes in native byte order.
/// Field order leaves no implicit padding (checked in a test).
pub const PersistentData = extern struct {
    magic: u32 = magic,
    version: u32 = version,
    /// Bumped by a purge, so other processes drop what they have not merged.
    generation: u32 = 0,
    /// Bumped by every timer transition, so exactly one process performs it.
    timer_rev: u32 = 0,
    /// Wall-clock seconds of the last save.
    last_write_utc_s: i64 = 0,
    timer: Timer = .{},

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

    // Active Day and History
    history_count: u32 = 0,
    history: [max_history_days]DayRecord = [_]DayRecord{.{}} ** max_history_days,
    today: DayRecord = .{},

    /// Space for later versions; sized so the struct needs no tail padding.
    reserved: [68]u8 = @splat(0),

    pub const empty: PersistentData = .{};
};

/// Decodes a version 2 state file. The file must have exactly the size of
/// `PersistentData`, and `history_count` is bounded so a damaged file
/// cannot index past `history`.
pub fn decode(bytes: []const u8) error{InvalidStateFile}!PersistentData {
    if (bytes.len != @sizeOf(PersistentData)) return error.InvalidStateFile;
    var data: PersistentData = undefined;
    @memcpy(std.mem.asBytes(&data), bytes);
    if (data.magic != magic or data.version != version) return error.InvalidStateFile;
    if (data.history_count > max_history_days) return error.InvalidStateFile;
    return data;
}

pub const SaveError = Io.Dir.CreateDirPathOpenError || Io.Dir.CreateFileAtomicError ||
    Io.File.WritePositionalError || Io.File.Atomic.ReplaceError;

/// Writes `data` to `state_dir/filename`, creating the directory if needed.
/// The new file replaces the old one atomically; a crash before the rename
/// can leave a temporary file with a hex name in `state_dir`.
pub fn save(
    io: Io,
    data: *const PersistentData,
    state_dir: []const u8,
    filename: []const u8,
) SaveError!void {
    const dir = try std.Io.Dir.createDirPathOpen(.cwd(), io, state_dir, .{});
    defer dir.close(io);

    var atomic = try dir.createFileAtomic(io, filename, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, std.mem.asBytes(data), 0);
    try atomic.replace(io);
}

pub const LoadError = Io.Dir.OpenError || Io.File.OpenError || Io.File.ReadPositionalError ||
    error{InvalidStateFile};

/// Reads `state_dir/filename` (see `decode`). A missing directory or file
/// means nothing was saved yet and gives `.empty`.
pub fn load(
    io: Io,
    state_dir: []const u8,
    filename: []const u8,
) LoadError!PersistentData {
    const dir = std.Io.Dir.openDir(.cwd(), io, state_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        else => |e| return e,
    };
    defer dir.close(io);

    const file = dir.openFile(io, filename, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        else => |e| return e,
    };
    defer file.close(io);

    // One byte more than the format, so a longer file is detected.
    var buf: [@sizeOf(PersistentData) + 1]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    return decode(buf[0..n]);
}

pub const PurgeError = Io.Dir.OpenError || Io.Dir.DeleteFileError;

/// Deletes `state_dir/filename`. A missing directory or file counts as
/// already purged.
pub fn purge(
    io: Io,
    state_dir: []const u8,
    filename: []const u8,
) PurgeError!void {
    const dir = std.Io.Dir.openDir(.cwd(), io, state_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);

    dir.deleteFile(io, filename) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

/// Identifies one version of the state file. Every save creates a new file,
/// so the inode changes; the mtime covers a freed inode being reused. Both
/// are only compared, so the mtime is truncated to 64 bits.
pub const Stamp = struct {
    inode: Io.File.INode,
    mtime_ns: i64,
};

pub const StampError = Io.Dir.OpenError || Io.Dir.StatFileError;

/// The stamp of `state_dir/filename`, or null when it does not exist.
pub fn stamp(io: Io, state_dir: []const u8, filename: []const u8) StampError!?Stamp {
    const dir = std.Io.Dir.openDir(.cwd(), io, state_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer dir.close(io);
    const st = dir.statFile(io, filename, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    return .{ .inode = st.inode, .mtime_ns = @truncate(st.mtime.nanoseconds) };
}

pub const LockError = Io.Dir.CreateDirPathOpenError || Io.File.OpenError || Io.File.LockError ||
    error{NameTooLong};

/// The exclusive lock writers hold while they read, modify and write the
/// state file. It lives on `<filename>.lock`, not on the state file, because
/// `save` replaces the state file and a lock on it would stay on the old one.
pub const WriteLock = struct {
    file: Io.File,

    pub fn release(self: WriteLock, io: Io) void {
        self.file.unlock(io);
        self.file.close(io);
    }
};

/// Takes the write lock without blocking, or returns null when another
/// process (or another open of the lock file) holds it.
pub fn tryLockWrite(io: Io, state_dir: []const u8, filename: []const u8) LockError!?WriteLock {
    const file = try openSideFile(io, state_dir, filename, ".lock");
    errdefer file.close(io);
    if (!try file.tryLock(io, .exclusive)) {
        file.close(io);
        return null;
    }
    return .{ .file = file };
}

/// A shared lock on `<filename>.alive`, held for the life of a process so
/// that a starting process can tell whether any other one is running.
pub const Presence = struct {
    file: Io.File,

    pub fn release(self: Presence, io: Io) void {
        self.file.unlock(io);
        self.file.close(io);
    }
};

/// Takes the presence lock. `alone` is true when no other process held it:
/// an exclusive lock succeeded and is downgraded to shared without a gap.
/// Otherwise this blocks for a shared lock, which waits only while another
/// starting process sits between its exclusive lock and the downgrade.
pub fn acquirePresence(
    io: Io,
    state_dir: []const u8,
    filename: []const u8,
) LockError!struct { presence: Presence, alone: bool } {
    const file = try openSideFile(io, state_dir, filename, ".alive");
    errdefer file.close(io);
    const alone = try file.tryLock(io, .exclusive);
    if (alone) {
        try file.downgradeLock(io);
    } else {
        try file.lock(io, .shared);
    }
    return .{ .presence = .{ .file = file }, .alone = alone };
}

fn openSideFile(io: Io, state_dir: []const u8, filename: []const u8, suffix: []const u8) LockError!Io.File {
    var name_buf: [Io.Dir.max_name_bytes]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ filename, suffix }) catch return error.NameTooLong;
    const dir = try std.Io.Dir.createDirPathOpen(.cwd(), io, state_dir, .{});
    defer dir.close(io);
    return dir.createFile(io, name, .{ .truncate = false });
}
