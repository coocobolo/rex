//! The user-facing config keys: one row per setting, bound to a `Config`
//! field by a comptime path, so a renamed or removed field breaks the row at
//! compile time. Each row also says how its value is written (`Kind`), its
//! bounds, and which keyword means null for an optional field.
//!
//! Value rules (config rebuild plan §4.3 and C9): bool is `true`/`false`;
//! integers are decimal digits only; floats are digits with an optional
//! fraction; enums are their tag names exactly; durations are an integer with
//! a unit (`ms`, `s`, `m`, `h`); a time of day is `HH:MM` on the 24-hour
//! clock (F9); `default` resets any key to the built-in value; quoted strings
//! take the escapes `\\ \" \' \n \t \xHH \u{H…}`. Kinds that no row uses
//! yet (color, list, set) are added with their first row.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const Theme = @import("../color/Theme.zig");
const FontConfig = @import("../freetype/Config.zig");
const TimeOfDay = @import("../builtin/wellbeing/winddown.zig").TimeOfDay;

/// Section headers as users write them; dotted names are subsections (`[modal.blur]`).
pub const Section = enum {
    root,
    font,
    window,
    bell,
    surface,
    card,
    toast,
    banner,
    modal,
    @"modal.blur",
    wellbeing,
    @"wellbeing.screen_time",
    @"wellbeing.focus",
    @"wellbeing.winddown",
    @"wellbeing.eyesight",
    @"wellbeing.movement",
    @"wellbeing.routines",
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
    /// `HH:MM` on the 24-hour clock, exactly two digits each, from 00:00 to
    /// 23:59, into a `TimeOfDay` field.
    time_of_day,
    /// A font weight: a whole number stored as a float "wght" axis value.
    font_weight,
    /// A theme preset name.
    theme,
    /// A list of fallback font files, one path per line (F2): the first line
    /// in a file replaces the lower layer's list, `none` empties it and
    /// `default` restores the base list. Paths resolve like `path`.
    /// Sema collects these rows (`isList`); `apply` doesn't take them.
    font_fallback,
    /// A path into a NUL-terminated string field or a static `Face`. `~/` is
    /// the home directory; a relative path is relative to the directory of
    /// the file that sets it (F11).
    path,
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

/// When a changed value takes effect (F17).
pub const Reload = enum {
    /// On the next config reload.
    live,
    /// Only when Rex starts; a reload keeps the running value.
    restart,
};

/// Where a key has an effect (F17).
pub const Os = enum { any, linux, macos };

/// Whether a key may differ per profile (F15, reserved until profiles exist).
pub const Scope = enum { global, profile };

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
    reload: Reload = .live,
    os: Os = .any,
    scope: Scope = .global,
};

pub const KeyIndex = u16;

/// What `apply` needs besides the text: the values `default` restores, the
/// arena that owns strings stored in the config, and where paths resolve.
pub const Context = struct {
    defaults: *const Config,
    /// Owns every string `apply` stores in the config; must outlive it.
    arena: Allocator,
    /// Directory of the file being applied.
    dir: []const u8,
    /// The home directory, for `~/` paths; null when unknown.
    home: ?[]const u8,
};

pub const Error = error{
    /// The text is not a value of the key's kind.
    InvalidValue,
    /// A value of the right kind, outside the bounds or the field's type.
    OutOfRange,
    /// A `~/` path without a known home directory.
    NoHome,
};

pub const ApplyError = Error || Allocator.Error;

/// Comptime branch budget for code that unrolls over `table`: each row's path
/// is resolved at comptime, and the default quota (1000) covers only a few rows.
pub const eval_branch_quota = 2000 * table.len;

const at_least_one: Bounds = .{ .min = 1 };
/// Font sizes in logical pixels. The cap only rejects absurd values: the
/// real limit is a glyph fitting the atlas texture, which depends on the GL
/// driver and the display scale.
const font_size: Bounds = .{ .min = 1, .max = 1000 };

pub const table = [_]Key{
    .{ .section = .root, .name = "theme", .field = "theme", .kind = .theme },

    // One file per style; a style without one takes the next in
    // `Faces.face`'s order (naming doc §9, superseding F16 for fonts).
    .{ .section = .font, .name = "file", .field = "font.faces.regular", .kind = .path },
    .{ .section = .font, .name = "bold_file", .field = "font.faces.bold", .kind = .path, .null_keyword = .none },
    .{ .section = .font, .name = "italic_file", .field = "font.faces.italic", .kind = .path, .null_keyword = .none },
    .{ .section = .font, .name = "bold_italic_file", .field = "font.faces.bold_italic", .kind = .path, .null_keyword = .none },
    .{ .section = .font, .name = "emoji_file", .field = "font.faces.emoji", .kind = .path, .null_keyword = .none },
    .{ .section = .font, .name = "fallback", .field = "font.faces.fallbacks", .kind = .font_fallback },
    .{ .section = .font, .name = "size", .field = "font.size", .bounds = font_size },
    .{ .section = .font, .name = "size_step", .field = "font.size_step", .bounds = font_size },
    .{ .section = .font, .name = "min_size", .field = "font.min_size", .bounds = font_size },
    .{ .section = .font, .name = "max_size", .field = "font.max_size", .bounds = font_size },
    .{ .section = .font, .name = "weight", .field = "font.faces.regular_weight", .kind = .font_weight, .bounds = .{ .min = 1, .max = 1000 } },
    .{ .section = .font, .name = "bold_weight", .field = "font.faces.bold_weight", .kind = .font_weight, .bounds = .{ .min = 1, .max = 1000 } },

    .{ .section = .window, .name = "background_opacity", .field = "window.background.alpha", .kind = .fraction },
    .{ .section = .window, .name = "dim_text_opacity", .field = "window.dim_alpha", .kind = .fraction },
    .{ .section = .window, .name = "confirm_quit", .field = "window.confirm_quit" },
    .{ .section = .window, .name = "platform", .field = "window.platform", .reload = .restart, .os = .linux },
    // The size the window opens with.
    .{ .section = .window, .name = "width", .field = "window.size.width", .bounds = at_least_one, .reload = .restart },
    .{ .section = .window, .name = "height", .field = "window.size.height", .bounds = at_least_one, .reload = .restart },

    .{ .section = .bell, .name = "enabled", .field = "window.bell.enabled" },
    .{ .section = .bell, .name = "volume", .field = "window.bell.volume", .kind = .fraction },

    // The surface cascade (CF11): [surface] is every surface's look, and a
    // component's own keys override it, `inherit` by default.
    .{ .section = .surface, .name = "corner_radius", .field = "window.surface.corner_radius" },
    .{ .section = .surface, .name = "border_width", .field = "window.surface.border_width" },
    .{ .section = .surface, .name = "border_shape", .field = "window.surface.border_shape" },
    .{ .section = .surface, .name = "border_style", .field = "window.surface.border_style" },

    .{ .section = .card, .name = "corner_radius", .field = "window.surfaces.card.corner_radius", .null_keyword = .inherit },
    .{ .section = .card, .name = "border_width", .field = "window.surfaces.card.border_width", .null_keyword = .inherit },
    .{ .section = .card, .name = "border_shape", .field = "window.surfaces.card.border_shape", .null_keyword = .inherit },
    .{ .section = .card, .name = "border_style", .field = "window.surfaces.card.border_style", .null_keyword = .inherit },

    .{ .section = .toast, .name = "enabled", .field = "window.toast.enabled" },
    .{ .section = .toast, .name = "position", .field = "window.toast.position" },
    // At least 1 ms: Toast.Queue.push turns 0 into 5000 ms (ui/Toast.zig:450).
    .{ .section = .toast, .name = "duration", .field = "window.toast.duration_ms", .kind = .duration, .bounds = at_least_one },
    .{ .section = .toast, .name = "min_cols", .field = "window.toast.min_cols", .bounds = at_least_one },
    .{ .section = .toast, .name = "max_cols", .field = "window.toast.max_cols", .bounds = at_least_one },
    .{ .section = .toast, .name = "margin_cols", .field = "window.toast.margin_cols" },
    .{ .section = .toast, .name = "margin_rows", .field = "window.toast.margin_rows" },
    .{ .section = .toast, .name = "corner_radius", .field = "window.surfaces.toast.corner_radius", .null_keyword = .inherit },
    .{ .section = .toast, .name = "border_width", .field = "window.surfaces.toast.border_width", .null_keyword = .inherit },
    .{ .section = .toast, .name = "border_shape", .field = "window.surfaces.toast.border_shape", .null_keyword = .inherit },
    .{ .section = .toast, .name = "border_style", .field = "window.surfaces.toast.border_style", .null_keyword = .inherit },

    .{ .section = .banner, .name = "enabled", .field = "window.banner.enabled" },
    .{ .section = .banner, .name = "placement", .field = "window.banner.placement" },
    .{ .section = .banner, .name = "position", .field = "window.banner.position" },
    .{ .section = .banner, .name = "min_cols", .field = "window.banner.min_cols", .bounds = at_least_one },
    .{ .section = .banner, .name = "max_cols", .field = "window.banner.max_cols", .bounds = at_least_one },
    .{ .section = .banner, .name = "margin_cols", .field = "window.banner.margin_cols" },
    .{ .section = .banner, .name = "margin_rows", .field = "window.banner.margin_rows" },
    .{ .section = .banner, .name = "corner_radius", .field = "window.surfaces.banner.corner_radius", .null_keyword = .inherit },
    .{ .section = .banner, .name = "border_width", .field = "window.surfaces.banner.border_width", .null_keyword = .inherit },
    .{ .section = .banner, .name = "border_shape", .field = "window.surfaces.banner.border_shape", .null_keyword = .inherit },
    .{ .section = .banner, .name = "border_style", .field = "window.surfaces.banner.border_style", .null_keyword = .inherit },

    .{ .section = .modal, .name = "cols", .field = "window.modal.cols", .bounds = at_least_one },
    .{ .section = .modal, .name = "backdrop_opacity", .field = "window.modal.backdrop_opacity", .kind = .fraction },
    .{ .section = .modal, .name = "close_on_outside_click", .field = "window.modal.close_on_outside_click" },
    .{ .section = .modal, .name = "default_focus", .field = "window.modal.default_focus" },
    .{ .section = .modal, .name = "corner_radius", .field = "window.surfaces.modal.corner_radius", .null_keyword = .inherit },
    .{ .section = .modal, .name = "border_width", .field = "window.surfaces.modal.border_width", .null_keyword = .inherit },
    .{ .section = .modal, .name = "border_shape", .field = "window.surfaces.modal.border_shape", .null_keyword = .inherit },
    .{ .section = .modal, .name = "border_style", .field = "window.surfaces.modal.border_style", .null_keyword = .inherit },
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
    // Sema rejects `start` equal to `end`, a window that is never active.
    .{ .section = .@"wellbeing.winddown", .name = "enabled", .field = "wellbeing.winddown.enabled" },
    .{ .section = .@"wellbeing.winddown", .name = "start", .field = "wellbeing.winddown.start", .kind = .time_of_day },
    .{ .section = .@"wellbeing.winddown", .name = "end", .field = "wellbeing.winddown.end", .kind = .time_of_day },
    .{ .section = .@"wellbeing.winddown", .name = "warmth", .field = "wellbeing.winddown.warmth_factor", .kind = .fraction },
    .{ .section = .@"wellbeing.winddown", .name = "mute_bell", .field = "wellbeing.winddown.mute_audio_bell" },
    // Reminder timers count whole seconds and round an interval up.
    .{ .section = .@"wellbeing.eyesight", .name = "enabled", .field = "wellbeing.eyesight.enabled" },
    .{ .section = .@"wellbeing.eyesight", .name = "interval", .field = "wellbeing.eyesight.interval_ms", .kind = .duration, .bounds = at_least_one },
    .{ .section = .@"wellbeing.eyesight", .name = "duration", .field = "wellbeing.eyesight.duration_ms", .kind = .duration, .bounds = at_least_one },
    .{ .section = .@"wellbeing.eyesight", .name = "lock_input", .field = "wellbeing.eyesight.lock_input" },
    .{ .section = .@"wellbeing.eyesight", .name = "animation", .field = "wellbeing.eyesight.animation" },
    .{ .section = .@"wellbeing.movement", .name = "enabled", .field = "wellbeing.movement.enabled" },
    .{ .section = .@"wellbeing.movement", .name = "interval", .field = "wellbeing.movement.interval_ms", .kind = .duration, .bounds = at_least_one },
    .{ .section = .@"wellbeing.movement", .name = "duration", .field = "wellbeing.movement.duration_ms", .kind = .duration, .bounds = at_least_one },
    .{ .section = .@"wellbeing.movement", .name = "lock_input", .field = "wellbeing.movement.lock_input" },
    .{ .section = .@"wellbeing.movement", .name = "animation", .field = "wellbeing.movement.animation" },
    .{ .section = .@"wellbeing.routines", .name = "hydration_interval", .field = "wellbeing.routines.hydration_interval_ms", .kind = .duration, .bounds = at_least_one, .null_keyword = .none },
    .{ .section = .@"wellbeing.routines", .name = "posture_interval", .field = "wellbeing.routines.posture_interval_ms", .kind = .duration, .bounds = at_least_one, .null_keyword = .none },
    .{ .section = .@"wellbeing.routines", .name = "lock_input", .field = "wellbeing.routines.lock_input" },
    .{ .section = .@"wellbeing.routines", .name = "animation", .field = "wellbeing.routines.animation" },

    .{ .section = .scroll, .name = "step_lines", .field = "scroll.lines", .bounds = at_least_one },
    .{ .section = .scroll, .name = "wheel_lines", .field = "scroll.wheel_lines", .bounds = at_least_one },
};

/// A key that existed in a released version and is gone or renamed; Sema
/// reports it instead of "unknown key".
pub const Retired = struct {
    section: Section,
    name: []const u8,
    fate: union(enum) {
        renamed: []const u8,
        removed: []const u8,
    },
};

/// Keys the old parser read but never applied (rebuild plan C8). They come
/// back as real keys when implemented.
pub const retired = [_]Retired{
    .{ .section = .window, .name = "background_blur", .fate = .{ .removed = "not implemented yet" } },
    .{ .section = .window, .name = "title", .fate = .{ .removed = "not implemented yet" } },
    .{ .section = .wellbeing, .name = "eyesight_interval", .fate = .{ .renamed = "wellbeing.eyesight.interval" } },
    .{ .section = .wellbeing, .name = "movement_interval", .fate = .{ .renamed = "wellbeing.movement.interval" } },
    .{ .section = .wellbeing, .name = "hydration_interval", .fate = .{ .renamed = "wellbeing.routines.hydration_interval" } },
    .{ .section = .wellbeing, .name = "posture_interval", .fate = .{ .renamed = "wellbeing.routines.posture_interval" } },
};

/// Whether the row at `index` has an effect on `os` (F17).
pub fn availableOn(index: KeyIndex, os: std.Target.Os.Tag) bool {
    return switch (table[index].os) {
        .any => true,
        .linux => os == .linux,
        .macos => os == .macos,
    };
}

/// `availableOn` for the system Rex is built for.
pub fn availableHere(index: KeyIndex) bool {
    return availableOn(index, builtin.os.tag);
}

pub fn retiredLookup(section: Section, name: []const u8) ?Retired {
    for (retired) |entry| {
        if (entry.section == section and std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// `Config` fields set by a whole section rather than a row.
pub const section_fields = [_]struct { Section, []const u8 }{
    .{ .keybinds, "keymap" },
};

/// `Config` fields (or subtrees) deliberately not exposed as keys. The
/// exposure test (keys_test.zig) fails for a leaf field that is neither in a
/// row, in `section_fields` nor here, so adding a field is a decision. This
/// list is also what could become configurable later.
pub const internal = [_][]const u8{
    // Startup and process settings, set by main.zig or fixed at compile time.
    "blink",
    "termio",
    "environments",
    "terminal",
    "threading",
    // Colors and UI tokens: a `[colors]` section later (#33).
    "tokens",
    // Rendering details.
    "window.scrollbar",
    "window.cursor",
    "window.decoration",
    "window.atlas",
    "window.selection",
    "selection",
    // UI copy and glyphs not exposed yet.
    "window.title",
    "window.toast.icon_style",
    "window.toast.dismiss_str",
    "window.toast.action_prompt",
    "window.toast.action_margin",
    "window.banner.dismiss_str",
    "window.icon",
    "window.modal.icon_style",
    "window.quit_dialog",
    "window.button",
    // Wellbeing settings not exposed yet (some come back from keys.retired).
    "wellbeing.privacy",
    "wellbeing.screen_time.proc_sample_interval_ms",
    "wellbeing.screen_time.grayscale_on_limit",
    "wellbeing.screen_time.grayscale_transition_ms",
    "wellbeing.screen_time.lock_input_on_limit",
    "wellbeing.screen_time.show_limit_animation",
    "wellbeing.screen_time.track_foreground_apps",
    "wellbeing.eyesight.prompt",
    "wellbeing.movement.prompt",
    "wellbeing.focus.display",
    "wellbeing.focus.time_fields",
    "wellbeing.focus.timer_mode",
    "wellbeing.focus.transition_mode",
    "wellbeing.focus.rotate_break_prompts",
    "wellbeing.focus.auto_pause_on_alert",
    "wellbeing.winddown.prompt",
    "wellbeing.routines.hydration_prompt",
    "wellbeing.routines.posture_prompt",
    "wellbeing.routines.custom_name",
    "wellbeing.routines.custom_interval_ms",
    "wellbeing.routines.custom_prompt",
    "wellbeing.lock_screen",
    "wellbeing.dashboard",
};

/// Whether `leaf` is `prefix` or lies below it.
pub fn covers(prefix: []const u8, leaf: []const u8) bool {
    return std.mem.eql(u8, prefix, leaf) or
        (std.mem.startsWith(u8, leaf, prefix) and leaf.len > prefix.len and leaf[prefix.len] == '.');
}

/// `section.name` (or `name` for root keys) of each row, for messages.
pub const qualified_names = blk: {
    var names: [table.len][]const u8 = undefined;
    for (table, 0..) |key, i| names[i] = qualifiedName(key);
    break :blk names;
};

const theme_preset_list = .{
    .{ "graphite", Theme.graphite },
};

/// Theme presets by name, for `Kind.theme`.
pub const theme_presets = std.StaticStringMap(Theme).initComptime(theme_preset_list);

/// Writes what a value of the row at `index` looks like, for messages:
/// "true or false", "one of: auto, wayland, x11", "a whole number from 1 to
/// 65535", and so on, plus the null keyword if the field has one.
pub fn writeExpected(index: KeyIndex, w: *std.Io.Writer) std.Io.Writer.Error!void {
    @setEvalBranchQuota(eval_branch_quota);
    inline for (table, 0..) |key, i| {
        if (i == index) return writeExpectedKey(key, w);
    }
    unreachable;
}

fn writeExpectedKey(comptime key: Key, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const T = FieldType(Config, key.field);
    const Value = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    switch (key.kind) {
        .infer => switch (@typeInfo(Value)) {
            .bool => try w.writeAll("true or false"),
            .@"enum" => |info| {
                try w.writeAll("one of: ");
                inline for (info.fields, 0..) |field, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(field.name);
                }
            },
            .int => {
                const max = @min(key.bounds.max, @as(f64, @floatFromInt(std.math.maxInt(Value))));
                // A 32-bit or wider type's own limit is no setting's real one.
                if (max >= std.math.maxInt(u32))
                    try w.print("a whole number of at least {d}", .{key.bounds.min})
                else
                    try w.print("a whole number from {d} to {d}", .{ key.bounds.min, max });
            },
            .float => if (key.bounds.max == std.math.inf(f64))
                try w.print("a number of at least {d}, like 4.5", .{key.bounds.min})
            else
                try w.print("a number from {d} to {d}", .{ key.bounds.min, key.bounds.max }),
            else => unreachable,
        },
        .fraction => try w.writeAll("a number from 0 to 1"),
        .duration => try w.writeAll("a duration of at least 1ms, like 500ms, 30s, 25m or 1h"),
        .time_of_day => try w.writeAll("a time of day from 00:00 to 23:59, like 21:30"),
        .font_weight => try w.print("a whole number from {d} to {d}", .{ key.bounds.min, key.bounds.max }),
        .theme => {
            try w.writeAll("a theme name: ");
            inline for (theme_preset_list, 0..) |preset, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(preset[0]);
            }
        },
        .font_fallback => try w.writeAll("a path to a font file, one per line, or none"),
        .path => try w.writeAll("a path to a font file"),
    }
    if (key.null_keyword) |keyword| try w.print(", or {t}", .{keyword});
}

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

/// Whether the row is a list, which Sema collects line by line instead of
/// passing to `apply`.
pub fn isList(index: KeyIndex) bool {
    return table[index].kind == .font_fallback;
}

/// One line of a list row.
pub const ListItem = union(enum) {
    /// Empty the list.
    none,
    /// Back to the base list.
    default,
    face: FontConfig.Face,
};

/// Parses one `fallback = ...` line.
pub fn parseFallback(ctx: Context, text: []const u8) ApplyError!ListItem {
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "default")) return .default;
    return .{ .face = .static(try resolvePath(ctx, try unquote(ctx.arena, text))) };
}

/// Parses `text` (the raw value token, quotes included) for the row at
/// `index` and stores it in `config`. `default` copies the field from
/// `ctx.defaults`. The field is unchanged on error.
pub fn apply(config: *Config, ctx: Context, index: KeyIndex, text: []const u8) ApplyError!void {
    @setEvalBranchQuota(eval_branch_quota);
    inline for (table, 0..) |key, i| {
        if (i == index) return applyKey(key, config, ctx, text);
    }
    unreachable;
}

fn applyKey(comptime key: Key, config: *Config, ctx: Context, text: []const u8) ApplyError!void {
    const defaults = ctx.defaults;
    const T = FieldType(Config, key.field);
    comptime checkRow(key, T);

    if (key.kind == .font_fallback) unreachable; // Sema handles list rows (isList)

    if (std.mem.eql(u8, text, "default")) {
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
    if (key.kind == .path) {
        const path = try resolvePath(ctx, try unquote(ctx.arena, text));
        fieldPtr(Config, key.field, config).* = if (Value == FontConfig.Face) .static(path) else path;
        return;
    }
    fieldPtr(Config, key.field, config).* = try parseValue(key, Value, text);
}

/// The text of a value: a quoted value with its escapes interpreted (F10), a
/// bare value as is. The tokenizer guarantees a quoted value is closed.
pub fn unquote(arena: Allocator, raw: []const u8) ApplyError![]const u8 {
    if (raw.len < 2 or (raw[0] != '"' and raw[0] != '\'') or raw[raw.len - 1] != raw[0]) return raw;
    const inner = raw[1 .. raw.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;
    var out: std.ArrayList(u8) = try .initCapacity(arena, inner.len);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] != '\\') {
            out.appendAssumeCapacity(inner[i]);
            continue;
        }
        i += 1;
        if (i == inner.len) return error.InvalidValue;
        switch (inner[i]) {
            '\\', '"', '\'' => out.appendAssumeCapacity(inner[i]),
            'n' => out.appendAssumeCapacity('\n'),
            't' => out.appendAssumeCapacity('\t'),
            'x' => {
                if (i + 2 >= inner.len) return error.InvalidValue;
                const hex = inner[i + 1 .. i + 3];
                if (!isHex(hex)) return error.InvalidValue;
                out.appendAssumeCapacity(std.fmt.parseUnsigned(u8, hex, 16) catch unreachable);
                i += 2;
            },
            'u' => {
                if (i + 1 >= inner.len or inner[i + 1] != '{') return error.InvalidValue;
                const close = std.mem.indexOfScalarPos(u8, inner, i + 2, '}') orelse return error.InvalidValue;
                const hex = inner[i + 2 .. close];
                if (hex.len == 0 or hex.len > 6 or !isHex(hex)) return error.InvalidValue;
                const cp = std.fmt.parseUnsigned(u21, hex, 16) catch return error.InvalidValue;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidValue;
                try out.appendSlice(arena, buf[0..n]);
                i = close;
            },
            else => return error.InvalidValue,
        }
    }
    return out.items;
}

fn isHex(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// A NUL-terminated copy of `path` in the arena, resolved by F11.
fn resolvePath(ctx: Context, path: []const u8) ApplyError![:0]const u8 {
    if (path.len == 0) return error.InvalidValue;
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = ctx.home orelse return error.NoHome;
        return std.fs.path.joinZ(ctx.arena, &.{ home, path[2..] });
    }
    if (std.fs.path.isAbsolute(path)) return ctx.arena.dupeZ(u8, path);
    return std.fs.path.joinZ(ctx.arena, &.{ ctx.dir, path });
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
        .time_of_day => Value == TimeOfDay,
        .font_weight => @typeInfo(Value) == .float,
        .theme => Value == Theme,
        .font_fallback => Value == []const FontConfig.Face,
        .path => Value == [*:0]const u8 or Value == FontConfig.Face,
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
        .time_of_day => return parseTimeOfDay(text),
        .font_weight => {
            const weight = try parseDigits(text);
            if (!inBounds(key.bounds, @floatFromInt(weight))) return error.OutOfRange;
            return @floatFromInt(weight);
        },
        .theme => return theme_presets.get(text) orelse error.InvalidValue,
        .font_fallback => unreachable, // Sema handles list rows
        .path => unreachable, // applyKey handles it
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

/// `HH:MM`: two digits, a colon, two digits. A well-formed time past 23:59
/// is out of range rather than invalid.
fn parseTimeOfDay(text: []const u8) Error!TimeOfDay {
    if (text.len != 5 or text[2] != ':') return error.InvalidValue;
    const hour = try parseDigits(text[0..2]);
    const minute = try parseDigits(text[3..5]);
    if (hour > 23 or minute > 59) return error.OutOfRange;
    return .{ .hour = @intCast(hour), .minute = @intCast(minute) };
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
