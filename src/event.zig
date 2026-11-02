const std = @import("std");

const log = std.log.scoped(.event);

pub const Event = union(enum) {
    char: u21,
    key: void,
    mouse: void,
    resize: void,
};

pub const EventQueue = struct {
    queue: std.ArrayList(Event),
    mutex: std.Io.Mutex = .init,
};