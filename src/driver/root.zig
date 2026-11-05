//! Driver subsystem managing communication between the terminal emulator core,
//! the OS pseudo-terminal (PTY), and the GUI thread.
//!
//! Exposes a polymorphic `Driver(option)` union dispatching between synchronous
//! `SingleDriver` execution and asynchronous `ThreadedDriver` execution backed
//! by `TripleBuffer` frame publishing and lock-free `InputQueue` event delivery.
//! Also provides canonical selection extraction and scrollback anchor resolution.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const term = @import("../term/root.zig");
const Option = term.Option;
const termio = @import("../termio/root.zig");
const Pty = termio.pty.Posix;
const Theme = @import("../color/root.zig").Theme;

pub const single = @import("single.zig");
pub const threaded = @import("threaded.zig");
pub const triple_buffer = @import("triple_buffer.zig");
pub const InputQueue = @import("InputQueue.zig");

pub const Single = single.Driver;
pub const Threaded = threaded.Driver;
pub const TripleBuffer = triple_buffer.Buffer;

pub const SingleDriver = Single;
pub const ThreadedDriver = Threaded;
pub const InputEvent = InputQueue.InputEvent;
pub const WakeupChannel = InputQueue.WakeupChannel;

/// Terminal modes shared atomically between driver and GUI thread.
pub const SharedModes = packed struct(u32) {
    cursor_keys: bool = false,
    keypad_app: bool = false,
    modify_other_keys: u2 = 0,
    mouse_reporting: bool = false,
    bracketed_paste: bool = false,
    focus_events: bool = false,
    reports_wheel: bool = false,
    _pad: u24 = 0,

    /// Bitcast helper to u32 for atomic storage.
    pub inline fn toU32(self: SharedModes) u32 {
        return @bitCast(self);
    }

    /// Bitcast helper from u32 from atomic storage.
    pub inline fn fromU32(val: u32) SharedModes {
        return @bitCast(val);
    }
};

/// High-level events accumulated by the driver to notify the GUI thread.
pub const DriverEvents = struct {
    bell: bool = false,
    title: bool = false,
    icon_name: bool = false,
    cursor_color: bool = false,
    selection_reset: bool = false,
    hard_reset: bool = false,
    resize: ?term.Events.Resize = null,
    child_closed: bool = false,
    had_data: bool = false,

    pub inline fn any(self: DriverEvents) bool {
        return self.bell or self.title or self.icon_name or
            self.cursor_color or self.selection_reset or
            self.hard_reset or self.resize != null or
            self.child_closed or self.had_data;
    }
};

/// Strongly typed bit flags for atomic cross-thread driver event signaling.
pub const EventBits = packed struct(u32) {
    bell: bool = false,
    title: bool = false,
    icon_name: bool = false,
    cursor_color: bool = false,
    selection_reset: bool = false,
    hard_reset: bool = false,
    child_closed: bool = false,
    had_data: bool = false,
    resize: bool = false,
    _pad: u23 = 0,

    pub const bell_mask: u32 = 1 << 0;
    pub const title_mask: u32 = 1 << 1;
    pub const icon_name_mask: u32 = 1 << 2;
    pub const cursor_color_mask: u32 = 1 << 3;
    pub const selection_reset_mask: u32 = 1 << 4;
    pub const hard_reset_mask: u32 = 1 << 5;
    pub const child_closed_mask: u32 = 1 << 6;
    pub const had_data_mask: u32 = 1 << 7;
    pub const resize_mask: u32 = 1 << 8;

    /// Bitcast helper to u32 for atomic storage.
    pub inline fn toU32(self: EventBits) u32 {
        return @bitCast(self);
    }

    /// Bitcast helper from u32 from atomic storage.
    pub inline fn fromU32(val: u32) EventBits {
        return @bitCast(val);
    }
};

/// Resolves an anchor row in scrollback history space, returning null if evicted.
pub fn resolveAnchor(position: anytype, total_lines_scrolled: i64, scrollback_used: i64) ?i64 {
    const delta: i64 = total_lines_scrolled - position.captured_scroll_gen;
    const anchor_now: i64 = @as(i64, position.row) - delta;
    if (anchor_now < -scrollback_used) return null;
    return anchor_now;
}

/// Extracts UTF-8 text within `selection` from `screen` into `buf`.
/// Performs zero dynamic allocations; returns number of bytes written.
pub fn extractSelectionText(screen: anytype, selection: anytype, buf: []u8) usize {
    const total_lines_scrolled = screen.total_lines_scrolled;
    const scrollback_used = screen.scrollbackUsedAs(i64);

    const start_anchor = resolveAnchor(selection.range.start, total_lines_scrolled, scrollback_used) orelse return 0;
    const end_anchor = resolveAnchor(selection.range.end, total_lines_scrolled, scrollback_used) orelse return 0;

    const start_col: u16 = @intCast(selection.range.start.col);
    const end_col: u16 = @intCast(selection.range.end.col);

    const lo_anchor, const lo_col, const hi_anchor, const hi_col = blk: {
        if (start_anchor < end_anchor or (start_anchor == end_anchor and start_col <= end_col)) {
            break :blk .{ start_anchor, start_col, end_anchor, end_col };
        } else {
            break :blk .{ end_anchor, end_col, start_anchor, start_col };
        }
    };

    const active_rows: i64 = @intCast(screen.active_rows);
    const clamped_lo: i64 = std.math.clamp(lo_anchor, -scrollback_used, active_rows - 1);
    const clamped_hi: i64 = std.math.clamp(hi_anchor, -scrollback_used, active_rows - 1);
    if (clamped_hi < clamped_lo) return 0;

    const is_block = selection.kind == .block;
    const block_left = @min(start_col, end_col);
    const block_right = @min(@max(start_col, end_col), @max(screen.active_cols, 1) - 1);

    var pos: usize = 0;
    var anchor_row: i64 = clamped_lo;
    while (anchor_row <= clamped_hi) : (anchor_row += 1) {
        var col_start: usize = if (is_block) block_left else (if (anchor_row == clamped_lo) lo_col else 0);
        const col_end: usize = if (is_block) block_right else (if (anchor_row == clamped_hi) hi_col else @max(screen.active_cols, 1) - 1);

        if (col_start > 0) {
            const maybe_placeholder = screen.cellAtAnchor(anchor_row, col_start);
            if (maybe_placeholder.kind == .wide_right) col_start -= 1;
        }

        const row_start = pos;

        for (col_start..col_end + 1) |col| {
            const cell = screen.cellAtAnchor(anchor_row, col);
            if (pos + 4 > buf.len) break;

            switch (cell.kind) {
                .wide_right => continue,
                .empty => {
                    buf[pos] = ' ';
                    pos += 1;
                },
                .narrow, .wide_left => {
                    const cp: u21 = std.math.cast(u21, cell.codepoint) orelse ' ';
                    const len = std.unicode.utf8Encode(cp, buf[pos..][0..4]) catch continue;
                    pos += len;
                },
                .grapheme, .grapheme_wide => {
                    const cps = screen.getGrapheme(cell.codepoint) orelse continue;
                    for (cps) |cp| {
                        const len = std.unicode.utf8Encode(cp, buf[pos..][0..4]) catch continue;
                        pos += len;
                    }
                },
                .shaped => {},
            }
        }

        while (pos > row_start and buf[pos - 1] == ' ') pos -= 1;

        if (anchor_row < clamped_hi and pos < buf.len - 1) {
            buf[pos] = '\n';
            pos += 1;
        }
    }

    return pos;
}

/// Unified polymorphic driver interface dispatching between Single and Threaded drivers.
pub fn Driver(comptime option: Option) type {
    const SingleType = Single(option);
    const ThreadedType = Threaded(option);
    const FrameType = term.Frame(option);

    return union(enum) {
        single: SingleType,
        threaded: *ThreadedType,

        const Self = @This();

        /// Releases resources owned by the driver, destroying the terminal,
        /// freeing buffers, and closing the PTY.
        pub fn deinit(self: *Self) void {
            switch (self.*) {
                .single => |*d| d.deinit(),
                .threaded => |d| d.destroy(),
            }
        }

        /// Backward-compatible deinit accepting io parameter.
        pub fn deinitIo(self: *Self, io: std.Io) void {
            _ = io;
            self.deinit();
        }

        /// Drains accumulated driver events and checks if a fresh frame is ready.
        pub fn pollAndDrain(self: *Self) !DriverEvents {
            return switch (self.*) {
                .single => |*d| d.pollAndDrain(),
                .threaded => |d| d.pollAndDrain(),
            };
        }

        /// Returns the freshest viewport snapshot.
        pub fn getFrame(self: *const Self) *const FrameType {
            return switch (self.*) {
                .single => |*d| d.getFrame(),
                .threaded => |d| d.getFrame(),
            };
        }

        /// Returns true if a fresh frame is waiting in the triple buffer.
        pub fn hasNewFrame(self: *const Self) bool {
            return switch (self.*) {
                .single => false,
                .threaded => |d| d.hasNewFrame(),
            };
        }

        /// Sends an input event (keystroke, mouse, resize, focus) to the driver.
        pub fn sendInput(self: *Self, event: InputEvent) !void {
            switch (self.*) {
                .single => |*d| try d.sendInput(event),
                .threaded => |d| _ = d.sendInput(event),
            }
        }

        /// Sends raw bytes to the child process via the PTY.
        pub fn sendBytes(self: *Self, bytes: []const u8) !void {
            switch (self.*) {
                .single => |*d| try d.sendBytes(bytes),
                .threaded => |d| d.sendBytes(bytes),
            }
        }

        /// Writes pasted clipboard text to the PTY.
        pub fn writePaste(self: *Self, text: []const u8) !void {
            switch (self.*) {
                .single => |*d| try d.writePaste(text),
                .threaded => |d| try d.writePaste(text),
            }
        }

        /// Returns a snapshot of shared terminal modes (cursor keys, mouse tracking, etc.).
        pub fn getModes(self: *const Self) SharedModes {
            return switch (self.*) {
                .single => |*d| d.getModes(),
                .threaded => |d| d.getModes(),
            };
        }

        /// Returns the current window title snapshot.
        pub fn getTitle(self: *const Self) []const u8 {
            return switch (self.*) {
                .single => |*d| d.getTitle(),
                .threaded => |d| d.getTitle(),
            };
        }

        /// Returns the process ID of the child process running on the PTY.
        pub fn getPid(self: *const Self) posix.pid_t {
            return switch (self.*) {
                .single => |*d| d.getPid(),
                .threaded => |d| d.getPid(),
            };
        }

        /// Returns the file descriptor of the master PTY end.
        pub fn getMasterFd(self: *const Self) posix.fd_t {
            return switch (self.*) {
                .single => |*d| d.pty.master,
                .threaded => |d| d.pty.master,
            };
        }

        /// Copies selected text into `buf` without allocating. Returns bytes written.
        pub fn copySelectionText(self: *Self, selection: anytype, buf: []u8) usize {
            return switch (self.*) {
                .single => |*d| d.copySelectionText(selection, buf),
                .threaded => |d| d.copySelectionText(selection, buf),
            };
        }
    };
}

test {
    _ = @import("InputQueue.zig");
    _ = @import("triple_buffer.zig");
    _ = @import("single.zig");
    _ = @import("threaded.zig");
    std.testing.refAllDecls(@This());
}

test "driver.root: SharedModes packing and bit conversion" {
    const testing = std.testing;

    var modes = SharedModes{
        .cursor_keys = true,
        .keypad_app = true,
        .modify_other_keys = 2,
        .mouse_reporting = true,
        .bracketed_paste = true,
        .focus_events = true,
        .reports_wheel = true,
    };

    const raw = modes.toU32();
    const unpacked = SharedModes.fromU32(raw);

    try testing.expect(unpacked.cursor_keys);
    try testing.expect(unpacked.keypad_app);
    try testing.expectEqual(@as(u2, 2), unpacked.modify_other_keys);
    try testing.expect(unpacked.mouse_reporting);
    try testing.expect(unpacked.bracketed_paste);
    try testing.expect(unpacked.focus_events);
    try testing.expect(unpacked.reports_wheel);
}

test "driver.root: DriverEvents bit flags and any()" {
    const testing = std.testing;

    var events = DriverEvents{};
    try testing.expect(!events.any());

    events.bell = true;
    try testing.expect(events.any());

    const bits = EventBits{
        .bell = true,
        .title = true,
        .child_closed = true,
    };
    const raw = bits.toU32();
    const unpacked = EventBits.fromU32(raw);
    try testing.expect(unpacked.bell);
    try testing.expect(unpacked.title);
    try testing.expect(!unpacked.icon_name);
    try testing.expect(unpacked.child_closed);
}

test "driver.root: resolveAnchor coordinate calculations" {
    const testing = std.testing;

    // Normal anchor within viewport (captured_scroll_gen == total_lines_scrolled -> delta = 0)
    const norm = resolveAnchor(
        .{ .row = 5, .captured_scroll_gen = 100 },
        100, // total_lines_scrolled
        50, // scrollback_used
    );
    try testing.expect(norm != null);
    try testing.expectEqual(@as(i64, 5), norm.?);

    // Anchor scrolled backwards by 10 lines (delta = 110 - 100 = 10)
    const scrolled = resolveAnchor(
        .{ .row = 5, .captured_scroll_gen = 100 },
        110, // total_lines_scrolled
        50, // scrollback_used
    );
    try testing.expect(scrolled != null);
    try testing.expectEqual(@as(i64, -5), scrolled.?);

    // Anchor evicted past scrollback capacity
    const evicted = resolveAnchor(
        .{ .row = 0, .captured_scroll_gen = 0 },
        100, // total_lines_scrolled
        50, // scrollback_used (evicted since -100 < -50)
    );
    try testing.expect(evicted == null);
}

test "driver.root: Driver polymorphic union dispatch" {
    const testing = std.testing;
    const test_option: Option = .{
        .max_rows = 24,
        .max_cols = 80,
        .max_scrollback = 100,
    };
    const DriverUnion = Driver(test_option);
    const SingleType = Single(test_option);
    const ThreadedType = Threaded(test_option);

    // 1. Single driver variant
    {
        const s = try SingleType.init(testing.allocator, testing.io, Pty.inactive, Theme.graphite);
        var driver = DriverUnion{ .single = s };
        defer driver.deinit();

        try testing.expect(!driver.hasNewFrame());
        const frame = driver.getFrame();
        try testing.expectEqual(@as(u16, 24), frame.active_rows);
        try testing.expectEqual(@as(u16, 80), frame.active_cols);

        const modes = driver.getModes();
        try testing.expect(!modes.mouse_reporting);
        try testing.expectEqual(Pty.inactive.master, driver.getMasterFd());
    }

    // 2. Threaded driver variant
    {
        const th = try ThreadedType.create(testing.allocator, testing.io, Pty.inactive, Theme.graphite, 200);
        var driver = DriverUnion{ .threaded = th };
        defer driver.deinit();

        const frame = driver.getFrame();
        try testing.expectEqual(@as(u16, 24), frame.active_rows);
        try testing.expectEqual(@as(u16, 80), frame.active_cols);

        const modes = driver.getModes();
        try testing.expect(!modes.mouse_reporting);
        try testing.expectEqual(Pty.inactive.master, driver.getMasterFd());
    }
}
