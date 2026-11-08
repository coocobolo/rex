//! The active config built from layers: a base config with each source
//! applied on top of the previous one, in order (system file, then user
//! file). Startup and reload both go through `load`. Replaces `loader.zig`
//! at the switch-over (rebuild plan §9).
//!
//! Two allocation scopes: `arena` owns what `config` points to beyond the
//! base config's static data (paths, the merged keymap) and can move to the
//! owner of `config` with `takeArena`; `layers` and the files in them own the
//! diagnostics and are freed by `deinit`. `config` never points into file
//! bytes.
//!
//! `load` applies every valid entry, also from files with errors. Whether to
//! use such a config is the caller's policy (decision P4): startup uses it and
//! shows the first error; reload keeps the running config on any error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Ast = @import("Ast.zig");
const Sema = @import("Sema.zig");
const keys = @import("keys.zig");
const Config = @import("Config.zig");
const diagnostics = @import("diagnostics.zig");

const Loaded = @This();

config: Config,
arena: std.heap.ArenaAllocator,
/// Owned (gpa). One per source, same order.
layers: []Layer,
/// The layer and name token that last set each key; `Origin.unset` if none
/// did (provenance, plan P1).
set_by: [keys.table.len]Origin,

/// Largest source accepted; above it a layer is `unreadable` with
/// `error.FileTooBig`, never truncated (plan C6).
pub const max_bytes = 64 * 1024;

/// Where a layer's text comes from. Everything is borrowed and must outlive
/// the `Loaded` built from it.
pub const Source = struct {
    /// Names the source in diagnostics: the path, or a label such as
    /// `<command line>` (plan P3).
    label: []const u8,
    from: From,

    pub const From = union(enum) {
        /// A file; missing is not an error.
        path: []const u8,
        /// Text given directly. Relative paths in it resolve against `dir`.
        text: struct { bytes: []const u8, dir: []const u8 },
    };

    pub fn file(path: []const u8) Source {
        return .{ .label = path, .from = .{ .path = path } };
    }
};

/// `FileTooBig` above `max_bytes`; otherwise why the file couldn't be read.
/// Never `FileNotFound` (that is `missing`) or `OutOfMemory` (returned by
/// `load`).
pub const ReadError = std.Io.Dir.ReadFileAllocError || error{FileTooBig};

pub const Layer = struct {
    source: Source,
    state: union(enum) {
        missing,
        unreadable: ReadError,
        loaded: diagnostics.File,
    },
};

/// 8 bytes: a sentinel layer instead of an optional, which would add a tag
/// after the padding.
pub const Origin = struct {
    token: Ast.TokenIndex,
    layer: u8,

    pub const no_layer = std.math.maxInt(u8);
    pub const unset: Origin = .{ .token = 0, .layer = no_layer };

    pub fn isSet(origin: Origin) bool {
        return origin.layer != no_layer;
    }
};

/// What makes a config unfit to replace a running one. Points into
/// `layers`; valid until `deinit`.
pub const Problem = union(enum) {
    unreadable: struct { layer: *const Layer, err: ReadError },
    syntax: struct { layer: *const Layer, err: Ast.Error },
};

/// Applies `sources` in order to a copy of `base`, which is also what the
/// `default` keyword restores. `gpa` must be a general-purpose allocator: the
/// arena grows on it and the files live until `deinit`. `home` expands `~/`
/// paths; null when unknown. On `error.OutOfMemory` nothing is leaked. The
/// caller frees the result with `deinit`.
pub fn load(gpa: Allocator, io: std.Io, base: *const Config, home: ?[]const u8, sources: []const Source) Allocator.Error!Loaded {
    assert(sources.len < Origin.no_layer);
    const layers = try gpa.alloc(Layer, sources.len);
    for (layers, sources) |*layer, source| layer.* = .{ .source = source, .state = .missing };

    var loaded: Loaded = .{
        .config = base.*,
        .arena = .init(gpa),
        .layers = layers,
        .set_by = @splat(.unset),
    };
    errdefer loaded.deinit(gpa);

    for (loaded.layers, 0..) |*layer, i| {
        try loaded.loadLayer(gpa, io, base, home, layer);
        const file = switch (layer.state) {
            .loaded => |*f| f,
            .missing, .unreadable => continue,
        };
        for (&loaded.set_by, file.sema.set_by) |*origin, token| {
            if (token) |t| origin.* = .{ .token = t, .layer = @intCast(i) };
        }
    }
    return loaded;
}

fn loadLayer(loaded: *Loaded, gpa: Allocator, io: std.Io, base: *const Config, home: ?[]const u8, layer: *Layer) Allocator.Error!void {
    const source: []u8, const dir: []const u8 = switch (layer.source.from) {
        .path => |path| .{
            // A limit is "reached or exceeded", so one byte above the cap
            // lets a file of exactly `max_bytes` through.
            std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes + 1)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileNotFound => return,
                error.StreamTooLong => {
                    layer.state = .{ .unreadable = error.FileTooBig };
                    return;
                },
                else => |e| {
                    layer.state = .{ .unreadable = e };
                    return;
                },
            },
            std.fs.path.dirname(path) orelse ".",
        },
        .text => |text| .{
            if (text.bytes.len > max_bytes) {
                layer.state = .{ .unreadable = error.FileTooBig };
                return;
            } else try gpa.dupe(u8, text.bytes),
            text.dir,
        },
    };
    errdefer gpa.free(source);

    var tree = Ast.parse(gpa, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // `max_bytes` is far below the Ast's 4 GiB limit.
        error.SourceTooLong => unreachable,
    };
    errdefer tree.deinit(gpa);

    const sema = try Sema.apply(gpa, &tree, &loaded.config, .{
        .defaults = base,
        .arena = loaded.arena.allocator(),
        .dir = dir,
        .home = home,
    });
    layer.state = .{ .loaded = .{ .source = source, .tree = tree, .sema = sema } };
}

/// Frees the layers and their files, and the arena unless it was taken.
pub fn deinit(loaded: *Loaded, gpa: Allocator) void {
    for (loaded.layers) |*layer| switch (layer.state) {
        .loaded => |*file| file.deinit(gpa),
        .missing, .unreadable => {},
    };
    gpa.free(loaded.layers);
    loaded.arena.deinit();
    loaded.* = undefined;
}

/// Moves the arena, and so ownership of what `config` points to, to the
/// caller. `loaded` keeps an empty arena, so `deinit` stays safe.
pub fn takeArena(loaded: *Loaded) std.heap.ArenaAllocator {
    const arena = loaded.arena;
    loaded.arena = .init(arena.child_allocator);
    return arena;
}

/// Whether any source was found (text sources always are).
pub fn found(loaded: *const Loaded) bool {
    for (loaded.layers) |layer| switch (layer.state) {
        .missing => {},
        .unreadable, .loaded => return true,
    };
    return false;
}

/// The first unreadable layer, else the first syntax error, in layer order.
/// Warnings are never problems.
pub fn firstError(loaded: *const Loaded) ?Problem {
    for (loaded.layers) |*layer| switch (layer.state) {
        .unreadable => |err| return .{ .unreadable = .{ .layer = layer, .err = err } },
        .missing, .loaded => {},
    };
    for (loaded.layers) |*layer| switch (layer.state) {
        .loaded => |*file| if (file.tree.errors.len > 0) {
            return .{ .syntax = .{ .layer = layer, .err = file.tree.errors[0] } };
        },
        .missing, .unreadable => {},
    };
    return null;
}
