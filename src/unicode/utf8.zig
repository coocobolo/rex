const std = @import("std");

test {
    // _ = @import("utf8_test.zig");
}

/// Bjoern Hoehrmann DFA table.
/// see [Bjoern Hoehrmann DFA](https://bjoern.hoehrmann.de/utf-8/decoder/dfa/) for details.
const dfa_table = [_]u8{
    // The first part of the table maps bytes to character classes that
    // to reduce the size of the transition table and create bitmasks.
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,
    7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,
    8,  8,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
    10, 3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  4,  3,  3,  11, 6,  6,  6,  5,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,

    // The second part is a transition table that maps a combination
    // of a state of the automaton and a character class to a state.
    0,  12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 0,  12, 12, 12, 12, 12, 0,
    12, 0,  12, 12, 12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 24, 12, 12,
    12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12, 12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
    12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
};

pub const Decoder = struct {
    state: u8,
    codepoint: u32,

    pub const accept = 0;
    pub const reject = 12;
    const base: usize = 256;

    pub const empty: Decoder = .{
        .codepoint = 0,
        .state = 0,
    };

    pub const Result = union(enum) {
        ok,
        codepoint: u32,
        reject,
    };

    /// Returns the number of leading bytes in `bytes` that are guaranteed-safe
    /// plain ASCII, given the decoder's current state. Returns 0 if the decoder
    /// is mid-sequence (caller must fall back to feed()) or if bytes[0] itself
    /// is not ASCII. Pure query, does not mutate decoder state.
    pub fn asciiPrefixLenSwar(self: *const Decoder, bytes: []const u8) usize {
        // mid-sequence: caller must go byte-by-byte
        if (self.state != accept) return 0;

        const N = @sizeOf(usize);
        const MASK = 0x80 * ((std.math.maxInt(usize)) / 0xFF);

        var i: usize = 0;
        while (i + N <= bytes.len) : (i += N) {
            const word = std.mem.readInt(usize, bytes[i..][0..N], .native);
            if (word & MASK != 0) break;
        }

        // Capture the <N tail bytes too, so short runs (or the tails of a long one) are
        // still fully included in a single reported prefix length.
        while (i < bytes.len and bytes[i] < 0x80) : (i += 1) {}
        return i;
    }

    /// Returns the length of the leading run of pure ASCII bytes (< 0x80) in `bytes`.
    /// Its allowing the caller to feed that whole run to the VT Parser in one batch feed
    /// call instead of decoding byte-by-byte.
    ///
    /// Returns 0 when the decoder is mid-sequence, even an ASCII byte would then have to
    /// go through the reject path for the malformed sequence, no prefix may be fast-batched.
    ///
    /// The first byte that stops the scan is always a high byte (>= 0x80), which allowing
    /// the the caller to handle the byte individually, that byte may be a continuation,
    /// a new lead byte, or raw string-state payload data.
    pub fn asciiPrefixLen(self: *const Decoder, bytes: []const u8) usize {
        // A partial multibyte sequence must be rejected byte-by-byte.
        if (self.state != accept) return 0;

        var i: usize = 0;

        // Vector scan to check a whole chunk of `bytes` at once.
        // A byte is non-ASCII if its high bit is set.
        if (std.simd.suggestVectorLength(u8)) |chunk_len| {
            const Chunk = @Vector(chunk_len, u8);
            const mask: Chunk = @splat(0x80);
            while (i + chunk_len <= bytes.len) {
                const chunk: Chunk = bytes[i..][0..chunk_len].*;
                const hi_bits = chunk & mask == mask;
                if (std.simd.firstTrue(hi_bits)) |first| return i + first;
                i += chunk_len;
            }
        }

        // SWAR fallback to detects the high bit in every byte of a usize word
        // at once. Covers small inputs (or targets without a useful vector length)
        // and the sub-chunk tail left over after the vector loop.
        const n = @sizeOf(usize);
        const mask = 0x80 * (std.math.maxInt(usize) / 0xFF);
        while (i + n <= bytes.len) : (i += n) {
            const word = std.mem.readInt(usize, bytes[i..][0..n], .native);
            if (word & mask != 0) break;
        }

        // Scalar tail, word-level check can't tell which byte stopped it,
        // and there may also be a final partial word to scan.
        while (i < bytes.len and bytes[i] < 0x80) : (i += 1) {}
        return i;
    }

    /// Returns the length of the leading run of high bytes (>= 0x80) in `bytes`.
    ///
    /// Returns 0 when the decoder is mid-sequence, since those bytes must be
    /// processed by the decoder rather than fast-batched.
    pub fn highBytePrefixLen(self: *const Decoder, bytes: []const u8) usize {
        if (self.state != accept) return 0;

        var i: usize = 0;

        // Find the first ASCII byte in each vector chunk.
        if (std.simd.suggestVectorLength(u8)) |chunk_len| {
            const Chunk = @Vector(chunk_len, u8);
            const high_bit: Chunk = @splat(0x80);
            const zero: Chunk = @splat(0);

            while (chunk_len <= bytes.len - i) {
                const chunk: Chunk = bytes[i..][0..chunk_len].*;
                const is_ascii = (chunk & high_bit) == zero;
                if (std.simd.firstTrue(is_ascii)) |first| return i + first;
                i += chunk_len;
            }
        }

        // If any byte in a word is ASCII, fall through to locate it exactly.
        const n = @sizeOf(usize);
        const high_bits = 0x80 * (std.math.maxInt(usize) / 0xFF);
        while (n <= bytes.len - i) {
            const word = std.mem.readInt(usize, bytes[i..][0..n], .native);
            if (word & high_bits != high_bits) break;
            i += n;
        }

        // Locate the first ASCII byte in the remaining word or tail.
        while (i < bytes.len and bytes[i] >= 0x80) : (i += 1) {}
        return i;
    }

    pub fn reset(self: *Decoder) void {
        self.state = 0;
        self.codepoint = 0;
    }

    pub fn finish(self: *Decoder) Result {
        if (self.state == accept) {
            return .ok;
        }

        // The stream ended in the middle of a UTF-8 sequence.
        self.reset();
        return .reject;
    }

    pub inline fn feed(self: *Decoder, byte: u32) Result {
        if (self.state == accept and byte < 0x80) {
            // ASCII fast path: skip both table lookups entirely
            return .{ .codepoint = byte };
        }

        const typ = dfa_table[byte];
        const cont = (self.codepoint << 6) | (byte & 0x3F);
        const mask = @as(u32, 0xFF) >> @intCast(typ);
        const lead = byte & mask;

        self.codepoint = if (self.state != accept) cont else lead;
        self.state = dfa_table[base + self.state + typ];

        return switch (self.state) {
            accept => .{ .codepoint = self.codepoint },
            reject => .reject,
            else => .ok,
        };
    }
};

pub const Encoder = struct {
    pub const max_bytes = 4;

    pub const Error = error{
        InvalidCodepoint,
        NoSpace,
    };

    pub inline fn utf8ValidCodepoint(cp: u21) bool {
        return !(cp >= 0xD800 and cp <= 0xDFFF);
    }

    // Safe single-codepoint encoding.
    pub fn encode(cp: u21, out: []u8) Error!u3 {
        if (!utf8ValidCodepoint(cp)) return error.InvalidCodepoint;
        return encodeUnchecked(cp, out);
    }

    // Hot path when cp is already known to be valid.
    pub inline fn encodeUnchecked(cp: u21, out: []u8) u3 {
        if (cp <= 0x7F) {
            out[0] = @intCast(cp);
            return 1;
        }

        if (cp <= 0x7FF) {
            out[0] = @intCast(0xC0 | (cp >> 6));
            out[1] = @intCast(0x80 | (cp & 0x3F));
            return 2;
        }

        if (cp <= 0xFFFF) {
            out[0] = @intCast(0xE0 | (cp >> 12));
            out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            out[2] = @intCast(0x80 | (cp & 0x3F));
            return 3;
        }

        out[0] = @intCast(0xF0 | (cp >> 18));
        out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }

    // For prepend/reverse-buffer construction.
    pub inline fn encodeBackwards(
        cp: u21,
        out: []u8,
        end: usize,
    ) Error!usize {
        if (!utf8ValidCodepoint(cp))
            return error.InvalidCodepoint;

        if (cp <= 0x7F) {
            if (end < 1) return error.NoSpace;
            out[end - 1] = @intCast(cp);
            return end - 1;
        }

        if (cp <= 0x7FF) {
            if (end < 2) return error.NoSpace;
            out[end - 1] = @intCast(0x80 | (cp & 0x3F));
            out[end - 2] = @intCast(0xC0 | (cp >> 6));
            return end - 2;
        }

        if (cp <= 0xFFFF) {
            if (end < 3) return error.NoSpace;
            out[end - 1] = @intCast(0x80 | (cp & 0x3F));
            out[end - 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            out[end - 3] = @intCast(0xE0 | (cp >> 12));
            return end - 3;
        }

        if (end < 4) return error.NoSpace;
        out[end - 1] = @intCast(0x80 | (cp & 0x3F));
        out[end - 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[end - 3] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        out[end - 4] = @intCast(0xF0 | (cp >> 18));
        return end - 4;
    }
};