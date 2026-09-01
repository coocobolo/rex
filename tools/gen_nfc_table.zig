//! Generates src/term/nfc_table.zig from Unicode Character Database data:
//! UnicodeData.txt.
//!
//! Usage:
//!  gen_nfc_table <path/to/UnicodeData.txt> > src/term/nfc_table.zig
//!
//! This generator uses data from the Unicode Character Database.
//! See THIRD_PARTY_NOTICES/unicode.license.txt for the applicable Unicode license terms.
//!
//! Unicode version: 17.0.0
//!
//! Data sources:
//! - [UnicodeData.txt](https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt)
//! - [CompositionExclusions.txt](https://www.unicode.org/Public/17.0.0/ucd/CompositionExclusions.txt)
//!
//! The composition-exclusion data is embedded in this generator.
//! The output is a sorted array of packed `u64` entries and a `compose()`
//! lookup function.
//!
//! Each entry is encoded as follows:
//! - bits [62,42] = base code point
//! - bits [41,21] = combining code point
//! - bits [20,0]  = composed code point
//! Bit 63 is unused.

const std = @import("std");

const log = std.log.scoped(.gen_nfc_table);

pub fn main(init: std.process.Init) !void {
    var args_it = init.minimal.args.iterate();

    if (args_it.inner.remaining.len < 2) {
        log.info("Usage: gen_nfc_table <file_name.txt>\n", .{});
        std.process.exit(0);
    }

    _ = args_it.skip(); // skip argv[0]

    const src_file = args_it.next() orelse {
        log.err("expected unicode data source file, got null\n", .{});
        std.process.exit(1);
    };

    if (src_file.len == 0) {
        log.err("expected unicode data source file, got {s}\n", .{src_file});
        std.process.exit(1);
    }

    const io = init.io;

    const file = try std.Io.Dir.openFile(.cwd(), io, src_file, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const content_buffer = try init.gpa.alloc(u8, stat.size);
    defer init.gpa.free(content_buffer);

    const read_n = try file.readPositionalAll(io, content_buffer, 0);

    if (stat.size != read_n) {
        log.err("mismatched file_size and read content size. {};{}", .{ stat.size, read_n });
        std.process.exit(1);
    }

    const content = content_buffer[0..read_n];

    // Collect canonical combining class (CCC) for every codepoint.
    // We need this to filter out non-starter decompositions.
    var ccc_map: std.AutoHashMap(u21, u8) = .init(init.gpa);
    defer ccc_map.deinit();

    {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var f = std.mem.splitScalar(u8, line, ';');
            const cp = std.fmt.parseInt(u21, f.next() orelse continue, 16) catch continue;
            _ = f.next(); // name
            _ = f.next(); // category
            const ccc = std.fmt.parseInt(u8, f.next() orelse continue, 10) catch continue;
            if (ccc > 0) try ccc_map.put(cp, ccc);
        }
    }

    // collect canonical two-codepoint decompositions.
    const Triple = struct { base: u21, combiner: u21, composed: u21 };
    var triples: std.ArrayList(Triple) = try .initCapacity(init.gpa, 1024);
    defer triples.deinit(init.gpa);

    {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var f = std.mem.splitScalar(u8, line, ';');
            const composed = std.fmt.parseInt(u21, f.next() orelse continue, 16) catch continue;
            _ = f.next(); // name
            _ = f.next(); // category
            _ = f.next(); // CCC
            _ = f.next(); // bidi
            const decomp = f.next() orelse continue;

            // Skip empty and compatibility decompositions (<compat>, <circle>, etc.)
            if (decomp.len == 0 or decomp[0] == '<') continue;

            var parts = std.mem.splitScalar(u8, decomp, ' ');
            const base_str = parts.next() orelse continue;
            const combiner_str = parts.next() orelse continue;
            if (parts.next() != null) continue; // 3+ codepoints: not a simple pair

            const base = std.fmt.parseInt(u21, base_str, 16) catch continue;
            const combiner = std.fmt.parseInt(u21, combiner_str, 16) catch continue;

            // Non-starter decomposition: base has CCC > 0 → excluded from composition.
            if (ccc_map.contains(base)) continue;

            // Explicit composition exclusions (CompositionExclusions.txt, Unicode 15.1).
            if (isExclusion(composed)) continue;

            try triples.append(init.gpa, .{ .base = base, .combiner = combiner, .composed = composed });
        }
    }

    // Sort by (base, combiner) so the generated table supports binary search.
    std.mem.sort(Triple, triples.items, {}, struct {
        fn lt(_: void, a: Triple, b: Triple) bool {
            if (a.base != b.base) return a.base < b.base;
            return a.combiner < b.combiner;
        }
    }.lt);

    // Emit the Zig source file.
    var stdout_buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &stdout_buf);
    defer _ = writer.flush() catch {};

    try writer.interface.writeAll(
        \\//! Generated by tools/gen_nfc_table.zig; DO NOT EDIT.
        \\//!
        \\//! The data is derived from the Unicode Character Database (UCD).
        \\//! See THIRD_PARTY_NOTICES/unicode.license.txt for the applicable
        \\//! Unicode license terms.
        \\//!
        \\//! Data sources:
        \\//!  https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt
        \\//!  https://www.unicode.org/Public/17.0.0/ucd/CompositionExclusions.txt
        \\//!
        \\//! Regenerate with: zig build gen-nfc
        \\//!
        \\//! Each entry packs three 21-bit code points into a `u64`:
        \\//!
        \\//! - bits [62,42] = base (starter code point)
        \\//! - bits [41,21] = combiner (combining code point)
        \\//! - bits [20,0]  = composed (NFC result)
        \\//!
        \\//! Entries are sorted by (base, combiner) for O(log n) binary search.
        \\//! Bit 63 is unused.
        \\
        \\
    );

    try writer.interface.print(
        \\ pub const entries: [{}]u64 = .{{
        \\
    , .{triples.items.len});
    for (triples.items) |t| {
        const entry: u64 = (@as(u64, t.base) << 42) |
            (@as(u64, t.combiner) << 21) |
            @as(u64, t.composed);
        try writer.interface.print(
            "    0x{X:0>16}, // U+{X:0>4} + U+{X:0>4} → U+{X:0>4}\n",
            .{ entry, t.base, t.combiner, t.composed },
        );
    }
    try writer.interface.writeAll("};\n");
    try writer.interface.writeAll(
        \\  
        \\/// Returns the NFC canonical composition of (base, combiner), or null.  
        \\/// O(log n) binary search over the sorted entries table.  
        \\pub fn compose(base: u32, combiner: u32) ?u21 {  
        \\    const key: u64 = (@as(u64, base) << 42) | (@as(u64, combiner) << 21);  
        \\    var lo: usize = 0;  
        \\    var hi: usize = entries.len;  
        \\    while (lo < hi) {  
        \\        const mid = lo + (hi - lo) / 2;  
        \\        const entry     = entries[mid];  
        \\        const entry_key = entry & 0xFFFFFFFFFFE00000; // zero out composed bits  
        \\        if (entry_key < key) {  
        \\            lo = mid + 1;  
        \\        } else if (entry_key > key) {  
        \\            hi = mid;  
        \\        } else {  
        \\            return @intCast(entry & 0x1FFFFF);  
        \\        }  
        \\    }  
        \\    return null;  
        \\}  
    );
}

/// Explicit composition exclusions from Unicode's CompositionExclusions.txt (Unicode 17.0.0).
///
/// These code points are excluded from NFC composition in order to preserve
/// Unicode normalization stability guarantees.
fn isExclusion(cp: u21) bool {
    return switch (cp) {
        // Script-specific exclusions (Devanagari, Bengali, Gurmukhi, Oriya, Tibetan)
        0x0958...0x095F,
        0x09DC,
        0x09DD,
        0x09DF,
        0x0A33,
        0x0A36,
        0x0A59...0x0A5B,
        0x0A5E,
        0x0B5C,
        0x0B5D,
        0x0F43,
        0x0F4D,
        0x0F52,
        0x0F57,
        0x0F5C,
        0x0F69,
        0x0F73,
        0x0F75,
        0x0F76,
        0x0F78,
        0x0F81,
        0x0F82,
        0x0F83,
        0x0F93,
        0x0F9D,
        0x0FA2,
        0x0FA7,
        0x0FAC,
        0x0FB9,
        // Hebrew presentation forms
        0xFB1D,
        0xFB1F,
        0xFB2A...0xFB36,
        0xFB38...0xFB3C,
        0xFB3E,
        0xFB40,
        0xFB41,
        0xFB43,
        0xFB44,
        0xFB46...0xFB4E,
        // Post-composition version issues (Unicode 1.1.5)
        0x2ADC,
        // Musical symbols
        0x1D15E...0x1D164,
        0x1D1BB...0x1D1C0,
        => true,
        else => false,
    };
}
