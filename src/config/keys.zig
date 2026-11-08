//! The user-facing config keys: one row per setting, bound to a `Config`
//! field by a comptime path, so a renamed or removed field breaks the row at
//! compile time. Each row also says how its value is written (`Kind`), its
//! bounds, and which keyword means null for an optional field.
//!
//! Value rules (config rebuild plan §4.3 and C9): bool is `true`/`false`;
//! integers are decimal digits only; floats are digits with an optional
//! fraction; enums are their tag names exactly; durations are an integer with
//! a unit (`ms`, `s`, `m`, `h`); `default` resets any key to the built-in
//! value. Kinds that no row uses yet (path, string, color, time of day, list,
//! set) are added with their first row.

const std = @import("std");
const Config = @import("Config.zig");
const Theme = @import("../color/Theme.zig");

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

/// How a value is written, beyond what the field type implies.
pub const Kind = enum {
    /// From the field type: bool, enum, unsigned integer or float.
    infer,
    /// A float from 0 to 1 (opacity, volume).
    fraction,
    /// An integer with a unit, stored as milliseconds in an integer field.
    duration,
    /// A font weight: a whole number stored in a variable font's float axis.
    /// Rejected with `NotApplicable` when the font family isn't variable.
    font_weight,
    /// A theme preset name.
    theme,
};

/// The value that stands for null in an optional field (C9/F4).
pub const Keyword = enum {
    /// Derive the value (from the font, for example).
    auto,
    /// Off, no limit or no color.
    none,
    /// Use the value of a parent setting.
    inherit,
};

/// Inclusive bounds, in the field's unit (milliseconds for durations).
/// Integers are compared after conversion to f64, which is exact for every
/// bound used here (all below 2^53).
pub const Bounds = struct {
    min: f64 = 0,
    max: f64 = std.math.inf(f64),
};

pub const Key = struct {
    section: Section,
    /// Canonical snake_case name within `section` (naming guide K1–K16).
    name: []const u8,
    /// Dot path from `Config` to the field this key sets.
    field: []const u8,
    kind: Kind = .infer,
    bounds: Bounds = .{},
    /// Required exactly when the field is optional.
    null_keyword: ?Keyword = null,
};

pub const KeyIndex = u16;

pub const Error = error{
    /// The text is not a value of the key's kind.
    InvalidValue,
    /// A value of the right kind, outside the bounds or the field's type.
    OutOfRange,
    /// The key has no effect with the current settings (a font weight for a
    /// static font family).
    NotApplicable,
};

/// Comptime branch budget for code that unrolls over `table`: each row's path
/// is resolved at comptime, and the default quota (1000) covers only a few rows.
pub const eval_branch_quota = 2000 * table.len;

const at_least_one: Bounds = .{ .min = 1 };

pub const table = [_]Key{
    .{ .section = .root, .name = "theme", .field = "theme", .kind = .theme },

    .{ .section = .font, .name = "size", .field = "font.size", .bounds = at_least_one },
    .{ .section = .font, .name = "size_step", .field = "font.size_step", .bounds = at_least_one },
    .{ .section = .font, .name = "min_size", .field = "font.min_size", .bounds = at_least_one },
    .{ .section = .font, .name = "max_size", .field = "font.max_size", .bounds = at_least_one },
    .{ .section = .font, .name = "weight", .field = "font.faces.family.variable.regular_weight", .kind = .font_weight, .bounds = .{ .min = 1, .max = 1000 } },
    .{ .section = .font, .name = "bold_weight", .field = "font.faces.family.variable.bold_weight", .kind = .font_weight, .bounds = .{ .min = 1, .max = 1000 } },

    .{ .section = .window, .name = "background_opacity", .field = "window.background.alpha", .kind = .fraction },
    .{ .section = .window, .name = "dim_text_opacity", .field = "window.dim_alpha", .kind = .fraction },
    .{ .section = .window, .name = "confirm_quit", .field = "window.confirm_quit" },
    .{ .section = .window, .name = "platform", .field = "window.platform" },
    .{ .section = .window, .name = "width", .field = "window.size.width", .bounds = at_least_one },
    .{ .section = .window, .name = "height", .field = "window.size.height", .bounds = at_least_one },

    .{ .section = .bell, .name = "enabled", .field = "window.bell.enabled" },
    .{ .section = .bell, .name = "volume", .field = "window.bell.volume", .kind = .fraction },

    .{ .section = .card, .name = "corner_radius", .field = "window.card.corner_radius" },
    .{ .section = .card, .name = "border_width", .field = "window.card.border_width" },
    .{ .section = .card, .name = "border_shape", .field = "window.card.border_shape" },
    .{ .section = .card, .name = "border_style", .field = "window.card.border_style" },

    .{ .section = .toast, .name = "enabled", .field = "window.toast.enabled" },
    .{ .section = .toast, .name = "position", .field = "window.toast.position" },
    .{ .section = .toast, .name = "border_style", .field = "window.toast.border_style" },
    // At least 1 ms: Toast.Queue.push turns 0 into 5000 ms (ui/Toast.zig:450).
    .{ .section = .toast, .name = "duration", .field = "window.toast.duration_ms", .kind = .duration, .bounds = at_least_one },
    .{ .section = .toast, .name = "min_cols", .field = "window.toast.min_cols", .bounds = at_least_one },
    .{ .section = .toast, .name = "max_cols", .field = "window.toast.max_cols", .bounds = at_least_one },
    .{ .section = .toast, .name = "margin_cols", .field = "window.toast.margin_cols" },
    .{ .section = .toast, .name = "margin_rows", .field = "window.toast.margin_rows" },

    .{ .section = .banner, .name = "enabled", .field = "window.banner.enabled" },
    .{ .section = .banner, .name = "placement", .field = "window.banner.placement" },
    .{ .section = .banner, .name = "position", .field = "window.banner.position" },
    .{ .section = .banner, .name = "border_style", .field = "window.banner.border_style" },
    .{ .section = .banner, .name = "corner_radius", .field = "window.banner.corner_radius" },
    .{ .section = .banner, .name = "border_width", .field = "window.banner.border_width" },
    .{ .section = .banner, .name = "min_cols", .field = "window.banner.min_cols", .bounds = at_least_one },
    .{ .section = .banner, .name = "max_cols", .field = "window.banner.max_cols", .bounds = at_least_one },
    .{ .section = .banner, .name = "margin_cols", .field = "window.banner.margin_cols" },
    .{ .section = .banner, .name = "margin_rows", .field = "window.banner.margin_rows" },

    .{ .section = .modal, .name = "cols", .field = "window.modal.cols", .bounds = at_least_one },
    .{ .section = .modal, .name = "backdrop_opacity", .field = "window.modal.backdrop_opacity", .kind = .fraction },
    .{ .section = .modal, .name = "close_on_outside_click", .field = "window.modal.close_on_outside_click" },
    .{ .section = .modal, .name = "default_focus", .field = "window.modal.default_focus" },
    .{ .section = .modal, .name = "border_style", .field = "window.modal.border_style", .null_keyword = .inherit },
    .{ .section = .@"modal.blur", .name = "enabled", .field = "window.modal.blur" },
    .{ .section = .@"modal.blur", .name = "radius", .field = "window.modal.blur_radius" },

    .{ .section = .wellbeing, .name = "enabled", .field = "wellbeing.enabled" },
    .{ .section = .@"wellbeing.screen_time", .name = "daily_limit", .field = "wellbeing.screen_time.daily_limit_ms", .kind = .duration, .bounds = at_least_one, .null_keyword = .none },
    .{ .section = .@"wellbeing.screen_time", .name = "idle_threshold", .field = "wellbeing.screen_time.idle_threshold_ms", .kind = .duration, .bounds = at_least_one },
    .{ .section = .@"wellbeing.focus", .name = "task", .field = "wellbeing.focus.task_ms", .kind = .duration, .bounds = at_least_one },
    .{ .section = .@"wellbeing.focus", .name = "short_break", .field = "wellbeing.focus.short_break_ms", .kind = .duration, .bounds = at_least_one },
    .{ .section = .@"wellbeing.focus", .name = "long_break", .field = "wellbeing.focus.long_break_ms", .kind = .duration, .bounds = at_least_one },
    .{ .section = .@"wellbeing.focus", .name = "tasks_before_long_break", .field = "wellbeing.focus.tasks_before_long_break", .bounds = at_least_one },
    .{ .section = .@"wellbeing.focus", .name = "lock_input_on_break", .field = "wellbeing.focus.lock_input_on_break" },
    .{ .section = .@"wellbeing.focus", .name = "show_break_animation", .field = "wellbeing.focus.show_break_animation" },
    .{ .section = .@"wellbeing.focus", .name = "mute_notifications_in_task", .field = "wellbeing.focus.mute_notifications_in_task" },

    .{ .section = .scroll, .name = "step_lines", .field = "scroll.lines", .bounds = at_least_one },
    .{ .section = .scroll, .name = "wheel_lines", .field = "scroll.wheel_lines", .bounds = at_least_one },
};

/// Theme presets by name, for `Kind.theme`.
pub const theme_presets = std.StaticStringMap(Theme).initComptime(.{
    .{ "graphite", Theme.graphite },
});

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

/// The value of the field at `path` inside `root.*`; same union rule as `fieldPtr`.
pub fn fieldValue(comptime Root: type, comptime path: []const u8, root: *const Root) FieldType(Root, path) {
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| {
        const head = path[0..dot];
        return fieldValue(@FieldType(Root, head), path[dot + 1 ..], &@field(root.*, head));
    }
    return @field(root.*, path);
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

/// Parses `text` for the row at `index` and stores it in `config`. `default`
/// copies the field from `defaults`. The field is unchanged on error.
pub fn apply(config: *Config, defaults: *const Config, index: KeyIndex, text: []const u8) Error!void {
    @setEvalBranchQuota(eval_branch_quota);
    inline for (table, 0..) |key, i| {
        if (i == index) return applyKey(key, config, defaults, text);
    }
    unreachable;
}

fn applyKey(comptime key: Key, config: *Config, defaults: *const Config, text: []const u8) Error!void {
    const T = FieldType(Config, key.field);
    comptime checkRow(key, T);

    // A font weight lives in the variable family's payload; touching an
    // inactive union field is illegal, so check before taking the pointer.
    if (key.kind == .font_weight and config.font.faces.family != .variable) return error.NotApplicable;

    if (std.mem.eql(u8, text, "default")) {
        if (key.kind == .font_weight and defaults.font.faces.family != .variable) return error.NotApplicable;
        fieldPtr(Config, key.field, config).* = fieldValue(Config, key.field, defaults);
        return;
    }
    if (key.null_keyword) |keyword| {
        if (std.mem.eql(u8, text, @tagName(keyword))) {
            fieldPtr(Config, key.field, config).* = null;
            return;
        }
    }
    const Value = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    fieldPtr(Config, key.field, config).* = try parseValue(key, Value, text);
}

/// Rejects, at compile time, a row whose kind, bounds or keyword doesn't fit
/// its field.
fn checkRow(comptime key: Key, comptime T: type) void {
    const is_optional = @typeInfo(T) == .optional;
    if (is_optional and key.null_keyword == null)
        @compileError(key.name ++ ": optional field needs a null_keyword");
    if (!is_optional and key.null_keyword != null)
        @compileError(key.name ++ ": null_keyword on a field that can't be null");
    const Value = if (is_optional) @typeInfo(T).optional.child else T;
    const ok = switch (key.kind) {
        .infer => switch (@typeInfo(Value)) {
            .bool, .@"enum" => key.bounds.min == 0 and key.bounds.max == std.math.inf(f64),
            .int => |int| int.signedness == .unsigned,
            .float => true,
            else => false,
        },
        .fraction => @typeInfo(Value) == .float,
        .duration => @typeInfo(Value) == .int and @typeInfo(Value).int.signedness == .unsigned,
        .font_weight => @typeInfo(Value) == .float,
        .theme => Value == Theme,
    };
    if (!ok) @compileError(key.name ++ ": kind ." ++ @tagName(key.kind) ++ " doesn't fit " ++ @typeName(T));
}

fn parseValue(comptime key: Key, comptime V: type, text: []const u8) Error!V {
    switch (key.kind) {
        .infer => switch (@typeInfo(V)) {
            .bool => {
                if (std.mem.eql(u8, text, "true")) return true;
                if (std.mem.eql(u8, text, "false")) return false;
                return error.InvalidValue;
            },
            .@"enum" => return std.meta.stringToEnum(V, text) orelse error.InvalidValue,
            .int => return fitInt(V, key.bounds, try parseDigits(text)),
            .float => return fitFloat(V, key.bounds, try parseDecimal(text)),
            else => unreachable, // checkRow
        },
        .fraction => return fitFloat(V, .{ .min = 0, .max = 1 }, try parseDecimal(text)),
        .duration => return fitInt(V, key.bounds, try parseDuration(text)),
        .font_weight => {
            const weight = try parseDigits(text);
            if (!inBounds(key.bounds, @floatFromInt(weight))) return error.OutOfRange;
            return @floatFromInt(weight);
        },
        .theme => return theme_presets.get(text) orelse error.InvalidValue,
    }
}

fn inBounds(bounds: Bounds, value: f64) bool {
    return value >= bounds.min and value <= bounds.max;
}

fn fitInt(comptime V: type, bounds: Bounds, value: u64) Error!V {
    if (!inBounds(bounds, @floatFromInt(value))) return error.OutOfRange;
    return std.math.cast(V, value) orelse error.OutOfRange;
}

fn fitFloat(comptime V: type, bounds: Bounds, value: f64) Error!V {
    if (!inBounds(bounds, value)) return error.OutOfRange;
    const narrowed: V = @floatCast(value);
    if (!std.math.isFinite(narrowed)) return error.OutOfRange;
    return narrowed;
}

/// Decimal digits only: no sign, no '_' (which `std.fmt.parseUnsigned`
/// would accept, std/fmt.zig:471), no base prefix.
fn parseDigits(text: []const u8) Error!u64 {
    if (text.len == 0) return error.InvalidValue;
    for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidValue;
    return std.fmt.parseUnsigned(u64, text, 10) catch error.OutOfRange;
}

/// Digits, optionally a '.' and more digits: no sign, exponent, hex, `inf`
/// or `nan`.
fn parseDecimal(text: []const u8) Error!f64 {
    const dot = std.mem.indexOfScalar(u8, text, '.');
    const whole = text[0 .. dot orelse text.len];
    if (whole.len == 0) return error.InvalidValue;
    for (whole) |c| if (!std.ascii.isDigit(c)) return error.InvalidValue;
    if (dot) |d| {
        const fraction = text[d + 1 ..];
        if (fraction.len == 0) return error.InvalidValue;
        for (fraction) |c| if (!std.ascii.isDigit(c)) return error.InvalidValue;
    }
    return std.fmt.parseFloat(f64, text) catch error.InvalidValue;
}

/// `<digits><unit>` with unit `ms`, `s`, `m` or `h`, as milliseconds.
fn parseDuration(text: []const u8) Error!u64 {
    const unit_ms: u64, const digits = if (std.mem.endsWith(u8, text, "ms"))
        .{ 1, text[0 .. text.len - 2] }
    else if (std.mem.endsWith(u8, text, "s"))
        .{ std.time.ms_per_s, text[0 .. text.len - 1] }
    else if (std.mem.endsWith(u8, text, "m"))
        .{ std.time.ms_per_min, text[0 .. text.len - 1] }
    else if (std.mem.endsWith(u8, text, "h"))
        .{ std.time.ms_per_hour, text[0 .. text.len - 1] }
    else
        return error.InvalidValue;
    const count = try parseDigits(digits);
    const product = @mulWithOverflow(count, unit_ms);
    if (product[1] != 0) return error.OutOfRange;
    return product[0];
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
