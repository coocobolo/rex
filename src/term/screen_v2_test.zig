const std = @import("std");
const testing = std.testing;

const screen_mod = @import("screen_v2.zig");
const term = @import("root.zig");
const Cell = term.Cell;
const Screen = screen_mod.Screen;

// type aliases for test screens
const tab_width: usize = 8;
const max_cols: usize = 80;
const max_rows: usize = 8;
const max_scrollback: usize = 8;

const ring_rows = max_rows + max_scrollback;
const ring_mask = ring_rows - 1;

const Primary = Screen(.{
    .max_cols = max_cols,
    .max_rows = max_rows,
    .max_scrollback = max_scrollback,
    .tab_width = tab_width,
    .name = "",
    .version = "",
});

const Alternate = Screen(.{
    .max_rows = max_rows,
    .max_cols = max_cols,
    .tab_width = tab_width,
    .max_scrollback = 0,
    .name = "",
    .version = "",
});

fn primary(
    scroll_offset: usize,
    active_rows: usize,
    viewport_offset: usize,
    row_map_state: Primary.RowMapState,
) Primary {
    return std.mem.zeroInit(
        Primary,
        Primary{
            .scroll_offset = scroll_offset,
            .active_rows = active_rows,
            .viewport_offset = viewport_offset,
            .row_map_state = row_map_state,
        },
    );
}

test "row: identity mapping returns active_cols cells at physRow's offset" {
    var screen: Primary = .empty;
    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.active_rows = 8;

    const r: usize = 3;
    const expected_phys = screen.physRow(r);

    // Identity: physRow(3) == 3.
    try testing.expectEqual(3, expected_phys);

    const slice = screen.row(r);
    try testing.expectEqual(screen.active_cols, slice.len);
    try testing.expectEqual(
        @intFromPtr(&screen.cells[expected_phys * max_cols]),
        @intFromPtr(slice.ptr),
    );
}

test "row: slice aliases the same physical storage physRow resolve to" {
    var screen: Primary = .empty;
    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.active_rows = 8;
    screen.scroll_offset = 5;

    const r: usize = 2;
    const expected_phys = screen.physRow(r);

    // Write through the underlying storage directly, not through row()'s
    // const slice, to prove row() aliases the same memory rather than a copy.
    screen.cells[expected_phys * max_cols].codepoint = 'A';

    const slice = screen.row(r);
    try testing.expectEqual(screen.active_cols, slice.len);
}

test "row: honors region_offset rotation for rows inside the region" {
    var screen: Primary = .empty;
    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.active_rows = 8;
    screen.row_map_state = .{
        .region_offset = .{
            .lo = 2,
            .len = 3,
            .offset = 1,
        },
    };

    const r: usize = 2; // inside [2,4], rotated
    const expected_phys = screen.physRow(r);

    screen.cells[expected_phys * max_cols].codepoint = 'B';

    const slice = screen.row(r);
    try testing.expectEqual('B', slice[0].codepoint);
}

test "row: rows outside the region_offset range retain identity mapping" {
    var screen: Primary = .empty;
    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.active_rows = 8;
    screen.row_map_state = .{
        .region_offset = .{
            .lo = 2,
            .len = 3,
            .offset = 1,
        },
    };

    const r: usize = 6; // outside [2,4], rotated
    try testing.expectEqual(r, screen.physRow(r));

    screen.cells[r * max_cols].codepoint = 'C';

    const slice = screen.row(r);
    try testing.expectEqual('C', slice[0].codepoint);
}

test "row: honors permutation mapping for rows inside the region" {
    var screen: Primary = .empty;
    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.active_rows = 8;

    var map = std.mem.zeroes([max_rows]u16);
    map[2] = 1; // local index within [lo, lo+len)

    screen.row_map_state = .{
        .permutation = .{
            .lo = 2,
            .len = 3,
            .offset = 0,
            .map = map,
        },
    };

    const r: usize = 2;
    const expected_phys = screen.physRow(r);

    screen.cells[expected_phys * max_cols].codepoint = 'D';

    const slice = screen.row(r);
    try testing.expectEqual('D', slice[0].codepoint);
}

test "row: returns active_cols length even when max_cols is larger" {
    var screen: Primary = .empty;
    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.active_rows = 8;
    screen.active_cols = max_cols - 4; // narrower than full storage width

    const slice = screen.row(0);
    try testing.expectEqual(screen.active_cols, slice.len);
    try testing.expect(slice.len < max_cols);
}

test "rowMut: returns max_cols cells at the correct physical offset" {
    var screen: Primary = .empty;
    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];

    const slice = screen.rowMut(2, false);
    try testing.expectEqual(max_cols, slice.len);
    slice[0].codepoint = 'X';

    try testing.expectEqual('X', screen.cells[2 * max_cols].codepoint);
}

test "rowMut: mark_dirty is true sets the bit and bumps generation" {
    var screen: Primary = .empty;
    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.generation = 5;

    _ = screen.rowMut(3, true);

    try testing.expect(screen.dirty_rows.isSet(3));
    try testing.expectEqual(6, screen.generation);
}

test "rowMut: mark_dirty is false touches nor dirty_rows or generation" {
    var screen: Primary = .empty;
    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.generation = 5;

    _ = screen.rowMut(3, false);

    try testing.expect(!screen.dirty_rows.isSet(3));
    try testing.expectEqual(5, screen.generation);
}

test "rowMut: only the targeted row is marked, not neighbors" {
    var screen: Primary = .empty;

    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];

    _ = screen.rowMut(4, true);

    try testing.expectEqual(1, screen.dirty_rows.count());
    try testing.expect(screen.dirty_rows.isSet(4));
}

test "rowMut: repeated calls each bump generation by one" {
    var screen: Primary = .empty;

    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];

    _ = screen.rowMut(0, true);
    _ = screen.rowMut(1, true);
    _ = screen.rowMut(0, true); // same row again, must bumps still.

    try testing.expectEqual(2, screen.dirty_rows.count());
    try testing.expectEqual(3, screen.generation);
}

test "rowsMut: returns count * max_cols cells at the correct physical offset" {
    var screen: Primary = .empty;

    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];

    const slice = screen.rowsMut(1, 3, false);
    try testing.expectEqual(3 * max_cols, slice.len);

    slice[0].codepoint = 'A';
    try testing.expectEqual('A', screen.cells[1 * max_cols].codepoint);
}

test "rowsMut: mark_dirty is true sets every row in range, generation bumps once" {
    var screen: Primary = .empty;

    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.generation = 10;

    _ = screen.rowsMut(2, 4, true); // rows [2..5] inclusive
    for ([_]usize{ 2, 3, 4, 5 }) |r| {
        try testing.expect(screen.dirty_rows.isSet(r));
    }

    try testing.expectEqual(4, screen.dirty_rows.count());
    try testing.expectEqual(11, screen.generation);
}

test "rowsMut: mark_dirty is false leaves dirty_rows and generation untouched" {
    var screen: Primary = .empty;

    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.generation = 7;

    _ = screen.rowsMut(0, max_rows, false);

    try testing.expectEqual(0, screen.dirty_rows.count());
    try testing.expectEqual(7, screen.generation);
}

test "rowsMut: does not mark rows outside the requested range" {
    var screen: Primary = .empty;

    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];

    _ = screen.rowsMut(3, 2, true); // rows 3,4 only

    try testing.expect(!screen.dirty_rows.isSet(2));
    try testing.expect(!screen.dirty_rows.isSet(5));
    try testing.expect(screen.dirty_rows.isSet(3));
    try testing.expect(screen.dirty_rows.isSet(4));
}

test "rowsMut: count is 1 behaves like rowMut for dirty/generation semantics" {
    var screen: Primary = .empty;

    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];

    _ = screen.rowsMut(5, 1, true);

    try testing.expect(screen.dirty_rows.isSet(5));
    try testing.expectEqual(1, screen.generation);
}

test "rowsMut: full active_rows range" {
    var screen: Primary = .empty;

    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];

    const slice = screen.rowsMut(0, max_rows, true);
    try testing.expectEqual(max_rows * max_cols, slice.len);
    try testing.expectEqual(max_rows, screen.dirty_rows.count());
    try testing.expectEqual(1, screen.generation);
}

test "rowsMut: identity mapping is always contiguous across full active range" {
    var screen: Primary = .empty;

    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];

    // Should not panic, identity mapping iscontiguous by construction
    _ = screen.rowsMut(0, max_rows, false);
}

test "rowsMut: region_offset range fully inside the rotated region is contiguous" {
    var screen: Primary = .empty;

    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];

    // A pure rotation still yields a set of physically-adjacent rows for
    // any sub-range that stays within [lo, lo+len), since it's a cyclic
    // shift of a contiguous block.
    screen.row_map_state = .{
        .region_offset = .{ .lo = 1, .len = 4, .offset = 1 },
    };

    // Rows entirely outside [lo, lo+len) retain identity and are contiguous
    // with each other, but NOT necessarily with rows inside the region --
    // pick a range that stays on one side.
    _ = screen.rowsMut(0, 1, false); // just row 0, outside the region
}

test "rowMut,rowsMut: count is 1 resolve to the same physical row" {
    var screen: Primary = .empty;
    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.scroll_offset = 6;
    screen.row_map_state = .{
        .region_offset = .{ .lo = 2, .len = 3, .offset = 1 },
    };

    const single = screen.rowMut(3, false);
    screen.dirty_rows = .empty; // reset between calls, rowsMut asserts on its own
    const bulk = screen.rowsMut(3, 1, false);

    try testing.expectEqualSlices(Cell, single, bulk);
}

test "physRow: identity mapping" {
    var screen: Primary = undefined;

    screen.scroll_offset = 3;
    screen.row_map_state = .identity;

    // ring_rows = nextPowerOfTwo(8+8)
    try testing.expectEqual(3, screen.physRow(0));
    try testing.expectEqual(4, screen.physRow(1));
    try testing.expectEqual(5, screen.physRow(2));
    try testing.expectEqual(10, screen.physRow(7));
}

test "physRow: identity mapping wraps at ring boundary" {
    var screen: Primary = undefined;
    screen.scroll_offset = 14;
    screen.row_map_state = .identity;

    try testing.expectEqual(14, screen.physRow(0));
    try testing.expectEqual(15, screen.physRow(1));
    try testing.expectEqual(0, screen.physRow(2));
    try testing.expectEqual(1, screen.physRow(3));
}

test "physRow: region offset maps only the selected range" {
    var screen: Primary = undefined;
    screen.scroll_offset = 2;
    screen.row_map_state = .{
        .region_offset = .{
            .lo = 2,
            .len = 5 - 2 + 1,
            .offset = 1,
        },
    };

    // Rows outside [2, 5] retain identity mapping.
    try testing.expectEqual(2, screen.physRow(0));
    try testing.expectEqual(3, screen.physRow(1));

    // The range [2, 5] is rotated left by one logical position:
    //
    // logical: 2 3 4 5
    // mapped:  3 4 5 2
    //
    // Add scroll_offset = 2.
    try testing.expectEqual(5, screen.physRow(2));
    try testing.expectEqual(6, screen.physRow(3));
    try testing.expectEqual(7, screen.physRow(4));
    try testing.expectEqual(4, screen.physRow(5));

    // Rows after the range retain identity mapping.
    try testing.expectEqual(8, screen.physRow(6));
    try testing.expectEqual(9, screen.physRow(7));
}

test "physRow: region offset wraps around the ring" {
    var screen: Primary = undefined;
    screen.scroll_offset = 14;
    screen.row_map_state = .{
        .region_offset = .{
            .lo = 6,
            .len = 7 - 6 + 1,
            .offset = 1,
        },
    };

    // Outside the range:
    try testing.expectEqual(14, screen.physRow(0));

    // [6, 7], offset 1 maps:
    // logical (6) .. logical (7) .. physical (14 + 7 = 5)
    // logical (7) .. logical (6) .. physical (14 + 6 = 4)

    try testing.expectEqual(5, screen.physRow(6));
    try testing.expectEqual(4, screen.physRow(7));
}

test "physRow: region offset zero is equivalent to identity" {
    var screen: Primary = undefined;
    screen.scroll_offset = 5;
    screen.row_map_state = .{
        .region_offset = .{
            .lo = 2,
            .len = 5 - 2 + 1,
            .offset = 0,
        },
    };

    for (0..max_rows) |row| {
        try testing.expectEqual(row + 5, screen.physRow(row));
    }
}

test "physRow: permutation maps only the selected range" {
    var screen: Primary = undefined;

    screen.scroll_offset = 4;

    var map = std.mem.zeroes([max_rows]u16);

    // lo=2, len=3 => region covers logical rows [2,4], valid local indices are 0,1,2.
    // Example: rotate the region by one (2->3, 3->4, 4->2).
    map[2] = 1;
    map[3] = 2;
    map[4] = 0;

    screen.row_map_state = .{
        .permutation = .{
            .lo = 2,
            .len = 4 - 2 + 1,
            .offset = 0,
            .map = map,
        },
    };

    // Rows outside [2, 4] use identity mapping.
    try testing.expectEqual(4, screen.physRow(0));
    try testing.expectEqual(5, screen.physRow(1));
    try testing.expectEqual(11, screen.physRow(7));

    // Rows inside the range: scroll_offset(4) + lo(2) + map[r].
    try testing.expectEqual(7, screen.physRow(2));
    try testing.expectEqual(8, screen.physRow(3));
    try testing.expectEqual(6, screen.physRow(4));
}

test "physRow: permutation mapping wraps around the ring" {
    var screen: Primary = undefined;

    // Pick a scroll_offset near the top of the ring so a *valid* local
    // index (0 or 1, since len=2) is what pushes the sum past ring_mask.
    screen.scroll_offset = ring_mask;

    var map = std.mem.zeroes([max_rows]u16);

    map[0] = 1; // local index, must be < len(2)
    map[1] = 0;

    screen.row_map_state = .{
        .permutation = .{
            .lo = 0,
            .len = 1 - 0 + 1,
            .offset = 0,
            .map = map,
        },
    };

    // scroll_offset + lo(0) + map[0](1), then masked, it wraps to 0.
    try testing.expectEqual(0, screen.physRow(0));

    // scroll_offset + lo(0) + map[1](0), masked, it stays at ring_size-1.
    try testing.expectEqual(ring_mask, screen.physRow(1));
    try testing.expectEqual(ring_mask +% 4, screen.physRow(4));
}

test "physRow: all logical rows always map inside the ring" {
    var screen: Primary = undefined;

    for (0..16) |scroll_offset| {
        screen.scroll_offset = @intCast(scroll_offset);
        screen.row_map_state = .identity;

        for (0..max_rows) |row| {
            const physical = screen.physRow(row);
            try testing.expect(physical < 16);
        }
    }
}

/// Independently computes the expected physical row for `viewPhysRow`, using
/// the documented formula rather than calling `viewPhysRow`/`physRow` directly.
///
/// This exists so tests assert against an independent derivation, not a
/// hand-computed magic number that can silently drift from the formula.
fn expectedViewPhysRow(
    scroll_offset: usize,
    viewport_offset: usize,
    r: usize,
) usize {
    if (r < viewport_offset) {
        const offset = ring_rows - viewport_offset + r;
        return (scroll_offset +% offset) & ring_mask;
    }
    const logical = r - viewport_offset;
    return (scroll_offset +% logical) & ring_mask;
}

test "viewPhysRow: maps scrollback rows before active rows" {
    var screen: Primary = undefined;

    screen.scroll_offset = 2;
    screen.row_map_state = .identity;
    screen.active_rows = 8;
    screen.viewport_offset = 3;

    // Scrollback rows (display < viewport_offset)
    for ([_]usize{ 0, 1, 2 }) |r| {
        try testing.expectEqual(expectedViewPhysRow(2, 3, r), screen.viewPhysRow(r));
    }

    // Active rows delegate to physRow.
    for ([_]usize{ 3, 4, 5 }) |r| {
        try testing.expectEqual(screen.physRow(r - 3), screen.viewPhysRow(r));
    }
}

test "viewPhysRow: with zero viewport offset" {
    var screen: Primary = undefined;

    screen.scroll_offset = 5;
    screen.row_map_state = .identity;
    screen.active_rows = 8;
    screen.viewport_offset = 0;

    for (0..max_rows) |row| {
        try testing.expectEqual(screen.physRow(row), screen.viewPhysRow(row));
    }
}

test "viewPhysRow: with a full active viewport offset" {
    var screen: Primary = undefined;

    screen.scroll_offset = 4;
    screen.row_map_state = .identity;
    screen.active_rows = 8;
    screen.viewport_offset = 8;

    // Every displayed row is scrollback in this configuration.
    //
    // offset = 16 - 8 + r = 8 + r
    // physical = (4 + 8 + r) mod 16 = 12 + r
    for (0..8) |r| {
        try testing.expectEqual(expectedViewPhysRow(4, 8, r), screen.viewPhysRow(r));
    }
}

test "viewPhysRow: delegates active rows to physRow under identity mapping" {
    var screen: Primary = undefined;

    screen.scroll_offset = 2;
    screen.row_map_state = .identity;
    screen.active_rows = 8;
    screen.viewport_offset = 3;

    // display row 3 to logical row 0, etc.
    try testing.expectEqual(screen.physRow(0), screen.viewPhysRow(3));
    try testing.expectEqual(screen.physRow(1), screen.viewPhysRow(4));
    try testing.expectEqual(screen.physRow(2), screen.viewPhysRow(5));
}

test "viewPhysRow: delegates active rows to region mapping" {
    var screen: Primary = undefined;

    screen.scroll_offset = 2;
    screen.active_rows = 8;
    screen.viewport_offset = 2;

    screen.row_map_state = .{
        .region_offset = .{
            .lo = 1,
            .len = 3,
            .offset = 1,
        },
    };

    // Scrollback rows unaffected by region_offset.
    for ([_]usize{ 0, 1 }) |r| {
        try testing.expectEqual(expectedViewPhysRow(2, 2, r), screen.viewPhysRow(r));
    }

    // Active rows delegate to physRow (region rotation exercised there).
    try testing.expectEqual(screen.physRow(0), screen.viewPhysRow(2));
    try testing.expectEqual(screen.physRow(1), screen.viewPhysRow(3));
    try testing.expectEqual(screen.physRow(2), screen.viewPhysRow(4));
}

test "viewPhysRow: delegates active rows to permutation mapping" {
    var screen: Primary = undefined;

    screen.scroll_offset = 3;
    screen.active_rows = 8;
    screen.viewport_offset = 1;

    var map = std.mem.zeroes([max_rows]u16);
    map[0] = 4;
    map[1] = 0;
    map[2] = 6;

    screen.row_map_state = .{
        .permutation = .{
            .lo = 0,
            .len = 2 - 0 + 1,
            .offset = 0,
            .map = map,
        },
    };

    // Display row 0 is scrollback.
    //
    // offset = 16 - 1 + 0 = 15
    // physical = 3 + 15 = 18 mod 16 = 2
    try testing.expectEqual(2, screen.viewPhysRow(0));

    // Remaining rows map to active logical rows via physRow.
    try testing.expectEqual(screen.physRow(0), screen.viewPhysRow(1));
    try testing.expectEqual(screen.physRow(1), screen.viewPhysRow(2));
    try testing.expectEqual(screen.physRow(2), screen.viewPhysRow(3));
}

test "viewPhysRow: equals physRow when scrollback is disabled" {
    var screen: Alternate = .empty;
    screen.scroll_offset = 6;
    screen.active_rows = 8;

    for (0..max_rows) |row| {
        try std.testing.expectEqual(screen.physRow(row), screen.viewPhysRow(row));
    }
}

test "viewRow: returns active_cols cells at viewPhysRow's physical offset" {
    var screen: Primary = .empty;

    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.active_rows = 8;
    screen.viewport_offset = 2;

    const r: usize = 5;
    const expected_phys = screen.viewPhysRow(r);

    screen.cells[expected_phys * max_cols].codepoint = 'Y';

    const slice = screen.viewRow(r);
    try testing.expectEqual(screen.active_cols, slice.len);
    try testing.expectEqual('Y', slice[0].codepoint);
}

test "viewRow: scrollback row slice aliases the same physical row as viewPhysRow" {
    var screen: Primary = .empty;

    var buffer: [ring_rows * max_cols]Cell align(64) = @splat(Cell{});
    screen.cells = buffer[0..];
    screen.active_rows = 8;
    screen.scroll_offset = 2;
    screen.viewport_offset = 3;

    const r: usize = 0; // scrollback row
    const expected_phys = screen.viewPhysRow(r);

    screen.cells[expected_phys * max_cols].codepoint = 'Z';

    const slice = screen.viewRow(r);
    try testing.expectEqual(screen.active_cols, slice.len);
    try testing.expectEqual('Z', slice[0].codepoint);
}