//! OSC 52, xterm's "Manipulate Selection Data": `OSC 52 ; Pc ; Pd ST`.
//!
//! The terminal hands over the bytes after `52;` as they arrive, and this
//! decodes `Pd` from base64 straight into `buf`, so a write never passes
//! through the 1,024-byte OSC buffer. The result is one pending `Request`
//! for the host to take; this file holds no policy (ADR 0006).
//!
//! `Pc` targets: `c`, `s` and an empty `Pc` mean the clipboard (a
//! documented difference from xterm, where `s` is PRIMARY), `p` means
//! PRIMARY, and `q`, `0`-`7` and anything else are ignored. `Pd` is base64
//! (padded, or unpadded at the end), `?` asks for the selection, and
//! anything else clears it, as in xterm.

const std = @import("std");

const Clipboard = @This();

const decoder = std.base64.standard.Decoder;
const tail_decoder = std.base64.standard_no_pad.Decoder;

pub const Targets = packed struct(u8) {
    clipboard: bool = false,
    primary: bool = false,
    _pad: u6 = 0,

    pub fn any(self: Targets) bool {
        return self.clipboard or self.primary;
    }
};

/// What the last complete OSC 52 asked for. A `write`'s data is
/// `buf[0..len]`; empty data clears the targets.
pub const Request = union(enum) {
    none,
    write: Targets,
    read: Targets,
};

/// Where the next byte of the sequence goes.
const State = enum {
    /// No OSC 52 in progress.
    idle,
    /// At the start of `Pc`: a `;` here means an empty `Pc`.
    targets_start,
    /// Collecting `Pc`, up to the `;`.
    targets,
    /// Decoding `Pd`.
    data,
    /// `Pd` ended with `=` padding; any further byte makes it invalid.
    padded,
    /// `Pd` so far is `?`.
    query,
    /// `Pd` is neither base64 nor `?`: the request clears the targets.
    invalid,
    /// The decoded data would not fit in `buf`: the request is dropped.
    overflow,
};

/// Decoded data of the pending or in-progress write. Owned; its length is
/// the most a write can hold.
buf: []u8,
request: Request = .none,
/// Writes dropped because they did not fit in `buf`.
dropped: u32 = 0,

state: State = .idle,
targets: Targets = .{},
/// Bytes of `buf` filled by the write in progress or pending.
len: usize = 0,
/// Base64 characters waiting for the rest of their group of four.
carry: [4]u8 = undefined,
carry_len: u8 = 0,

/// Allocates a buffer for writes of up to `max_len` decoded bytes.
pub fn init(gpa: std.mem.Allocator, max_len: usize) std.mem.Allocator.Error!Clipboard {
    return .{ .buf = try gpa.alloc(u8, max_len) };
}

pub fn deinit(self: *Clipboard, gpa: std.mem.Allocator) void {
    gpa.free(self.buf);
    self.* = undefined;
}

/// Starts a new OSC 52. It replaces a pending request, even if the new one
/// then fails, because its data overwrites `buf`.
pub fn begin(self: *Clipboard) void {
    self.request = .none;
    self.state = .targets_start;
    self.targets = .{};
    self.len = 0;
    self.carry_len = 0;
}

/// Feeds the next bytes of the sequence. They may be split anywhere.
pub fn put(self: *Clipboard, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        switch (self.state) {
            .idle, .invalid, .overflow => return,
            .targets_start, .targets => {
                const b = rest[0];
                rest = rest[1..];
                if (self.state == .targets_start and b == ';') {
                    self.targets.clipboard = true; // empty `Pc` means `s`
                    self.state = .data;
                    continue;
                }
                self.state = .targets;
                switch (b) {
                    ';' => self.state = .data,
                    'c', 's' => self.targets.clipboard = true,
                    'p' => self.targets.primary = true,
                    else => {}, // secondary, cut buffers, unknown
                }
            },
            .data => rest = self.putData(rest),
            .padded, .query => self.state = .invalid,
        }
    }
}

/// Decodes as much of `bytes` as forms whole groups of four, keeping the
/// rest in `carry`, and returns what is left for the next state.
fn putData(self: *Clipboard, bytes: []const u8) []const u8 {
    var rest = bytes;
    if (self.len == 0 and self.carry_len == 0 and rest[0] == '?') {
        self.state = .query;
        return rest[1..];
    }
    while (self.carry_len > 0 and rest.len > 0) {
        self.carry[self.carry_len] = rest[0];
        self.carry_len += 1;
        rest = rest[1..];
        if (self.carry_len == 4) {
            self.carry_len = 0;
            self.decodeGroups(&self.carry);
            if (self.state != .data) return rest;
        }
    }
    if (rest.len == 0) return rest;
    // `carry` is empty here: the loop above emptied it or used up `rest`.
    const whole = rest.len - rest.len % 4;
    if (whole > 0) {
        self.decodeGroups(rest[0..whole]);
        rest = rest[whole..];
        if (self.state != .data) return rest;
    }
    @memcpy(self.carry[0..rest.len], rest);
    self.carry_len = @intCast(rest.len);
    return &.{};
}

/// Decodes whole groups of four. `=` may only end the last group, and then
/// ends the data.
fn decodeGroups(self: *Clipboard, groups: []const u8) void {
    std.debug.assert(groups.len % 4 == 0);
    const size = decoder.calcSizeForSlice(groups) catch unreachable; // a multiple of 4
    if (size > self.buf.len - self.len) {
        self.state = .overflow;
        return;
    }
    decoder.decode(self.buf[self.len..][0..size], groups) catch {
        self.state = .invalid;
        return;
    };
    self.len += size;
    if (groups[groups.len - 1] == '=') self.state = .padded;
}

/// Ends the sequence. Returns true when it left a request to take.
pub fn end(self: *Clipboard) bool {
    const state = self.state;
    self.state = .idle;
    switch (state) {
        .idle => return false,
        // No `;`: there is no `Pd`.
        .targets_start, .targets => return false,
        .overflow => {
            self.dropped +|= 1;
            return false;
        },
        .data => switch (self.decodeTail()) {
            .ok => {},
            .invalid => self.len = 0,
            .overflow => {
                self.dropped +|= 1;
                return false;
            },
        },
        .padded => {},
        .invalid => self.len = 0,
        .query => {
            if (!self.targets.any()) return false;
            self.request = .{ .read = self.targets };
            return true;
        },
    }
    if (!self.targets.any()) return false;
    self.request = .{ .write = self.targets };
    return true;
}

/// Decodes the 2 or 3 characters left without padding; 1 is not base64.
fn decodeTail(self: *Clipboard) enum { ok, invalid, overflow } {
    const tail = self.carry[0..self.carry_len];
    if (tail.len == 0) return .ok;
    const size = tail_decoder.calcSizeForSlice(tail) catch return .invalid;
    if (size > self.buf.len - self.len) return .overflow;
    tail_decoder.decode(self.buf[self.len..][0..size], tail) catch return .invalid;
    self.len += size;
    return .ok;
}

/// The pending request, and for a write its data, valid until the next
/// `begin`. Leaves no request pending.
pub fn take(self: *Clipboard) struct { Request, []const u8 } {
    const request = self.request;
    self.request = .none;
    return switch (request) {
        .write => .{ request, self.buf[0..self.len] },
        else => .{ request, &.{} },
    };
}
