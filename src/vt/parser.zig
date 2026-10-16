const std = @import("std");
const log = std.log.scoped(.vt_parser);

const assert = std.debug.assert;

test {
    _ = @import("parser_test.zig");
    // _ = @import("parser_fuzzy_test.zig");
}

/// States of the VT Parser. The current state determines how the
/// next input byte is interpreted.
pub const State = enum(u8) {
    ground = 0,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_ignore,
    osc_string,
    sos_pm_apc_string,

    pub const count: usize = 14;

    /// Scans `bytes` from the beginning and returns the index of the
    /// first that stops the scan, or `bytes.len` if every continues it.
    ///
    /// `stopVector(chunk)` must return a mask where `true` marks a byte that
    /// ends the run.
    ///
    /// `continuesScalar(context, byte)` determines whether a byte continues
    /// the scan when checked scalar-wise; it should agree with the vector
    /// predicate.
    ///
    /// `context` is passed to `continuesScalar`.
    pub fn scanUntil(
        bytes: []const u8,
        context: anytype,
        comptime stopVector: anytype,
        comptime continuesScalar: anytype,
    ) usize {
        var i: usize = 0;

        if (std.simd.suggestVectorLength(u8)) |chunk_len| {
            const Chunk = @Vector(chunk_len, u8);
            while (i + chunk_len <= bytes.len) : (i += chunk_len) {
                const chunk: Chunk = bytes[i..][0..chunk_len].*;
                if (std.simd.firstTrue(stopVector(chunk))) |first| return i + first;
            }
        }

        while (i < bytes.len and continuesScalar(context, bytes[i])) : (i += 1) {}
        return i;
    }

    /// Returns whether `byte` belongs to the payload run for `self`.
    ///
    /// Returns `false` for states without payload bytes.
    pub inline fn isPayload(self: State, byte: u8) bool {
        return switch (self) {
            .osc_string => switch (byte) {
                0x20...0x7F => true, // incl. DEL — table puts it
                0xA0...0xFF => true,
                else => false, // C0 .ignore via step(); 0x80–0x9F => anywhere
            },
            .dcs_passthrough => switch (byte) {
                0x7F => false, // .ignore, dropped — not payload
                0x18, 0x1A, 0x1B => false,
                0x80...0x9F => false, // C1 controls → anywhere transitions
                else => true, // C0 ∪ [0x20,0x7E] ∪ [0xA0,0xFF] => .put
            },
            .sos_pm_apc_string => switch (byte) {
                0x18, 0x1A, 0x1B => false,
                0x80...0x9F => false,
                else => true, // else .ignore, swallowed
            },
            else => false,
        };
    }

    /// Returns a mask where `true` marks a byte that ends a DCS payload run.
    inline fn dcsStopVector(chunk: anytype) @TypeOf(chunk == @as(@TypeOf(chunk), @splat(0))) {
        const Chunk = @TypeOf(chunk);
        const control = // matches 0x18...0x1B except 0x19.
            ((chunk & @as(Chunk, @splat(0xFC))) == @as(Chunk, @splat(0x18))) &
            (chunk != @as(Chunk, @splat(0x19)));

        const del = chunk == @as(Chunk, @splat(0x7F));
        const c1 = (chunk & @as(Chunk, @splat(0xE0))) == @as(Chunk, @splat(0x80));

        return control | del | c1;
    }

    /// Returns a mask where `true` marks a byte that ends a SOS payload run.
    inline fn sosStopVector(chunk: anytype) @TypeOf(chunk == @as(@TypeOf(chunk), @splat(0))) {
        const Chunk = @TypeOf(chunk);

        // DEL is payload in SOS; unlike DCS, it is not a stop byte.
        const control =
            ((chunk & @as(Chunk, @splat(0xFC))) == @as(Chunk, @splat(0x18))) &
            (chunk != @as(Chunk, @splat(0x19)));

        const c1 =
            (chunk & @as(Chunk, @splat(0xE0))) == @as(Chunk, @splat(0x80));

        return control | c1;
    }

    /// Returns a mask where `true` marks a byte that ends a OSC payload run.
    inline fn oscStopVector(chunk: anytype) @TypeOf(chunk == @as(@TypeOf(chunk), @splat(0))) {
        const Chunk = @TypeOf(chunk);

        // Stops at C0 bytes and C1 bytes [0x80, 0x9F].
        const c0 = chunk < @as(Chunk, @splat(0x20));
        const c1 =
            (chunk -% @as(Chunk, @splat(0x80))) < @as(Chunk, @splat(0x20));

        return c0 | c1;
    }

    /// Returns the length of the leading payload run in `bytes` for `self`.
    ///
    /// For payload-string states, scanning stops before the first bytes that
    /// ends the run, or at `bytes.len` if no such byte is present.
    ///
    /// Returns `0` for states without payload scanning.
    /// This method does not change parser state or consume any bytes.
    pub fn payloadEnd(self: State, bytes: []const u8) usize {
        return switch (self) {
            .dcs_passthrough => scanUntil(bytes, self, dcsStopVector, isPayload),
            .sos_pm_apc_string => scanUntil(bytes, self, sosStopVector, isPayload),
            .osc_string => scanUntil(bytes, self, oscStopVector, isPayload),
            else => 0,
        };
    }

    /// Returns a stop mask `true` marks bytes outside the CSI parameter range.
    inline fn csiParamStopVector(chunk: anytype) @TypeOf(chunk == @as(@TypeOf(chunk), @splat(0))) {
        const Chunk = @TypeOf(chunk);
        const offset = chunk -% @as(Chunk, @splat(0x30));
        const is_param = offset <= @as(Chunk, @splat(0x0B)); // 0x30–0x3B
        return !is_param;
    }

    /// Returns a stop mask `true` marks bytes outside the DCS parameter range.
    inline fn dcsParamStopVector(chunk: anytype) @TypeOf(chunk == @as(@TypeOf(chunk), @splat(0))) {
        const Chunk = @TypeOf(chunk);
        const offset = chunk -% @as(Chunk, @splat(0x30));
        const is_digit = offset <= @as(Chunk, @splat(0x09));
        const is_semicolon = chunk == @as(Chunk, @splat(0x3B));
        return !(is_digit | is_semicolon);
    }

    inline fn csiParamContinues(_: State, byte: u8) bool {
        return byte >= 0x30 and byte <= 0x3B;
    }

    inline fn dcsParamContinues(_: State, byte: u8) bool {
        return (byte >= 0x30 and byte <= 0x39) or byte == 0x3B;
    }

    /// Returns the length of the leading parameter run in `bytes`.
    ///
    /// Uses the parameter-byte rules for `.csi_param` or `.dcs_param`.
    /// Returns `bytes.len` if every byte continues the run.
    /// Panics if `self` is in any other state.
    pub fn paramEnd(self: State, bytes: []const u8) usize {
        if (self != .csi_param and self != .dcs_param) {
            std.debug.panic("paramEnd called in {t}", .{self});
        }

        if (self == .csi_param) {
            return scanUntil(bytes, self, csiParamStopVector, csiParamContinues);
        }

        return scanUntil(bytes, self, dcsParamStopVector, dcsParamContinues);
    }
};

pub const Action = enum(u8) {
    none = 0,
    print,
    execute,
    ignore,
    clear,
    collect,
    param,
    esc_dispatch,
    csi_dispatch,
    hook,
    put,
    unhook,
    osc_start,
    osc_put,
    osc_end,
};

const Entry = extern struct {
    action: Action,
    next: State,
    exit: Action,
    entry: Action,
};

const entries: [State.count][256]Entry = createEntries();

fn createEntries() [State.count][256]Entry {
    @setEvalBranchQuota(10_000);

    const state_count = State.count;
    var t: [state_count][256]Entry = undefined;

    const exit_action: [State.count]Action = blk: {
        var a: [State.count]Action = @splat(Action.none);
        a[@intFromEnum(State.osc_string)] = .osc_end;
        a[@intFromEnum(State.dcs_passthrough)] = .unhook;
        break :blk a;
    };

    const entry_action: [State.count]Action = blk: {
        var a: [State.count]Action = @splat(Action.none);
        a[@intFromEnum(State.escape)] = .clear;
        a[@intFromEnum(State.csi_entry)] = .clear;
        a[@intFromEnum(State.dcs_entry)] = .clear;
        a[@intFromEnum(State.osc_string)] = .osc_start;
        a[@intFromEnum(State.dcs_passthrough)] = .hook;
        break :blk a;
    };

    // Default: stay in current state, no action
    for (0..state_count) |s| {
        @memset(t[s][0..], Entry{
            .action = .none,
            .exit = exit_action[s],
            .entry = entry_action[s],
            .next = @enumFromInt(s),
        });
        // Don't mark seen[] here, defaults don't count as "set".
    }

    // Tracks which (state, byte) pairs have been explicitly set
    const checker = struct {
        seen: [state_count][256]bool = @splat(@splat(false)),
        const Self = @This();

        fn set(
            self: *Self,
            table: *[state_count][256]Entry,
            state: State,
            byte: u8,
            action: Action,
            next: State,
        ) void {
            const si: u8 = @intFromEnum(state);
            if (self.seen[si][byte]) {
                @compileError("duplicate: table entry already exist.");
            }
            self.seen[si][byte] = true;
            table[si][byte].action = action;
            table[si][byte].next = next;
        }

        fn sets(
            self: *Self,
            table: *[state_count][256]Entry,
            state: State,
            from: u8,
            to: u8,
            action: Action,
            next: State,
        ) void {
            var b: u9 = from;
            while (b <= to) : (b += 1) {
                self.set(table, state, @intCast(b), action, next);
            }
        }
    };

    var check: checker = .{};

    // GROUND
    // zig fmt: off
    check.sets(&t, .ground, 0x00, 0x17, .execute, .ground);
    check.set(&t,  .ground, 0x19,       .execute, .ground);
    check.sets(&t, .ground, 0x1C, 0x1F, .execute, .ground);
    check.sets(&t, .ground, 0x20, 0x7E, .print,   .ground);
    check.set(&t,  .ground, 0x7F,       .ignore,  .ground);
    check.sets(&t, .ground, 0xA0, 0xFF, .print,   .ground);
    // zig fmt: on

    // ESCAPE
    // zig fmt: off
    check.sets(&t, .escape, 0x00, 0x17, .execute,      .escape);
    check.set(&t,  .escape, 0x19,       .execute,      .escape);
    check.sets(&t, .escape, 0x1C, 0x1F, .execute,      .escape);
    check.set(&t,  .escape, 0x7F,       .ignore,       .escape);
    check.sets(&t, .escape, 0x20, 0x2F, .collect,      .escape_intermediate);
    check.sets(&t, .escape, 0x30, 0x4F, .esc_dispatch, .ground);
    check.sets(&t, .escape, 0x51, 0x57, .esc_dispatch, .ground);
    check.set(&t,  .escape, 0x59,       .esc_dispatch, .ground);
    check.set(&t,  .escape, 0x5A,       .esc_dispatch, .ground);
    check.set(&t,  .escape, 0x5C,       .esc_dispatch, .ground);
    check.set(&t,  .escape, 0x5B,       .none,         .csi_entry);
    check.set(&t,  .escape, 0x5D,       .none,         .osc_string);
    check.set(&t,  .escape, 0x50,       .none,         .dcs_entry);
    check.sets(&t, .escape, 0x60, 0x7E, .esc_dispatch, .ground);
    check.set(&t,  .escape, 0x58,       .none,         .sos_pm_apc_string);
    check.set(&t,  .escape, 0x5E,       .none,         .sos_pm_apc_string);
    check.set(&t,  .escape, 0x5F,       .none,         .sos_pm_apc_string);
    // zig fmt: on

    // ESCAPE INTERMEDIATE
    // zig fmt: off
    check.sets(&t, .escape_intermediate, 0x00, 0x17, .execute,      .escape_intermediate);
    check.set(&t,  .escape_intermediate, 0x19,       .execute,      .escape_intermediate);
    check.sets(&t, .escape_intermediate, 0x1C, 0x1F, .execute,      .escape_intermediate);
    check.set(&t,  .escape_intermediate, 0x7F,       .ignore,       .escape_intermediate);
    check.sets(&t, .escape_intermediate, 0x20, 0x2F, .collect,      .escape_intermediate);
    check.sets(&t, .escape_intermediate, 0x30, 0x7E, .esc_dispatch, .ground);
    // zig fmt: on

    // CSI ENTRY
    // zig fmt: off
    check.sets(&t, .csi_entry, 0x00, 0x17, .execute,      .csi_entry);
    check.set(&t,  .csi_entry, 0x19,       .execute,      .csi_entry);
    check.sets(&t, .csi_entry, 0x1C, 0x1F, .execute,      .csi_entry);
    check.set(&t,  .csi_entry, 0x7F,       .ignore,       .csi_entry);
    check.sets(&t, .csi_entry, 0x20, 0x2F, .collect,      .csi_intermediate);
    check.set(&t,  .csi_entry, 0x3A,       .param,        .csi_param);
    check.sets(&t, .csi_entry, 0x30, 0x39, .param,        .csi_param);
    check.set(&t,  .csi_entry, 0x3B,       .param,        .csi_param);
    check.sets(&t, .csi_entry, 0x3C, 0x3F, .collect,      .csi_param);
    check.sets(&t, .csi_entry, 0x40, 0x7E, .csi_dispatch, .ground);
    // zig fmt: on

    // CSI PARAM
    // zig fmt: off
    check.sets(&t, .csi_param, 0x00, 0x17, .execute,      .csi_param);
    check.set(&t,  .csi_param, 0x19,       .execute,      .csi_param);
    check.sets(&t, .csi_param, 0x1C, 0x1F, .execute,      .csi_param);
    check.set(&t,  .csi_param, 0x7F,       .ignore,       .csi_param);
    check.sets(&t, .csi_param, 0x30, 0x39, .param,        .csi_param);
    check.set(&t,  .csi_param, 0x3B,       .param,        .csi_param);
    check.set(&t,  .csi_param, 0x3A,       .param,        .csi_param);
    check.sets(&t, .csi_param, 0x3C, 0x3F, .none,         .csi_ignore);
    check.sets(&t, .csi_param, 0x20, 0x2F, .collect,      .csi_intermediate);
    check.sets(&t, .csi_param, 0x40, 0x7E, .csi_dispatch, .ground);
    // zig fmt: on

    // CSI INTERMEDIATE
    // zig fmt: off
    check.sets(&t, .csi_intermediate, 0x00, 0x17, .execute,      .csi_intermediate);
    check.set(&t,  .csi_intermediate, 0x19,       .execute,      .csi_intermediate);
    check.sets(&t, .csi_intermediate, 0x1C, 0x1F, .execute,      .csi_intermediate);
    check.set(&t,  .csi_intermediate, 0x7F,       .ignore,       .csi_intermediate);
    check.sets(&t, .csi_intermediate, 0x20, 0x2F, .collect,      .csi_intermediate);
    check.sets(&t, .csi_intermediate, 0x30, 0x3F, .none,         .csi_ignore);
    check.sets(&t, .csi_intermediate, 0x40, 0x7E, .csi_dispatch, .ground);
    // zig fmt: on

    // CSI IGNORE
    // zig fmt: off
    check.sets(&t, .csi_ignore, 0x00, 0x17, .execute, .csi_ignore);
    check.set(&t,  .csi_ignore, 0x19,       .execute, .csi_ignore);
    check.sets(&t, .csi_ignore, 0x1C, 0x1F, .execute, .csi_ignore);
    check.set(&t,  .csi_ignore, 0x7F,       .ignore,  .csi_ignore);
    check.sets(&t, .csi_ignore, 0x20, 0x3F, .none,    .csi_ignore);
    check.sets(&t, .csi_ignore, 0x40, 0x7E, .none,    .ground);
    // zig fmt: on

    // DCS ENTRY
    // Entered via ESC P (0x50) or C1 (0x90)
    // zig fmt: off
    check.sets(&t, .dcs_entry, 0x00, 0x17, .ignore,  .dcs_entry);
    check.set(&t,  .dcs_entry, 0x19,       .ignore,  .dcs_entry);
    check.sets(&t, .dcs_entry, 0x1C, 0x1F, .ignore,  .dcs_entry);
    check.set(&t,  .dcs_entry, 0x7F,       .ignore,  .dcs_entry);
    check.sets(&t, .dcs_entry, 0x20, 0x2F, .collect, .dcs_intermediate);
    check.set(&t,  .dcs_entry, 0x3A,       .none,    .dcs_ignore);
    check.sets(&t, .dcs_entry, 0x30, 0x39, .param,   .dcs_param);
    check.set(&t,  .dcs_entry, 0x3B,       .param,   .dcs_param);
    check.sets(&t, .dcs_entry, 0x3C, 0x3F, .collect, .dcs_param);
    check.sets(&t, .dcs_entry, 0x40, 0x7E, .none,    .dcs_passthrough);
    // zig fmt: on

    // DCS PARAM
    // zig fmt: off
    check.sets(&t, .dcs_param, 0x00, 0x17, .ignore,  .dcs_param);
    check.set(&t,  .dcs_param, 0x19,       .ignore,  .dcs_param);
    check.sets(&t, .dcs_param, 0x1C, 0x1F, .ignore,  .dcs_param);
    check.set(&t,  .dcs_param, 0x7F,       .ignore,  .dcs_param);
    check.sets(&t, .dcs_param, 0x30, 0x39, .param,   .dcs_param);
    check.set(&t,  .dcs_param, 0x3B,       .param,   .dcs_param);
    check.set(&t,  .dcs_param, 0x3A,       .none,    .dcs_ignore);
    check.sets(&t, .dcs_param, 0x3C, 0x3F, .none,    .dcs_ignore);
    check.sets(&t, .dcs_param, 0x20, 0x2F, .collect, .dcs_intermediate);
    check.sets(&t, .dcs_param, 0x40, 0x7E, .none,    .dcs_passthrough);
    // zig fmt: on

    // DCS INTERMEDIATE
    // zig fmt: off
    check.sets(&t, .dcs_intermediate, 0x00, 0x17, .ignore,  .dcs_intermediate);
    check.set(&t,  .dcs_intermediate, 0x19,       .ignore,  .dcs_intermediate);
    check.sets(&t, .dcs_intermediate, 0x1C, 0x1F, .ignore,  .dcs_intermediate);
    check.set(&t,  .dcs_intermediate, 0x7F,       .ignore,  .dcs_intermediate);
    check.sets(&t, .dcs_intermediate, 0x20, 0x2F, .collect, .dcs_intermediate);
    check.sets(&t, .dcs_intermediate, 0x30, 0x3F, .none,    .dcs_ignore);
    check.sets(&t, .dcs_intermediate, 0x40, 0x7E, .none,    .dcs_passthrough);
    // zig fmt: on

    // DCS PASSTHROUGH
    // the data stream, fires put for each byte (hook and unhook).
    // zig fmt: off
    check.sets(&t, .dcs_passthrough, 0x00, 0x17, .put,    .dcs_passthrough);
    check.set(&t,  .dcs_passthrough, 0x19,       .put,    .dcs_passthrough);
    check.sets(&t, .dcs_passthrough, 0x1C, 0x1F, .put,    .dcs_passthrough);
    check.sets(&t, .dcs_passthrough, 0x20, 0x7E, .put,    .dcs_passthrough);
    check.set(&t,  .dcs_passthrough, 0x7F,       .ignore, .dcs_passthrough);
    // binary payloads (Sixel/Kitty) need high bytes  
    check.sets(&t, .dcs_passthrough, 0xA0, 0xFF, .put, .dcs_passthrough);
    // 0x9C (ST) terminates dcs_passthrough via the anywhere loop to ground
    // zig fmt: on

    // DCS IGNORE
    // malformed DCS, swallow untill ST
    // zig fmt: off
    check.sets(&t, .dcs_ignore, 0x00, 0x17, .ignore, .dcs_ignore);
    check.set(&t,  .dcs_ignore, 0x19,       .ignore, .dcs_ignore);
    check.sets(&t, .dcs_ignore, 0x1C, 0x1F, .ignore, .dcs_ignore);
    check.sets(&t, .dcs_ignore, 0x20, 0x7F, .ignore, .dcs_ignore);
    // 0x9C (ST) terminates dcs_ignore via the anywhere loop to ground
    // zig fmt: on

    // OSC STRING
    // zig fmt: off
    check.sets(&t, .osc_string, 0x00, 0x06, .ignore,  .osc_string); // C0 before BEL
    check.set(&t,  .osc_string, 0x07,       .none,    .ground);
    check.sets(&t, .osc_string, 0x08, 0x17, .ignore,  .osc_string); // C0 after BEL
    check.set(&t,  .osc_string, 0x19,       .ignore,  .osc_string);
    check.sets(&t, .osc_string, 0x1C, 0x1F, .ignore,  .osc_string);
    check.sets(&t, .osc_string, 0x20, 0x7F, .osc_put, .osc_string); // data bytes (incl. 0x7F)
    check.sets(&t, .osc_string, 0xA0, 0xFF, .osc_put, .osc_string);
    // zig fmt: on

    // SOS_PM_APC_STRING
    // black hole, everything ignored until ST
    // zig fmt: off
    check.sets(&t, .sos_pm_apc_string, 0x00, 0x17, .ignore, .sos_pm_apc_string);
    check.set(&t,  .sos_pm_apc_string, 0x19,       .ignore, .sos_pm_apc_string);
    check.sets(&t, .sos_pm_apc_string, 0x1C, 0x1F, .ignore, .sos_pm_apc_string);
    check.sets(&t, .sos_pm_apc_string, 0x20, 0x7F, .ignore, .sos_pm_apc_string);
    // NOTE! explicit swallow for now (adjust if we collect these too for future)
    check.sets(&t, .sos_pm_apc_string, 0xA0, 0xFF, .ignore, .sos_pm_apc_string);
    // zig fmt: on

    // ANYWHERE TRANSITIONS (override everything above)
    for (0..state_count) |s| {
        const state: State = @enumFromInt(s);

        // zig fmt: off
        check.set(&t, state, 0x18, .execute, .ground);              // CAN  
        check.set(&t, state, 0x1A, .execute, .ground);              // SUB  
        check.set(&t, state, 0x1B, .none,    .escape);              // ESC  
        check.set(&t, state, 0x9C, .none,    .ground);              // ST  
        check.set(&t, state, 0x9B, .none,    .csi_entry);  
        check.set(&t, state, 0x90, .none,    .dcs_entry);  
        check.set(&t, state, 0x98, .none,    .sos_pm_apc_string);  
        check.set(&t, state, 0x9E, .none,    .sos_pm_apc_string);  
        check.set(&t, state, 0x9F, .none,    .sos_pm_apc_string);  
        check.set(&t, state, 0x99, .execute, .ground);  
        check.set(&t, state, 0x9A, .execute, .ground);  

        check.sets(&t, state, 0x80, 0x8F, .execute, .ground);  
        check.sets(&t, state, 0x91, 0x97, .execute, .ground);  
        // zig fmt: on

        // Every transition into .osc_string via 0x9D, whether from .osc_string
        // itself (abandon + restart) or from any other state (fresh start)
        // needs the same two effects: finalize whatever was in flight, then
        // reset osc_len. For non-osc_string source states, oscEnd() reading
        // osc_len==0 must be a safe/cheap no-op (verify this in oscEnd()'s
        // ';' == null branch: std.fmt.parseInt on an empty slice should
        // return an error, caught and discarded.
        check.set(&t, state, 0x9D, .none, .osc_string);
        // t[@intFromEnum(State.osc_string)][0x9D].force_transition = true;
    }

    // Backfill: exit action is a pure function of the source state,
    // entry action a pure function of the successor state.
    for (0..state_count) |s| {
        const source: State = @enumFromInt(s);
        for (0..256) |b| {
            t[s][b].exit = exit_action[@intFromEnum(source)];
            t[s][b].entry = entry_action[@intFromEnum(t[s][b].next)];
        }
    }

    return t;
}

inline fn forcedTransition(state: State, byte: u8) bool {
    // Derived contents: exactly {osc_string, 0x9D}. Pinned by the
    // comptime assert below against the builder's bitset.
    return state == .osc_string and byte == 0x9D;
}

comptime {
    @setEvalBranchQuota(4 << 10);

    // Bits set on cells that force the transition path even when e.next == self.state.
    const forced_transitions: [State.count]u256 = blk: {
        var sets: [State.count]u256 = @splat(0);
        sets[@intFromEnum(State.osc_string)] |= @as(u256, 1) << 0x9D;
        break :blk sets;
    };

    for (0..State.count) |s| {
        for (0..256) |b| {
            const bits = (forced_transitions[s] >> @intCast(b)) & 1 != 0;
            const fast = @as(State, @enumFromInt(s)) == .osc_string and b == 0x9D;
            if (bits != fast) @compileError("forcedTransition fast path drifted");
        }
    }
}

comptime {
    @setEvalBranchQuota(3 << 10);

    for ([_]State{ .osc_string, .dcs_passthrough, .sos_pm_apc_string }) |s| {
        for (0..256) |b| {
            const byte: u8 = @intCast(b);
            const e = entries[@intFromEnum(s)][byte];

            // isPayload must match the table's definition of byte consumed
            // while staying in the string state run.
            const consumed: bool = switch (s) {
                .osc_string => e.action == .osc_put,
                .dcs_passthrough => e.action == .put,
                .sos_pm_apc_string => e.action == .ignore,
                else => unreachable,
            };

            const table_ok = e.next == s and !forcedTransition(s, byte) and consumed;
            const scalar_ok = s.isPayload(byte);

            if (table_ok != scalar_ok) {
                @compileError("payloadEnd predicate drifted from entries");
            }

            // The SIMD stop vector must agree with isPayload
            // stop exactly when the byte is payload.
            const unit: @Vector(1, u8) = @splat(byte);
            const payload_vec_stop = switch (s) {
                .dcs_passthrough => State.dcsStopVector(unit)[0],
                .sos_pm_apc_string => State.sosStopVector(unit)[0],
                .osc_string => State.oscStopVector(unit)[0],
                else => unreachable,
            };

            if (payload_vec_stop == scalar_ok) {
                @compileError("stopVector drifted from isPayload");
            }
        }
    }
}

comptime {
    @setEvalBranchQuota(4 << 10);

    for ([_]State{ .csi_param, .dcs_param }) |s| {
        for (0..256) |b| {
            const byte: u8 = @intCast(b);
            const e = entries[@intFromEnum(s)][byte];
            const table_ok = e.action == .param and e.next == s and !forcedTransition(s, byte);

            // Scalar continues-function must match the table.
            const scalar_ok = if (s == .csi_param)
                State.csiParamContinues(s, byte)
            else
                State.dcsParamContinues(s, byte);

            if (table_ok != scalar_ok) {
                @compileError("param scalar predicate drifted from entries");
            }
        }
    }

    // Pin the SIMD param predicates to the scalar ones: paramEnd's
    // stop-vector mask must agree with *continues() on every bytes.
    // Probing with a 1-byte chunk exercises the same vector expressions
    // the Chunk-width path runs, the predicates are width-agnostic.

    for ([_]State{ .csi_param, .dcs_param }) |s| {
        for (0..256) |b| {
            const byte: u8 = @intCast(b);
            const unit: @Vector(1, u8) = @splat(byte);
            const vec_stop = if (s == .csi_param)
                State.csiParamStopVector(unit)[0]
            else
                State.dcsParamStopVector(unit)[0];

            const scalar_ok = if (s == .csi_param)
                State.csiParamContinues(s, byte)
            else
                State.dcsParamContinues(s, byte);

            if (vec_stop == scalar_ok) {
                @compileError("paramEnd SIMD predicate drifted from scalar");
            }
        }
    }
}

comptime {
    // The ground printable fast path is a subset of the table's
    // printable set: every byte it batches must be .print + stay,
    // but the table may legitimately cover bytes the predicate
    // leaves to step(), 0xA0...0xFF (latin1 printables, unreachable
    // in utf8 sessions) being the deliberate case.
    for (0..256) |b| {
        const byte: u8 = @intCast(b);
        const e = entries[@intFromEnum(State.ground)][byte];
        const table_ok = e.action == .print and e.next == .ground and !forcedTransition(.ground, byte);
        const simd_ok = (b >= 0x20 and b <= 0x7E);
        if (simd_ok and !table_ok)
            @compileError("ground printable run predicate outside table's .print set");
    }
}

comptime {
    @setEvalBranchQuota(36 << 10);

    const Recorder = struct {
        log: [8]u32 = @splat(0),
        len: usize = 0,

        inline fn rec(self: *@This(), tag: u32, byte: u8) void {
            self.log[self.len] = (tag << 8) | byte;
            self.len += 1;
        }

        // One method per handler API used by dispatch();
        // encode a distinct tag per action.
        pub fn printByte(s: *@This(), b: u8) void {
            s.rec(1, b);
        }
        pub fn dcsPut(s: *@This(), b: u8) void {
            s.rec(2, b);
        }
        pub fn execute(s: *@This(), b: u8) void {
            s.rec(3, b);
        }
        pub fn oscPut(s: *@This(), b: u8) void {
            s.rec(4, b);
        }
        pub fn oscEnd(s: *@This()) void {
            s.rec(5, 0);
        }
        pub fn oscStart(s: *@This()) void {
            s.rec(6, 0);
        }
        pub fn unhook(s: *@This()) void {
            s.rec(7, 0);
        }
        pub fn escDispatch(s: *@This(), b: u8, i: []const u8) void {
            _ = i;
            s.rec(8, b);
        }
        pub fn hook(s: *@This(), b: u8, i: []const u8, p: []const Parameter) void {
            _ = i;
            _ = p;
            s.rec(9, b);
        }
        pub fn csiDispatch(s: *@This(), b: u8, i: []const u8, p: []const Parameter) void {
            _ = i;
            _ = p;
            s.rec(10, b);
        }
        pub fn print(s: *@This(), bytes: []const u8) void {
            for (bytes) |b| s.rec(1, b);
        }
        pub fn oscPutSlice(s: *@This(), bytes: []const u8) void {
            for (bytes) |b| s.rec(4, b);
        }
        pub fn dcsPutSlice(s: *@This(), bytes: []const u8) void {
            for (bytes) |b| s.rec(2, b);
        }
    };

    const P = Parser(Recorder, .{});

    for (0..State.count) |s| {
        for (0..256) |b| {
            const e = entries[s][b];
            const st: State = @enumFromInt(s);
            // Only stay cells: the residue arm's domain.
            if (e.next != st or forcedTransition(st, @intCast(b))) continue;

            var p1 = P{};
            var r1 = Recorder{};
            p1.state = st;
            p1.step(&r1, @intCast(b)); // full path

            var p2 = P{};
            var r2 = Recorder{};
            p2.state = st;
            p2.dispatch(&r2, e.action, @intCast(b)); // residue arm

            const logs_match = r1.len == r2.len and
                std.mem.eql(u32, r1.log[0..r1.len], r2.log[0..r2.len]);

            const state_match = p1.state == p2.state and
                p1.param_len == p2.param_len and
                p1.intermediate_len == p2.intermediate_len and
                std.mem.eql(Parameter, p1.getParams(), p2.getParams()) and
                std.mem.eql(u8, p1.getIntermediates(), p2.getIntermediates());

            if (!logs_match or !state_match) {
                @compileError("residue arm dispatch drifted from step()");
            }
        }
    }
}

pub const Parameter = packed struct(u16) {
    // The numeric value up to (0...32767).
    // sufficent for cursor positions, SGR codes, color values, etc.
    value: u15,
    separator: enum(u1) { sub_parameter, parameter },
    const Self = @This();

    pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Parameter\n", .{});
        try writer.print(".value={x}\n", .{self.value});
        try writer.print(".separator={}\n", .{self.separator});
    }

    pub const default: Self = .{
        .value = 0,
        .separator = .parameter,
    };
};

comptime {
    assert(@bitSizeOf(u16) == @bitSizeOf(Parameter));
    assert(@sizeOf(u16) == @sizeOf(Parameter));
}

pub const ParserOptions = struct {
    max_params: u8 = 16,
    max_intermediates: u8 = 2,
};

/// VT/ANSI escape sequence parser (DEC 8-bit control semantics).
///
/// Raw UTF-8 input must be decoded on upstream before feeding it to Parser.
pub fn Parser(comptime Handler: type, comptime options: ParserOptions) type {
    return struct {
        const max_params = options.max_params;
        const max_intermediates = options.max_intermediates;

        const Self = @This();

        state: State = .ground,

        params: [max_params]Parameter = @splat(Parameter.default),
        param_len: u8 = 0,

        intermediates: [max_intermediates]u8 = @splat(0),
        intermediate_len: u8 = 0,

        /// Feed bytes through the DEC-compatible state transition table (8-bit control semantics).
        ///
        /// Bytes (0x80...0x9F) are interpreted as C1 controls per the table, they abort
        /// string states, dispatch as commands, and are never treated as string payload
        /// or printable data.
        ///
        /// Terminial that supports for UTF-8 mode, callers must not pass raw multibyte
        /// input directly here. UTF-8 continuation bytes live in 0x80...0xBF and would
        /// be misinterpreted as C1 controls, which silently corrupting string state.
        /// UTF-8 input must be decoded upstream and routed per run: decoded text via feed(),
        /// string-payload runs via feedData() if necessary.
        pub fn feedBytes(self: *Self, h: *Handler, bytes: []const u8) void {
            var i: usize = 0;
            while (i < bytes.len) {

                // Fast path batch ASCII printable runs in ground state
                if (self.state == .ground) {
                    @branchHint(.likely);

                    const start = i;

                    if (std.simd.suggestVectorLength(u8)) |chunk_len| {
                        const Chunk = @Vector(chunk_len, u8);

                        // Printable run is [0x20, 0x7E], space included (it's .print in the table).
                        // Everything below 0x20 and DEL/C1/high bytes fall to step().
                        const base: Chunk = @splat(0x20);
                        const range: Chunk = @splat(0x7E - 0x20); // 0x5E

                        while (i + chunk_len <= bytes.len) {
                            const chunk: Chunk = bytes[i..][0..chunk_len].*;

                            // NOTE! using unsigned-wraparound range trick, anything < 0x20 wraps
                            // to huge value under -%, so a single ">" catches both tails of the
                            // original "chunk <= 0x20 | chunk >= 0x7F" check.
                            const not_printable = (chunk -% base) > range;

                            if (std.simd.firstTrue(not_printable)) |first| {
                                i += first;
                                break;
                            }
                            i += chunk_len;
                        } else {
                            // fell through the while without breaking the scan scalar tail
                            while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x7E) : (i += 1) {}
                        }
                    } else {
                        while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x7E) : (i += 1) {}
                    }

                    if (i > start) h.print(bytes[start..i]);
                    if (i >= bytes.len) break;
                }

                // Inside a string state, batch the pure payload prefix and skip
                // per-byte table lookups for it. payloadEnd stops at the first
                // terminator, which then goes through the normal step() path,
                // same contract feedStringRun already relies on.
                if (self.inStringState()) { // or the switch, if inStringState lives on Parser not State
                    const j = i + self.state.payloadEnd(bytes[i..]);
                    if (j > i) self.feedData(h, bytes[i..j]);
                    i = j;
                    if (i >= bytes.len) break;
                }

                // Param run batch: csi_param/dcs_param runs of [0x30,0x3F] skip the
                // table entirely. Every byte in the run maps to pushParam, digit
                // accumulation, ';' slot advance, ':' subparam marking with no
                // transition possible.
                if (self.inParamState()) {
                    const j = i + self.state.paramEnd(bytes[i..]);
                    if (j > i) {
                        for (bytes[i..j]) |b| self.pushParam(b);
                        i = j;
                        continue;
                    }
                }

                // Mixed byte residue: run length the stay in state tail so the
                // transition check is paid once per run, not once per byte.
                var j = i;
                while (j < bytes.len) : (j += 1) {
                    const e = entries[@intFromEnum(self.state)][bytes[j]];
                    if (e.next != self.state or forcedTransition(self.state, bytes[j])) break;
                    self.dispatch(h, e.action, bytes[j]);
                }

                if (j > i) {
                    i = j;
                    continue;
                }

                const byte = bytes[i];
                i += 1;

                self.step(h, byte);
            }
        }

        /// Feeds a contiguous payload span to the handler for the parser's current
        /// string state. It performs the bulk equivalent of the per byte `.osc_put`
        /// and `.put` actions. The parser must be in `.osc_string`, `.dcs_passthrough`,
        /// or `.sos_pm_apc_string`.
        ///
        /// The `bytes` must contain payload bytes only. The caller must split input at
        /// string terminators and aborting controls, then dispatch those controls separately.
        /// In 8-bit sessions, C1 controls must also be handled separately when they terminate
        /// or interrupt the string.
        ///
        /// This function does not inspect or filter `bytes`; the slice handlers receive
        /// the entire span. In UTF-8 sessions, bytes `>= 0x80` are payload data rather
        /// than C1 controls. Decode raw UTF-8 input upstream and identify control
        /// boundaries before calling this function.
        pub fn feedData(self: *Self, h: *Handler, bytes: []const u8) void {
            switch (self.state) {
                .osc_string => h.oscPutSlice(bytes),
                .dcs_passthrough => h.dcsPutSlice(bytes),
                .sos_pm_apc_string => {}, // swallowed
                else => std.debug.panic("feedData called in non string state: {t}", .{self.state}),
            }
        }

        /// True while the parser is consuming bytes as string payload rather than
        /// interpreting them; the states where feedData() applies. Centralised so
        /// adding a future string state can't silently miss a call site.
        pub fn inStringState(self: *Self) bool {
            return switch (self.state) {
                .osc_string, .dcs_passthrough, .sos_pm_apc_string => true,
                else => false,
            };
        }

        pub fn inParamState(self: *const Self) bool {
            return switch (self.state) {
                .csi_param, .dcs_param => true,
                else => false,
            };
        }

        inline fn step(self: *Self, h: *Handler, byte: u8) void {
            const e = entries[@intFromEnum(self.state)][byte];
            const prev_state = self.state;

            if (e.next != prev_state or forcedTransition(self.state, byte)) {
                self.dispatch(h, e.exit, byte);
                self.dispatch(h, e.action, byte);
                self.state = e.next;
                self.dispatch(h, e.entry, byte);
            } else {
                self.dispatch(h, e.action, byte);
            }
        }

        inline fn clear(self: *Self) void {
            self.param_len = 0;
            self.intermediate_len = 0;

            // No @memset needed: pushParam() always initializes params[0] on the
            // first digit and params[param_len-1] on each new separator before
            // any read via getParams() (which is bounded by param_len). Stale
            // slots beyond param_len are never observed.
            // @memset(&self.params, Parameter{ .value = 0, .separator = .parameter });
        }

        inline fn pushIntermediates(self: *Self, byte: u8) void {
            if (self.intermediate_len < max_intermediates) {
                self.intermediates[self.intermediate_len] = byte;
                self.intermediate_len += 1;
            }
        }

        inline fn pushParam(self: *Self, byte: u8) void {
            switch (byte) {
                ';', ':' => {
                    if (self.param_len < max_params - 1) {
                        self.param_len += 1;
                        // Initialize the new current slot (param_len-1)
                        self.params[self.param_len - 1] = .{
                            .value = 0,
                            .separator = if (byte == ':') .sub_parameter else .parameter,
                        };
                    }
                },
                else => { // digit
                    if (self.param_len == 0) {
                        self.param_len = 1;
                        self.params[0] = .{ .value = 0, .separator = .parameter };
                    }
                    if (self.param_len <= max_params - 1) { // only accumulate into valid slots
                        const i = self.param_len - 1;
                        self.params[i].value = self.params[i].value *% 10 +% (byte -% '0');
                    }
                },
            }
        }

        inline fn getIntermediates(self: *Self) []const u8 {
            return self.intermediates[0..self.intermediate_len];
        }

        inline fn getParams(self: *Self) []const Parameter {
            return self.params[0..self.param_len];
        }

        inline fn dispatch(self: *Self, handler: *Handler, action: Action, byte: u8) void {
            switch (action) {
                // zig fmt: off
                .none, .ignore => {},
                .clear         => self.clear(),
                .param         => self.pushParam(byte),
                .collect       => self.pushIntermediates(byte),
                .unhook        => handler.unhook(),
                .print         => handler.printByte(byte),
                .put           => handler.dcsPut(byte),
                .execute       => handler.execute(byte),
                .osc_end       => handler.oscEnd(),  
                .osc_start     => handler.oscStart(),  
                .osc_put       => handler.oscPut(byte),  
                .esc_dispatch  => handler.escDispatch(byte, self.getIntermediates()),
                .hook          => handler.hook(byte, self.getIntermediates(), self.getParams()),
                .csi_dispatch  => handler.csiDispatch(byte, self.getIntermediates(), self.getParams()),
                // zig fmt: on
            }
        }
    };
}

pub const NoopDispatcher = struct {
    checksum: u64 = 0,

    // no-op, doesn't touch checksum at all for the bulk print path.
    pub fn print(self: *@This(), bytes: []const u8) void {
        for (bytes) |b| self.checksum +%= @as(u64, b) *% 31;
    }

    // Everything else still accumulates, since these ARE called once per
    // byte already on the non fast path, so they don't change per-byte cost.
    pub fn printByte(self: *@This(), b: u8) void {
        self.checksum +%= b;
    }
    pub fn execute(self: *@This(), b: u8) void {
        self.checksum +%= b;
    }
    pub fn escDispatch(self: *@This(), final: u8, intermediates: []const u8) void {
        self.checksum +%= final;
        for (intermediates) |b| self.checksum +%= b;
    }
    pub fn csiDispatch(self: *@This(), final: u8, intermediates: []const u8, params: anytype) void {
        self.checksum +%= final;
        for (intermediates) |b| self.checksum +%= b;
        for (params) |p| self.checksum +%= p.value;
    }
    pub fn hook(self: *@This(), final: u8, intermediates: []const u8, params: anytype) void {
        self.checksum +%= final;
        for (intermediates) |b| self.checksum +%= b;
        for (params) |p| self.checksum +%= p.value;
    }
    pub fn dcsPut(self: *@This(), b: u8) void {
        self.checksum +%= b;
    }
    pub fn dcsPutSlice(self: *NoopDispatcher, bytes: []const u8) void {
        for (bytes) |b| self.checksum +%= @as(u64, b) *% 31;
    }
    pub fn unhook(_: *@This()) void {}
    pub fn oscStart(_: *@This()) void {}
    pub fn oscPut(self: *@This(), b: u8) void {
        self.checksum +%= b;
    }
    pub fn oscPutSlice(self: *NoopDispatcher, bytes: []const u8) void {
        for (bytes) |b| self.checksum +%= @as(u64, b) *% 31;
    }
    pub fn oscEnd(_: *@This()) void {}
};
