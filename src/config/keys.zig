//! The user-facing config keys: one row per setting, bound to a `Config`
//! field by a comptime path, so a renamed or removed field breaks the row at
//! compile time.
//!
//! Prototype stage of the config rebuild (R1, #24): path resolution, lookup,
//! dispatch and the leaf walk, with plain value parsing. Value kinds, ranges,
//! keywords, custom apply functions and the remaining rows follow.

const std = @import("std");
const Config = @import("Config.zig");

/// Section headers as users write them; dotted names are subsections (`[modal.blur]`).
pub const Section = enum {
    root,
    font,
    window,
    bell,
    card,
    toast,
    banner,
    modal,
    @"modal.blur",
    wellbeing,
    @"wellbeing.screen_time",
    @"wellbeing.focus",
    scroll,
    keybinds,
};

pub const Key = struct {
    section: Section,
    /// Canonical snake_case name within `section` (naming guide K1–K16).
    name: []const u8,
    /// Dot path from `Config` to the field this key sets.
    field: []const u8,
};

pub const KeyIndex = u16;

/// Comptime branch budget for code that unrolls over `table`: each row's path
/// is resolved at comptime, and the default quota (1000) covers only a few rows.
pub const eval_branch_quota = 1000 * table.len;

pub const table = [_]Key{
    .{ .section = .font, .name = "size", .field = "font.size" },
    .{ .section = .font, .name = "size_step", .field = "font.size_step" },
    .{ .section = .font, .name = "min_size", .field = "font.min_size" },
    .{ .section = .font, .name = "max_size", .field = "font.max_size" },
    .{ .section = .font, .name = "weight", .field = "font.faces.family.variable.regular_weight" },
    .{ .section = .font, .name = "bold_weight", .field = "font.faces.family.variable.bold_weight" },

    .{ .section = .window, .name = "background_opacity", .field = "window.background.alpha" },
    .{ .section = .window, .name = "dim_text_opacity", .field = "window.dim_alpha" },
    .{ .section = .window, .name = "confirm_quit", .field = "window.confirm_quit" },
    .{ .section = .window, .name = "platform", .field = "window.platform" },
    .{ .section = .window, .name = "width", .field = "window.size.width" },
    .{ .section = .window, .name = "height", .field = "window.size.height" },

    .{ .section = .bell, .name = "enabled", .field = "window.bell.enabled" },
    .{ .section = .bell, .name = "volume", .field = "window.bell.volume" },

    .{ .section = .card, .name = "corner_radius", .field = "window.card.corner_radius" },
    .{ .section = .card, .name = "border_width", .field = "window.card.border_width" },
    .{ .section = .card, .name = "border_shape", .field = "window.card.border_shape" },
    .{ .section = .card, .name = "border_style", .field = "window.card.border_style" },

    .{ .section = .toast, .name = "enabled", .field = "window.toast.enabled" },
    .{ .section = .toast, .name = "position", .field = "window.toast.position" },
    .{ .section = .toast, .name = "border_style", .field = "window.toast.border_style" },
    .{ .section = .toast, .name = "duration", .field = "window.toast.duration_ms" },
    .{ .section = .toast, .name = "min_cols", .field = "window.toast.min_cols" },
    .{ .section = .toast, .name = "max_cols", .field = "window.toast.max_cols" },
    .{ .section = .toast, .name = "margin_cols", .field = "window.toast.margin_cols" },
    .{ .section = .toast, .name = "margin_rows", .field = "window.toast.margin_rows" },

    .{ .section = .banner, .name = "enabled", .field = "window.banner.enabled" },
    .{ .section = .banner, .name = "placement", .field = "window.banner.placement" },
    .{ .section = .banner, .name = "position", .field = "window.banner.position" },
    .{ .section = .banner, .name = "border_style", .field = "window.banner.border_style" },
    .{ .section = .banner, .name = "corner_radius", .field = "window.banner.corner_radius" },
    .{ .section = .banner, .name = "border_width", .field = "window.banner.border_width" },
    .{ .section = .banner, .name = "min_cols", .field = "window.banner.min_cols" },
    .{ .section = .banner, .name = "max_cols", .field = "window.banner.max_cols" },
    .{ .section = .banner, .name = "margin_cols", .field = "window.banner.margin_cols" },
    .{ .section = .banner, .name = "margin_rows", .field = "window.banner.margin_rows" },

    .{ .section = .modal, .name = "cols", .field = "window.modal.cols" },
    .{ .section = .modal, .name = "backdrop_opacity", .field = "window.modal.backdrop_opacity" },
    .{ .section = .modal, .name = "close_on_outside_click", .field = "window.modal.close_on_outside_click" },
    .{ .section = .modal, .name = "default_focus", .field = "window.modal.default_focus" },
    .{ .section = .modal, .name = "border_style", .field = "window.modal.border_style" },
    .{ .section = .@"modal.blur", .name = "enabled", .field = "window.modal.blur" },
    .{ .section = .@"modal.blur", .name = "radius", .field = "window.modal.blur_radius" },

    .{ .section = .wellbeing, .name = "enabled", .field = "wellbeing.enabled" },
    .{ .section = .@"wellbeing.screen_time", .name = "daily_limit", .field = "wellbeing.screen_time.daily_limit_ms" },
    .{ .section = .@"wellbeing.screen_time", .name = "idle_threshold", .field = "wellbeing.screen_time.idle_threshold_ms" },
    .{ .section = .@"wellbeing.focus", .name = "task", .field = "wellbeing.focus.task_ms" },
    .{ .section = .@"wellbeing.focus", .name = "short_break", .field = "wellbeing.focus.short_break_ms" },
    .{ .section = .@"wellbeing.focus", .name = "long_break", .field = "wellbeing.focus.long_break_ms" },
    .{ .section = .@"wellbeing.focus", .name = "tasks_before_long_break", .field = "wellbeing.focus.tasks_before_long_break" },
    .{ .section = .@"wellbeing.focus", .name = "lock_input_on_break", .field = "wellbeing.focus.lock_input_on_break" },
    .{ .section = .@"wellbeing.focus", .name = "show_break_animation", .field = "wellbeing.focus.show_break_animation" },
    .{ .section = .@"wellbeing.focus", .name = "mute_notifications_in_task", .field = "wellbeing.focus.mute_notifications_in_task" },

    .{ .section = .scroll, .name = "step_lines", .field = "scroll.lines" },
    .{ .section = .scroll, .name = "wheel_lines", .field = "scroll.wheel_lines" },
};

/// The type of the field at the dot-separated `path` inside `Root`. Struct and
/// union fields can be passed through.
pub fn FieldType(comptime Root: type, comptime path: []const u8) type {
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| {
        return FieldType(@FieldType(Root, path[0..dot]), path[dot + 1 ..]);
    }
    return @FieldType(Root, path);
}

/// Pointer to the field at `path` inside `root.*`. Passing through a union
/// field requires it to be the active one (checked in safe builds).
pub fn fieldPtr(comptime Root: type, comptime path: []const u8, root: *Root) *FieldType(Root, path) {
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| {
        const head = path[0..dot];
        return fieldPtr(@FieldType(Root, head), path[dot + 1 ..], &@field(root.*, head));
    }
    return &@field(root.*, path);
}

fn qualifiedName(comptime key: Key) []const u8 {
    if (key.section == .root) return key.name;
    return @tagName(key.section) ++ "." ++ key.name;
}

const max_qualified_len = blk: {
    var max: usize = 0;
    for (table) |key| max = @max(max, qualifiedName(key).len);
    break :blk max;
};

const lookup_map = blk: {
    var kvs: [table.len]struct { []const u8, KeyIndex } = undefined;
    for (table, 0..) |key, i| kvs[i] = .{ qualifiedName(key), i };
    break :blk std.StaticStringMap(KeyIndex).initComptime(kvs);
};

/// The row for `name` in `section`, or null. Names are matched exactly.
pub fn lookup(section: Section, name: []const u8) ?KeyIndex {
    if (section == .root) return lookup_map.get(name);
    const prefix = @tagName(section);
    if (prefix.len + 1 + name.len > max_qualified_len) return null;
    var buf: [max_qualified_len]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = '.';
    @memcpy(buf[prefix.len + 1 ..][0..name.len], name);
    return lookup_map.get(buf[0 .. prefix.len + 1 + name.len]);
}

/// Parses `text` for the row at `index` and stores it in `config`; the field is
/// unchanged on error.
pub fn apply(config: *Config, index: KeyIndex, text: []const u8) error{InvalidValue}!void {
    @setEvalBranchQuota(eval_branch_quota);
    inline for (table, 0..) |key, i| {
        if (i == index) {
            const ptr = fieldPtr(Config, key.field, config);
            ptr.* = parseValue(@TypeOf(ptr.*), text) orelse return error.InvalidValue;
            return;
        }
    }
    unreachable;
}

// Prototype parsing, derived from the field type only. Not the strict rules of
// the plan (§4.3): `std.fmt.parseUnsigned` accepts '_' between digits
// (std/fmt.zig:471), and optionals have no keyword yet.
fn parseValue(comptime T: type, text: []const u8) ?T {
    switch (@typeInfo(T)) {
        .bool => {
            if (std.mem.eql(u8, text, "true")) return true;
            if (std.mem.eql(u8, text, "false")) return false;
            return null;
        },
        .int => return std.fmt.parseUnsigned(T, text, 10) catch null,
        .float => {
            const value = std.fmt.parseFloat(T, text) catch return null;
            return if (std.math.isFinite(value)) value else null;
        },
        .@"enum" => return std.meta.stringToEnum(T, text),
        .optional => |optional| return parseValue(optional.child, text),
        else => @compileError("no value kind for " ++ @typeName(T)),
    }
}

/// Dot paths of every leaf field reachable from `T`: struct fields are entered,
/// anything else (including unions, optionals, slices and pointers) is a leaf.
pub fn leafPaths(comptime T: type) []const []const u8 {
    comptime {
        @setEvalBranchQuota(10_000);
        return leafPathsPrefixed(T, "");
    }
}

fn leafPathsPrefixed(comptime T: type, comptime prefix: []const u8) []const []const u8 {
    var paths: []const []const u8 = &.{};
    for (@typeInfo(T).@"struct".fields) |field| {
        const path = prefix ++ field.name;
        paths = paths ++ switch (@typeInfo(field.type)) {
            .@"struct" => leafPathsPrefixed(field.type, path ++ "."),
            else => &[_][]const u8{path},
        };
    }
    return paths;
}
