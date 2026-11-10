//! The `memset` that Rex's executables link instead of Zig 0.16.0's
//! `compiler_rt.memset`, which stores one byte per iteration and wins
//! over the libc one at link time because it is defined in the
//! executable (#78). Every `@memset` with a byte-repeating value, every
//! loop LLVM recognizes as a fill, and FreeType's and GLFW's `memset`
//! calls land here.
//!
//! This file must be built as its own module with `no_builtin = true`:
//! otherwise LLVM turns the store loops below back into a `memset` call,
//! which would be this function calling itself. The symbol is strong, so
//! it replaces compiler_rt's weak one, and hidden, so only the executable
//! binds to it; libc and the libraries Rex loads at runtime keep their own.

const std = @import("std");

/// Bytes per store: the widest vector the target CPU handles well (16 on
/// baseline x86-64 and aarch64, 32 with AVX2).
const vector_len = std.simd.suggestVectorLength(u8) orelse 16;

comptime {
    @export(&memset, .{ .name = "memset", .visibility = .hidden });
}

/// C `memset`: sets `len` bytes at `dest` to `c` and returns `dest`.
/// C passes `c` as an `int`; only its low byte is used, so taking a `u8`
/// matches the C ABI on every target Rex supports, as compiler_rt does.
fn memset(dest: ?[*]u8, c: u8, len: usize) callconv(.c) ?[*]u8 {
    if (len != 0) fill(dest.?, c, len);
    return dest;
}

/// Sets `len` bytes at `dest` to `c` with unaligned vector stores. Lengths
/// that aren't a multiple of the store width end with one store that
/// overlaps the previous one, instead of a byte loop.
pub fn fill(dest: [*]u8, c: u8, len: usize) void {
    if (len < vector_len) return fillShort(dest, c, len);

    var i: usize = 0;
    while (len - i > vector_len) : (i += vector_len) store(vector_len, dest + i, c);
    store(vector_len, dest + len - vector_len, c);
}

/// `fill` for `len < vector_len`: two stores of the widest power of two
/// that fits in `len` cover it, the second one ending at `len`.
fn fillShort(dest: [*]u8, c: u8, len: usize) void {
    comptime var width = vector_len / 2;
    inline while (width >= 2) : (width /= 2) {
        if (len >= width) {
            store(width, dest, c);
            store(width, dest + len - width, c);
            return;
        }
    }
    if (len == 1) dest[0] = c;
}

/// Stores `width` copies of `c` at `dest`, which may be unaligned. Widths up
/// to 8 use an integer: Zig 0.16.0's self-hosted x86-64 backend (Debug
/// builds) writes past the end of unaligned `@Vector(2|4|8, u8)` stores,
/// while 16 and wider are correct (`memset_test.zig` catches it).
fn store(comptime width: usize, dest: [*]u8, c: u8) void {
    if (width <= 8) {
        const T = std.meta.Int(.unsigned, width * 8);
        // maxInt / 0xff is 0x0101...01, which copies `c` into every byte.
        @as(*align(1) T, @ptrCast(dest)).* = @as(T, c) * (std.math.maxInt(T) / 0xff);
    } else {
        const V = @Vector(width, u8);
        @as(*align(1) V, @ptrCast(dest)).* = @as(V, @splat(c));
    }
}
