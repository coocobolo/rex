//! Comptime memory-layout inspector across all `rex` subsystems.
//!
//! Run `zig build layout` for a size/padding table across modules, pass
//! substring filters (`zig build layout -- kit.Tree KitPainter.Instance`)
//! for field-by-field `@offsetOf` breakdowns and padding holes, or pass
//! `--holes` / `--by-size` / `--all`.

const std = @import("std");
const rex = @import("rex");

const FieldKind = enum { field, variant, packed_field };

const FieldInfo = struct {
    kind: FieldKind,
    name: []const u8,
    type_name: []const u8,
    offset_or_bit: usize,
    size_or_bits: usize,
    alignment: usize,
};

const EntryKind = enum { @"struct", packed_struct, @"union" };

const Entry = struct {
    name: []const u8,
    type_name: []const u8,
    kind: EntryKind,
    size: usize,
    alignment: usize,
    pad: usize,
    fields: []const FieldInfo,
};

const skip_decls = [_][]const u8{
    "gl",
    "glfw",
    "c",
    "std",
};

const max_walk_depth = 4;

fn shouldSkipDecl(name: []const u8) bool {
    for (skip_decls) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

fn isTypeContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => true,
        else => false,
    };
}

fn hasFields(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields.len > 0,
        .@"union" => |u| u.fields.len > 0,
        else => false,
    };
}

fn isNamespaceContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.decls.len > 0,
        .@"union" => |u| u.decls.len > 0,
        .@"enum" => |e| e.decls.len > 0,
        else => false,
    };
}

fn measureEntry(comptime path: []const u8, comptime T: type) Entry {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                var fields: [s.fields.len]FieldInfo = undefined;
                var total_bits: usize = 0;
                for (s.fields, 0..) |f, i| {
                    const bits = @bitSizeOf(f.type);
                    fields[i] = .{
                        .kind = .packed_field,
                        .name = f.name,
                        .type_name = @typeName(f.type),
                        .offset_or_bit = @bitOffsetOf(T, f.name),
                        .size_or_bits = bits,
                        .alignment = 0,
                    };
                    total_bits += bits;
                }
                const used_bytes = (total_bits + 7) / 8;
                const finalized = fields;
                return .{
                    .name = path,
                    .type_name = @typeName(T),
                    .kind = .packed_struct,
                    .size = @sizeOf(T),
                    .alignment = @alignOf(T),
                    .pad = @sizeOf(T) -| used_bytes,
                    .fields = &finalized,
                };
            }

            var fields: [s.fields.len]FieldInfo = undefined;
            for (s.fields, 0..) |f, i| {
                fields[i] = .{
                    .kind = .field,
                    .name = f.name,
                    .type_name = @typeName(f.type),
                    .offset_or_bit = @offsetOf(T, f.name),
                    .size_or_bits = @sizeOf(f.type),
                    .alignment = @alignOf(f.type),
                };
            }
            // Sort by offset so field listings and hole calculations run monotonically.
            for (0..fields.len) |i| {
                var min_i = i;
                for (i + 1..fields.len) |j| {
                    if (fields[j].offset_or_bit < fields[min_i].offset_or_bit) min_i = j;
                }
                if (min_i != i) std.mem.swap(FieldInfo, &fields[i], &fields[min_i]);
            }
            var cursor: usize = 0;
            var pad: usize = 0;
            for (fields) |f| {
                if (f.offset_or_bit > cursor) pad += f.offset_or_bit - cursor;
                cursor = @max(cursor, f.offset_or_bit + f.size_or_bits);
            }
            if (@sizeOf(T) > cursor) pad += @sizeOf(T) - cursor;

            const finalized = fields;
            return .{
                .name = path,
                .type_name = @typeName(T),
                .kind = .@"struct",
                .size = @sizeOf(T),
                .alignment = @alignOf(T),
                .pad = pad,
                .fields = &finalized,
            };
        },
        .@"union" => |u| {
            var fields: [u.fields.len]FieldInfo = undefined;
            var max_payload: usize = 0;
            for (u.fields, 0..) |f, i| {
                const sz = @sizeOf(f.type);
                max_payload = @max(max_payload, sz);
                fields[i] = .{
                    .kind = .variant,
                    .name = f.name,
                    .type_name = @typeName(f.type),
                    .offset_or_bit = 0,
                    .size_or_bits = sz,
                    .alignment = @alignOf(f.type),
                };
            }
            const tag_size = if (u.tag_type) |Tag| @sizeOf(Tag) else 0;
            const finalized = fields;
            return .{
                .name = path,
                .type_name = @typeName(T),
                .kind = .@"union",
                .size = @sizeOf(T),
                .alignment = @alignOf(T),
                .pad = @sizeOf(T) -| (max_payload + tag_size),
                .fields = &finalized,
            };
        },
        else => @compileError("expected struct or union"),
    }
}

const Collector = struct {
    const capacity = 2048;

    entries: [capacity]Entry = undefined,
    len: usize = 0,

    fn containsType(self: *const Collector, type_name: []const u8) bool {
        for (self.entries[0..self.len]) |entry| {
            if (std.mem.eql(u8, entry.type_name, type_name)) return true;
        }
        return false;
    }

    fn append(self: *Collector, comptime path: []const u8, comptime T: type) void {
        if (!isTypeContainer(T)) return;
        if (!hasFields(T)) return;
        if (self.containsType(@typeName(T))) return;
        if (self.len == capacity) @compileError("layout inspect Collector.capacity exceeded; increase Collector.capacity");
        self.entries[self.len] = measureEntry(path, T);
        self.len += 1;
    }

    fn walk(self: *Collector, comptime path: []const u8, comptime Container: type, comptime depth: usize) void {
        if (isTypeContainer(Container)) self.append(path, Container);
        if (depth >= max_walk_depth) return;
        if (!isNamespaceContainer(Container)) return;

        const decls = switch (@typeInfo(Container)) {
            .@"struct" => |s| s.decls,
            .@"union" => |u| u.decls,
            .@"enum" => |e| e.decls,
            else => return,
        };
        inline for (decls) |decl| {
            if (shouldSkipDecl(decl.name)) continue;
            const field_val = @field(Container, decl.name);
            if (@TypeOf(field_val) == type) {
                const Child = field_val;
                if (isNamespaceContainer(Child) or isTypeContainer(Child)) {
                    const child_path = if (path.len == 0) decl.name else path ++ "." ++ decl.name;
                    self.walk(child_path, Child, depth + 1);
                }
            }
        }
    }
};

fn buildCatalog() []const Entry {
    @setEvalBranchQuota(500_000);
    comptime {
        var c: Collector = .{};
        c.walk("", rex, 0);
        // `KitOverlay` is a private field type on `App` rather than a `pub const` declaration.
        const KitOverlayType = std.meta.Child(std.meta.Child(@FieldType(rex.App, "kit")));
        c.append("KitOverlay", KitOverlayType);
        const out = c.entries[0..c.len].*;
        return &out;
    }
}

const catalog = buildCatalog();

const Options = struct {
    all: bool = false,
    holes_only: bool = false,
    by_size: bool = false,
    help: bool = false,
    filters: []const []const u8 = &.{},
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var opts: Options = .{};
    var filters: std.ArrayList([]const u8) = .empty;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            opts.all = true;
        } else if (std.mem.eql(u8, arg, "--holes")) {
            opts.holes_only = true;
        } else if (std.mem.eql(u8, arg, "--by-size")) {
            opts.by_size = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.help = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.log.err("unknown option: {s}", .{arg});
            std.process.exit(2);
        } else {
            try filters.append(arena, arg);
        }
    }
    opts.filters = filters.items;

    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const out = &stdout_writer.interface;

    if (opts.help) {
        try out.writeAll(
            \\Usage: zig build layout -- [options] [filter...]
            \\
            \\Inspects @sizeOf, @alignOf, field @offsetOf, and padding holes across rex modules.
            \\When filters are supplied, prints full field layouts for every matching type.
            \\
            \\Options:
            \\  --holes    Show only types with internal or tail padding > 0
            \\  --by-size  Sort output by descending @sizeOf
            \\  --all      Print detailed field layouts for every matched type
            \\  -h, --help Show this message
            \\
        );
        try out.flush();
        return;
    }

    var indices: [catalog.len]usize = undefined;
    var count: usize = 0;
    for (catalog, 0..) |entry, i| {
        if (!matches(entry, opts)) continue;
        indices[count] = i;
        count += 1;
    }

    if (opts.by_size) {
        std.mem.sort(usize, indices[0..count], {}, lessBySize);
    }

    const detailed = opts.all or opts.filters.len > 0;
    if (!detailed) {
        try out.print("{s:>9}  {s:>5}  {s:>5}  {s:<6}  {s}\n", .{ "size", "align", "pad", "kind", "type" });
        for (indices[0..count]) |idx| {
            const entry = catalog[idx];
            try out.print("{d:>9}  {d:>5}  {d:>5}  {s:<6}  {s}\n", .{
                entry.size,
                entry.alignment,
                entry.pad,
                kindLabel(entry.kind),
                entry.name,
            });
        }
    } else {
        for (indices[0..count]) |idx| {
            try writeDetailed(out, catalog[idx]);
        }
    }
    try out.flush();
}

fn lessBySize(_: void, a: usize, b: usize) bool {
    if (catalog[a].size != catalog[b].size) return catalog[a].size > catalog[b].size;
    return std.mem.order(u8, catalog[a].name, catalog[b].name) == .lt;
}

fn matches(entry: Entry, opts: Options) bool {
    if (opts.holes_only and entry.pad == 0) return false;
    if (opts.filters.len == 0) return true;
    for (opts.filters) |needle| {
        if (containsFold(entry.name, needle)) return true;
        if (containsFold(entry.type_name, needle)) return true;
    }
    return false;
}

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn kindLabel(kind: EntryKind) []const u8 {
    return switch (kind) {
        .@"struct" => "struct",
        .packed_struct => "packed",
        .@"union" => "union",
    };
}

fn writeDetailed(out: *std.Io.Writer, entry: Entry) !void {
    try out.print("=== {s}: size={d} align={d} pad={d} ({s}) ===\n", .{
        entry.name,
        entry.size,
        entry.alignment,
        entry.pad,
        kindLabel(entry.kind),
    });
    switch (entry.kind) {
        .@"struct" => {
            var cursor: usize = 0;
            for (entry.fields) |f| {
                if (f.offset_or_bit > cursor) {
                    try out.print("  +{d:>4} ({d:>3} B): <padding>\n", .{ cursor, f.offset_or_bit - cursor });
                }
                try out.print("  +{d:>4} ({d:>3} B, align {d:>2}): {s}: {s}\n", .{
                    f.offset_or_bit,
                    f.size_or_bits,
                    f.alignment,
                    f.name,
                    f.type_name,
                });
                cursor = @max(cursor, f.offset_or_bit + f.size_or_bits);
            }
            if (entry.size > cursor) {
                try out.print("  +{d:>4} ({d:>3} B): <tail padding>\n", .{ cursor, entry.size - cursor });
            }
        },
        .packed_struct => {
            for (entry.fields) |f| {
                try out.print("  bit+{d:>3} ({d:>2} b): {s}: {s}\n", .{
                    f.offset_or_bit,
                    f.size_or_bits,
                    f.name,
                    f.type_name,
                });
            }
        },
        .@"union" => {
            for (entry.fields) |f| {
                try out.print("  variant ({d:>3} B, align {d:>2}): {s}: {s}\n", .{
                    f.size_or_bits,
                    f.alignment,
                    f.name,
                    f.type_name,
                });
            }
        },
    }
}

test "measureEntry counts internal and tail padding accurately" {
    const ExternSample = extern struct {
        a: u8,
        b: u32,
        c: u8,
    };
    const extern_info = comptime measureEntry("ExternSample", ExternSample);
    try std.testing.expectEqual(@sizeOf(ExternSample), extern_info.size);
    try std.testing.expectEqual(@alignOf(ExternSample), extern_info.alignment);
    try std.testing.expectEqual(@as(usize, 6), extern_info.pad);
    try std.testing.expectEqual(@as(usize, 3), extern_info.fields.len);

    const AutoSample = struct {
        a: u8,
        b: u32,
        c: u8,
    };
    const auto_info = comptime measureEntry("AutoSample", AutoSample);
    try std.testing.expectEqual(@as(usize, 8), auto_info.size);
    try std.testing.expectEqual(@as(usize, 2), auto_info.pad);
}

test "measureEntry handles packed structs and unions without offset errors" {
    const Bits = packed struct(u8) { a: u3, b: u5 };
    const bits_info = comptime measureEntry("Bits", Bits);
    try std.testing.expectEqual(@as(usize, 1), bits_info.size);
    try std.testing.expectEqual(@as(usize, 0), bits_info.pad);
    try std.testing.expectEqual(EntryKind.packed_struct, bits_info.kind);

    const Choice = union(enum(u8)) { none: void, num: u32 };
    const choice_info = comptime measureEntry("Choice", Choice);
    try std.testing.expectEqual(@sizeOf(Choice), choice_info.size);
    try std.testing.expectEqual(EntryKind.@"union", choice_info.kind);
}

test "containsFold matches substrings case-insensitively" {
    try std.testing.expect(containsFold("renderer.KitPainter.Instance", "kitpainter.instance"));
    try std.testing.expect(containsFold("kit.Tree.Box", "Tree.Box"));
    try std.testing.expect(!containsFold("kit.Tree.Box", "Anchor"));
}

test "catalog walks rex namespaces including builtin, FreeType, kit, and KitOverlay" {
    try std.testing.expect(catalog.len > 200);
    var has_tree_node = false;
    var has_builtin = false;
    var has_freetype = false;
    var has_overlay = false;
    for (catalog) |entry| {
        if (std.mem.eql(u8, entry.name, "kit.Tree.Node")) has_tree_node = true;
        if (std.mem.startsWith(u8, entry.name, "builtin.")) has_builtin = true;
        if (std.mem.startsWith(u8, entry.name, "FreeType.")) has_freetype = true;
        if (std.mem.eql(u8, entry.name, "KitOverlay")) has_overlay = true;
    }
    try std.testing.expect(has_tree_node);
    try std.testing.expect(has_builtin);
    try std.testing.expect(has_freetype);
    try std.testing.expect(has_overlay);
}
