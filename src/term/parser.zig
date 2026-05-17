const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.parser);
const SgrOp = @import("actions.zig").SgrOp;
const Control = @import("actions.zig").Control;
pub const Osc = @import("osc.zig");
const Utf8Dfa = @import("unicode.zig").Utf8Dfa;

test {
    std.testing.refAllDecls(@This());
    _ = @import("si_test.zig");
}

/// In CSI sequences, 65535 is not a valid parameter anyway
/// (the spec generally allows 0 up to 65534)
/// if the input parameter is "65535" which will treat as "parameter not specified".
const no_value = 0xffff;

// Definitions
// Many controls use parameters, shown in italics.  If a control uses a
// single parameter, only one parameter name is listed.  Some parameters
// (along with separating ;  characters) may be optional.  Other characters
// in the control are required.
//
// C    A single (required) character.
// Ps   A single (usually optional) numeric parameter, composed of one or
//      more digits.
// Pm   Any number of single numeric parameters, separated by ;
//      character(s).  Individual values for the parameters are listed with
//      Ps .
// Pt   A text parameter composed of printable characters.
//
// see details (3. Device Control functions)[https://invisible island.net/xterm/ctlseqs/ctlseqs.html#h3 Device Control functions].

pub const Transition = enum { complete, next, abort };

/// Maximum number of parameter values supported.
pub const max_values: usize = 32;

/// Maximum number of intermediate values supported.
pub const max_intermediates = 4;

/// Packed separator token used by the parser.
pub const Separator = enum(u2) {
    /// Final parameter in the sequence.
    end = 0,

    /// Continue parsing sub-parameters.
    colon = 1,

    /// Advance to the next parameter.
    semicolon = 2,

    /// padding to cover all u2 values
    /// need to prove its actualy full coverage
    invalid = 3,
};

comptime {
    const info = @typeInfo(Separator);
    if (info != .@"enum") {
        @compileError("Separator must be an enum.");
    }

    const tag_type = info.@"enum".tag_type;
    if (@typeInfo(tag_type).int.signedness != .unsigned) {
        @compileError("Separator enum must use unsigned tag type");
    }

    const max = std.math.maxInt(std.meta.Tag(Separator));
    var i: usize = 0;
    while (i <= max) : (i += 1) {
        _ = std.enums.fromInt(Separator, i) orelse {
            @compileError("Separator does not cover all values of its backing integer");
        };
    }
}

/// Fixed-size bit-packed array of `Separator` values.
///
/// It stores exactly `n` separators using a tightly bit-packed representation,
/// with each `Separator` occupying `@bitSizeOf(Separator)` bits inside a single
/// unsigned integer.
///
/// To read or written an element use method `get` or `set`,
/// which perform bit shifting and masking into the underlying storage.
///
/// NOTE
/// * The underlying integer type is automatically
///   selected to fit `n * @bitSizeOf(Separator)` bits.
/// * Out-of-bounds access is asserted in debug builds.
pub fn SeparatorPacked(comptime n: usize) type {
    const bits_per = @bitSizeOf(Separator);
    const size = n * bits_per;

    comptime {
        if (n == 0) {
            @compileError("SeparatorPacked requires n > 0.");
        }

        if (size > 65535) {
            @compileError("Packed size too large");
        }
    }

    const Storage = std.meta.Int(.unsigned, size);
    const ShiftInt = std.math.Log2Int(Storage);
    const SeparatorMask: Storage = (1 << bits_per) - 1;

    return struct {
        const Self = @This();
        pub const capacity = n;
        pub const empty: Self = .{ .bits = 0 };

        /// The bit mask, as a single integer
        bits: Storage,

        /// Read separator at index
        pub inline fn get(self: Self, index: usize) Separator {
            std.debug.assert(index < n);

            const raw: u2 = @truncate(self.bits >> @intCast(index * bits_per));
            return @enumFromInt(raw);
        }

        /// Write separator at index
        pub inline fn set(self: *Self, index: usize, value: Separator) void {
            std.debug.assert(index < n);

            const shift: ShiftInt = @intCast(index * bits_per);
            self.bits &= ~(SeparatorMask << shift);
            self.bits |= @as(Storage, @intFromEnum(value)) << shift;
        }
    };
}

const PrivateMarker = enum(u3) {
    none,
    lt,
    eq,
    gt,
    question,
};

/// Sequence Introducer: `Introducer P...P I...I F`
///
/// Parameter values are capped at no_value - 1 (65534).
/// 65535 is reserved as the no_value sentinel.
pub fn Csi(comptime max_value: usize) type {
    const ValueCount = std.math.IntFittingRange(0, max_value);

    // NOTE (dapa)
    // In real terminal sequences, no standard escape sequence uses
    // 65535 (0xFFFF) as a parameter value. THe highest commonly used
    // values are things like 256 (color indices) or a few thousand
    // (window size). So the sentinel collision is a theoretical
    // correctness bug that won't affect real-world usage.

    // then why not set current and valuus as optional?
    // `?u16` in Zig is stored as u16 + u1 (bool) + padding = 4 bytes per slot
    // instead of 2. For SI(16), values grows from 32 to 64 bytes.

    // other alternative: using empty_bits: std.meta.Int(.unsigned, max_value) = 0,
    // One bit per slot: 1 = slot is empty (no digit entered), 0 = has explicit value
    // For SI(16), empty_bits is u16 (2 bytes) much cheaper than ?u16 per slot.
    // But it adds complexity to pushValue and value().

    // so, yet this is a real design conflict. no_value = 0xFFFF is used as a sentinel
    // for "no digit entered yet", but at the same time '65535' is also a valid u16 parameter value.
    // It's not correct behavior for now, it's a sentinel collision.
    // The parser correctly parses 65535 into current, but pushValue stores it as no_value, and value() then treats it as "empty parameter".

    return struct {
        final: u8,
        current: u16,
        private_marker: PrivateMarker,
        separators: SeparatorPacked(max_value),
        state: enum(u2) { params, intermediates, ignore },

        values: [max_value]u16,
        intermediates: [max_intermediates]u8,

        intermediate_count: u4,
        value_count: ValueCount,

        const Self = @This();
        pub const capacity = max_value;

        pub const default: Self = .{
            .final = 0,
            .state = .params,
            .current = no_value,
            .separators = .empty,
            .private_marker = .none,

            .value_count = 0,
            .intermediate_count = 0,

            .values = undefined,
            .intermediates = undefined,
        };

        pub fn feed(self: *Self, byte: u8) Transition {
            return switch (self.state) {
                .ignore => switch (byte) {
                    // consume all bytes until final, then signal abort (malformed)
                    0x40...0x7E => .abort, // caller shold not dispatch any
                    else => .next,
                },
                .params => switch (byte) {
                    '<', '=', '>', '?' => blk: {
                        // a private marker is only meaningful as the first byte
                        // of the parameter string. A sequence like `CSI 1 ? m`
                        // will overwrite `private_marker` after `1` has already
                        // been parsed. so need to guard this!
                        if (self.value_count == 0 and self.current == no_value) {
                            self.private_marker = @enumFromInt(byte - 0x3B);
                            break :blk .next;
                        }

                        self.state = .ignore;
                        break :blk .next;
                    },

                    '0'...'9' => blk: {
                        const digit: u16 = byte - '0';

                        if (self.current == no_value) {
                            self.current = digit;
                            break :blk .next;
                        }

                        const temp = (@as(u32, self.current) * 10) + digit;
                        // set a sentinel collision current to ignore
                        if (temp >= 0xFFFF) {
                            self.state = .ignore;
                            break :blk .next;
                        }

                        self.current = @truncate(temp);
                        break :blk .next;
                    },

                    ';' => blk: {
                        self.pushValue(.semicolon);
                        break :blk .next;
                    },

                    ':' => blk: {
                        self.pushValue(.colon);
                        break :blk .next;
                    },

                    0x20...0x2F => blk: {
                        self.state = .intermediates;
                        self.pushIntermediate(byte);
                        break :blk .next;
                    },

                    0x40...0x7E => blk: {
                        self.finish(byte);
                        // break :blk .complete;
                        break :blk if (self.state == .ignore) Transition.abort else Transition.complete;
                    },

                    0x7F => .next,
                    else => .abort,
                },

                .intermediates => switch (byte) {
                    0x20...0x2F => blk: {
                        self.pushIntermediate(byte);
                        break :blk .next;
                    },

                    0x30...0x3F => blk: {
                        self.state = .ignore;
                        break :blk .next;
                    },

                    0x40...0x7E => blk: {
                        self.finish(byte);
                        break :blk if (self.state == .ignore) Transition.abort else Transition.complete;
                    },

                    0x7F => .next,

                    else => .abort,
                },
            };
        }

        pub fn reset(self: *Self) void {
            self.final = 0;
            self.state = .params;
            self.current = no_value;

            self.separators = .empty;
            self.private_marker = .none;

            self.value_count = 0;
            self.intermediate_count = 0;
        }

        fn pushIntermediate(self: *Self, byte: u8) void {
            if (self.intermediate_count < self.intermediates.len) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            } else {
                self.state = .ignore;
            }
        }

        fn pushValue(self: *Self, separator: Separator) void {
            if (self.value_count < self.values.len) {
                self.separators.set(self.value_count, separator);

                self.values[self.value_count] = self.current;
                self.value_count += 1;
                self.current = no_value;
            } else {
                self.state = .ignore;
            }
        }

        fn finish(self: *Self, byte: u8) void {
            self.final = byte;

            // store trailing parameter
            if (self.current != no_value or self.value_count > 0) {
                self.pushValue(.end);
            }
        }

        pub fn value(self: *const Self, index: usize, fallback: u16) u16 {
            if (index >= self.value_count) return fallback;
            const v = self.values[index];
            return if (v == no_value) fallback else v;
        }

        pub fn intermediate(self: *const Self, index: u4) u8 {
            if (index >= self.intermediates.len) return 0;
            return self.intermediates[index];
        }
    };
}

                0x40...0x7E => blk: {
                    self.finish(byte);
                    break :blk .complete;
                },

                else => .abort,
            },

            .intermediates => switch (byte) {
                0x20...0x2F => blk: {
                    self.pushIntermediate(byte);
                    break :blk .next;
                },
                0x40...0x7E => blk: {
                    self.finish(byte);
                    break :blk .complete;
                },
                else => .abort,
            },
        };
    }

    pub fn reset(self: *Csi) void {
        self.final = 0;
        self.state = .params;
        self.param_count = 0;
        self.current = no_param;
        self.private_marker = .none;
        self.intermediate_count = 0;
    }

    fn pushIntermediate(self: *Csi, byte: u8) void {
        if (self.intermediate_count < self.intermediates.len) {
            self.intermediates[self.intermediate_count] = byte;
            self.intermediate_count += 1;
        }
    }

    fn pushParam(self: *Csi) void {
        if (self.param_count < self.params.len) {
            // self.params[self.param_count] = if (self.current == no_param) 0 else self.current;
            self.params[self.param_count] = self.current;
            self.param_count += 1;

            self.current = no_param;
        }
    }

    fn finish(self: *Csi, byte: u8) void {
        self.final = byte;

        // store trailing parameter
        if (self.current != no_param or self.param_count > 0) {
            self.pushParam();
        }
    }

    pub fn param(self: *const Csi, idx: usize, default: u16) u16 {
        if (idx >= self.param_count) return default;
        const value = self.params[idx];
        return if (value == no_param) default else value;
    }

    pub fn intermediateBySpace(self: *const Csi) bool {
        return self.intermediate_count >= 1 and self.intermediates[0] == ' ';
    }

    pub fn dispatch(self: *const Csi) Action {
        return switch (self.final) {
            '@' => blk: {
                const ps = self.param(0, 1);
                // [CSI Ps SP @]
                // Shift left Ps columns(s) (default = 1) (SL), ECMA-48.
                if (self.intermediateBySpace()) {
                    break :blk .{ .shift = .{ .direction = .left, .n = ps } };
                }

                // CSI Ps @
                // Insert Ps (Blank) Character(s) (default = 1) (ICH).
                break :blk .{ .padding_character = ps };
            },

            'A' => blk: {
                const ps = self.param(0, 1);

                // CSI Ps SP A
                // Shift right Ps columns(s) (default = 1) (SR), ECMA-48.
                if (self.intermediateBySpace()) {
                    break :blk .{ .shift = .{ .direction = .right, .n = ps } };
                }

                // CSI Ps A
                // Cursor Up Ps Times (default = 1) (CUU).
                break :blk .{ .cursor_rel = .{ .direction = .up, .n = ps } };
            },

            'B' => .{ .cursor_rel = .{ .direction = .down, .n = self.param(0, 1) } },
            'C' => .{ .cursor_rel = .{ .direction = .right, .n = self.param(0, 1) } },
            'D' => .{ .cursor_rel = .{ .direction = .left, .n = self.param(0, 1) } },
            'E' => .{ .cursor_next_line = self.param(0, 1) },
            'F' => .{ .cursor_previous_line = self.param(0, 1) },
            'G' => .{ .cursor_horizontal_abs = self.param(0, 1) },
            'H', 'f' => .{ // CUP/HVP
                // CSI Ps I
                // Cursor Forward Tabulation Ps tab stops (default = 1) (CHT).
                .cursor_abs = .{ .row = self.param(0, 1), .col = self.param(1, 1) },
            },
            'J' => .{ .erase_display = @enumFromInt(self.param(0, 0)) },
            'K' => .{ .erase_line = @enumFromInt(self.param(0, 0)) },
            'R' => .{ .cursor_abs = .{ .row = self.param(0, 0), .col = self.param(0, 0) } },

            // CSI Ps S
            // Scroll up Ps lines (default = 1) (SU), VT420, ECMA-48.
            'S' => .{ .scroll_rel = .{ .direction = .up, .n = self.param(0, 1) } },

            // CSI Ps T
            //      Scroll down Ps lines (default = 1) (SD), VT420.
            // CSI Ps ^
            //      Scroll down Ps lines (default = 1) (SD), ECMA-48.
            'T', '^' => blk: {
                // DEC/xterm private mode
                if (self.private_marker == .gt) {
                    break :blk .{ .xtrmtitle_reset = self.params[0..self.param_count] };
                }

                // XTHIMOUSE
                // Parameters are [func;startx;starty;firstrow;lastrow].
                // See the section [Mouse Tracking](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-Mouse-Tracking).
                if (self.param_count >= 5) {
                    break :blk .{
                        .xthimouse = .{
                            .func = self.param(0, 0),
                            .start_x = self.param(1, 0),
                            .start_y = self.param(2, 0),
                            .fisrt_row = self.param(3, 0),
                            .last_row = self.param(4, 0),
                        },
                    };
                }

                break :blk .{ .scroll_rel = .{ .direction = .down, .n = self.param(0, 1) } };
            },

            'm' => .{ .sgr = Sgr.decode(self.params[0..self.param_count]) },
            // CSI 5i | AUX Port On | Enable aux serial port usually for local serial printer
            // CSI 4i | AUX Port Off | Disable aux serial port usually for local serial printer
            else => .{ .ignored = {} }, // ignored
        };
    }
};

test "CSI: default actions" {
    var csi: Csi = .empty;

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .padding_character = 1 },
            csi.finish(0x40), // PAD
        );
    }

    {
        defer csi = .empty;
        csi.pushIntermediate(' ');
        try std.testing.expectEqualDeep(
            Action{ .shift = .{ .direction = .left, .n = 1 } },
            csi.finish(0x40), // Shift left Ps
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_rel = .{ .n = 1, .direction = .up } },
            csi.finish(0x41), // CUU
        );
    }

    {
        defer csi = .empty;
        csi.pushIntermediate(' ');
        try std.testing.expectEqualDeep(
            Action{ .shift = .{ .direction = .right, .n = 1 } },
            csi.finish(0x41), // Shift right Ps
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_rel = .{ .n = 1, .direction = .down } },
            csi.finish(0x42), // CUD
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_rel = .{ .n = 1, .direction = .right } },
            csi.finish(0x43), // CUF
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_rel = .{ .n = 1, .direction = .left } },
            csi.finish(0x44), // CUB
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_next_line = 1 },
            csi.finish(0x45), // CNL
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_previous_line = 1 },
            csi.finish(0x46), // CPL
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_horizontal_abs = 1 },
            csi.finish(0x47), // CHA

        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .erase_display = .to_end },
            csi.finish(0x4A), // ED
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .erase_line = .to_end },
            csi.finish(0x4B), // EL
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .scroll_rel = .{ .direction = .up, .n = 1 } },
            csi.finish(0x53), // SU
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .scroll_rel = .{ .direction = .down, .n = 1 } },
            csi.finish(0x54), // SD ('T') not ansi.system
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .scroll_rel = .{ .direction = .down, .n = 1 } },
            csi.finish(0x5E), // SD ('^') ECMA-48
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_abs = .{ .row = 0, .col = 0 } },
            csi.finish(0x52), // CPR
        );
    }
}

test "CSI: sgr" {
    var csi: Csi = .empty;
    var sgr: Sgr = undefined;

    // reset
    {
        defer csi = .empty;
        csi.current = 0;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp.reset, sgr.ops[0]);
    }

    // bold
    {
        defer csi = .empty;
        csi.current = 1;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .bold = true }, sgr.ops[0]);
    }

    // !bold
    {
        defer csi = .empty;
        csi.current = 22;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .bold = false }, sgr.ops[0]);
    }

    // dim
    {
        defer csi = .empty;
        csi.current = 2;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .dim = true }, sgr.ops[0]);
    }

    // italic
    {
        defer csi = .empty;
        csi.current = 3;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .italic = true }, sgr.ops[0]);
    }

    // !italic
    {
        defer csi = .empty;
        csi.current = 23;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .italic = false }, sgr.ops[0]);
    }

    // underline
    {
        defer csi = .empty;
        csi.current = 4;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .underline = true }, sgr.ops[0]);
    }

    // !underline
    {
        defer csi = .empty;
        csi.current = 24;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .underline = false }, sgr.ops[0]);
    }

    // blink
    {
        defer csi = .empty;
        csi.current = 5;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .blink = true }, sgr.ops[0]);
    }

    // !blink
    {
        defer csi = .empty;
        csi.current = 25;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .blink = false }, sgr.ops[0]);
    }

    // reverse
    {
        defer csi = .empty;
        csi.current = 7;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .reverse = true }, sgr.ops[0]);
    }

    // !reverse
    {
        defer csi = .empty;
        csi.current = 27;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .reverse = false }, sgr.ops[0]);
    }

    // hidden
    {
        defer csi = .empty;
        csi.current = 8;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .hidden = true }, sgr.ops[0]);
    }

    // !hidden
    {
        defer csi = .empty;
        csi.current = 28;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .hidden = false }, sgr.ops[0]);
    }

    // strikethrough
    {
        defer csi = .empty;
        csi.current = 9;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .strikethrough = true }, sgr.ops[0]);
    }

    // !strikethrough
    {
        defer csi = .empty;
        csi.current = 29;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .strikethrough = false }, sgr.ops[0]);
    }

    // Default foreground color
    {
        defer csi = .empty;
        csi.current = 39;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .fg = .default }, sgr.ops[0]);
    }

    // Default background color
    {
        defer csi = .empty;
        csi.current = 49;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .bg = .default }, sgr.ops[0]);
    }

    // 4-bit Colors

    // fg solid
    for (30..37) |v| {
        const expected: u4 = @intCast(v - 30);
        {
            defer csi = .empty;
            csi.current = @intCast(v);
            sgr = csi.finish(0x6D).sgr;
            try std.testing.expectEqual(1, sgr.len);
            try std.testing.expectEqual(SgrOp{ .fg = .{ .ansi = expected } }, sgr.ops[0]);
        }
    }

    // fg bright
    for (90..97) |v| {
        const expected: u4 = @intCast(v - 90 + 8);
        {
            defer csi = .empty;
            csi.current = @intCast(v);
            sgr = csi.finish(0x6D).sgr;
            try std.testing.expectEqual(1, sgr.len);
            try std.testing.expectEqual(SgrOp{ .fg = .{ .ansi = expected } }, sgr.ops[0]);
        }
    }

    // bg solid
    for (40..47) |v| {
        const expected: u4 = @intCast(v - 40);
        {
            defer csi = .empty;
            csi.current = @intCast(v);
            sgr = csi.finish(0x6D).sgr;
            try std.testing.expectEqual(1, sgr.len);
            try std.testing.expectEqual(SgrOp{ .bg = .{ .ansi = expected } }, sgr.ops[0]);
        }
    }

    // bg bright
    for (100..107) |v| {
        const expected: u4 = @intCast(v - 100 + 8);
        {
            defer csi = .empty;
            csi.current = @intCast(v);
            sgr = csi.finish(0x6D).sgr;
            try std.testing.expectEqual(1, sgr.len);
            try std.testing.expectEqual(SgrOp{ .bg = .{ .ansi = expected } }, sgr.ops[0]);
        }
    }

    // 8-bits color

    // indexed foreground color
    {
        defer csi = .empty;
        csi.params[0] = 38;
        csi.params[1] = 5;
        csi.current = 123;
        csi.param_count = 2;

        sgr = csi.finish('m').sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqualDeep(
            SgrOp{ .fg = .{ .indexed = 123 } },
            sgr.ops[0],
        );
    }

    // indexed background color
    {
        defer csi = .empty;
        csi.params[0] = 48;
        csi.params[1] = 5;
        csi.current = 200;
        csi.param_count = 2;

        sgr = csi.finish('m').sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqualDeep(
            SgrOp{ .bg = .{ .indexed = 200 } },
            sgr.ops[0],
        );
    }

    // rgb foreground color
    {
        defer csi = .empty;
        csi.params[0] = 38;
        csi.params[1] = 2;
        csi.params[2] = 255;
        csi.params[3] = 255;
        csi.current = 255;
        csi.param_count = 4;

        sgr = csi.finish('m').sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqualDeep(
            SgrOp{ .fg = .{ .rgb = .{ .b = 255, .r = 255, .g = 255 } } },
            sgr.ops[0],
        );
    }

    // rgb background color
    {
        defer csi = .empty;
        csi.params[0] = 48;
        csi.params[1] = 2;
        csi.params[2] = 32;
        csi.params[3] = 32;
        csi.current = 32;
        csi.param_count = 4;

        sgr = csi.finish('m').sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqualDeep(
            SgrOp{ .bg = .{ .rgb = .{ .b = 32, .r = 32, .g = 32 } } },
            sgr.ops[0],
        );
    }
}
