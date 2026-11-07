//! Bracketed paste (xterm, `CSI ? 2004 h`): with the mode set, a paste
//! reaches the child wrapped in `ESC [ 200 ~` and `ESC [ 201 ~`, so it can
//! tell pasted text from typed input. See xterm's ctlseqs, "Bracketed Paste
//! Mode".

const std = @import("std");
const Allocator = std.mem.Allocator;

const OutboundQueue = @import("OutboundQueue.zig");

pub const start = "\x1b[200~";
pub const end = "\x1b[201~";

const esc = 0x1b;

/// Queues `text` as one bracketed paste, all or nothing: the start marker,
/// `text` without its ESC bytes, and the end marker. Removing every ESC
/// means the pasted text can't contain an end marker of its own, which
/// would end the paste early and turn the rest into typed input. ESC is
/// ASCII, so in UTF-8 it never occurs inside a multi-byte character and
/// removing it leaves every other character intact.
///
/// The limit check counts `text` with its ESC bytes, so it may refuse a
/// paste up to that many bytes early.
pub fn queueBracketed(queue: *OutboundQueue, gpa: Allocator, text: []const u8) OutboundQueue.AppendError!void {
    const slot = try queue.reserve(gpa, start.len + text.len + end.len);

    @memcpy(slot[0..start.len], start);
    var len: usize = start.len;

    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, esc)) |i| {
        @memcpy(slot[len..][0..i], rest[0..i]);
        len += i;
        rest = rest[i + 1 ..];
    }
    @memcpy(slot[len..][0..rest.len], rest);
    len += rest.len;

    @memcpy(slot[len..][0..end.len], end);
    len += end.len;

    queue.commit(len);
}
