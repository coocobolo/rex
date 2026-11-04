//! OSC and DCS fuzz target: sequences built from a known introducer, a
//! code or DCS header, a random payload and a random terminator (BEL,
//! ST, ESC with another final, CAN, SUB or none), fed to a `Terminal`
//! after an optional prefix, then followed by plain text.
//!
//! Invariants:
//!   - no panic, safety check or leak;
//!   - `invariants.expectTerminal` after every sequence;
//!   - a sequence ended by BEL (OSC) or ST leaves the parser in ground.

const std = @import("std");
const testing = std.testing;

const harness = @import("harness.zig");
const invariants = @import("invariants.zig");
const Source = harness.Source;
const term = @import("../term/term.zig");
const test_option = @import("../term/test_fixtures.zig").test_option;

const Terminal = term.Terminal(test_option);

const osc_codes = [_][]const u8{
    "0", "1", "2", "4", "7", "8", "10", "11", "12", "17", "19", "52", "104", "110", "111", "112", "133", "",
};
const dcs_headers = [_][]const u8{ "$q", "+q", "q", "1;2|", "0;1$t", "2000p", "" };

const Kind = enum { osc, dcs };
const Terminator = enum { bel, st, st_c1, esc_other, can, sub, none };

fn sequence(src: *Source, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !Terminator {
    const kind = src.pick("kind", Kind);
    switch (kind) {
        .osc => {
            try out.appendSlice(gpa, "\x1b]");
            try out.appendSlice(gpa, osc_codes[src.index("osc code", osc_codes.len)]);
            if (src.chance("separator", 1, 7)) {} else try out.append(gpa, ';');
        },
        .dcs => {
            try out.appendSlice(gpa, "\x1bP");
            try out.appendSlice(gpa, dcs_headers[src.index("dcs header", dcs_headers.len)]);
        },
    }
    // Up to past the 1024-byte string buffers. Bytes that end or cancel
    // a string are swapped out; only the terminator supplies them.
    var buf: [1200]u8 = undefined;
    const payload = buf[0..src.range("payload len", usize, 0, buf.len)];
    src.bytes("payload", payload);
    for (payload) |b| {
        try out.append(gpa, switch (b) {
            0x07, 0x18, 0x1A, 0x1B => '.',
            0x80...0x9F => b + 0x20, // keep C1 out in latin1/8-bit runs
            else => b,
        });
    }
    const end = src.pick("terminator", Terminator);
    try out.appendSlice(gpa, switch (end) {
        .bel => if (kind == .osc) "\x07" else "\x1b\\",
        .st => "\x1b\\",
        .st_c1 => "\x9c",
        .esc_other => "\x1b7",
        .can => "\x18",
        .sub => "\x1a",
        .none => "",
    });
    return end;
}

fn run(src: *Source) !void {
    const gpa = testing.allocator;
    var t: Terminal = try .create(gpa);
    defer t.destroy(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    // A seed is a prefix: modes, an unfinished sequence, anything.
    var prefix_buf: [256]u8 = undefined;
    t.feed(src.chunk("prefix", &prefix_buf));
    try invariants.expectTerminal(&t);

    var count: usize = 0;
    while (count < 8 and !src.done("sequence", 3)) : (count += 1) {
        out.clearRetainingCapacity();
        const end = try sequence(src, &out, gpa);
        t.feed(out.items);
        try invariants.expectTerminal(&t);
        // In UTF-8 a lone 0x9C is not ST, so only the 7-bit forms count.
        if (end == .bel or end == .st) try testing.expectEqual(.ground, t.parser.state);
        t.events.clear();
    }
}

const seeds = [_][]const u8{
    "",
    "text before ",
    "\x1b]",
    "\x1bP",
    "\x1b[?1049h",
    "\x1b G\x1b[62;0\"p",
    "\x1b%@",
    "\xe2\x82",
};

const regressions = [_][]const u8{};

test "fuzz strings" {
    try harness.fuzz(run, &seeds, &regressions);
}

test "fuzz strings: seeded mutations" {
    try harness.seeded(run, &seeds, 0x05C5_7A11);
}
