const std = @import("std");

/// A set of flags stored in a packed struct and operated on as one integer.
///
/// `T` must be a `packed struct` whose fields are `bool` or `u1`. Fields
/// whose names start with `_` are treated as padding and ignored by
/// `complement`, `full`, and `count`. The wrapper has the same size
/// and layout as `T`.
///
/// Padding bits are expected to stay zero. `eql`, `isEmpty`, `any`, and the
/// set operations look at the raw integer, so stray padding bits (for
/// example from `fromInt`) are visible to them.
pub fn IntegerSet(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct" or info.@"struct".layout != .@"packed") {
        @compileError("IntegerSet requires a packed struct, found " ++ @typeName(T));
    }

    const Int = info.@"struct".backing_integer.?;
    const Field = std.meta.FieldEnum(T);

    // Bits that belong to real flags (padding excluded).
    const valid_mask: Int = blk: {
        var m: Int = 0;
        for (info.@"struct".fields) |field| {
            if (field.name[0] == '_') continue;
            if (field.type != bool and field.type != u1) {
                @compileError("IntegerSet field '" ++ field.name ++ "' must be bool or u1");
            }
            m |= @as(Int, 1) << @bitOffsetOf(T, field.name);
        }
        break :blk m;
    };

    return packed struct(Int) {
        const Self = @This();

        /// The underlying flags. Read and write fields directly.
        bits: T = @bitCast(@as(Int, 0)),

        /// A set with no flags present.
        pub const empty: Self = .{};

        /// A set with every flag present (padding stays clear).
        pub const full: Self = .{ .bits = @bitCast(valid_mask) };

        /// A set containing only `field`. Folds to a constant.
        pub inline fn of(comptime field: Field) Self {
            comptime std.debug.assert(@tagName(field)[0] != '_');
            return fromInt(@as(Int, 1) << @bitOffsetOf(T, @tagName(field)));
        }

        /// A set containing every listed field.
        pub inline fn initMany(comptime fields: []const Field) Self {
            comptime var m: Int = 0;
            inline for (fields) |f| m |= @as(Int, 1) << @bitOffsetOf(T, @tagName(f));
            return fromInt(m);
        }

        /// Adds `field` to `self`.
        pub inline fn insert(self: *Self, comptime field: Field) void {
            self.setUnion(of(field));
        }

        /// Removes `field` from `self`.
        pub inline fn remove(self: *Self, comptime field: Field) void {
            self.* = fromInt(self.toInt() & ~of(field).toInt());
        }

        /// True if `field` is set in `self`.
        pub inline fn has(self: Self, comptime field: Field) bool {
            return self.intersects(of(field));
        }

        // True if `self` and `other` share at least one flag.
        pub inline fn intersects(self: Self, other: Self) bool {
            return self.toInt() & other.toInt() != 0;
        }

        // True if every flag in `other` is in `self`.
        pub inline fn contains(self: Self, other: Self) bool {
            return other.subsetOf(self);
        }

        /// True if at least one flag is set.
        pub inline fn any(self: Self) bool {
            return self.toInt() != 0;
        }

        /// Returns the set as an integer.
        pub inline fn toInt(self: Self) Int {
            return @bitCast(self);
        }

        /// Builds a set from an integer.
        pub inline fn fromInt(v: Int) Self {
            return @bitCast(v);
        }

        /// True if no flag is set.
        pub inline fn isEmpty(self: Self) bool {
            return self.toInt() == 0;
        }

        /// Number of flags that are set.
        pub inline fn count(self: Self) usize {
            return @popCount(self.toInt());
        }

        /// True if both sets contain exactly the same flags.
        pub inline fn eql(self: Self, other: Self) bool {
            return self.toInt() == other.toInt();
        }

        /// Adds every flag in `other` to `self`.
        pub inline fn setUnion(self: *Self, other: Self) void {
            self.* = fromInt(self.toInt() | other.toInt());
        }

        /// Keeps only the flags present in both `self` and `other`.
        pub inline fn setIntersection(self: *Self, other: Self) void {
            self.* = fromInt(self.toInt() & other.toInt());
        }

        /// Returns the union of two sets.
        pub inline fn unionWith(self: Self, other: Self) Self {
            var r = self;
            r.setUnion(other);
            return r;
        }

        /// Returns the intersection of two sets.
        pub inline fn intersectWith(self: Self, other: Self) Self {
            var r = self;
            r.setIntersection(other);
            return r;
        }

        /// Returns the flags set in `self` but not in `other`.
        pub inline fn differenceWith(self: Self, other: Self) Self {
            return fromInt(self.toInt() & ~other.toInt());
        }

        /// Returns the flags set in exactly one of the two sets.
        pub inline fn xorWith(self: Self, other: Self) Self {
            return fromInt(self.toInt() ^ other.toInt());
        }

        /// Returns every flag that is not set in `self`.
        pub inline fn complement(self: Self) Self {
            return fromInt(~self.toInt() & valid_mask);
        }

        /// True if every flag in `self` is also in `other`.
        pub inline fn subsetOf(self: Self, other: Self) bool {
            return self.intersectWith(other).eql(self);
        }

        /// True if every flag in `other` is also in `self`.
        pub inline fn supersetOf(self: Self, other: Self) bool {
            return other.subsetOf(self);
        }

        pub const Atomic = struct {
            raw: std.atomic.Value(Int) = .init(0),

            /// Adds `s` to the pending flags.
            pub inline fn set(self: *Atomic, s: Self) void {
                _ = self.raw.fetchOr(s.toInt(), .release);
            }

            /// Returns all pending flags and clears them in one step.
            pub inline fn take(self: *Atomic) Self {
                return fromInt(self.raw.swap(0, .acquire));
            }

            /// Reads the pending flags without cleariing them.
            pub inline fn peek(self: *const Atomic) Self {
                return fromInt(self.raw.load(.acquire));
            }
        };
    };
}

test IntegerSet {
    const F = packed struct(u8) {
        a: bool = false,
        b: bool = false,
        c: bool = false,
        _pad: u5 = 0,
    };
    const S = IntegerSet(F);

    comptime std.debug.assert(@sizeOf(S) == 1);

    try std.testing.expect(S.empty.isEmpty());
    try std.testing.expectEqual(3, S.full.count());
    try std.testing.expectEqual(0b111, S.full.toInt());

    var x: S = .{};
    x.bits.a = true;
    const y: S = .{ .bits = .{ .b = true } };

    const u = x.unionWith(y);
    try std.testing.expectEqual(2, u.count());
    try std.testing.expect(u.intersectWith(y).eql(y));
    try std.testing.expect(!u.differenceWith(y).bits.b);
    try std.testing.expect(u.differenceWith(y).bits.a);
    try std.testing.expect(x.subsetOf(u) and u.supersetOf(x));

    // complement must not set padding bits
    try std.testing.expectEqual(0b100, u.complement().toInt());
    try std.testing.expect(u.xorWith(u).isEmpty());

    var z = x;
    z.setUnion(y);
    try std.testing.expect(z.eql(u));
    z.setIntersection(x);
    try std.testing.expect(z.eql(x));

    var m = S.empty;
    m.insert(.a);
    try std.testing.expect(m.has(.a));
    try std.testing.expect(!m.has(.b));
    m.insert(.b);
    try std.testing.expect(m.has(.b));
    m.remove(.a);
    try std.testing.expect(!m.has(.a));
    try std.testing.expect(m.has(.b));

    var shared: S.Atomic = .{};
    try std.testing.expect(shared.peek().isEmpty());
    shared.set(x);
    try std.testing.expect(shared.peek().bits.a);
    const taken = shared.take();
    try std.testing.expect(taken.bits.a);
    try std.testing.expect(shared.peek().isEmpty());
}
