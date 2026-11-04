const std = @import("std");
const log = std.log.scoped(.vt_parser);

const assert = std.debug.assert;

/// State machine of the VT Parser.
///
/// The current state determines how the next input byte is interpreted.
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
    /// ESC seen inside an OSC string. The string is kept until the next
    /// byte: '\\' (ST) or BEL dispatches it, anything else drops it and
    /// runs as it would after a plain ESC, as xterm does.
    osc_escape,
    /// ESC seen inside a DCS data string. The string stays hooked until
    /// the next byte: '\\' (ST) unhooks it, anything else drops it
    /// without an unhook and runs as it would after a plain ESC, as
    /// xterm does. Unlike OSC, BEL does not end a DCS.
    dcs_escape,

    pub const count: usize = 16;

    /// Scans `bytes` from the beginning and returns the index of the
    /// first byte where the stops fires, or `bytes.len` if every continues it.
    ///
    /// `stopVector(chunk)` must return a mask where `true` marks a byte that
    /// ends the run.
    ///
    /// `continuesScalar(context, byte)` determines whether a byte continues
    /// the scan when checked scalar-wise; it should agree with the vector
    /// predicate.
    ///
    /// `context` is passed to `continuesScalar`.
    pub inline fn scanUntil(
        bytes: []const u8,
        context: anytype,
        comptime stopVector: anytype, // fn(Chunk) @Vector(N, bool)
        comptime continuesScalar: anytype, // fn(context, u8) bool
    ) usize {
        var i: usize = 0;

        if (std.simd.suggestVectorLength(u8)) |chunk_len| {
            const Chunk = @Vector(chunk_len, u8);
            const Mask = std.meta.Int(.unsigned, chunk_len);

            while (i + chunk_len <= bytes.len) : (i += chunk_len) {
                const chunk: Chunk = bytes[i..][0..chunk_len].*;
                const m: Mask = @bitCast(stopVector(chunk));
                if (m != 0) return i + @ctz(m);
            }

            // Overlapping tail load bytes before `i` are proven non-stop, so
            // re-scanning the overlap [bytes.len - chunk_len, i] cannot produce
            // a stop earlier than the true one in the tail.
            if (i < bytes.len and bytes.len >= chunk_len) {
                const at = bytes.len - chunk_len;
                const chunk: Chunk = bytes[at..][0..chunk_len].*;
                const m: Mask = @bitCast(stopVector(chunk));
                return if (m != 0) at + @ctz(m) else bytes.len;
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
        const c1 = (chunk -% @as(Chunk, @splat(0x80))) < @as(Chunk, @splat(0x20));

        return c0 | c1;
    }

    /// Returns the length of the leading payload run in `bytes` for `self`.
    ///
    /// For payload-string states, scanning stops before the first bytes that
    /// ends the run, or at `bytes.len` if no such byte is present.
    ///
    /// Returns `0` for states without payload scanning.
    /// This method does not change parser state or consume any bytes.
    pub inline fn payloadEnd(self: State, bytes: []const u8) usize {
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
        return byte >= 0x30 and byte <= 0x3B; // digits + ':' + ';'
    }

    inline fn dcsParamContinues(_: State, byte: u8) bool {
        return (byte >= 0x30 and byte <= 0x39) or byte == 0x3B; // digits + ';' only
    }

    /// Returns the length of the leading parameter run in `bytes`.
    ///
    /// Uses the parameter-byte rules for `.csi_param` or `.dcs_param`.
    /// Returns `bytes.len` if every byte continues the run.
    /// Panics if `self` is in any other state.
    pub inline fn paramEnd(self: State, bytes: []const u8) usize {
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
        a[@intFromEnum(State.osc_escape)] = .clear;
        a[@intFromEnum(State.dcs_escape)] = .clear;
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
    // malformed DCS, swallow until ST
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

    // Except: CAN and SUB cancel an OSC or DCS string, as xterm does
    // (sos_table CAN/SUB reset the parser and drop the string), so
    // osc_end and unhook must not dispatch it.
    for ([_]State{ .osc_string, .dcs_passthrough }) |s| {
        for ([_]u8{ 0x18, 0x1A }) |b| t[@intFromEnum(s)][b].exit = .none;
    }

    // Except: ESC inside an OSC string does not end it. xterm (charproc.c,
    // sos_table) moves to esc_table and keeps the string; only ESC \\
    // (CASE_ST) dispatches it, and any other escape abandons it. So
    // osc_escape is the escape row with the string still pending.
    {
        const osc: u8 = @intFromEnum(State.osc_string);
        const esc: u8 = @intFromEnum(State.osc_escape);
        t[osc][0x1B] = .{
            .action = .none,
            .next = .osc_escape,
            .exit = .none,
            .entry = entry_action[esc],
        };
        for (0..256) |b| {
            var e = t[@intFromEnum(State.escape)][b];
            if (e.next == .escape) {
                e.next = .osc_escape;
                e.entry = entry_action[esc];
            }
            t[esc][b] = e;
        }
        // ESC \\ is ST. BEL still ends it too: xterm's CASE_BELL checks
        // string_mode, which ESC leaves set.
        for ([_]u8{ '\\', 0x07 }) |b| t[esc][b] = .{
            .action = .none,
            .next = .ground,
            .exit = .osc_end,
            .entry = entry_action[@intFromEnum(State.ground)],
        };
    }

    // Except: ESC inside a DCS data string does not end it either. xterm
    // keeps the string across ESC exactly as for OSC; ESC \\ (CASE_ST)
    // runs do_dcs and any other escape abandons it. So dcs_escape is
    // the escape row with the string still hooked. BEL is not special:
    // CASE_BELL only ends a string in OSC mode, so here it rings the
    // bell (execute) and stays in dcs_escape, as the escape row does.
    //
    // Only dcs_passthrough needs this. ESC in dcs_entry, dcs_param,
    // dcs_intermediate or dcs_ignore happens before hook, so there is
    // nothing to keep and the plain escape row already matches xterm.
    {
        const dcs: u8 = @intFromEnum(State.dcs_passthrough);
        const esc: u8 = @intFromEnum(State.dcs_escape);
        t[dcs][0x1B] = .{
            .action = .none,
            .next = .dcs_escape,
            .exit = .none,
            .entry = entry_action[esc],
        };
        for (0..256) |b| {
            var e = t[@intFromEnum(State.escape)][b];
            if (e.next == .escape) {
                e.next = .dcs_escape;
                e.entry = entry_action[esc];
            }
            t[esc][b] = e;
        }
        t[esc]['\\'] = .{
            .action = .none,
            .next = .ground,
            .exit = .unhook,
            .entry = entry_action[@intFromEnum(State.ground)],
        };
    }

    return t;
}

inline fn forcedTransition(state: State, byte: u8) bool {
    // Derived contents: exactly {osc_string, 0x9D}. Pinned by the
    // comptime assert below against the builder's bitset.
    return state == .osc_string and byte == 0x9D;
}

comptime {
    // One branch per (state, byte) cell plus the outer loop.
    @setEvalBranchQuota((State.count + 1) * 256);

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

    for ([_]State{
        .csi_entry,
        .csi_param,
        .dcs_entry,
        .dcs_param,
    }) |s| {
        for (0..256) |b| {
            const byte: u8 = @intCast(b);
            const e = entries[@intFromEnum(s)][byte];
            // A byte is "param-like" or this state if the table keeps it
            // in-state as .param with no forced transition.
            const table_ok = e.action == .param and e.next == s and !forcedTransition(s, byte);

            // entry states have no continues-predicate; skip the scalar check
            // for them. csi_param/dcs_param must match the table byte-for-byte.
            if (s == .csi_param) {
                if (table_ok != State.csiParamContinues(s, byte)) {
                    @compileError("csiParamContinues drifted from entries");
                }
            }

            if (s == .dcs_param) {
                if (table_ok != State.dcsParamContinues(s, byte)) {
                    @compileError("dcsParamContinues drifted from entries");
                }
            }

            // SIMD predicate agrees with scalar at width 1 (width-agnostic per-lane
            // comparisons make wider lanes equivalent).
            const unit: @Vector(1, u8) = @splat(byte);
            if (s == .csi_param or s == .dcs_param) {
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

    // feedCsi's param-marker shortcut: safe only while these rows are
    // pure csi_ignore with no side effects.
    for ([_]State{ .csi_param, .csi_intermediate, .csi_ignore }) |s| {
        for (0x3C..0x40) |b| {
            const e = entries[@intFromEnum(s)][@intCast(b)];
            if (e.next != .csi_ignore or e.exit != .none or e.action != .none or e.entry != .none)
                @compileError("csi_ignore fast-path no longer matches entries");
        }
    }

    // Separately: markers in csi_entry must remain .collect into csi_param;
    // feedCsi pushes marker_at via pushIntermediates, mirroring this row.
    for (0x3C..0x40) |b| {
        const e = entries[@intFromEnum(State.csi_entry)][@intCast(b)];
        if (e.next != .csi_param or e.exit != .none or e.action != .collect)
            @compileError("csi_entry marker row drifted — feedCsi's marker_at path no longer matches");
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
        if (simd_ok and !table_ok) {
            @compileError("ground printable run predicate outside table's .print set");
        }
    }
}

comptime {
    @setEvalBranchQuota(128 << 10);

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

comptime {
    for (0..256) |b| {
        const octet: u64 = @as(u64, b) *% 0x0101010101010101; // broadcast
        const lo = octet -% 0x3030303030303030; // wraps (high nibble set) iff b < 0x30
        const hi = octet -% 0x3A3A3A3A3A3A3A3A; // wraps iff b <= 0x39
        const swar =
            (lo & 0xF0F0F0F0F0F0F0F0) == 0 and
            (hi & 0x8080808080808080) == 0x8080808080808080;

        const scalar = b >= '0' and b <= '9';

        if (swar != scalar) {
            @compileError("SWAR isdigit mask drifted from scalar predicate");
        }
    }
}

comptime {
    for (0..256) |b| {
        if (!continuesPrintableScalar({}, @intCast(b))) continue;
        const e = entries[@intFromEnum(State.ground)][b];
        // Bytes that are in the run must be print/stay-in-ground in the table.
        // (0x7F is allowed to be print in the table but excluded from the run.)
        if (e.next != .ground or e.action != .print or e.exit != .none or e.entry != .none) {
            @compileError(std.fmt.comptimePrint("print run includes 0x{x}, table disagrees", .{b}));
        }
    }
}

fn stopPrintableVector(chunk: anytype) @Vector(@typeInfo(@TypeOf(chunk)).vector.len, bool) {
    const Chunk = @TypeOf(chunk);
    const min: Chunk = @splat(0x20);
    const range: Chunk = @splat(0x7E -% 0x20);

    // True for bytes outside printable ASCII (0x20–0x7E).
    return (chunk -% min) > range;
}

fn continuesPrintableScalar(_: void, byte: u8) bool {
    return byte >= 0x20 and byte <= 0x7E;
}

pub const Parameter = packed struct(u16) {
    const Self = @This();

    // The numeric value up to (0...32767).
    // sufficent for cursor positions, SGR codes, color values, etc.
    value: u15,
    separator: enum(u1) { sub_parameter, parameter },

    pub const Value = @TypeOf(default.value);

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

comptime {
    for (0..0x20) |b| {
        if (b == 0x1B) continue;
        const e = entries[@intFromEnum(State.ground)][b];
        if (e.action != .execute or e.next != .ground or
            e.exit != .none or e.entry != .none or
            forcedTransition(.ground, @intCast(b)))
        {
            @compileError(std.fmt.comptimePrint(
                "ground 0x{x} is not a plain execute; direct-execute path is invalid",
                .{b},
            ));
        }
    }
}

pub const ParserOptions = struct {
    max_params: u8 = 32,
    max_intermediates: u8 = 2,
};

/// VT/ANSI escape sequence parser (DEC 8-bit control semantics).
///
/// Raw UTF-8 input must be decoded on upstream before feeding it to Parser.
pub fn Parser(comptime Handler: type, comptime options: ParserOptions) type {
    const max_params = options.max_params;
    const max_intermediates = options.max_intermediates;

    comptime {
        // param_len and intermediate_len are u8.
        if (max_params > 255) {
            @compileError("max_params must be <= 255 (param_len is u8)");
        }
        if (max_intermediates > 255) {
            @compileError("max_intermediates must be <= 255 (intermediate_len is u8)");
        }

        // max_params == 0 leaves no room for even one slot; == 1 makes
        // every separator input degenerate to overflow. Reject both.
        if (max_params < 2) {
            @compileError("max_params must be >= 2 (leading separator opens slot 0, then the separator's slot)");
        }

        // Same reasoning: intermediates need at least
        // one slot to be representable at all.
        if (max_intermediates < 1) {
            @compileError("max_intermediates must be >= 1");
        }
    }

    return struct {
        const Self = @This();

        state: State = .ground,

        params: [max_params]Parameter = @splat(Parameter.default),
        param_len: u8 = 0,

        intermediates: [max_intermediates]u8 = @splat(0),
        intermediate_len: u8 = 0,

        /// An internal flag set when a separator cannot open a slot at the parameter
        /// limit. Remaining parameter bytes are consumed without modifying the stored
        /// prefix, so dropped digits cannot alter its last slot. Dispatch exposes the
        /// retained prefix through `getParams()`; truncation is intentional.
        ///
        /// Cleared by `reset()` on sequence entry.
        params_overflow: bool = false,

        /// Feeds `bytes` through the DEC 8-bit state machine, calling `Handler`
        /// methods in stream order.
        ///
        /// Parser state persists across calls, so a sequence may be split at any byte
        /// boundary. Behavior is identical to feeding each byte through the transition
        /// table individually; the fast paths below only change cost, not output.
        ///
        /// `0x80..0x9F` are C1 controls. UTF-8 must be decoded upstream.
        /// Slices passed to the Handler are valid only for the duration of the call.
        pub fn feedBytes(self: *Self, h: *Handler, bytes: []const u8) void {
            var i: usize = 0;
            while (i < bytes.len) {
                switch (self.state) {
                    .ground => {
                        @branchHint(.likely);

                        i = self.feedPrintRun(h, bytes, i);
                        if (i >= bytes.len) break;

                        // Fused CSI sequence a complete `ESC [ ... final` inside the buffer.
                        // null means incomplete or non-plain CSI, so step() handles ESC.
                        // if (i + 1 < bytes.len and bytes[i] == 0x1B and bytes[i + 1] == '[') {
                        //     if (self.feedCsi(h, bytes, i)) |next| {
                        //         i = next;
                        //         continue;
                        //     }
                        // }
                        //

                        if (bytes[i] == 0x1B) {
                            if (i + 1 < bytes.len and bytes[i + 1] == '[') {
                                if (self.feedCsi(h, bytes, i)) |next| {
                                    i = next;
                                    continue;
                                }
                            }
                            // ESC needs a real transition (clear + enter escape): fall to step().
                        } else if (bytes[i] < 0x20) {
                            h.execute(bytes[i]); // plain C0 in ground: no transition, no exit/entry action
                            i += 1;
                            continue;
                        }

                        // Exactly one control byte (C0, DEL, C1, ESC), then back to scan.
                        self.step(h, bytes[i]);
                        i += 1;
                        continue;
                    },

                    .osc_string, .sos_pm_apc_string, .dcs_passthrough => {
                        // Batch the payload prefix up to the first terminator; the
                        // terminator itself falls through to residue or step handling.
                        const end = i + self.state.payloadEnd(bytes[i..]);
                        if (end > i) self.feedData(h, bytes[i..end]);
                        i = end;
                        if (i >= bytes.len) break;
                        // fall through to residue for the terminator byte
                    },

                    inline .csi_param, .dcs_param => |st| {
                        const j = self.feedParamRun(bytes, i, st == .csi_param);
                        if (j > i) {
                            i = j;
                            continue;
                        }
                    },

                    else => {},
                }

                // Look up each entry once and reuse it for both
                // the stay-in-state test and transition().

                const s = self.state; // loop-invariant: dispatch() never writes .state
                const row = &entries[@intFromEnum(s)];

                var j = i;
                var e: Entry = undefined;
                while (j < bytes.len) : (j += 1) {
                    e = row[bytes[j]];
                    if (e.next != s or forcedTransition(s, bytes[j])) break;
                    self.dispatch(h, e.action, bytes[j]);
                }

                if (j < bytes.len) {
                    self.transition(h, e, bytes[j]);
                    j += 1;
                }

                i = j;
                continue;
            }
        }

        /// Apply the table entry resolved for the current `(state, byte)` pair.
        ///
        /// Runs the exit and transition actions, updates `self.state` to `e.next`,
        /// then runs the entry action. Both `step()` and the `feedBytes` residue loop
        /// use this function to keep transition ordering consistent.
        inline fn transition(self: *Self, h: *Handler, e: Entry, byte: u8) void {
            if (e.exit != .none) self.dispatch(h, e.exit, byte);
            self.dispatch(h, e.action, byte);
            self.state = e.next;
            if (e.entry != .none) self.dispatch(h, e.entry, byte);
        }

        inline fn step(self: *Self, h: *Handler, byte: u8) void {
            const e = entries[@intFromEnum(self.state)][byte];
            if (e.next != self.state or forcedTransition(self.state, byte)) {
                self.transition(h, e, byte);
            } else {
                self.dispatch(h, e.action, byte);
            }
        }

        /// Emits the maximal run of printable ASCII bytes beginning at `start`.
        ///
        /// Printable ASCII is the inclusive range `0x20...0x7E`. Returns the index
        /// immediately after the emitted run: the first non-printable byte's index,
        /// or `bytes.len` if the remaining bytes are all printable. The byte at the
        /// returned index is not emitted, leaving it for the caller to dispatch.
        ///
        /// `start` must be at most `bytes.len`.
        fn feedPrintRun(_: *const Self, h: *Handler, bytes: []const u8, start: usize) usize {
            // scanUntil returns an index relative to the slice passed to it.
            const i = start + State.scanUntil(
                bytes[start..],
                {},
                stopPrintableVector,
                continuesPrintableScalar,
            );

            if (i > start) h.print(bytes[start..i]);
            return i;
        }

        /// Scan and dispatch a CSI sequence beginning at `start`.
        ///
        /// On success, returns the index just past the final byte. Returns `null`
        /// without changing parser state if the sequence is incomplete or its final
        /// byte is not a CSI final; the caller then handles the ESC via `step()`.
        ///
        /// If a private marker (0x3C..0x3F) follows parameter bytes, enters
        /// `.csi_ignore` and returns the marker's index. The marker is left unconsumed
        /// so the caller can process it through the table-driven path, matching the
        /// `.csi_param` to `.csi_ignore` transition.
        fn feedCsi(self: *Self, h: *Handler, bytes: []const u8, start: usize) ?usize {
            const n = bytes.len;
            var p = start + 2;

            const marker_at: ?usize = if (p < n and bytes[p] >= 0x3C and bytes[p] <= 0x3F) blk: {
                p += 1;
                break :blk p - 1;
            } else null;

            const params_begin = p;
            // CSI parameter bytes are in the range 0x30..0x3B.
            // scan bounds only, no state.
            while (p < n and bytes[p] >= 0x30 and bytes[p] <= 0x3B) : (p += 1) {}
            const params_end = p;

            // A private marker here is invalid after parameters. Preserve the table
            // parser's behaviour and leave the marker for processing in .csi_ignore.
            if (p < n and bytes[p] >= 0x3C and bytes[p] <= 0x3F) {
                self.state = .csi_ignore;
                return p;
            }

            // Collect intermediates so they can be included in the dispatch.
            while (p < n and bytes[p] >= 0x20 and bytes[p] <= 0x2F) : (p += 1) {}
            const intermediates_end = p;

            if (p >= n) return null;

            const final = bytes[p];
            if (final < 0x40 or final > 0x7E) return null;

            self.reset();

            // marker is intermediates, not params
            if (marker_at) |m| self.pushIntermediates(bytes[m]);

            // fill params through the batched path, one slot open per separator,
            // register-held digit accumulation, no per-byte pushParam machinery
            _ = self.feedParamRun(bytes[0..params_end], params_begin, true);
            for (bytes[params_end..intermediates_end]) |b| self.pushIntermediates(b);

            self.dispatch(h, .csi_dispatch, final);
            self.state = .ground;
            return p + 1;
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

        inline fn reset(self: *Self) void {
            self.param_len = 0;
            self.intermediate_len = 0;
            self.params_overflow = false;
        }

        inline fn pushIntermediates(self: *Self, byte: u8) void {
            if (self.intermediate_len < max_intermediates) {
                self.intermediates[self.intermediate_len] = byte;
                self.intermediate_len += 1;
            }
        }

        inline fn isDigit(b: u8) bool {
            return b -% '0' < 10;
        }

        // `value * 10 + digit`, saturating at `maxInt(Parameter.Value)` (32767).
        // Params that large are degenerate; clamping is strictly better than a
        // wrapped command value.
        //
        // `digit` must be in 0..9, which enforced by the caller's debug assert.
        // inline fn accumDigit(value: Parameter.Value, digit: Parameter.Value) Parameter.Value {
        //     // u16 intermediate: u15*10+9 fits in u16, no overflow flag needed,
        //     // the clamp is one cmovae instead of saturating ops.
        //     const wide = @as(u32, value) * 10 + digit; // max 327679, never wraps
        //     return @min(wide, 32767); // one cmp + cmov
        // }

        const max_param_value = std.math.maxInt(Parameter.Value);

        /// `value * 10 + digit`, saturating at `maxInt(Parameter.Value)` (32767).
        /// Params that large are degenerate; clamping is strictly better than a
        /// wrapped command value.
        ///
        /// `digit` must be in 0..9, enforced by the caller's debug assert.
        /// Table-path use (pushParam): one digit at a time, cmp+cmov only.
        inline fn accumDigit(value: Parameter.Value, digit: Parameter.Value) Parameter.Value {
            // u32 intermediate: 32767*10+9 = 327679, never wraps.
            const wide = @as(u32, value) * 10 + digit;
            return @min(wide, max_param_value);
        }

        /// Consume a maximal digit run at `start`, returning the saturated
        /// accumulation into `value` and the new index.
        ///
        /// Five digits are accumulated unclamped in u32: value <= 32767, so
        /// value*10^5 + 99999 < 2^32 cannot wrap. A longer run saturates at
        /// 32767 and its remaining digits are skipped. v*10+d is monotonic in
        /// v, so one clamp at the end equals per-digit clamping. Leading zeros
        /// are counted as digits, so 000001 stays 1; parity with pushParam.
        fn accumDigits(v0: Parameter.Value, bytes: []const u8, start: usize) struct {
            value: Parameter.Value,
            index: usize,
        } {
            var v: u32 = v0;
            var i = start;

            var k: usize = 0;
            while (k < 5 and i < bytes.len) : (k += 1) {
                const d = bytes[i] -% '0';
                if (d >= 10) break;
                v = v * 10 + d;
                i += 1;
            }
            if (k == 5) {
                v = @min(v, 32767);
                while (i < bytes.len and isDigit(bytes[i])) : (i += 1) {
                    // past the provable window: fold with clamp per digit
                    v = @min(v * 10 + (bytes[i] -% '0'), 32767);
                }
            }

            const clamped: u32 = @min(v, max_param_value);
            return .{ .value = @intCast(@min(v, clamped)), .index = i };
        }

        /// Consumes parameter bytes starting at `start` and returns the index of the
        /// first byte it did not consume.
        ///
        /// Digits update the current parameter. `;` starts a new parameter, and `:`
        /// starts a sub-parameter when `allow_colon` is true. If no parameter is open,
        /// the first byte is passed to `pushParam` to preserve its handling of leading
        /// separators.
        ///
        /// With `allow_colon` false (the DCS caller), `:` is NOT a param byte: the
        /// loop exits on it, and the residue/table path transitions to `dcs_ignore`.
        /// This contract is pinned at comptime against `dcsParamContinues` /
        /// `dcsParamStopVector` and the `entries` table; do not add `:` handling
        /// to this function for the DCS path.
        ///
        /// At the slot cap a separator is consumed but dropped and `params_overflow`
        /// is set; once set, remaining digits and separators are consumed without
        /// modifying any slot, so digits never leak into the last kept parameter.
        ///
        /// State transitions for non-parameter bytes are left to `step`.
        fn feedParamRun(
            self: *Self,
            bytes: []const u8,
            start: usize,
            comptime allow_colon: bool,
        ) usize {
            const n = bytes.len;
            var i = start;
            var plen = self.param_len;

            // First param byte opens slot 0, let pushParam own that transition.
            if (plen == 0) {
                if (i >= n) return i;

                const b = bytes[i];
                const ok = (b -% '0' < 10) or b == ';' or (allow_colon and b == ':');
                if (!ok) return i;

                self.pushParam(b);

                i += 1;
                plen = self.param_len;
            }

            // prelude guarantees a slot exists
            std.debug.assert(plen > 0);

            while (i < n) {
                const b = bytes[i];

                if (isDigit(b)) {
                    if (self.params_overflow) {
                        // separator was dropped at the cap; consume digits for
                        // the slot that doesn't exist, never touching slot max_params-1.
                        while (i < n and isDigit(bytes[i])) : (i += 1) {}
                    } else {
                        const r = accumDigits(self.params[plen - 1].value, bytes, i);
                        self.params[plen - 1].value = r.value;
                        i = r.index;
                    }
                } else if (b == ';' or (allow_colon and b == ':')) {
                    if (plen < max_params) {
                        plen += 1;
                        self.params[plen - 1] = .{
                            .value = 0,
                            .separator = if (b == ':') .sub_parameter else .parameter,
                        };
                    } else {
                        // Cap reached, mark overflow so following digits drop.
                        self.params_overflow = true;
                    }
                    i += 1;
                } else break;

                // Finals, intermediates, markers 0x3C..0x3F, C0, ESC all exit here.
                // step() owns every transition out of a param state (incl. csi_ignore).
            }

            self.param_len = plen;
            return i;
        }

        /// Consume one param byte: digit, ';', or ':'. Any other byte is a contract
        /// violation, in debug builds the digit arm asserts `byte -% '0' < 10` to
        /// catch misrouted input early.
        ///
        /// A separator opens the next slot and sets its kind (`;` is a `.parameter`,
        /// `:` is a `.sub_parameter`). A leading separator first creates an implicit
        /// empty `.default` slot, so `:5` remains distinct from `0:5`.
        ///
        /// Keep this rule shared by the fast and table-driven paths. At the slot
        /// limit a separator is consumed without opening a slot and sets
        /// `params_overflow`; while overflowed, digits are consumed without
        /// accumulating into the last parameter.
        inline fn pushParam(self: *Self, byte: u8) void {
            switch (byte) {
                ';', ':' => {
                    if (self.param_len == 0) {
                        // Preserve the empty parameter before a leading separator.
                        self.param_len = 1;
                        self.params[0] = .default;
                    }

                    if (self.param_len < max_params) {
                        // Open a new slot tagged by this separator's kind.
                        self.param_len += 1;
                        self.params[self.param_len - 1] = .{
                            .value = 0,
                            .separator = if (byte == ':') .sub_parameter else .parameter,
                        };
                    } else {
                        self.params_overflow = true;
                    }
                },
                else => { // digit
                    // callers must only route param bytes here, the table's `.param`
                    // action covers exactly 0x30..0x3B (digits + separators), and
                    // `feedCsi` or `feedParamRun` scan the same range. Anything else would
                    // wrap into a bogus digit via '-% '0''
                    std.debug.assert(byte -% '0' < 10);

                    if (self.param_len == 0) {
                        self.param_len = 1;
                        self.params[0] = .default;
                    }

                    // param_len <= max_params is structural; the only guard that
                    // matters is !params_overflow; digits after a dropped
                    // separator must not leak into the last kept slot.
                    if (!self.params_overflow) {
                        const p = &self.params[self.param_len - 1];
                        p.value = accumDigit(p.value, byte -% '0');
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
                .clear         => self.reset(),
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

pub const ChecksumDispatcher = struct {
    checksum: u64 = 0,

    // Per-kind weights. Every path for the same kind uses the same weight,
    // so the checksum is invariant to how the parser batches bytes.
    const w_print: u64 = 31;
    const w_osc: u64 = 37;
    const w_dcs: u64 = 41;

    pub fn reset(self: *@This()) void {
        self.checksum = 0;
    }

    inline fn add(self: *@This(), w: u64, b: u8) void {
        self.checksum +%= @as(u64, b) *% w;
    }

    inline fn addSlice(self: *@This(), w: u64, bytes: []const u8) void {
        for (bytes) |b| self.add(w, b);
    }

    pub fn print(self: *@This(), bytes: []const u8) void {
        self.addSlice(w_print, bytes);
    }
    pub fn printByte(self: *@This(), b: u8) void {
        self.add(w_print, b);
    }
    pub fn execute(self: *@This(), b: u8) void {
        self.checksum +%= @as(u64, b) *% 43;
    }
    pub fn escDispatch(self: *@This(), final: u8, intermediates: []const u8) void {
        self.checksum +%= @as(u64, final) *% 47;
        for (intermediates) |b| self.checksum +%= @as(u64, b) *% 53;
    }
    pub fn csiDispatch(self: *@This(), final: u8, intermediates: []const u8, params: anytype) void {
        self.checksum +%= @as(u64, final) *% 43;
        self.checksum +%= @as(u64, params.len) *% 67; // count
        for (intermediates) |b| self.checksum +%= @as(u64, b) *% 53;
        for (params) |p| self.checksum +%= @as(u64, p.value) *% 61;
    }
    pub fn hook(self: *@This(), final: u8, intermediates: []const u8, params: anytype) void {
        self.checksum +%= @as(u64, final) *% 67;
        for (intermediates) |b| self.checksum +%= @as(u64, b) *% 53;
        for (params) |p| self.checksum +%= @as(u64, p.value) *% 61;
    }
    pub fn dcsPut(self: *@This(), b: u8) void {
        self.add(w_dcs, b);
    }
    pub fn dcsPutSlice(self: *@This(), bytes: []const u8) void {
        self.addSlice(w_dcs, bytes);
    }
    pub fn unhook(self: *@This()) void {
        self.checksum +%= 71;
    }
    pub fn oscStart(self: *@This()) void {
        self.checksum +%= 73;
    }
    pub fn oscPut(self: *@This(), b: u8) void {
        self.add(w_osc, b);
    }
    pub fn oscPutSlice(self: *@This(), bytes: []const u8) void {
        self.addSlice(w_osc, bytes);
    }
    pub fn oscEnd(self: *@This()) void {
        self.checksum +%= 79;
    }
};

// String-state payload prefix, batch up to first terminator.
// fn feedStringRun(self: *Self, h: *Handler, bytes: []const u8, start: usize) usize {
//     const end = start + self.state.payloadEnd(bytes[start..]);
//     if (end > start) self.feedData(h, bytes[start..end]);
//     return end;
// }
