//! Wayland CLIPBOARD (`wl_data_device`) and PRIMARY (`zwp_primary_selection_v1`)
//! ownership and pipe-backed reads. Uses fixed 1 MiB buffers matching
//! `TerminalOption.max_clipboard_bytes` so selection operations allocate nothing.

const std = @import("std");

const pipe = @import("../../termio/pipe.zig");
const backend = @import("backend.zig");
const proto = @import("proto.zig");
const seat = @import("seat.zig");
const wl = @import("wl.zig");

const posix = std.posix;
const system = posix.system;
const log = std.log.scoped(.platform);

/// Mirrors `TerminalOption.max_clipboard_bytes` (1 MiB) plus null terminator.
pub const selection_capacity = (1 << 20) + 1;

pub const mime_utf8: [:0]const u8 = "text/plain;charset=utf-8";
pub const mime_plain: [:0]const u8 = "text/plain";

const OfferMime = packed struct(u8) {
    utf8: bool = false,
    plain: bool = false,
    _: u6 = 0,

    pub fn preferred(self: OfferMime) ?[:0]const u8 {
        if (self.utf8) return mime_utf8;
        if (self.plain) return mime_plain;
        return null;
    }

    pub fn record(self: *OfferMime, mime: []const u8) void {
        if (std.mem.eql(u8, mime, mime_utf8) or std.mem.eql(u8, mime, "UTF8_STRING")) {
            self.utf8 = true;
        } else if (std.mem.eql(u8, mime, mime_plain)) {
            self.plain = true;
        }
    }
};

pub const Selection = struct {
    data_device: ?*wl.Proxy = null,
    clipboard_source: ?*wl.Proxy = null,
    clipboard_offer: ?*wl.Proxy = null,
    pending_clip_offer: ?*wl.Proxy = null,
    pending_clip_mime: OfferMime = .{},
    clipboard_mime: OfferMime = .{},

    primary_device: ?*wl.Proxy = null,
    primary_source: ?*wl.Proxy = null,
    primary_offer: ?*wl.Proxy = null,
    pending_prim_offer: ?*wl.Proxy = null,
    pending_prim_mime: OfferMime = .{},
    primary_mime: OfferMime = .{},

    clipboard_buf: [selection_capacity]u8 = undefined,
    clipboard_len: usize = 0,
    primary_buf: [selection_capacity]u8 = undefined,
    primary_len: usize = 0,
    read_buf: [selection_capacity]u8 = undefined,
    read_len: usize = 0,

    /// Binds `wl_data_device` on `wl_seat` for CLIPBOARD.
    pub fn attachClipboard(self: *Selection, mgr: *wl.Proxy, wl_seat: *wl.Proxy) void {
        if (self.data_device != null) return;
        const wl_lib = &backend.state.wl.?;
        if (wl_lib.wl_proxy_marshal_flags(
            mgr,
            proto.data_device_manager.get_data_device,
            wl_lib.data_device_interface,
            wl_lib.wl_proxy_get_version(mgr),
            0,
            @as(?*anyopaque, null),
            wl_seat,
        )) |dev| {
            self.data_device = dev;
            _ = wl_lib.wl_proxy_add_listener(dev, @ptrCast(@constCast(&data_device_listener)), self);
        }
    }

    /// Binds `zwp_primary_selection_device_v1` on `wl_seat` for PRIMARY.
    pub fn attachPrimary(self: *Selection, mgr: *wl.Proxy, wl_seat: *wl.Proxy) void {
        if (self.primary_device != null) return;
        const wl_lib = &backend.state.wl.?;
        const ifaces = proto.interfaces();
        if (wl_lib.wl_proxy_marshal_flags(
            mgr,
            proto.primary_selection_manager.get_device,
            ifaces.primary_selection_device,
            wl_lib.wl_proxy_get_version(mgr),
            0,
            @as(?*anyopaque, null),
            wl_seat,
        )) |dev| {
            self.primary_device = dev;
            _ = wl_lib.wl_proxy_add_listener(dev, @ptrCast(@constCast(&primary_device_listener)), self);
        }
    }

    /// Releases all Wayland selection devices, sources and offers.
    pub fn deinit(self: *Selection) void {
        if (backend.state.wl) |*wl_lib| {
            destroyOffer(wl_lib, &self.pending_clip_offer, false);
            destroyOffer(wl_lib, &self.clipboard_offer, false);
            destroySource(wl_lib, &self.clipboard_source, false);
            if (self.data_device) |dev| {
                if (wl_lib.wl_proxy_get_version(dev) >= 2) {
                    _ = wl_lib.wl_proxy_marshal_flags(dev, proto.data_device.release, null, wl_lib.wl_proxy_get_version(dev), proto.marshal_flag_destroy);
                } else {
                    wl_lib.wl_proxy_destroy(dev);
                }
                self.data_device = null;
            }

            destroyOffer(wl_lib, &self.pending_prim_offer, true);
            destroyOffer(wl_lib, &self.primary_offer, true);
            destroySource(wl_lib, &self.primary_source, true);
            if (self.primary_device) |dev| {
                _ = wl_lib.wl_proxy_marshal_flags(dev, proto.primary_selection_device.destroy, null, wl_lib.wl_proxy_get_version(dev), proto.marshal_flag_destroy);
                self.primary_device = null;
            }
        }
        self.clipboard_len = 0;
        self.primary_len = 0;
        self.read_len = 0;
    }

    /// Copies `text` into the owned CLIPBOARD buffer and advertises it to the compositor.
    pub fn setClipboard(self: *Selection, text: [:0]const u8) void {
        self.clipboard_len = copyBounded(&self.clipboard_buf, text);
        const wl_lib = if (backend.state.wl) |*wlib| wlib else return;
        const mgr = backend.state.data_device_manager orelse return;
        const dev = self.data_device orelse return;

        destroySource(wl_lib, &self.clipboard_source, false);
        const src = wl_lib.wl_proxy_marshal_flags(
            mgr,
            proto.data_device_manager.create_data_source,
            wl_lib.data_source_interface,
            wl_lib.wl_proxy_get_version(mgr),
            0,
            @as(?*anyopaque, null),
        ) orelse return;
        self.clipboard_source = src;
        _ = wl_lib.wl_proxy_add_listener(src, @ptrCast(@constCast(&data_source_listener)), self);

        const src_ver = wl_lib.wl_proxy_get_version(src);
        _ = wl_lib.wl_proxy_marshal_flags(src, proto.data_source.offer, null, src_ver, 0, mime_utf8.ptr);
        _ = wl_lib.wl_proxy_marshal_flags(src, proto.data_source.offer, null, src_ver, 0, mime_plain.ptr);
        _ = wl_lib.wl_proxy_marshal_flags(
            dev,
            proto.data_device.set_selection,
            null,
            wl_lib.wl_proxy_get_version(dev),
            0,
            src,
            backend.state.seat_state.last_serial,
        );
        if (backend.state.display) |dpy| _ = wl_lib.wl_display_flush(dpy);
    }

    /// Reads CLIPBOARD text, returning our owned buffer directly or receiving via pipe.
    pub fn getClipboard(self: *Selection) ?[:0]const u8 {
        if (self.clipboard_source != null) {
            return self.clipboard_buf[0..self.clipboard_len :0];
        }
        const offer = self.clipboard_offer orelse return null;
        const mime = self.clipboard_mime.preferred() orelse return null;
        return self.receiveOffer(offer, proto.data_offer.receive, mime);
    }

    /// Copies `text` into the owned PRIMARY buffer and advertises it if supported.
    pub fn setPrimary(self: *Selection, text: [:0]const u8) bool {
        self.primary_len = copyBounded(&self.primary_buf, text);
        const wl_lib = if (backend.state.wl) |*wlib| wlib else return false;
        const mgr = backend.state.primary_selection_manager orelse return false;
        const dev = self.primary_device orelse return false;
        const ifaces = proto.interfaces();

        destroySource(wl_lib, &self.primary_source, true);
        const src = wl_lib.wl_proxy_marshal_flags(
            mgr,
            proto.primary_selection_manager.create_source,
            ifaces.primary_selection_source,
            wl_lib.wl_proxy_get_version(mgr),
            0,
            @as(?*anyopaque, null),
        ) orelse return false;
        self.primary_source = src;
        _ = wl_lib.wl_proxy_add_listener(src, @ptrCast(@constCast(&primary_source_listener)), self);

        const src_ver = wl_lib.wl_proxy_get_version(src);
        _ = wl_lib.wl_proxy_marshal_flags(src, proto.primary_selection_source.offer, null, src_ver, 0, mime_utf8.ptr);
        _ = wl_lib.wl_proxy_marshal_flags(src, proto.primary_selection_source.offer, null, src_ver, 0, mime_plain.ptr);
        _ = wl_lib.wl_proxy_marshal_flags(
            dev,
            proto.primary_selection_device.set_selection,
            null,
            wl_lib.wl_proxy_get_version(dev),
            0,
            src,
            backend.state.seat_state.last_serial,
        );
        if (backend.state.display) |dpy| _ = wl_lib.wl_display_flush(dpy);
        return true;
    }

    /// Reads PRIMARY selection text, returning our owned buffer or receiving via pipe.
    pub fn getPrimary(self: *Selection) ?[:0]const u8 {
        if (self.primary_source != null) {
            return self.primary_buf[0..self.primary_len :0];
        }
        const offer = self.primary_offer orelse return null;
        const mime = self.primary_mime.preferred() orelse return null;
        return self.receiveOffer(offer, proto.primary_selection_offer.receive, mime);
    }

    fn receiveOffer(self: *Selection, offer: *wl.Proxy, receive_opcode: u32, mime: [:0]const u8) ?[:0]const u8 {
        const wl_lib = if (backend.state.wl) |*wlib| wlib else return null;
        const dpy = backend.state.display orelse return null;

        var fds: [2]posix.fd_t = undefined;
        pipe.open(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }) catch |err| {
            log.err("cannot create a selection read pipe: {}", .{err});
            return null;
        };
        const read_fd = fds[0];
        const write_fd = fds[1];
        defer _ = system.close(read_fd);

        _ = wl_lib.wl_proxy_marshal_flags(
            offer,
            receive_opcode,
            null,
            wl_lib.wl_proxy_get_version(offer),
            0,
            mime.ptr,
            write_fd,
        );
        _ = system.close(write_fd);
        _ = wl_lib.wl_display_flush(dpy);

        var total: usize = 0;
        const max_bytes = selection_capacity - 1;
        var pfd = [1]posix.pollfd{.{ .fd = read_fd, .events = posix.POLL.IN, .revents = 0 }};
        const deadline_ns = seat.monotonicNs() + 500 * std.time.ns_per_ms;

        while (total < max_bytes) {
            const rem_ns = deadline_ns - seat.monotonicNs();
            if (rem_ns <= 0) break;
            const rem_ms: i32 = @intCast(@max(@divTrunc(rem_ns, std.time.ns_per_ms), 1));
            const ready = system.poll(&pfd, 1, rem_ms);
            if (ready < 0) {
                if (posix.errno(ready) == .INTR) continue;
                break;
            }
            if (ready == 0) break;
            if ((pfd[0].revents & posix.POLL.IN) != 0) {
                const n = system.read(read_fd, self.read_buf[total..max_bytes].ptr, max_bytes - total);
                if (n > 0) {
                    total += @intCast(n);
                    continue;
                }
                if (n == 0) break;
                const err = posix.errno(n);
                if (err == .INTR or err == .AGAIN) continue;
                break;
            }
            if ((pfd[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) break;
        }

        self.read_buf[total] = 0;
        self.read_len = total;
        return self.read_buf[0..total :0];
    }
};

/// Copies `text` into `dst` leaving room for a null terminator.
pub fn copyBounded(dst: *[selection_capacity]u8, text: []const u8) usize {
    const n = @min(text.len, selection_capacity - 1);
    @memcpy(dst[0..n], text[0..n]);
    dst[n] = 0;
    return n;
}

/// Exposed for unit tests to verify MIME selection precedence.
pub fn preferredMime(has_utf8: bool, has_plain: bool) ?[:0]const u8 {
    const m: OfferMime = .{ .utf8 = has_utf8, .plain = has_plain };
    return m.preferred();
}

fn writeAllAndClose(fd: i32, data: []const u8) void {
    defer _ = system.close(fd);
    var written: usize = 0;
    const deadline_ns = seat.monotonicNs() + 500 * std.time.ns_per_ms;
    while (written < data.len) {
        const n = system.write(fd, data[written..].ptr, data.len - written);
        if (n > 0) {
            written += @intCast(n);
            continue;
        }
        const err = posix.errno(n);
        if (err == .INTR) continue;
        if (err == .AGAIN) {
            const rem_ns = deadline_ns - seat.monotonicNs();
            if (rem_ns <= 0) break;
            const rem_ms: i32 = @intCast(@max(@divTrunc(rem_ns, std.time.ns_per_ms), 1));
            var pfd = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
            const ready = system.poll(&pfd, 1, rem_ms);
            if (ready > 0 and (pfd[0].revents & posix.POLL.OUT) != 0) continue;
            if (ready < 0 and posix.errno(ready) == .INTR) continue;
            break;
        }
        break;
    }
}

fn destroyOffer(wl_lib: *const wl.Wayland, slot: *?*wl.Proxy, is_primary: bool) void {
    const offer = slot.* orelse return;
    slot.* = null;
    const op = if (is_primary) proto.primary_selection_offer.destroy else proto.data_offer.destroy;
    _ = wl_lib.wl_proxy_marshal_flags(offer, op, null, wl_lib.wl_proxy_get_version(offer), proto.marshal_flag_destroy);
}

fn destroySource(wl_lib: *const wl.Wayland, slot: *?*wl.Proxy, is_primary: bool) void {
    const src = slot.* orelse return;
    slot.* = null;
    const op = if (is_primary) proto.primary_selection_source.destroy else proto.data_source.destroy;
    _ = wl_lib.wl_proxy_marshal_flags(src, op, null, wl_lib.wl_proxy_get_version(src), proto.marshal_flag_destroy);
}

fn onDataOffer(data: ?*anyopaque, _: ?*wl.Proxy, offer: ?*wl.Proxy) callconv(.c) void {
    const self: *Selection = @ptrCast(@alignCast(data.?));
    const wl_lib = &backend.state.wl.?;
    destroyOffer(wl_lib, &self.pending_clip_offer, false);
    self.pending_clip_offer = offer;
    self.pending_clip_mime = .{};
    if (offer) |o| {
        _ = wl_lib.wl_proxy_add_listener(o, @ptrCast(@constCast(&data_offer_listener)), self);
    }
}

fn onDataOfferMime(data: ?*anyopaque, offer: ?*wl.Proxy, mime: [*c]const u8) callconv(.c) void {
    const self: *Selection = @ptrCast(@alignCast(data.?));
    if (mime == null) return;
    if (offer == self.pending_clip_offer) {
        self.pending_clip_mime.record(std.mem.span(mime));
    } else if (offer == self.clipboard_offer) {
        self.clipboard_mime.record(std.mem.span(mime));
    }
}

fn onDataDeviceSelection(data: ?*anyopaque, _: ?*wl.Proxy, offer: ?*wl.Proxy) callconv(.c) void {
    const self: *Selection = @ptrCast(@alignCast(data.?));
    const wl_lib = &backend.state.wl.?;
    destroyOffer(wl_lib, &self.clipboard_offer, false);
    self.clipboard_offer = offer;
    if (offer != null and offer == self.pending_clip_offer) {
        self.clipboard_mime = self.pending_clip_mime;
        self.pending_clip_offer = null;
        self.pending_clip_mime = .{};
    } else {
        self.clipboard_mime = .{};
    }
}

fn onDataSourceSend(data: ?*anyopaque, _: ?*wl.Proxy, _: [*c]const u8, fd: i32) callconv(.c) void {
    const self: *Selection = @ptrCast(@alignCast(data.?));
    writeAllAndClose(fd, self.clipboard_buf[0..self.clipboard_len]);
}

fn onDataSourceCancelled(data: ?*anyopaque, src: ?*wl.Proxy) callconv(.c) void {
    const self: *Selection = @ptrCast(@alignCast(data.?));
    if (self.clipboard_source == src) {
        destroySource(&backend.state.wl.?, &self.clipboard_source, false);
    }
}

fn onPrimaryOffer(data: ?*anyopaque, _: ?*wl.Proxy, offer: ?*wl.Proxy) callconv(.c) void {
    const self: *Selection = @ptrCast(@alignCast(data.?));
    const wl_lib = &backend.state.wl.?;
    destroyOffer(wl_lib, &self.pending_prim_offer, true);
    self.pending_prim_offer = offer;
    self.pending_prim_mime = .{};
    if (offer) |o| {
        _ = wl_lib.wl_proxy_add_listener(o, @ptrCast(@constCast(&primary_offer_listener)), self);
    }
}

fn onPrimaryOfferMime(data: ?*anyopaque, offer: ?*wl.Proxy, mime: [*c]const u8) callconv(.c) void {
    const self: *Selection = @ptrCast(@alignCast(data.?));
    if (mime == null) return;
    if (offer == self.pending_prim_offer) {
        self.pending_prim_mime.record(std.mem.span(mime));
    } else if (offer == self.primary_offer) {
        self.primary_mime.record(std.mem.span(mime));
    }
}

fn onPrimarySelection(data: ?*anyopaque, _: ?*wl.Proxy, offer: ?*wl.Proxy) callconv(.c) void {
    const self: *Selection = @ptrCast(@alignCast(data.?));
    const wl_lib = &backend.state.wl.?;
    destroyOffer(wl_lib, &self.primary_offer, true);
    self.primary_offer = offer;
    if (offer != null and offer == self.pending_prim_offer) {
        self.primary_mime = self.pending_prim_mime;
        self.pending_prim_offer = null;
        self.pending_prim_mime = .{};
    } else {
        self.primary_mime = .{};
    }
}

fn onPrimarySourceSend(data: ?*anyopaque, _: ?*wl.Proxy, _: [*c]const u8, fd: i32) callconv(.c) void {
    const self: *Selection = @ptrCast(@alignCast(data.?));
    writeAllAndClose(fd, self.primary_buf[0..self.primary_len]);
}

fn onPrimarySourceCancelled(data: ?*anyopaque, src: ?*wl.Proxy) callconv(.c) void {
    const self: *Selection = @ptrCast(@alignCast(data.?));
    if (self.primary_source == src) {
        destroySource(&backend.state.wl.?, &self.primary_source, true);
    }
}

fn onDataDeviceEnter(_: ?*anyopaque, _: ?*wl.Proxy, _: u32, _: ?*wl.Proxy, _: i32, _: i32, _: ?*wl.Proxy) callconv(.c) void {}
fn onDataDeviceLeave(_: ?*anyopaque, _: ?*wl.Proxy) callconv(.c) void {}
fn onDataDeviceMotion(_: ?*anyopaque, _: ?*wl.Proxy, _: u32, _: i32, _: i32) callconv(.c) void {}
fn onDataDeviceDrop(_: ?*anyopaque, _: ?*wl.Proxy) callconv(.c) void {}
fn onDataOfferSourceActions(_: ?*anyopaque, _: ?*wl.Proxy, _: u32) callconv(.c) void {}
fn onDataOfferAction(_: ?*anyopaque, _: ?*wl.Proxy, _: u32) callconv(.c) void {}
fn onDataSourceTarget(_: ?*anyopaque, _: ?*wl.Proxy, _: [*c]const u8) callconv(.c) void {}
fn onDataSourceDndDrop(_: ?*anyopaque, _: ?*wl.Proxy) callconv(.c) void {}
fn onDataSourceDndFinished(_: ?*anyopaque, _: ?*wl.Proxy) callconv(.c) void {}
fn onDataSourceAction(_: ?*anyopaque, _: ?*wl.Proxy, _: u32) callconv(.c) void {}

const data_device_listener: proto.data_device.Listener = .{
    .data_offer = onDataOffer,
    .enter = onDataDeviceEnter,
    .leave = onDataDeviceLeave,
    .motion = onDataDeviceMotion,
    .drop = onDataDeviceDrop,
    .selection = onDataDeviceSelection,
};

const data_offer_listener: proto.data_offer.Listener = .{
    .offer = onDataOfferMime,
    .source_actions = onDataOfferSourceActions,
    .action = onDataOfferAction,
};

const data_source_listener: proto.data_source.Listener = .{
    .target = onDataSourceTarget,
    .send = onDataSourceSend,
    .cancelled = onDataSourceCancelled,
    .dnd_drop_performed = onDataSourceDndDrop,
    .dnd_finished = onDataSourceDndFinished,
    .action = onDataSourceAction,
};

const primary_device_listener: proto.primary_selection_device.Listener = .{
    .data_offer = onPrimaryOffer,
    .selection = onPrimarySelection,
};

const primary_offer_listener: proto.primary_selection_offer.Listener = .{
    .offer = onPrimaryOfferMime,
};

const primary_source_listener: proto.primary_selection_source.Listener = .{
    .send = onPrimarySourceSend,
    .cancelled = onPrimarySourceCancelled,
};
