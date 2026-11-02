const std = @import("std");
const testing = std.testing;

const parser = @import("parser.zig");
const Parser = parser.Parser;
const State = parser.State;
const Parameter = parser.Parameter;

const ParserOptions = parser.ParserOptions;
const opt: ParserOptions = .{};

const max_params = opt.max_params;
const max_intermediates = opt.max_intermediates;

const EscapeDispatch = struct {
    final: u8,
    intermediates: [max_intermediates]u8 = @splat(0),
    intermediate_len: u8,
};

const CsiDispatch = struct {
    final: u8,
    params: [max_params]Parameter = @splat(Parameter.default),
    param_len: u8,
    intermediates: [max_intermediates]u8 = @splat(0),
    intermediate_len: u8,
};

const DcsDispatch = struct {
    final: u8,
    params: [max_params]Parameter = @splat(Parameter.default),
    param_len: u8,
    intermediates: [max_intermediates]u8 = @splat(0),
    intermediate_len: u8,
};

pub const OscDispatch = struct {
    data: []const u8, // owned slice
};

pub const TestDispatcher = struct {
    const Self = @This();

    prints: std.ArrayList(u8),
    executes: std.ArrayList(u8),
    escapes: std.ArrayList(EscapeDispatch),
    csi_events: std.ArrayList(CsiDispatch),
    gpa: std.mem.Allocator,

    dcs_hooks: std.ArrayList(DcsDispatch),
    dcs_puts: std.ArrayList(u8),
    dcs_unhook_count: usize = 0,

    osc_buf: std.ArrayList(u8),
    osc_events: std.ArrayList(OscDispatch),

    pub fn init(gpa: std.mem.Allocator) !TestDispatcher {
        return .{
            .prints = try .initCapacity(gpa, 256),
            .executes = try .initCapacity(gpa, 16),
            .escapes = try .initCapacity(gpa, 16),
            .csi_events = try .initCapacity(gpa, 16),
            .dcs_hooks = try .initCapacity(gpa, 8),
            .dcs_puts = try .initCapacity(gpa, 256),
            .osc_events = try .initCapacity(gpa, 8),
            .osc_buf = try .initCapacity(gpa, 256),
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Self) void {
        self.prints.deinit(self.gpa);
        self.executes.deinit(self.gpa);
        self.escapes.deinit(self.gpa);
        self.csi_events.deinit(self.gpa);
        self.dcs_puts.deinit(self.gpa);
        self.dcs_hooks.deinit(self.gpa);

        for (self.osc_events.items) |*osc| self.gpa.free(osc.data);
        self.osc_buf.deinit(self.gpa);
        self.osc_events.deinit(self.gpa);
    }

    pub fn print(self: *Self, bytes: []const u8) void {
        self.prints.appendSlice(self.gpa, bytes) catch unreachable;
    }

    pub fn printByte(self: *Self, byte: u8) void {
        self.prints.append(self.gpa, byte) catch unreachable;
    }

    pub fn execute(self: *Self, b: u8) void {
        self.executes.append(self.gpa, b) catch unreachable;
    }

    pub fn escDispatch(self: *Self, final: u8, intermediates: []const u8) void {
        var ev: EscapeDispatch = .{
            .final = final,
            .intermediate_len = @truncate(intermediates.len),
        };

        @memcpy(ev.intermediates[0..intermediates.len], intermediates);
        self.escapes.append(self.gpa, ev) catch unreachable;
    }

    pub fn csiDispatch(self: *Self, final: u8, intermediates: []const u8, params: []const Parameter) void {
        var ev: CsiDispatch = .{
            .final = final,
            .param_len = @truncate(params.len),
            .intermediate_len = @truncate(intermediates.len),
        };

        @memcpy(ev.params[0..params.len], params);
        @memcpy(ev.intermediates[0..intermediates.len], intermediates);
        self.csi_events.append(self.gpa, ev) catch unreachable;
    }

    // DCS
    pub fn hook(self: *TestDispatcher, final: u8, intermediates: []const u8, params: []const Parameter) void {
        var ev: DcsDispatch = .{
            .final = final,
            .param_len = @truncate(params.len),
            .intermediate_len = @truncate(intermediates.len),
        };

        @memcpy(ev.params[0..params.len], params);
        @memcpy(ev.intermediates[0..intermediates.len], intermediates);
        self.dcs_hooks.append(self.gpa, ev) catch unreachable;
    }

    pub fn dcsPut(self: *TestDispatcher, byte: u8) void {
        self.dcs_puts.append(self.gpa, byte) catch unreachable;
    }

    pub fn dcsPutSlice(self: *TestDispatcher, bytes: []const u8) void {
        self.dcs_puts.appendSlice(self.gpa, bytes) catch unreachable;
    }

    pub fn unhook(self: *TestDispatcher) void {
        self.dcs_unhook_count += 1;
    }

    // OSC
    pub fn oscStart(self: *TestDispatcher) void {
        self.osc_buf.clearRetainingCapacity();
    }

    pub fn oscPut(self: *TestDispatcher, byte: u8) void {
        self.osc_buf.append(self.gpa, byte) catch unreachable;
    }

    pub fn oscPutSlice(self: *TestDispatcher, bytes: []const u8) void {
        self.osc_buf.appendSlice(self.gpa, bytes) catch unreachable;
    }

    pub fn oscEnd(self: *TestDispatcher) void {
        const copy = self.gpa.dupe(u8, self.osc_buf.items) catch unreachable;
        self.osc_events.append(self.gpa, .{ .data = copy }) catch unreachable;
    }
};

const alloc = testing.allocator;

fn expectPayloadEnd(state: State, bytes: []const u8, expected: usize) !void {
    try std.testing.expectEqual(expected, State.payloadEnd(state, bytes));
}

fn testPayloadEnd(state: State, payload_byte: u8, stop_bytes: []const u8) !void {
    var buffer: [256]u8 = @splat(payload_byte);

    // Check empty input and all-payload runs of different lengths.
    var len: usize = 0;
    while (len <= buffer.len) : (len += 1) {
        try expectPayloadEnd(state, buffer[0..len], len);
    }

    // Check each stop byte at every position, with payload before and after it.
    for (stop_bytes) |stop| {
        var pos: usize = 0;
        while (pos < buffer.len) : (pos += 1) {
            @memset(buffer[0..], payload_byte);
            buffer[pos] = stop;
            try expectPayloadEnd(state, buffer[0..], pos);
        }
    }

    // Check stop bytes iin the scalar tail, lengths around chunk boundaries
    // where the SIMD loop exits into the tail with bytes left to scan.
    // Only positions past the last full chunk reach the scalar path.

    for (stop_bytes) |stop| {
        for ([_]usize{ 31, 33, 63, 65, 129, 255 }) |tail_len| {
            @memset(buffer[0..tail_len], payload_byte);
            // Stop byte inside the tail region
            const rem = tail_len % 32; // worst-case chunk_len; odd lens have a tail.

            if (rem > 0) {
                var pos: usize = tail_len - rem;
                while (pos < tail_len) : (pos += 1) {
                    buffer[pos] = stop;
                    try expectPayloadEnd(state, buffer[0..tail_len], pos);
                    buffer[pos] = payload_byte;
                }
            }

            // Stop byte straddling the last SIMD chunk's edge.
            const edge = (tail_len / 32) * 32;
            if (edge > 0) {
                buffer[edge - 1] = stop;
                try expectPayloadEnd(state, buffer[0..tail_len], edge - 1);
                buffer[edge - 1] = payload_byte;
            }
        }
    }
}

fn expectParamEnd(state: State, bytes: []const u8, expected: usize) !void {
    try std.testing.expectEqual(expected, State.paramEnd(state, bytes));
}

fn testParamEnd(state: State, valid_bytes: []const u8, invalid_bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;

    // Check empty input and valid runs of different lenghts. Cycling through
    // valid_bytes checks every valid byte, not just one representative.
    var len: usize = 0;
    while (len <= buffer.len) : (len += 1) {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            buffer[i] = valid_bytes[i % valid_bytes.len];
        }

        try expectParamEnd(state, buffer[0..len], len);
    }

    // Put each non-parameter byte at every position. The scan must stop there,
    // even though the rest of the input contains valid parameter bytes.
    for (invalid_bytes) |invalid| {
        var pos: usize = 0;
        while (pos < buffer.len) : (pos += 1) {
            @memset(buffer[0..], valid_bytes[0]);
            buffer[pos] = invalid;
            try expectParamEnd(state, buffer[0..], pos);
        }
    }

    // Same scalar-tail coverage for params runs, the DCS hole at ':' (0x3A)
    // is predicate most likely to drit between the SIMD mask and the scalar
    // check, so place it in the tail explicitly.
    for (invalid_bytes) |invalid| {
        for ([_]usize{ 31, 33, 63, 129, 255 }) |tail_len| {
            @memset(buffer[0..tail_len], valid_bytes[0]);
            const rem = tail_len % 32;
            if (rem > 0) {
                var pos: usize = tail_len - rem;
                while (pos < tail_len) : (pos += 1) {
                    buffer[pos] = invalid;
                    try expectParamEnd(state, buffer[0..tail_len], pos);
                    buffer[pos] = valid_bytes[0];
                }
            }
            const edge = (tail_len / 32) * 32;
            if (edge > 0) {
                buffer[edge - 1] = invalid;
                try expectParamEnd(state, buffer[0..tail_len], edge - 1);
                buffer[edge - 1] = valid_bytes[0];
            }
        }
    }
}

fn expectPayloadEndParam(state: State, bytes: []const u8, expected: usize) !void {
    try std.testing.expectEqual(expected, State.paramEnd(state, bytes));
}

test "vt_parser: payloadEnd agrees with isPayload at every position" {
    const string_states = [_]State{ .osc_string, .dcs_passthrough, .sos_pm_apc_string };
    for (string_states) |s| {
        var buf: [256]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @intCast(i);
        // payloadEnd must stop at the first byte isPayload rejects,
        // and consume exactly the leading accepted run.
        var expected: usize = 0;
        while (expected < buf.len and s.isPayload(buf[expected])) : (expected += 1) {}
        try expectPayloadEnd(s, &buf, expected);
    }
}

test "vt_parser: payloadEnd stops after a valid param prefix" {
    const string_states = [_]State{ .osc_string, .dcs_passthrough, .sos_pm_apc_string };
    for (string_states) |s| {
        var b: u8 = 0x80;
        while (b <= 0x9F) : (b += 1) {
            const input = [_]u8{ 'A', 'A', b };
            try expectPayloadEnd(s, &input, 2);
        }
    }
}

test "vt_parser: isPayload classifies string-state boundaries" {
    const Case = struct {
        state: State,
        byte: u8,
        expected: bool,
    };

    const cases = [_]Case{
        // OSC: printable bytes and DEL are payload; C0 and C1 controls are not.
        .{ .state = .osc_string, .byte = 0x1F, .expected = false },
        .{ .state = .osc_string, .byte = 0x20, .expected = true },
        .{ .state = .osc_string, .byte = 0x7F, .expected = true },
        .{ .state = .osc_string, .byte = 0x80, .expected = false },
        .{ .state = .osc_string, .byte = 0x9F, .expected = false },
        .{ .state = .osc_string, .byte = 0xA0, .expected = true },

        // DCS: CAN, SUB, ESC, DEL, and C1 controls are not payload.
        .{ .state = .dcs_passthrough, .byte = 0x17, .expected = true },
        .{ .state = .dcs_passthrough, .byte = 0x18, .expected = false },
        .{ .state = .dcs_passthrough, .byte = 0x19, .expected = true },
        .{ .state = .dcs_passthrough, .byte = 0x1A, .expected = false },
        .{ .state = .dcs_passthrough, .byte = 0x1B, .expected = false },
        .{ .state = .dcs_passthrough, .byte = 0x1C, .expected = true },
        .{ .state = .dcs_passthrough, .byte = 0x7E, .expected = true },
        .{ .state = .dcs_passthrough, .byte = 0x7F, .expected = false },
        .{ .state = .dcs_passthrough, .byte = 0x80, .expected = false },
        .{ .state = .dcs_passthrough, .byte = 0xA0, .expected = true },

        // SOS/PM/APC: like DCS, except DEL remains in the payload run.
        .{ .state = .sos_pm_apc_string, .byte = 0x18, .expected = false },
        .{ .state = .sos_pm_apc_string, .byte = 0x1C, .expected = true },
        .{ .state = .sos_pm_apc_string, .byte = 0x7F, .expected = true },
        .{ .state = .sos_pm_apc_string, .byte = 0x80, .expected = false },
        .{ .state = .sos_pm_apc_string, .byte = 0xA0, .expected = true },

        // States without payload runs have no payload bytes.
        .{ .state = .ground, .byte = 0x41, .expected = false },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            State.isPayload(case.state, case.byte),
        );
    }
}

test "vt_parser: payloadEnd handles payload runs, terminators, and SIMD boundaries" {
    try testPayloadEnd(
        .osc_string,
        0x41,
        &.{ 0x00, 0x1F, 0x80, 0x85, 0x9F },
    );

    try expectPayloadEnd(.osc_string, &.{ 'A', 0x7F, 'B' }, 3); // DEL is payload in OSC

    try testPayloadEnd(
        .dcs_passthrough,
        0x41,
        &.{ 0x18, 0x1A, 0x1B, 0x7F, 0x80, 0x85, 0x9F },
    );

    try expectPayloadEnd(.dcs_passthrough, &.{ 'A', 0x7F, 'B' }, 1); // DEL stops DCS

    try testPayloadEnd(
        .sos_pm_apc_string,
        0x41,
        &.{ 0x18, 0x1A, 0x1B, 0x80, 0x85, 0x9F },
    );

    try expectPayloadEnd(.ground, &.{ 0x41, 0x00, 0xFF }, 0);
}

test "vt_parser: paramEnd handles CSI and DCS parameter sets and SIMD boundaries" {
    var csi_valid: [12]u8 = undefined;
    for (0..csi_valid.len) |i| {
        csi_valid[i] = 0x30 + @as(u8, @intCast(i)); // 0x30–0x3B
    }

    var dcs_valid: [11]u8 = undefined;
    for (0..10) |i| {
        dcs_valid[i] = 0x30 + @as(u8, @intCast(i)); // 0x30–0x39
    }
    dcs_valid[10] = 0x3B;

    try testParamEnd(
        .csi_param,
        csi_valid[0..],
        &.{ 0x2F, 0x3C, 0x7F, 0x80, 0xFF },
    );

    try testParamEnd(
        .dcs_param,
        dcs_valid[0..],
        &.{ 0x2F, 0x3A, 0x3C, 0x7F, 0x80, 0xFF },
    );
}

test "vt_parser: paramEnd stops after a valid param prefix" {
    try expectPayloadEndParam(.csi_param, "12;34m", 5); // 'm' final byte
    try expectPayloadEndParam(.csi_param, "1;2;38p", 6); // CSI allows ':'
    try expectPayloadEndParam(.dcs_param, "12;34\x1b", 5); // ESC aborts
    try expectPayloadEndParam(.dcs_param, "1:2", 1); // ':' hole in DCS
    try expectPayloadEndParam(.csi_param, "?25", 0); // private marker not param-run
}

test "vt_parser: leading ':' opens implicit empty parent + sub-parameter" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[:5m");

    try testing.expectEqual(1, d.csi_events.items.len);

    const ev = d.csi_events.items[0];

    try testing.expectEqual(2, ev.param_len);
    try testing.expectEqual(@as(u15, 0), ev.params[0].value);
    try testing.expectEqual(.parameter, ev.params[0].separator);
    try testing.expectEqual(@as(u15, 5), ev.params[1].value);
    try testing.expectEqual(.sub_parameter, ev.params[1].separator);
    try testing.expectEqual(.ground, p.state);
}

test "vt_parser: leading ':' parity across feed shapes" {
    // Same input through different dispatcher must produce identical
    // params, pins pushParam v feedParamRun on the plen == 0 delegation boundary.

    const input = "\x1b[::7;1::2m";

    var expected_params: [16]Parameter = undefined;
    var expected_len: u8 = 0;
    var expected_overflow: bool = false;

    inline for (.{ 0, 3, 1 }) |chunk| {
        // 0 = feed once
        var d: TestDispatcher = try .init(alloc);
        defer d.deinit();

        var p: Parser(TestDispatcher, .{}) = .{};

        if (chunk == 0) {
            p.feedBytes(&d, input);
        } else {
            var i: usize = 0;
            while (i < input.len) {
                const end = @min(i + chunk, input.len);
                p.feedBytes(&d, input[i..end]);
                i = end;
            }
        }

        try testing.expectEqual(1, d.csi_events.items.len);
        const ev = d.csi_events.items[0];

        if (chunk == 0) {
            expected_len = ev.param_len;
            expected_overflow = p.params_overflow;
            @memcpy(expected_params[0..ev.param_len], ev.params[0..ev.param_len]);
        } else {
            try testing.expectEqual(expected_len, ev.param_len);
            try testing.expectEqual(expected_overflow, p.params_overflow);
            for (expected_params[0..expected_len], ev.params[0..expected_len]) |a, b| {
                try testing.expectEqual(a.value, b.value);
                try testing.expectEqual(a.separator, b.separator);
            }
        }
    }
}

test "vt_parser: digit accumulation paths agree at every split offset" {
    const inputs = [_][]const u8{
        "\x1b[000001m", // leading zeros: six digits, value 1; NOT saturated
        "\x1b[99999m", // exactly 5 digits, fits unclamped window
        "\x1b[100000m", // 6 digits, clamps to 32767
        "\x1b[4294967296m", // would wrap u32 if accumulated raw; must clamp
        "\x1b[0000000000042m", // many leading zeros then value; must stay 42
        "\x1b[1;99999m", // 5-digit run on a nonzero prior slot
        "\x1b[32767m", // boundary
        "\x1b[32768m", // boundary + 1
        "\x1b[327679m", // worst case: saturated slot then 9 clamps to 32767
    };

    for (inputs) |input| {
        // Reference: whole-buffer feed to feedCsi to feedParamRun windowed accumulate.
        var ref_d: TestDispatcher = try .init(alloc);
        defer ref_d.deinit();
        var ref_p: Parser(TestDispatcher, .{}) = .{};
        ref_p.feedBytes(&ref_d, input);

        // Per-byte: every byte goes through step()/pushParam's per-digit clamp.
        var byte_d: TestDispatcher = try .init(alloc);
        defer byte_d.deinit();
        var byte_p: Parser(TestDispatcher, .{}) = .{};
        for (0..input.len) |j| byte_p.feedBytes(&byte_d, input[j..][0..1]);

        // Parser-side param state must agree.
        try testing.expectEqual(ref_p.state, byte_p.state);
        try testing.expectEqual(ref_p.param_len, byte_p.param_len);
        try testing.expectEqual(ref_p.params_overflow, byte_p.params_overflow);
        try testing.expectEqualSlices(
            Parameter,
            ref_p.params[0..ref_p.param_len],
            byte_p.params[0..byte_p.param_len],
        );

        // And the dispatched event must agree on the observable surface.
        try testing.expectEqual(ref_d.csi_events.items.len, byte_d.csi_events.items.len);
        const e = ref_d.csi_events.items[0];
        const a = byte_d.csi_events.items[0];
        try testing.expectEqual(e.final, a.final);
        try testing.expectEqual(e.param_len, a.param_len);
        try testing.expectEqual(e.intermediate_len, a.intermediate_len);
        try testing.expectEqualSlices(Parameter, e.params[0..e.param_len], a.params[0..a.param_len]);
    }
}

test "vt_parser: digit accumulation boundary values" {
    const cases = [_]struct { input: []const u8, expect: u15 }{
        .{ .input = "\x1b[000001m", .expect = 1 },
        .{ .input = "\x1b[99999m", .expect = 32767 }, // 99999 > 32767 (clamped)
        .{ .input = "\x1b[100000m", .expect = 32767 },
        .{ .input = "\x1b[4294967296m", .expect = 32767 },
        .{ .input = "\x1b[0000000000042m", .expect = 42 },
        .{ .input = "\x1b[32767m", .expect = 32767 },
        .{ .input = "\x1b[32768m", .expect = 32767 },
        .{ .input = "\x1b[327679m", .expect = 32767 },
    };

    for (cases) |c| {
        var d: TestDispatcher = try .init(alloc);
        defer d.deinit();
        var p: Parser(TestDispatcher, .{}) = .{};
        p.feedBytes(&d, c.input);

        try testing.expectEqual(1, d.csi_events.items.len);
        const ev = d.csi_events.items[0];
        try testing.expectEqual(1, ev.param_len);
        try testing.expectEqual(c.expect, ev.params[0].value);
    }
}

test "vt_parser: digit overflow saturates at Parameter.Value max" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[99999999999H");

    try testing.expectEqual(1, d.csi_events.items.len);
    const ev = d.csi_events.items[0];
    try testing.expectEqual(1, ev.param_len);
    try testing.expectEqual(std.math.maxInt(Parameter.Value), ev.params[0].value);
}

test "vt_parser: overflow saturates on every digit, both paths" {
    // 40000 crosses the u15 bound mid-run, feedParamRun's accumDigit
    // loop and pushParam's digit arm must agree bit-for-bit.

    for ([_][]const u8{
        "\x1b[40000C",
        "\x1b[99999;9m",
        "\x1b[1;99999999;3m",
    }) |input| {
        var d1: TestDispatcher = try .init(alloc);
        defer d1.deinit();
        var p1: Parser(TestDispatcher, .{}) = .{};
        p1.feedBytes(&d1, input);

        var d2: TestDispatcher = try .init(alloc);
        defer d2.deinit();
        var p2: Parser(TestDispatcher, .{}) = .{};
        for (input) |b| p2.feedBytes(&d2, &.{b}); // feed one byte at a time

        const e1 = d1.csi_events.items[0];
        const e2 = d2.csi_events.items[0];
        try testing.expectEqual(e1.param_len, e2.param_len);
        for (e1.params[0..e1.param_len], e2.params[0..e2.param_len]) |a, b| {
            try testing.expectEqual(a.value, b.value);
            try testing.expectEqual(a.separator, b.separator);
        }
    }
}

test "vt_parser: params beyond cap set params_overflow, slot-max kept" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();

    var p: Parser(TestDispatcher, .{}) = .{};

    // 33 params against max_params = 32: slot 32 gets '32', '33' is dropped.
    p.feedBytes(&d, "\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20;21;22;23;24;25;26;27;28;29;30;31;32;33H");

    try testing.expectEqual(1, d.csi_events.items.len);
    const ev = d.csi_events.items[0];
    try testing.expectEqual(opt.max_params, ev.param_len); // max_params
    try testing.expectEqual(true, p.params_overflow);
    try testing.expectEqual(@as(u15, 32), ev.params[31].value); // last kept slot intact
}

test "vt_parser: exactly max_params sets no overflow" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20;21;22;23;24;25;26;27;28;29;30;31;32H");

    const ev = d.csi_events.items[0];
    try testing.expectEqual(32, ev.param_len);
    try testing.expectEqual(false, p.params_overflow); // boundary: full ≠ overflow
    try testing.expectEqual(@as(u15, 32), ev.params[31].value);
}

test "vt_parser: digits after dropped separator don't leak into last slot" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    // 32 params fill the cap; ";987654" is dropped — its digits must not
    // accumulate into slot 32, and 'H' must still dispatch.
    p.feedBytes(&d, "\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20;21;22;23;24;25;26;27;28;29;30;31;32;987654H");

    const ev = d.csi_events.items[0];
    try testing.expectEqual('H', ev.final);
    try testing.expectEqual(32, ev.param_len);
    try testing.expectEqual(@as(u15, 32), ev.params[31].value); // NOT 987654-wrapped
    try testing.expectEqual(true, p.params_overflow);
}

test "vt_parser: param paths agree at every split offset" {
    const inputs = [_][]const u8{
        "\x1b[40000C",
        "\x1b[99999999999C",
        "\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20;21;22;23;24;25;26;27;28;29;30;31;32;987654H",
        "\x1b[:5m",
    };

    for (inputs) |input| {
        // Reference: whole-buffer feed; fused feedCsi or feedParamRun path.
        var ref_d: TestDispatcher = try .init(alloc);
        defer ref_d.deinit();
        var ref_p: Parser(TestDispatcher, .{}) = .{};
        ref_p.feedBytes(&ref_d, input);

        // Byte-at-a-time feed; pure step() or pushParam path.
        var byte_d: TestDispatcher = try .init(alloc);
        defer byte_d.deinit();
        var byte_p: Parser(TestDispatcher, .{}) = .{};
        for (input, 0..) |_, j| byte_p.feedBytes(&byte_d, input[j..][0..1]);

        // Parser state must match exactly.
        try testing.expectEqual(ref_p.state, byte_p.state);
        try testing.expectEqual(ref_p.param_len, byte_p.param_len);
        try testing.expectEqual(ref_p.params_overflow, byte_p.params_overflow);
        try testing.expectEqualSlices(
            Parameter,
            ref_p.params[0..ref_p.param_len],
            byte_p.params[0..byte_p.param_len],
        );

        // Events must match, compare field-by-field, not whole struct,
        // because csi event carries slices that won't compare equal by value.
        try testing.expectEqual(ref_d.csi_events.items.len, byte_d.csi_events.items.len);
        for (ref_d.csi_events.items, byte_d.csi_events.items) |e, a| {
            try testing.expectEqual(e.final, a.final);
            try testing.expectEqual(e.param_len, a.param_len);
            try testing.expectEqual(e.intermediate_len, a.intermediate_len);
            try testing.expectEqualSlices(Parameter, e.params[0..e.param_len], a.params[0..a.param_len]);
            try testing.expectEqualSlices(u8, e.intermediates[0..e.intermediate_len], a.intermediates[0..a.intermediate_len]);
        }
    }
}

test "vt_parser: printable ascii" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "Hello");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqualSlices(u8, "Hello", d.prints.items[0..]);
    try testing.expectEqual(0, d.executes.items.len);
}

test "vt_parser: C0 control codes" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\r\n");
    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(0, d.prints.items.len);
    try testing.expectEqualSlices(u8, "\r\n", d.executes.items[0..]);
}

test "vt_parser: ESC transitions to escape state" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b");

    try testing.expectEqual(.escape, p.state);
    try testing.expectEqual(0, d.prints.items.len);
}

test "vt_parser: PAD C1 Control Characters" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b@");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual('@', d.escapes.items[0].final);
    try testing.expectEqual(0, d.escapes.items[0].intermediate_len);
}

test "vt_parser: IND C1 Control Characters" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1bD");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual('D', d.escapes.items[0].final);
    try testing.expectEqual(0, d.escapes.items[0].intermediate_len);
}

test "vt_parser: Set ANSI conformance level 1, ECMA-43" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, &.{ 0x1b, ' ', 'L' });

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual('L', d.escapes.items[0].final);
    const inter = d.escapes.items[0];
    try testing.expectEqualSlices(u8, &.{' '}, inter.intermediates[0..inter.intermediate_len]);
}

test "vt_parser: CSI no-param sequence dispatches with empty params" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[H");

    try testing.expectEqual(1, d.csi_events.items.len);

    const ev = d.csi_events.items[0];
    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual('H', ev.final);
    try testing.expectEqual(0, ev.param_len);
    try testing.expectEqual(0, ev.intermediate_len);
}

test "vt_parser: CSI single param" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[5A");

    try testing.expectEqual(1, d.csi_events.items.len);

    const ev = d.csi_events.items[0];
    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual('A', ev.final);
    try testing.expectEqualSlices(
        Parameter,
        &.{Parameter{ .value = 5, .separator = .parameter }},
        ev.params[0..ev.param_len],
    );
    try testing.expectEqual(0, ev.intermediate_len);
}

test "vt_parser: CSI multi-digit param" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[21;12H");

    try testing.expectEqual(1, d.csi_events.items.len);

    const ev = d.csi_events.items[0];
    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual('H', ev.final);
    try testing.expectEqualSlices(
        Parameter,
        &.{
            Parameter{ .value = 21, .separator = .parameter },
            Parameter{ .value = 12, .separator = .parameter },
        },
        ev.params[0..ev.param_len],
    );
    try testing.expectEqual(0, ev.intermediate_len);
}

test "vt_parser: CSI private marker '?' collected as intermediate" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[?25H");

    try testing.expectEqual(1, d.csi_events.items.len);

    const ev = d.csi_events.items[0];
    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual('H', ev.final);
    try testing.expectEqualSlices(
        Parameter,
        &.{Parameter{ .value = 25, .separator = .parameter }},
        ev.params[0..ev.param_len],
    );
    try testing.expectEqualSlices(u8, &.{'?'}, ev.intermediates[0..ev.intermediate_len]);
}

test "vt_parser: CSI intermediate byte (0x20-0x2F) before final" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[ q");

    try testing.expectEqual(1, d.csi_events.items.len);

    const ev = d.csi_events.items[0];
    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual('q', ev.final);
    try testing.expectEqual(0, ev.param_len);
    try testing.expectEqualSlices(u8, &.{' '}, ev.intermediates[0..ev.intermediate_len]);
}

test "vt_parser: CSI param then intermediate then final" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[2 q");

    try testing.expectEqual(1, d.csi_events.items.len);

    const ev = d.csi_events.items[0];
    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual('q', ev.final);
    try testing.expectEqualSlices(
        Parameter,
        &.{Parameter{ .value = 2, .separator = .parameter }},
        ev.params[0..ev.param_len],
    );
    try testing.expectEqualSlices(u8, &.{' '}, ev.intermediates[0..ev.intermediate_len]);
}

test "vt_parser: CSI private marker in csi_param goes to csi_ignore state" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[1<H");

    try testing.expectEqual(0, d.csi_events.items.len);
    try testing.expectEqual(.ground, p.state);
}

test "vt_parser: CSI intermediate then param-range byte goes to csi_ignore" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[ 1<H");

    try testing.expectEqual(0, d.csi_events.items.len);
    try testing.expectEqual(.ground, p.state);
}

test "vt_parser: CSI colon in csi_entry, sub-parameter with value 0" {
    // "\x1b[:m" colon csi_entry first param is {0, .sub_paramter}
    var d = try TestDispatcher.init(testing.allocator);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[:m");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(1, d.csi_events.items.len);
    const ev = d.csi_events.items[0];
    try testing.expectEqual('m', ev.final);
    try testing.expectEqualSlices(
        Parameter,
        &.{
            Parameter{ .value = 0, .separator = .parameter },
            Parameter{ .value = 0, .separator = .sub_parameter },
        },
        ev.params[0..ev.param_len],
    );
}

test "vt_parser: CSI SGR RGB foreground: 38:2:255:0:0" {
    // "\x1b[38:2:255:0:0m"
    var d = try TestDispatcher.init(testing.allocator);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[38:2:255:0:0m");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(1, d.csi_events.items.len);

    const ev = d.csi_events.items[0];
    try testing.expectEqual('m', ev.final);
    try testing.expectEqualSlices(
        Parameter,
        &.{
            // first param: .{ .value=38, separator=.parameter} (it's the group head)
            Parameter{ .value = 38, .separator = .parameter },
            // sub-params: 2,255,0,0
            Parameter{ .value = 2, .separator = .sub_parameter },
            Parameter{ .value = 255, .separator = .sub_parameter },
            Parameter{ .value = 0, .separator = .sub_parameter },
            Parameter{ .value = 0, .separator = .sub_parameter },
        },
        ev.params[0..ev.param_len],
    );
}

test "vt_parser: CSI mixed params and sub-params" {
    // "\x1b[1;38:2:255:0:0m"
    var d = try TestDispatcher.init(testing.allocator);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[1;38:2:255:0:0m");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(1, d.csi_events.items.len);

    const ev = d.csi_events.items[0];
    try testing.expectEqual('m', ev.final);
    try testing.expectEqualSlices(
        Parameter,
        &.{
            // first param: .{ .value=1, separator=.parameter} (it's the group head of first param)
            Parameter{ .value = 1, .separator = .parameter },
            // second param: .{ .value=38, separator=.parameter} (it's the group head of second param)
            Parameter{ .value = 38, .separator = .parameter },
            // sub-params: 2,255,0,0
            Parameter{ .value = 2, .separator = .sub_parameter },
            Parameter{ .value = 255, .separator = .sub_parameter },
            Parameter{ .value = 0, .separator = .sub_parameter },
            Parameter{ .value = 0, .separator = .sub_parameter },
        },
        ev.params[0..ev.param_len],
    );
}

test "vt_parser: CSI underline color" {
    // "\x1b[58:2:255:0:0m"
    var d = try TestDispatcher.init(testing.allocator);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[58:2:255:0:0m");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(1, d.csi_events.items.len);

    const ev = d.csi_events.items[0];
    try testing.expectEqual('m', ev.final);
    try testing.expectEqualSlices(
        Parameter,
        &.{
            // first param: .{ .value=58, separator=.parameter} (it's the group head of)
            Parameter{ .value = 58, .separator = .parameter },
            // sub-params: 2,255,0,0
            Parameter{ .value = 2, .separator = .sub_parameter },
            Parameter{ .value = 255, .separator = .sub_parameter },
            Parameter{ .value = 0, .separator = .sub_parameter },
            Parameter{ .value = 0, .separator = .sub_parameter },
        },
        ev.params[0..ev.param_len],
    );
}

test "vt_parser: CSI colon then semicolon resets parameter separator" {
    // "\x1b[38:2;1m" sub-param group then a normal param
    var d = try TestDispatcher.init(testing.allocator);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[38:2;1m");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(1, d.csi_events.items.len);

    const ev = d.csi_events.items[0];
    try testing.expectEqual('m', ev.final);
    try testing.expectEqualSlices(
        Parameter,
        &.{
            // first param: .{ .value=38, separator=.parameter} (it's the group head of)
            Parameter{ .value = 38, .separator = .parameter },
            // sub-params: 2
            Parameter{ .value = 2, .separator = .sub_parameter },
            // second param: 1 .{ .value=1, separator=.parameter}
            Parameter{ .value = 1, .separator = .parameter },
        },
        ev.params[0..ev.param_len],
    );
}

// Ported from the removed term/csi_test.zig: behaviour that had no
// equivalent vt_parser test.

fn expectCsiParams(input: []const u8, final: u8, expected: []const Parameter) !void {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, input);

    try testing.expectEqual(1, d.csi_events.items.len);
    const ev = d.csi_events.items[0];
    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(final, ev.final);
    try testing.expectEqualSlices(Parameter, expected, ev.params[0..ev.param_len]);
}

test "vt_parser: CSI DEL inside params is ignored" {
    try expectCsiParams("\x1b[1\x7f2m", 'm', &.{
        .{ .value = 12, .separator = .parameter },
    });
}

test "vt_parser: CSI DEL inside intermediates is ignored" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[ \x7fq");

    try testing.expectEqual(1, d.csi_events.items.len);
    const ev = d.csi_events.items[0];
    try testing.expectEqual('q', ev.final);
    try testing.expectEqualSlices(u8, &.{' '}, ev.intermediates[0..ev.intermediate_len]);
}

test "vt_parser: CSI trailing ';' opens an empty trailing param" {
    try expectCsiParams("\x1b[1;m", 'm', &.{
        .{ .value = 1, .separator = .parameter },
        .{ .value = 0, .separator = .parameter },
    });
}

test "vt_parser: CSI only separators yields empty params" {
    try expectCsiParams("\x1b[;;m", 'm', &.{
        .{ .value = 0, .separator = .parameter },
        .{ .value = 0, .separator = .parameter },
        .{ .value = 0, .separator = .parameter },
    });
}

test "vt_parser: CSI empty first param keeps its slot" {
    try expectCsiParams("\x1b[;5H", 'H', &.{
        .{ .value = 0, .separator = .parameter },
        .{ .value = 5, .separator = .parameter },
    });
}

test "vt_parser: C0 control inside csi_entry fires execute but stays in csi_entry" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[\rH");

    try testing.expectEqual(1, d.executes.items.len);
    try testing.expectEqual(0x0D, d.executes.items[0]);

    try testing.expectEqual(1, d.csi_events.items.len);
    try testing.expectEqual('H', d.csi_events.items[0].final);
    try testing.expectEqual(.ground, p.state);
}

test "vt_parser: ESC inside CSI resets to escape state (anywhare transition)" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[24\x1b");

    try testing.expectEqual(.escape, p.state);
    try testing.expectEqual(0, d.csi_events.items.len);
}

test "vt_parser: multiple sequences in one feed" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b[1A\x1b[2B");

    try testing.expectEqual(2, d.csi_events.items.len);
    try testing.expectEqual('A', d.csi_events.items[0].final);
    try testing.expectEqual(1, d.csi_events.items[0].params[0].value);
    try testing.expectEqual('B', d.csi_events.items[1].final);
    try testing.expectEqual(2, d.csi_events.items[1].params[0].value);
    try testing.expectEqual(.ground, p.state);
}

test "vt_parser: DCS q <data> ST fires hook/put/unhook" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    // ESC P q hello ST (SIXEL-style)
    p.feedBytes(&d, "\x1bPqhellO\x9c"); // final='q', data="hello"
    try testing.expectEqual(1, d.dcs_hooks.items.len);
    try testing.expectEqual('q', d.dcs_hooks.items[0].final);
    try testing.expectEqual(0, d.dcs_hooks.items[0].param_len);
    try testing.expectEqualSlices(u8, "hellO", d.dcs_puts.items[0..]);
    try testing.expectEqual(1, d.dcs_unhook_count);
    try testing.expectEqual(.ground, p.state);
}

test "vt_parser: DCS q <data> ST with params" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    // final='q', params=[1,2], data="data"
    p.feedBytes(&d, "\x1bP1;2qdata\x9c");
    try testing.expectEqual(1, d.dcs_hooks.items.len);
    const ev = d.dcs_hooks.items[0];
    try testing.expectEqual('q', ev.final);
    try testing.expectEqualSlices(
        Parameter,
        &.{
            Parameter{ .value = 1, .separator = .parameter },
            Parameter{ .value = 2, .separator = .parameter },
        },
        ev.params[0..ev.param_len],
    );
    try testing.expectEqualSlices(u8, "data", d.dcs_puts.items[0..]);
    try testing.expectEqual(1, d.dcs_unhook_count);
    try testing.expectEqual(.ground, p.state);
}

test "vt_parser: DCS P ! p <data> ST with intermediate byte" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    // final='p', intermediate='!', data="data"
    p.feedBytes(&d, "\x1bP!pdata\x9c");
    try testing.expectEqual(1, d.dcs_hooks.items.len);
    const ev = d.dcs_hooks.items[0];
    try testing.expectEqual('p', ev.final);
    try testing.expectEqualSlices(u8, &.{'!'}, ev.intermediates[0..ev.intermediate_len]);
    try testing.expectEqualSlices(u8, "data", d.dcs_puts.items[0..]);
    try testing.expectEqual(1, d.dcs_unhook_count);
    try testing.expectEqual(.ground, p.state);
}

test "vt_parser: DCS with empty data stream" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1bPq\x9c");

    try testing.expectEqual(1, d.dcs_hooks.items.len);
    try testing.expectEqual(1, d.dcs_unhook_count);
    try testing.expectEqual(0, d.dcs_puts.items.len);
    try testing.expectEqual(.ground, p.state);
}

test "vt_parser: DCS ESC inside dsc_passthrough cancels via anywhere, unhook fires" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    // ESC P q data ESC (anywhere: ESC -> escape, exit fires unhook)
    p.feedBytes(&d, "\x1bPqdata\x1b");

    try testing.expectEqual(1, d.dcs_hooks.items.len);
    try testing.expectEqual('q', d.dcs_hooks.items[0].final);
    try testing.expectEqualSlices(u8, "data", d.dcs_puts.items[0..]);
    try testing.expectEqual(1, d.dcs_unhook_count); // exit fired
    try testing.expectEqual(.escape, p.state);
}

test "vt_parser: DCS C1 0x90 shorthand enters dcs_entry" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    // 0x90 = C1 DCS (8-bit shorthand for ESC P)
    p.feedBytes(&d, "\x90qdata\x9c");

    try testing.expectEqual(1, d.dcs_hooks.items.len);
    try testing.expectEqual('q', d.dcs_hooks.items[0].final);
    try testing.expectEqualSlices(u8, "data", d.dcs_puts.items[0..]);
    try testing.expectEqual(1, d.dcs_unhook_count); // exit fired
    try testing.expectEqual(.ground, p.state);
}

test "vt_parser: OSC BEL termination (ESC ] code ; data BEL)" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b]0;My Title\x07");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(1, d.osc_events.items.len);
    try testing.expectEqualSlices(u8, "0;My Title", d.osc_events.items[0].data[0..]);
}

test "vt_parser: OSC ST termination (ESC ] code ; data ESC \\)" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b]2;Window\x1b\\");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(1, d.osc_events.items.len);
    try testing.expectEqualSlices(u8, "2;Window", d.osc_events.items[0].data[0..]);
}

test "vt_parser: OSC ST termination (0x9C)" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    // 0x9C = C1 DCS (8-bit shorthand for ST)
    p.feedBytes(&d, "\x1b]0;Title\x9c");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(1, d.osc_events.items.len);
    try testing.expectEqualSlices(u8, "0;Title", d.osc_events.items[0].data[0..]);
}

test "vt_parser: OSC C1 0x9D shorthand enters osc_string" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    // 0x9D = C1 DCS (8-bit shorthand for ESC ])
    p.feedBytes(&d, "\x9d0;Title\x9c");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(1, d.osc_events.items.len);
    try testing.expectEqualSlices(u8, "0;Title", d.osc_events.items[0].data[0..]);
}

test "vt_parser: C0 controls inside OSC are ignored (not put)" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b]0;\x01Title\x07");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(1, d.osc_events.items.len);
    try testing.expectEqualSlices(u8, "0;Title", d.osc_events.items[0].data[0..]);
}

test "vt_parser: ESC inside OSC cancels it (anywhare transition)" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    // ESC inside OSC -> anywhere -> escape state, osc_end fires
    p.feedBytes(&d, "\x1b]0;Title\x1b");

    try testing.expectEqual(.escape, p.state);
    // osc_end fired (incomplete OSC)
    try testing.expectEqual(1, d.osc_events.items.len);
    try testing.expectEqualSlices(u8, "0;Title", d.osc_events.items[0].data[0..]);
}

test "vt_parser: OSC multiple sequences in one feed" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();

    var p: Parser(TestDispatcher, .{}) = .{};

    // ESC inside OSC -> anywhere -> escape state, osc_end fires
    p.feedBytes(&d, "\x1b]0;First\x07\x1b]2;Second\x07");

    try testing.expectEqual(.ground, p.state);

    try testing.expectEqual(2, d.osc_events.items.len);
    try testing.expectEqualSlices(u8, "0;First", d.osc_events.items[0].data[0..]);
    try testing.expectEqualSlices(u8, "2;Second", d.osc_events.items[1].data[0..]);
}

test "vt_parser: OSC empty data" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1b]\x07");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(1, d.osc_events.items.len);
    try testing.expectEqualSlices(u8, "", d.osc_events.items[0].data[0..]);
}

test "vt_parser: SOS all bytes ignored until ST" {
    var d: TestDispatcher = try .init(alloc);
    defer d.deinit();
    var p: Parser(TestDispatcher, .{}) = .{};

    p.feedBytes(&d, "\x1bXanything here\x9c");

    try testing.expectEqual(.ground, p.state);
    try testing.expectEqual(0, d.prints.items.len);
    try testing.expectEqual(0, d.executes.items.len);
    try testing.expectEqual(0, d.osc_events.items.len);
}

test "vt_parser: ':' in DCS params aborts to dcs_ignore in both paths" {
    // Table: dcs_param × 0x3A (':') => .none or .dcs_ignore.
    // isParamOrSep(allow_colon=false) must agree; if the fast path
    // admits ':' as a param byte, the whole-buffer feed would reach
    // 'q' (final) and fire hook + dcsPut where feed_byte does not.
    const input = "\x1bP1:2qabc\x9c";

    // Fast path: whole-buffer feed.
    var fast_d: TestDispatcher = try .init(alloc);
    defer fast_d.deinit();
    var fast_p: Parser(TestDispatcher, .{}) = .{};
    fast_p.feedBytes(&fast_d, input);

    // Table path: byte-at-a-time.
    var slow_d: TestDispatcher = try .init(alloc);
    defer slow_d.deinit();
    var slow_p: Parser(TestDispatcher, .{}) = .{};
    for (input) |b| slow_p.feedBytes(&slow_d, &[1]u8{b});

    // Both must agree: sequence aborted at ':', nothing dispatched.
    try testing.expectEqual(0, fast_d.dcs_hooks.items.len);
    try testing.expectEqual(0, fast_d.dcs_puts.items.len);
    try testing.expectEqual(.ground, fast_p.state);

    try testing.expectEqual(0, slow_d.dcs_hooks.items.len);
    try testing.expectEqual(0, slow_d.dcs_puts.items.len);
    try testing.expectEqual(.ground, slow_p.state);
}

test "scanUntil: bitcast mask LSB == lane 0 (firstTrue equivalence)" {
    const N = std.simd.suggestVectorLength(u8) orelse return error.SkipZigTest;
    const Chunk = @Vector(N, u8);
    const Mask = std.meta.Int(.unsigned, N);

    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rnd = prng.random();
    for (0..4096) |_| {
        var buf: [N]u8 = undefined;
        rnd.bytes(&buf);
        const chunk: Chunk = buf;
        const stop = chunk > @as(Chunk, @splat(0x7F)); // arbitrary mask

        const expected: ?usize = if (std.simd.firstTrue(stop)) |f| f else null;
        const m: Mask = @bitCast(stop);
        const actual: ?usize = if (m != 0) @ctz(m) else null;

        try testing.expectEqual(expected, actual);
    }
}