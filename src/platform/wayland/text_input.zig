//! Wayland `zwp_text_input_v3` IME plumbing: double-buffered preedit and
//! commit strings delivered into the platform event ring with zero heap
//! allocation (ADR 0011 decisions 5 and 6).

const std = @import("std");

const events = @import("../Event.zig");
const backend = @import("backend.zig");
const proto = @import("proto.zig");
const WaylandWindow = @import("WaylandWindow.zig");
const wl = @import("wl.zig");

/// Maximum UTF-8 bytes accepted in one `commit_string` event. Oversized
/// commits are dropped whole rather than truncated.
pub const max_commit_bytes = 128;
/// Maximum UTF-8 bytes accepted in one `preedit_string` event (ten 3-byte CJK
/// characters, matching `Event.PreeditEvent`). Oversized preedits are dropped.
pub const max_preedit_bytes = 32;

pub const TextInput = struct {
    proxy: ?*wl.Proxy = null,
    focus: ?*WaylandWindow = null,
    pending_preedit: ?Preedit = null,
    pending_commit: ?Commit = null,
    preedit_active: bool = false,

    const Preedit = struct {
        text: [max_preedit_bytes]u8 = undefined,
        len: u8 = 0,
        cursor: u8 = 0,
        selection: u8 = 0,
    };

    const Commit = struct {
        text: [max_commit_bytes]u8 = undefined,
        len: u8 = 0,
    };

    /// Creates a `zwp_text_input_v3` object on `seat` and binds its listener.
    pub fn attach(self: *TextInput, mgr: *wl.Proxy, wl_seat: *wl.Proxy) void {
        if (self.proxy != null) return;
        const wl_lib = &backend.state.wl.?;
        const ifaces = proto.interfaces();
        if (wl_lib.wl_proxy_marshal_flags(
            mgr,
            proto.text_input_manager.get_text_input,
            ifaces.text_input,
            wl_lib.wl_proxy_get_version(mgr),
            0,
            @as(?*anyopaque, null),
            wl_seat,
        )) |ti| {
            self.proxy = ti;
            _ = wl_lib.wl_proxy_add_listener(ti, @ptrCast(@constCast(&text_input_listener)), self);
        }
    }

    /// Destroys the `zwp_text_input_v3` proxy and resets state.
    pub fn deinit(self: *TextInput) void {
        if (self.proxy) |ti| {
            if (backend.state.wl) |*wl_lib| {
                _ = wl_lib.wl_proxy_marshal_flags(ti, proto.text_input.destroy, null, wl_lib.wl_proxy_get_version(ti), proto.marshal_flag_destroy);
            }
            self.proxy = null;
        }
        self.* = .{};
    }

    /// Clears focus if the focused window is destroyed.
    pub fn onWindowDestroyed(self: *TextInput, win: *WaylandWindow) void {
        if (self.focus == win) {
            self.focus = null;
            self.preedit_active = false;
            self.resetPending();
        }
    }

    /// Stages a preedit string for the next `done` event. Preedits over
    /// `max_preedit_bytes` are dropped whole, matching `Event.PreeditEvent`.
    pub fn stagePreedit(self: *TextInput, text: ?[]const u8, cursor_begin: i32, cursor_end: i32) void {
        const bytes = text orelse {
            // A present but empty preedit clears the active one on `done`.
            self.pending_preedit = .{};
            return;
        };
        if (bytes.len > max_preedit_bytes) {
            // Drop whole rather than emitting a truncated UTF-8 sequence.
            self.pending_preedit = null;
            return;
        }
        var preedit: Preedit = .{};
        @memcpy(preedit.text[0..bytes.len], bytes);
        const len_u8: u8 = @intCast(bytes.len);
        preedit.len = len_u8;
        preedit.cursor = clampPos(cursor_begin, len_u8);
        preedit.selection = clampPos(cursor_end, len_u8);
        self.pending_preedit = preedit;
    }

    /// Stages a commit string for the next `done` event.
    pub fn stageCommit(self: *TextInput, text: ?[]const u8) void {
        const bytes = text orelse return;
        if (bytes.len == 0 or bytes.len > max_commit_bytes) return;
        var commit: Commit = .{ .len = @intCast(bytes.len) };
        @memcpy(commit.text[0..bytes.len], bytes);
        self.pending_commit = commit;
    }

    /// Applies staged commit and preedit state to the event ring on `done`.
    pub fn applyDone(self: *TextInput) void {
        defer self.resetPending();
        const win = self.focus orelse return;

        if (self.pending_commit) |*commit| {
            const slice = commit.text[0..commit.len];
            if (std.unicode.Utf8View.init(slice)) |view| {
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| {
                    backend.pushEvent(.{ .text = .{
                        .window = win.windowHandle(),
                        .codepoint = cp,
                    } });
                }
            } else |err| switch (err) {
                // Invalid UTF-8: drop the whole string, never emit truncated bytes.
                error.InvalidUtf8 => {},
            }
        }

        if (self.pending_preedit) |*preedit| {
            var ev: events.PreeditEvent = .{
                .window = win.windowHandle(),
                .len = preedit.len,
                .cursor = preedit.cursor,
                .selection = preedit.selection,
            };
            @memcpy(ev.text[0..ev.len], preedit.text[0..ev.len]);
            backend.pushEvent(.{ .preedit = ev });
            self.preedit_active = ev.len > 0;
        }
    }

    /// Clears active preedit on focus leave.
    pub fn clearPreeditOnLeave(self: *TextInput) void {
        if (self.preedit_active) {
            if (self.focus) |win| {
                backend.pushEvent(.{ .preedit = .{ .window = win.windowHandle() } });
            }
            self.preedit_active = false;
        }
        self.focus = null;
        self.resetPending();
    }

    fn resetPending(self: *TextInput) void {
        self.pending_preedit = null;
        self.pending_commit = null;
    }
};

fn clampPos(pos: i32, max_len: u8) u8 {
    if (pos <= 0) return 0;
    const u: u32 = @intCast(pos);
    return @intCast(@min(u, @as(u32, max_len)));
}

fn onEnter(data: ?*anyopaque, ti: ?*wl.Proxy, surface: ?*wl.Proxy) callconv(.c) void {
    const self: *TextInput = @ptrCast(@alignCast(data.?));
    self.focus = backend.findWindowBySurface(surface);
    self.resetPending();
    if (self.focus != null) {
        const wl_lib = &backend.state.wl.?;
        const ver = wl_lib.wl_proxy_get_version(ti);
        _ = wl_lib.wl_proxy_marshal_flags(ti, proto.text_input.enable, null, ver, 0);
        _ = wl_lib.wl_proxy_marshal_flags(ti, proto.text_input.commit, null, ver, 0);
    }
}

fn onLeave(data: ?*anyopaque, ti: ?*wl.Proxy, _: ?*wl.Proxy) callconv(.c) void {
    const self: *TextInput = @ptrCast(@alignCast(data.?));
    self.clearPreeditOnLeave();
    const wl_lib = &backend.state.wl.?;
    const ver = wl_lib.wl_proxy_get_version(ti);
    _ = wl_lib.wl_proxy_marshal_flags(ti, proto.text_input.disable, null, ver, 0);
    _ = wl_lib.wl_proxy_marshal_flags(ti, proto.text_input.commit, null, ver, 0);
}

fn onPreeditString(
    data: ?*anyopaque,
    _: ?*wl.Proxy,
    text: [*c]const u8,
    cursor_begin: i32,
    cursor_end: i32,
) callconv(.c) void {
    const self: *TextInput = @ptrCast(@alignCast(data.?));
    const slice: ?[]const u8 = if (text != null) std.mem.span(text) else null;
    self.stagePreedit(slice, cursor_begin, cursor_end);
}

fn onCommitString(data: ?*anyopaque, _: ?*wl.Proxy, text: [*c]const u8) callconv(.c) void {
    const self: *TextInput = @ptrCast(@alignCast(data.?));
    const slice: ?[]const u8 = if (text != null) std.mem.span(text) else null;
    self.stageCommit(slice);
}

fn onDeleteSurroundingText(_: ?*anyopaque, _: ?*wl.Proxy, _: u32, _: u32) callconv(.c) void {}

fn onDone(data: ?*anyopaque, _: ?*wl.Proxy, _: u32) callconv(.c) void {
    const self: *TextInput = @ptrCast(@alignCast(data.?));
    self.applyDone();
}

const text_input_listener: proto.text_input.Listener = .{
    .enter = onEnter,
    .leave = onLeave,
    .preedit_string = onPreeditString,
    .commit_string = onCommitString,
    .delete_surrounding_text = onDeleteSurroundingText,
    .done = onDone,
};
