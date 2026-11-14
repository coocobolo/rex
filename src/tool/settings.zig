//! Settings window (`rex settings`): sidebar-navigated form generated from
//! `config.keys.table`, saving edits immediately via `config.writer.writeKey`
//! and validating through `config.Loaded.load`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const kit = @import("../kit/root.zig");
const host = @import("host.zig");
const Config = @import("../config/Config.zig");
const Loaded = @import("../config/Loaded.zig");
const keys = @import("../config/keys.zig");
const config_defaults = @import("../config/default.zig");
const config_paths = @import("../config/paths.zig");
const config_writer = @import("../config/writer.zig");
const config_font = @import("../config/font.zig");
const ThemePreset = @import("../color/Theme.zig");

const sidebar = kit.sidebar;
const popup = kit.popup;
const switch_control = kit.switch_control;
const checkbox = kit.checkbox;
const toggle = kit.toggle;
const select = kit.select;
const slider = kit.slider;
const input = kit.input;
const Theme = kit.Theme;
const Tree = kit.tree.Tree;
const Id = kit.tree.Id;

pub const name = "settings";
pub const title = "Rex Settings";

pub const node_max = 1536;
pub const line_max = 1024;

pub const Page = enum(u8) {
    appearance,
    window_shell,
    overlays,
    wellbeing,
    focus_winddown,
    reminders,
};

const groups = [_]sidebar.Group{
    .{ .label = "Terminal", .items = &.{
        .{ .label = "Appearance" },
        .{ .label = "Window & Shell" },
        .{ .label = "Overlays" },
    } },
    .{ .label = "Wellbeing", .items = &.{
        .{ .label = "Screen Time & Privacy" },
        .{ .label = "Focus & Wind-down" },
        .{ .label = "Reminders" },
    } },
};
const page_count = sidebar.itemCount(&groups);

const page_titles = [_][]const u8{
    "Appearance",
    "Window & Shell",
    "Overlays",
    "Screen Time & Privacy",
    "Focus & Wind-down",
    "Reminders",
};

const page_descriptions = [_][]const u8{
    "Theme, UI motion, color scheme, and font configuration.",
    "Window behavior, bell, scrolling, selection, clipboard, and shell.",
    "Toasts, banners, and modal dialogs.",
    "Wellbeing tracking, daily screen time limits, and dashboard charts.",
    "Pomodoro focus intervals, alerts, and evening wind-down schedule.",
    "Periodic eyesight and movement break reminders.",
};

pub fn pageForSection(section: keys.Section) ?Page {
    return switch (section) {
        .root, .font, .ui => .appearance,
        .window, .bell, .scroll, .selection, .clipboard, .shell => .window_shell,
        .toast, .banner, .modal, .@"modal.blur" => .overlays,
        .wellbeing, .@"wellbeing.screen_time", .@"wellbeing.privacy", .@"wellbeing.dashboard" => .wellbeing,
        .@"wellbeing.focus", .@"wellbeing.winddown" => .focus_winddown,
        .@"wellbeing.eyesight", .@"wellbeing.movement" => .reminders,
        .@"wellbeing.routines", .keybinds, .env => null,
    };
}

comptime {
    for (keys.table) |key| {
        if (pageForSection(key.section) == null) {
            @compileError("unmapped config section in settings: " ++ @tagName(key.section));
        }
    }
}

const section_titles = std.EnumArray(keys.Section, []const u8).init(.{
    .root = "General",
    .font = "Font",
    .window = "Window",
    .bell = "Bell",
    .toast = "Toast",
    .banner = "Banner",
    .modal = "Modal",
    .@"modal.blur" = "Modal Blur",
    .wellbeing = "General",
    .@"wellbeing.screen_time" = "Screen Time",
    .@"wellbeing.focus" = "Focus Timer",
    .@"wellbeing.winddown" = "Wind-down",
    .@"wellbeing.eyesight" = "Eyesight Reminder",
    .@"wellbeing.movement" = "Movement Reminder",
    .@"wellbeing.routines" = "Routines",
    .@"wellbeing.privacy" = "Privacy",
    .@"wellbeing.dashboard" = "Dashboard",
    .ui = "Interface",
    .scroll = "Scroll",
    .selection = "Selection",
    .clipboard = "Clipboard",
    .shell = "Shell",
    .keybinds = "Keybinds",
    .env = "Environment",
});

const KeyMeta = struct {
    label: []const u8,
    description: []const u8,
};

fn keyMeta(comptime section: keys.Section, comptime key_name: []const u8) KeyMeta {
    return switch (section) {
        .root => if (std.mem.eql(u8, key_name, "theme")) .{
            .label = "Color Theme",
            .description = "Built-in terminal color palette preset.",
        } else @compileError("unmapped root key: " ++ key_name),

        .font => if (std.mem.eql(u8, key_name, "file")) .{
            .label = "Regular Font",
            .description = "Path to the primary monospace font file (or built-in default).",
        } else if (std.mem.eql(u8, key_name, "bold_file")) .{
            .label = "Bold Font",
            .description = "Path to the bold font face, or none to synthesize from regular.",
        } else if (std.mem.eql(u8, key_name, "italic_file")) .{
            .label = "Italic Font",
            .description = "Path to the italic font face, or none.",
        } else if (std.mem.eql(u8, key_name, "bold_italic_file")) .{
            .label = "Bold Italic Font",
            .description = "Path to the bold italic font face, or none.",
        } else if (std.mem.eql(u8, key_name, "emoji_file")) .{
            .label = "Emoji Font",
            .description = "Path to a color emoji font file, or none.",
        } else if (std.mem.eql(u8, key_name, "fallback")) .{
            .label = "Fallback Fonts",
            .description = "Ordered list of fallback font files for missing glyphs.",
        } else if (std.mem.eql(u8, key_name, "size")) .{
            .label = "Font Size",
            .description = "Default terminal font size in points.",
        } else if (std.mem.eql(u8, key_name, "size_step")) .{
            .label = "Zoom Step",
            .description = "Amount added or subtracted when zooming text in or out.",
        } else if (std.mem.eql(u8, key_name, "min_size")) .{
            .label = "Minimum Font Size",
            .description = "Smallest font size allowed when zooming out.",
        } else if (std.mem.eql(u8, key_name, "max_size")) .{
            .label = "Maximum Font Size",
            .description = "Largest font size allowed when zooming in.",
        } else if (std.mem.eql(u8, key_name, "weight")) .{
            .label = "Regular Weight",
            .description = "Variable font weight axis (wght) for regular text (1–1000).",
        } else if (std.mem.eql(u8, key_name, "bold_weight")) .{
            .label = "Bold Weight",
            .description = "Variable font weight axis (wght) for bold text (1–1000).",
        } else @compileError("unmapped font key: " ++ key_name),

        .ui => if (std.mem.eql(u8, key_name, "motion")) .{
            .label = "Interface Motion",
            .description = "Animate UI transitions or switch immediately.",
        } else if (std.mem.eql(u8, key_name, "color_scheme")) .{
            .label = "UI Color Scheme",
            .description = "Light or dark appearance for tool windows and overlays.",
        } else @compileError("unmapped ui key: " ++ key_name),

        .window => if (std.mem.eql(u8, key_name, "background_opacity")) .{
            .label = "Background Opacity",
            .description = "Terminal background opacity from 0.0 (transparent) to 1.0 (solid).",
        } else if (std.mem.eql(u8, key_name, "dim_text_opacity")) .{
            .label = "Dim Text Opacity",
            .description = "Opacity multiplier applied to SGR dim text (0.0–1.0).",
        } else if (std.mem.eql(u8, key_name, "on_close")) .{
            .label = "Close Behavior",
            .description = "Whether to confirm before closing when child processes are active.",
        } else if (std.mem.eql(u8, key_name, "platform")) .{
            .label = "Window Platform",
            .description = "Display server backend to use on Linux (auto, Wayland, or X11).",
        } else if (std.mem.eql(u8, key_name, "width")) .{
            .label = "Initial Width",
            .description = "Default window width in logical pixels on startup.",
        } else if (std.mem.eql(u8, key_name, "height")) .{
            .label = "Initial Height",
            .description = "Default window height in logical pixels on startup.",
        } else if (std.mem.eql(u8, key_name, "title")) .{
            .label = "Window Title",
            .description = "Static window title, or auto to follow the running program.",
        } else @compileError("unmapped window key: " ++ key_name),

        .bell => if (std.mem.eql(u8, key_name, "enabled")) .{
            .label = "Audible Bell",
            .description = "Play a sound when the terminal receives a BEL character.",
        } else if (std.mem.eql(u8, key_name, "volume")) .{
            .label = "Bell Volume",
            .description = "Playback volume for the terminal bell (0.0–1.0).",
        } else @compileError("unmapped bell key: " ++ key_name),

        .scroll => if (std.mem.eql(u8, key_name, "step_lines")) .{
            .label = "Keyboard Scroll Lines",
            .description = "Lines scrolled per keyboard scroll-up or scroll-down action.",
        } else if (std.mem.eql(u8, key_name, "wheel_lines")) .{
            .label = "Wheel Scroll Lines",
            .description = "Lines scrolled per mouse wheel notch.",
        } else @compileError("unmapped scroll key: " ++ key_name),

        .selection => if (std.mem.eql(u8, key_name, "extra_word_characters")) .{
            .label = "Extra Word Characters",
            .description = "Additional ASCII symbols treated as part of a word on double-click.",
        } else @compileError("unmapped selection key: " ++ key_name),

        .clipboard => if (std.mem.eql(u8, key_name, "osc52_write")) .{
            .label = "OSC 52 Write",
            .description = "Allow terminal programs to copy text to the system clipboard.",
        } else if (std.mem.eql(u8, key_name, "osc52_read")) .{
            .label = "OSC 52 Read",
            .description = "Allow terminal programs to read from the system clipboard.",
        } else @compileError("unmapped clipboard key: " ++ key_name),

        .shell => if (std.mem.eql(u8, key_name, "program")) .{
            .label = "Shell Program",
            .description = "Absolute or ~/ path to the shell executable, or auto for $SHELL.",
        } else if (std.mem.eql(u8, key_name, "argument")) .{
            .label = "Shell Arguments",
            .description = "Arguments passed to the shell on startup.",
        } else if (std.mem.eql(u8, key_name, "working_directory")) .{
            .label = "Working Directory",
            .description = "Starting directory for new shells, or inherit from the launcher.",
        } else @compileError("unmapped shell key: " ++ key_name),

        .toast, .banner, .modal => overlayMeta(section, key_name),

        .@"modal.blur" => if (std.mem.eql(u8, key_name, "enabled")) .{
            .label = "Backdrop Blur",
            .description = "Blur the terminal grid behind modal dialogs.",
        } else if (std.mem.eql(u8, key_name, "radius")) .{
            .label = "Blur Radius",
            .description = "Blur strength in pixels behind modal dialogs.",
        } else @compileError("unmapped modal.blur key: " ++ key_name),

        .wellbeing => if (std.mem.eql(u8, key_name, "enabled")) .{
            .label = "Enable Wellbeing",
            .description = "Track screen time and enable focus timers, reminders, and wind-down.",
        } else @compileError("unmapped wellbeing key: " ++ key_name),

        .@"wellbeing.screen_time" => if (std.mem.eql(u8, key_name, "daily_limit")) .{
            .label = "Daily Screen Limit",
            .description = "Maximum daily terminal time before limit actions trigger (or none).",
        } else if (std.mem.eql(u8, key_name, "idle_threshold")) .{
            .label = "Idle Threshold",
            .description = "Inactivity duration before screen time tracking pauses.",
        } else if (std.mem.eql(u8, key_name, "on_limit")) .{
            .label = "On Daily Limit",
            .description = "Actions triggered when you reach your daily screen time limit.",
        } else if (std.mem.eql(u8, key_name, "grayscale_transition")) .{
            .label = "Grayscale Transition",
            .description = "Duration over which the screen fades to grayscale on limit.",
        } else @compileError("unmapped wellbeing.screen_time key: " ++ key_name),

        .@"wellbeing.privacy" => if (std.mem.eql(u8, key_name, "track_foreground_apps")) .{
            .label = "Track Foreground Apps",
            .description = "Record which foreground programs you spend time in.",
        } else @compileError("unmapped wellbeing.privacy key: " ++ key_name),

        .@"wellbeing.dashboard" => if (std.mem.eql(u8, key_name, "timer_chart")) .{
            .label = "Timer Chart Style",
            .description = "Visualization style for the focus timer on the dashboard.",
        } else if (std.mem.eql(u8, key_name, "program_chart")) .{
            .label = "Program Chart Style",
            .description = "Visualization style for per-program usage on the dashboard.",
        } else @compileError("unmapped wellbeing.dashboard key: " ++ key_name),

        .@"wellbeing.focus" => if (std.mem.eql(u8, key_name, "task")) .{
            .label = "Focus Duration",
            .description = "Length of a single focused work interval (e.g. 25m).",
        } else if (std.mem.eql(u8, key_name, "short_break")) .{
            .label = "Short Break",
            .description = "Length of a short break between focus intervals (e.g. 5m).",
        } else if (std.mem.eql(u8, key_name, "long_break")) .{
            .label = "Long Break",
            .description = "Length of a longer break after a full cycle (e.g. 15m).",
        } else if (std.mem.eql(u8, key_name, "tasks_before_long_break")) .{
            .label = "Intervals Before Long Break",
            .description = "Number of focus intervals completed before taking a long break.",
        } else if (std.mem.eql(u8, key_name, "timer")) .{
            .label = "Timer Display",
            .description = "Where the focus countdown is shown while active.",
        } else if (std.mem.eql(u8, key_name, "on_phase_end")) .{
            .label = "On Phase End",
            .description = "Automatically advance to the next phase or wait for confirmation.",
        } else if (std.mem.eql(u8, key_name, "during_task")) .{
            .label = "During Focus",
            .description = "UI indicators or behaviors active during a focus interval.",
        } else if (std.mem.eql(u8, key_name, "on_break")) .{
            .label = "On Break",
            .description = "Actions triggered when a focus interval transitions into a break.",
        } else if (std.mem.eql(u8, key_name, "on_alert")) .{
            .label = "On Alert",
            .description = "Notification cues played when a focus phase ends.",
        } else @compileError("unmapped wellbeing.focus key: " ++ key_name),

        .@"wellbeing.winddown" => if (std.mem.eql(u8, key_name, "enabled")) .{
            .label = "Evening Wind-down",
            .description = "Shift terminal colors warmer during your scheduled wind-down hours.",
        } else if (std.mem.eql(u8, key_name, "start")) .{
            .label = "Start Time",
            .description = "24-hour clock time when wind-down begins (HH:MM).",
        } else if (std.mem.eql(u8, key_name, "end")) .{
            .label = "End Time",
            .description = "24-hour clock time when wind-down ends (HH:MM).",
        } else if (std.mem.eql(u8, key_name, "warmth")) .{
            .label = "Warmth Intensity",
            .description = "Color temperature shift intensity from 0.0 to 1.0.",
        } else if (std.mem.eql(u8, key_name, "during_window")) .{
            .label = "During Wind-down",
            .description = "Additional effects active during the wind-down schedule.",
        } else @compileError("unmapped wellbeing.winddown key: " ++ key_name),

        .@"wellbeing.eyesight" => reminderMeta("Eyesight", key_name),
        .@"wellbeing.movement" => reminderMeta("Movement", key_name),
        else => @compileError("unmapped section in keyMeta: " ++ @tagName(section)),
    };
}

fn overlayMeta(comptime section: keys.Section, comptime key_name: []const u8) KeyMeta {
    if (std.mem.eql(u8, key_name, "enabled")) return .{
        .label = if (section == .toast) "Enable Toasts" else "Enable Banners",
        .description = if (section == .toast)
            "Show transient toast notifications inside the terminal."
        else
            "Show persistent status banners inside the terminal.",
    };
    if (std.mem.eql(u8, key_name, "duration")) return .{
        .label = "Display Duration",
        .description = "How long a toast remains visible before dismissing.",
    };
    if (std.mem.eql(u8, key_name, "backdrop_opacity")) return .{
        .label = "Backdrop Opacity",
        .description = "Dimming opacity of the backdrop behind modal dialogs (0.0–1.0).",
    };
    if (std.mem.eql(u8, key_name, "on_outside_click")) return .{
        .label = "Outside Click",
        .description = "Whether clicking outside a modal dialog dismisses it.",
    };
    if (std.mem.eql(u8, key_name, "default_focus")) return .{
        .label = "Default Focus",
        .description = "Which button receives initial keyboard focus in a modal dialog.",
    };
    @compileError("unmapped overlay key: " ++ @tagName(section) ++ "." ++ key_name);
}

fn reminderMeta(comptime kind: []const u8, comptime key_name: []const u8) KeyMeta {
    if (std.mem.eql(u8, key_name, "enabled")) return .{
        .label = "Enable " ++ kind ++ " Reminders",
        .description = "Show periodic " ++ kind ++ " break reminders while active.",
    };
    if (std.mem.eql(u8, key_name, "interval")) return .{
        .label = "Reminder Interval",
        .description = "How often the " ++ kind ++ " reminder triggers (e.g. 20m).",
    };
    if (std.mem.eql(u8, key_name, "duration")) return .{
        .label = "Break Duration",
        .description = "How long the " ++ kind ++ " break lasts (e.g. 20s).",
    };
    if (std.mem.eql(u8, key_name, "during_reminder")) return .{
        .label = "During Reminder",
        .description = "Effects and cues active while the reminder is displayed.",
    };
    if (std.mem.eql(u8, key_name, "animation")) return .{
        .label = "Reminder Animation",
        .description = "Visual animation style for the reminder overlay.",
    };
    @compileError("unmapped reminder key: " ++ key_name);
}

fn inputPlaceholder(comptime key: keys.Key) []const u8 {
    if (key.null_keyword) |kw| {
        return switch (kw) {
            .none => if (key.section == .font)
                "none (synthesized)"
            else if (std.mem.eql(u8, key.name, "daily_limit"))
                "none (no limit)"
            else
                "none",
            .auto => if (key.section == .shell)
                "auto (default shell)"
            else if (key.section == .window and std.mem.eql(u8, key.name, "title"))
                "auto (terminal title)"
            else
                "auto",
            .inherit => if (key.section == .shell)
                "inherit (current dir)"
            else
                "inherit",
        };
    }
    return switch (key.kind) {
        .path => "/path/to/font.ttf",
        .font_fallback => "Add fallback font path...",
        .program_path => "/bin/zsh",
        .shell_argument => "Add argument...",
        .directory_path => "~/projects",
        .duration => "e.g. 25m",
        .time_of_day => "e.g. 22:00",
        .word_characters => "e.g. _-~.",
        .text => "Enter text...",
        .infer => "Enter number...",
        else => "",
    };
}

fn humanToken(comptime token: []const u8) []const u8 {
    if (std.mem.eql(u8, token, "x11")) return "X11";
    if (std.mem.eql(u8, token, "wayland")) return "Wayland";
    if (std.mem.eql(u8, token, "auto")) return "Automatic";
    if (std.mem.eql(u8, token, "none")) return "None";
    if (std.mem.eql(u8, token, "inherit")) return "Inherit";
    if (std.mem.eql(u8, token, "when_needed")) return "When needed";
    if (std.mem.eql(u8, token, "allow_always")) return "Always allow";
    if (std.mem.eql(u8, token, "grayscale")) return "Grayscale screen";
    if (std.mem.eql(u8, token, "dim_background")) return "Dim background";
    if (std.mem.eql(u8, token, "break_screen")) return "Show break screen";
    if (std.mem.eql(u8, token, "lock_screen")) return "Lock screen";
    if (std.mem.eql(u8, token, "top_left")) return "Top left";
    if (std.mem.eql(u8, token, "top_center")) return "Top center";
    if (std.mem.eql(u8, token, "top_right")) return "Top right";
    if (std.mem.eql(u8, token, "bottom_left")) return "Bottom left";
    if (std.mem.eql(u8, token, "bottom_center")) return "Bottom center";
    if (std.mem.eql(u8, token, "bottom_right")) return "Bottom right";
    if (std.mem.eql(u8, token, "catppuccin_mocha")) return "Catppuccin Mocha";
    if (std.mem.eql(u8, token, "catppuccin_latte")) return "Catppuccin Latte";
    if (std.mem.eql(u8, token, "gruvbox_dark")) return "Gruvbox Dark";
    if (std.mem.eql(u8, token, "tokyo_night")) return "Tokyo Night";
    if (std.mem.eql(u8, token, "solarized_dark")) return "Solarized Dark";
    if (std.mem.eql(u8, token, "solarized_light")) return "Solarized Light";
    if (std.mem.eql(u8, token, "one_dark")) return "One Dark";

    comptime {
        var out: [token.len]u8 = undefined;
        for (token, 0..) |c, i| {
            if (i == 0 and c >= 'a' and c <= 'z') {
                out[i] = c - 32;
            } else if (c == '_') {
                out[i] = ' ';
            } else {
                out[i] = c;
            }
        }
        const final = out;
        return &final;
    }
}

const font_weight_presets = [_]struct {
    value: []const u8,
    weight: f32,
    label: []const u8,
}{
    .{ .value = "100", .weight = 100, .label = "100 · Thin" },
    .{ .value = "200", .weight = 200, .label = "200 · Extra Light" },
    .{ .value = "300", .weight = 300, .label = "300 · Light" },
    .{ .value = "400", .weight = 400, .label = "400 · Regular" },
    .{ .value = "500", .weight = 500, .label = "500 · Medium" },
    .{ .value = "600", .weight = 600, .label = "600 · Semi Bold" },
    .{ .value = "700", .weight = 700, .label = "700 · Bold" },
    .{ .value = "800", .weight = 800, .label = "800 · Extra Bold" },
    .{ .value = "900", .weight = 900, .label = "900 · Black" },
};

const DurationUnit = enum(u8) {
    ms,
    s,
    m,
    h,
    none,

    fn suffix(self: DurationUnit) []const u8 {
        return switch (self) {
            .ms => "ms",
            .s => "s",
            .m => "m",
            .h => "h",
            .none => "none",
        };
    }

    fn shortLabel(self: DurationUnit) []const u8 {
        return switch (self) {
            .ms => "ms",
            .s => "s",
            .m => "m",
            .h => "h",
            .none => "Off",
        };
    }

    fn label(self: DurationUnit) []const u8 {
        return switch (self) {
            .ms => "Milliseconds (ms)",
            .s => "Seconds (s)",
            .m => "Minutes (m)",
            .h => "Hours (h)",
            .none => "No limit",
        };
    }
};

const ControlKind = enum {
    toggle,
    slider,
    duration,
    stepper,
    select,
    enum_set,
    list,
    text_input,
};

fn controlKind(comptime key: keys.Key) ControlKind {
    if (key.kind == .theme or key.kind == .font_weight) return .select;
    if (key.kind == .fraction) return .slider;
    if (key.kind == .duration) return .duration;
    if (key.kind == .font_fallback or key.kind == .shell_argument) return .list;
    const T = keys.FieldType(Config, key.field);
    if (key.kind == .set) return .enum_set;
    return switch (@typeInfo(T)) {
        .bool => .toggle,
        .@"enum" => .select,
        .int, .float => .stepper,
        .optional => |opt| switch (@typeInfo(opt.child)) {
            .@"enum" => .select,
            .int, .float => .stepper,
            else => .text_input,
        },
        else => .text_input,
    };
}

pub const Target = union(enum) {
    none,
    sidebar,
    key_switch: u16,
    key_slider: u16,
    key_select: u16,
    select_choice: usize,
    key_checkbox: struct { key: u16, bit: u8 },
    key_input: u16,
    stepper_dec: u16,
    stepper_inc: u16,
    list_add: u16,
    list_up: struct { key: u16, item: u16 },
    list_down: struct { key: u16, item: u16 },
    list_remove: struct { key: u16, item: u16 },
    layer,
};

const layer_id = Id.of("settings.layer");
const scroll_area_id = Id.of("settings.scroll_area");

fn switchId(idx: u16) Id {
    return Id.of("settings.switch").item(idx);
}

fn sliderId(idx: u16) Id {
    return Id.of("settings.slider").item(idx);
}

fn decId(idx: u16) Id {
    return Id.of("settings.dec").item(idx);
}

fn incId(idx: u16) Id {
    return Id.of("settings.inc").item(idx);
}

fn selectId(idx: u16) Id {
    return Id.of("settings.select").item(idx);
}

fn choiceId(idx: usize) Id {
    return Id.of("settings.choice").item(@intCast(idx));
}

fn checkboxId(idx: u16, bit: u8) Id {
    return Id.of("settings.check").item(@as(u32, idx) * 32 + bit);
}

fn inputId(idx: u16) Id {
    return Id.of("settings.input").item(idx);
}

fn listAddId(idx: u16) Id {
    return Id.of("settings.list_add").item(idx);
}

fn listUpId(idx: u16, item: usize) Id {
    return Id.of("settings.list_up").item(@as(u32, idx) * 256 + @as(u32, @intCast(item)));
}

fn listDownId(idx: u16, item: usize) Id {
    return Id.of("settings.list_dn").item(@as(u32, idx) * 256 + @as(u32, @intCast(item)));
}

fn listRemoveId(idx: u16, item: usize) Id {
    return Id.of("settings.list_rm").item(@as(u32, idx) * 256 + @as(u32, @intCast(item)));
}

pub const State = struct {
    gpa: Allocator,
    io: std.Io,
    config_path: []const u8,
    home_dir: []const u8,
    clipboard: host.Clipboard,
    node_rect: host.NodeRect = .{},
    initial_config: *const Config,
    loaded: ?Loaded = null,
    frame: sidebar.State = .{},
    scroll: f32 = 0,
    scroll_max: f32 = 0,
    viewport_width: f32 = 960,
    viewport_height: f32 = 600,
    pointer_x: f32 = 0,
    hover: Target = .none,
    pressed: Target = .none,
    focused: Target = .none,
    dragging_slider: ?u16 = null,
    open_select: ?struct { key: u16, highlight: usize } = null,
    inputs: [keys.table.len]input.State = [_]input.State{.{}} ** keys.table.len,
    list_items: [keys.table.len]std.ArrayListUnmanaged([]u8) = [_]std.ArrayListUnmanaged([]u8){.empty} ** keys.table.len,
    duration_units: [keys.table.len]DurationUnit = [_]DurationUnit{.ms} ** keys.table.len,
    slider_values: [keys.table.len]f32 = [_]f32{0} ** keys.table.len,
    dirty: [keys.table.len]bool = [_]bool{false} ** keys.table.len,
    error_key: ?u16 = null,
    error_msg: std.ArrayListUnmanaged(u8) = .empty,

    pub fn activeConfig(self: *const State) *const Config {
        if (self.loaded) |*l| return &l.config;
        return self.initial_config;
    }
};

pub fn init(context: host.Context) !State {
    var state: State = .{
        .gpa = context.gpa,
        .io = context.io,
        .config_path = context.config_path,
        .home_dir = context.home_dir,
        .clipboard = context.clipboard,
        .node_rect = context.node_rect,
        .initial_config = context.config,
    };
    errdefer deinit(&state);
    try syncInputs(&state);
    return state;
}

pub fn deinit(state: *State) void {
    for (&state.inputs) |*inp| inp.deinit(state.gpa);
    for (&state.list_items) |*list| {
        for (list.items) |item| state.gpa.free(item);
        list.deinit(state.gpa);
    }
    state.error_msg.deinit(state.gpa);
    if (state.loaded) |*l| l.deinit(state.gpa);
}

fn clearListItems(gpa: Allocator, list: *std.ArrayListUnmanaged([]u8)) void {
    for (list.items) |item| gpa.free(item);
    list.clearRetainingCapacity();
}

fn sliderValue(idx: u16, cfg: *const Config) f32 {
    @setEvalBranchQuota(keys.eval_branch_quota);
    inline for (keys.table, 0..) |key, i| {
        if (comptime controlKind(key) == .slider) {
            if (i == idx) return @floatCast(keys.fieldValue(Config, key.field, cfg));
        }
    }
    return 0;
}

fn durationMs(idx: u16, cfg: *const Config) ?u64 {
    @setEvalBranchQuota(keys.eval_branch_quota);
    inline for (keys.table, 0..) |key, i| {
        if (comptime controlKind(key) == .duration) {
            if (i == idx) {
                const val = keys.fieldValue(Config, key.field, cfg);
                return switch (@typeInfo(@TypeOf(val))) {
                    .optional => if (val) |v| @intCast(v) else null,
                    else => @intCast(val),
                };
            }
        }
    }
    return null;
}

fn formatSigned(val: i64, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{val}) catch "";
}

fn formatTime(hour: u8, minute: u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ hour, minute }) catch "";
}

fn readInputValue(idx: u16, cfg: *const Config, buf: []u8) []const u8 {
    @setEvalBranchQuota(keys.eval_branch_quota);
    inline for (keys.table, 0..) |key, i| {
        if (comptime controlKind(key) == .text_input or controlKind(key) == .stepper) {
            if (i == idx) {
                const val = keys.fieldValue(Config, key.field, cfg);
                return formatInputField(key.kind, @TypeOf(val), val, buf);
            }
        }
    }
    return "";
}

fn formatInputField(comptime kind: keys.Kind, comptime T: type, val: T, buf: []u8) []const u8 {
    if (@typeInfo(T) == .optional) {
        const inner = val orelse return "";
        return formatInputNonOptional(kind, @typeInfo(T).optional.child, inner, buf);
    }
    return formatInputNonOptional(kind, T, val, buf);
}

fn formatInputNonOptional(comptime kind: keys.Kind, comptime T: type, val: T, buf: []u8) []const u8 {
    if (kind == .time_of_day) return formatTime(val.hour, val.minute, buf);
    if (kind == .path or kind == .program_path or kind == .directory_path) {
        if (T == config_font.Face) return std.mem.span(val.path);
        if (T == [*:0]const u8) return std.mem.span(val);
        return val;
    }
    if (kind == .text or kind == .word_characters) return val;

    return switch (@typeInfo(T)) {
        .bool => if (val) "true" else "false",
        .@"enum" => @tagName(val),
        .int => formatSigned(@intCast(val), buf),
        .float => formatFloat(@floatCast(val), buf),
        else => "",
    };
}

fn syncInputs(state: *State) Allocator.Error!void {
    const cfg = state.activeConfig();
    var buf: [512]u8 = undefined;
    for (row_infos, 0..) |info, i| {
        const idx: u16 = @intCast(i);
        switch (info.kind) {
            .text_input, .stepper => if (!state.dirty[i]) {
                const text = readInputValue(idx, cfg, &buf);
                try state.inputs[i].setText(state.gpa, text);
            },
            .duration => if (!state.dirty[i]) {
                const parsed = splitDurationMs(durationMs(idx, cfg), &buf);
                state.duration_units[i] = parsed.unit;
                try state.inputs[i].setText(state.gpa, parsed.text);
            },
            .slider => {
                if (state.dragging_slider != idx) {
                    state.slider_values[i] = std.math.clamp(sliderValue(idx, cfg), 0.0, 1.0);
                }
            },
            .list => if (!state.dirty[i]) {
                clearListItems(state.gpa, &state.list_items[i]);
                if (info.key_kind == .font_fallback) {
                    for (cfg.font.faces.fallbacks) |face| {
                        try state.list_items[i].append(state.gpa, try state.gpa.dupe(u8, std.mem.span(face.path)));
                    }
                } else if (info.key_kind == .shell_argument) {
                    for (cfg.shell.arguments) |arg| {
                        try state.list_items[i].append(state.gpa, try state.gpa.dupe(u8, arg));
                    }
                }
            },
            else => {},
        }
    }
}

pub fn update(state: *State, event: host.Event) bool {
    switch (event) {
        .size => |size| {
            const changed = state.frame.update(page_count, .{ .width = size.width });
            const w_changed = state.viewport_width != size.width;
            const h_changed = state.viewport_height != size.height;
            state.viewport_width = size.width;
            state.viewport_height = size.height;
            return changed or w_changed or h_changed;
        },
        .pointer => |pointer| {
            state.pointer_x = pointer.x;
            if (state.dragging_slider) |idx| {
                return updateSliderFromPointer(state, idx, pointer.x);
            }
            const sb = state.frame.update(page_count, .{ .pointer = sidebar.hit(pointer.id, page_count) });
            const next_hover = over(state, pointer.id);
            const h_changed = !std.meta.eql(state.hover, next_hover);
            state.hover = next_hover;
            if (state.open_select) |*sel| {
                if (next_hover == .select_choice) {
                    const idx = next_hover.select_choice;
                    if (sel.highlight != idx) {
                        sel.highlight = idx;
                        return true;
                    }
                }
            }
            return sb or h_changed;
        },
        .press => |id| {
            if (state.open_select != null and id == layer_id) {
                state.open_select = null;
                state.pressed = .none;
                return true;
            }
            const target = over(state, id);
            if (target == .key_slider) {
                const idx = target.key_slider;
                blurFocused(state);
                state.focused = target;
                state.dragging_slider = idx;
                _ = updateSliderFromPointer(state, idx, state.pointer_x);
                return true;
            }
            if (target != .none) {
                state.pressed = target;
                return false;
            }
            const prev_page = state.frame.current;
            const sb = state.frame.update(page_count, .{ .press = sidebar.hit(id, page_count) });
            if (state.frame.current != prev_page) {
                blurFocused(state);
                state.scroll = 0;
                state.scroll_max = 0;
            } else if (state.focused != .none) {
                blurFocused(state);
                return true;
            }
            return sb;
        },
        .release => {
            if (state.dragging_slider) |idx| {
                state.dragging_slider = null;
                commitSlider(state, idx);
                return true;
            }
            const sb = state.frame.update(page_count, .release);
            const target = state.pressed;
            state.pressed = .none;
            if (std.meta.eql(target, state.hover)) {
                if (activate(state, target)) return true;
            }
            return sb;
        },
        .scroll => |wheel| {
            state.scroll_max = wheel.max;
            const next = std.math.clamp(state.scroll + wheel.dy, 0, wheel.max);
            if (next == state.scroll) return false;
            state.scroll = next;
            return true;
        },
        .char => |cp| {
            if (state.open_select != null) return false;
            if (state.focused != .key_input) return false;
            const idx = state.focused.key_input;
            const changed = state.inputs[idx].insertChar(state.gpa, cp) catch return false;
            if (changed) state.dirty[idx] = true;
            return changed;
        },
        .key => |press| return handleKey(state, press),
    }
}

fn handleKey(state: *State, press: host.KeyPress) bool {
    if (state.open_select) |*sel| {
        const count = selectChoiceCount(sel.key);
        switch (press.key) {
            .up => {
                sel.highlight -|= 1;
                return true;
            },
            .down => {
                if (count > 0) sel.highlight = @min(sel.highlight + 1, count - 1);
                return true;
            },
            .enter => {
                if (isEnumSetKey(sel.key)) {
                    toggleCheckbox(state, sel.key, @intCast(sel.highlight));
                } else {
                    chooseSelect(state, sel.key, sel.highlight);
                }
                return true;
            },
            .escape => {
                state.open_select = null;
                return true;
            },
            .tab => return cycleFocus(state, press.mods.shift),
            else => return false,
        }
    }

    if (state.focused == .key_slider) {
        const idx = state.focused.key_slider;
        const step: f32 = if (press.mods.shift) 0.01 else 0.05;
        const next: ?f32 = switch (press.key) {
            .left => @max(0.0, state.slider_values[idx] - step),
            .right => @min(1.0, state.slider_values[idx] + step),
            .home => 0.0,
            .end => 1.0,
            .escape => {
                state.focused = .none;
                return true;
            },
            else => null,
        };
        if (next) |v| {
            const rounded = @round(v * 100.0) / 100.0;
            state.slider_values[idx] = rounded;
            commitSlider(state, idx);
            return true;
        }
    }

    if (state.focused == .key_input) {
        const idx = state.focused.key_input;
        const inp = &state.inputs[idx];
        if (press.mods.ctrl) {
            switch (press.key) {
                .a => return inp.apply(.select_all),
                .c => {
                    copySelection(state, inp);
                    return false;
                },
                .x => {
                    copySelection(state, inp);
                    const changed = inp.deleteSelection();
                    if (changed) state.dirty[idx] = true;
                    return changed;
                },
                .v => {
                    if (state.clipboard.get()) |clip| {
                        const changed = inp.insertSlice(state.gpa, clip) catch false;
                        if (changed) state.dirty[idx] = true;
                        return changed;
                    }
                    return false;
                },
                else => {},
            }
        }
        switch (press.key) {
            .backspace => {
                const changed = inp.apply(.backspace);
                if (changed) state.dirty[idx] = true;
                return changed;
            },
            .delete => {
                const changed = inp.apply(.delete);
                if (changed) state.dirty[idx] = true;
                return changed;
            },
            .left => return inp.apply(if (press.mods.shift) .select_left else .left),
            .right => return inp.apply(if (press.mods.shift) .select_right else .right),
            .home => return inp.apply(if (press.mods.shift) .select_home else .home),
            .end => return inp.apply(if (press.mods.shift) .select_end else .end),
            .up => if (isStepperKey(idx)) {
                stepNumber(state, idx, if (press.mods.shift) 10 else 1);
                return true;
            } else return false,
            .down => if (isStepperKey(idx)) {
                stepNumber(state, idx, if (press.mods.shift) -10 else -1);
                return true;
            } else return false,
            .enter => {
                if (keys.isList(idx)) {
                    addListItem(state, idx);
                } else {
                    commitInput(state, idx);
                }
                return true;
            },
            .tab => return cycleFocus(state, press.mods.shift),
            .escape => {
                state.dirty[idx] = false;
                syncInputs(state) catch {};
                state.focused = .none;
                return true;
            },
            else => return false,
        }
    }

    if (press.key == .tab) {
        return cycleFocus(state, press.mods.shift);
    }

    switch (state.focused) {
        .key_switch => |idx| switch (press.key) {
            .enter, .space => return activate(state, .{ .key_switch = idx }),
            .escape => {
                state.focused = .none;
                return true;
            },
            else => {},
        },
        .key_select => |idx| switch (press.key) {
            .enter, .space, .down => return activate(state, .{ .key_select = idx }),
            .escape => {
                state.focused = .none;
                return true;
            },
            else => {},
        },
        .sidebar => switch (press.key) {
            .enter, .space => return cycleFocus(state, false),
            .escape => {
                _ = state.frame.update(page_count, .blur);
                state.focused = .none;
                return true;
            },
            else => {},
        },
        else => {},
    }

    const prev_page = state.frame.current;
    const moved = switch (press.key) {
        .up => state.frame.update(page_count, .{ .move = .previous }),
        .down => state.frame.update(page_count, .{ .move = .next }),
        .home => state.frame.update(page_count, .first),
        .end => state.frame.update(page_count, .last),
        .f9 => state.frame.update(page_count, .toggle),
        else => false,
    };
    if (state.frame.current != prev_page) {
        state.scroll = 0;
        state.scroll_max = 0;
        if (state.focused != .sidebar) state.focused = .none;
    }
    if (!state.frame.shown() and state.focused == .sidebar) {
        state.focused = .none;
    }
    return moved;
}

fn pageFocusTargets(page: Page, out: []Target) usize {
    var count: usize = 0;
    for (row_infos, 0..) |info, i| {
        const idx: u16 = @intCast(i);
        if (keys.availableHere(idx) and info.page == page) {
            switch (info.kind) {
                .toggle => {
                    out[count] = .{ .key_switch = idx };
                    count += 1;
                },
                .slider => {
                    out[count] = .{ .key_slider = idx };
                    count += 1;
                },
                .select, .enum_set => {
                    out[count] = .{ .key_select = idx };
                    count += 1;
                },
                .duration => {
                    out[count] = .{ .key_input = idx };
                    count += 1;
                    out[count] = .{ .key_select = idx };
                    count += 1;
                },
                .stepper, .text_input, .list => {
                    out[count] = .{ .key_input = idx };
                    count += 1;
                },
            }
        }
    }
    return count;
}

fn cycleFocus(state: *State, reverse: bool) bool {
    const page: Page = @enumFromInt(state.frame.current);
    var targets: [keys.table.len * 2 + 1]Target = undefined;
    var count: usize = 0;
    if (state.frame.shown()) {
        targets[0] = .sidebar;
        count = 1;
    }
    count += pageFocusTargets(page, targets[count..]);
    if (count == 0) return false;

    state.open_select = null;

    var found: ?usize = null;
    for (targets[0..count], 0..) |t, i| {
        if (std.meta.eql(t, state.focused)) {
            found = i;
            break;
        }
    }
    if (found == null and state.focused == .none and state.frame.shown() and state.frame.focused) {
        found = 0;
    }

    const next_idx: usize = if (found) |cur|
        if (reverse) (if (cur == 0) count - 1 else cur - 1) else (cur + 1) % count
    else if (reverse)
        count - 1
    else
        0;

    blurFocused(state);
    state.focused = targets[next_idx];
    if (state.focused == .sidebar) {
        _ = state.frame.update(page_count, .focus);
    } else {
        _ = state.frame.update(page_count, .blur);
        ensureFocusedVisible(state);
    }
    return true;
}

fn targetId(target: Target) ?Id {
    return switch (target) {
        .key_switch => |idx| switchId(idx),
        .key_slider => |idx| sliderId(idx),
        .key_select => |idx| selectId(idx),
        .key_input => |idx| inputId(idx),
        .stepper_dec => |idx| decId(idx),
        .stepper_inc => |idx| incId(idx),
        .list_add => |idx| listAddId(idx),
        else => null,
    };
}

fn ensureFocusedVisible(state: *State) void {
    const id = targetId(state.focused) orelse return;
    const area = state.node_rect.get(scroll_area_id) orelse return;
    const rect = state.node_rect.get(id) orelse return;
    const pad: f32 = 24;
    if (rect.y < area.y + pad) {
        state.scroll = @max(0.0, state.scroll - (area.y + pad - rect.y));
    } else if (rect.y + rect.h > area.y + area.h - pad) {
        const needed = state.scroll + (rect.y + rect.h - (area.y + area.h - pad));
        state.scroll = if (state.scroll_max > 0) @min(state.scroll_max, needed) else needed;
    }
}

fn copySelection(state: *State, inp: *const input.State) void {
    const sel = inp.selectedText();
    if (sel.len == 0) return;
    const z = state.gpa.dupeZ(u8, sel) catch return;
    defer state.gpa.free(z);
    state.clipboard.set(z);
}

fn blurFocused(state: *State) void {
    if (state.focused == .key_input) {
        const idx = state.focused.key_input;
        if (!keys.isList(idx) and state.dirty[idx]) commitInput(state, idx);
    }
    _ = state.frame.update(page_count, .blur);
    state.focused = .none;
}

fn activate(state: *State, target: Target) bool {
    switch (target) {
        .none, .sidebar, .layer => return false,
        .key_switch => |idx| {
            blurFocused(state);
            toggleSwitch(state, idx);
            return true;
        },
        .key_slider => |idx| {
            blurFocused(state);
            state.focused = .{ .key_slider = idx };
            return true;
        },
        .key_select => |idx| {
            blurFocused(state);
            if (state.open_select) |sel| {
                if (sel.key == idx) {
                    state.open_select = null;
                    return true;
                }
            }
            state.open_select = .{
                .key = idx,
                .highlight = if (keys.table[idx].kind == .duration)
                    @intFromEnum(state.duration_units[idx])
                else
                    currentSelectIndex(idx, state.activeConfig()) orelse 0,
            };
            return true;
        },
        .select_choice => |choice| {
            if (state.open_select) |sel| {
                if (isEnumSetKey(sel.key)) {
                    toggleCheckbox(state, sel.key, @intCast(choice));
                } else {
                    chooseSelect(state, sel.key, choice);
                }
                return true;
            }
            return false;
        },
        .key_checkbox => |cb| {
            blurFocused(state);
            toggleCheckbox(state, cb.key, cb.bit);
            return true;
        },
        .key_input => |idx| {
            if (state.focused != .key_input or state.focused.key_input != idx) {
                blurFocused(state);
                state.focused = target;
            }
            return true;
        },
        .stepper_dec => |idx| {
            blurFocused(state);
            stepNumber(state, idx, -1);
            return true;
        },
        .stepper_inc => |idx| {
            blurFocused(state);
            stepNumber(state, idx, 1);
            return true;
        },
        .list_add => |idx| {
            addListItem(state, idx);
            return true;
        },
        .list_up => |it| {
            blurFocused(state);
            moveListItem(state, it.key, it.item, -1);
            return true;
        },
        .list_down => |it| {
            blurFocused(state);
            moveListItem(state, it.key, it.item, 1);
            return true;
        },
        .list_remove => |it| {
            blurFocused(state);
            removeListItem(state, it.key, it.item);
            return true;
        },
    }
}

fn over(state: *const State, id: Id) Target {
    if (id == .none) return .none;
    if (id == layer_id) return .layer;
    for (0..32) |choice_idx| {
        if (id == choiceId(choice_idx)) return .{ .select_choice = choice_idx };
    }
    for (row_infos, 0..) |info, i| {
        const idx: u16 = @intCast(i);
        switch (info.kind) {
            .toggle => if (id == switchId(idx)) return .{ .key_switch = idx },
            .slider => if (id == sliderId(idx)) return .{ .key_slider = idx },
            .select => if (id == selectId(idx)) return .{ .key_select = idx },
            .duration => {
                if (id == inputId(idx)) return .{ .key_input = idx };
                if (id == selectId(idx)) return .{ .key_select = idx };
            },
            .stepper => {
                if (id == inputId(idx)) return .{ .key_input = idx };
                if (id == decId(idx)) return .{ .stepper_dec = idx };
                if (id == incId(idx)) return .{ .stepper_inc = idx };
            },
            .list => {
                if (id == inputId(idx)) return .{ .key_input = idx };
                if (id == listAddId(idx)) return .{ .list_add = idx };
                for (0..state.list_items[idx].items.len) |item_i| {
                    const item_u16: u16 = @intCast(item_i);
                    if (id == listUpId(idx, item_i)) return .{ .list_up = .{ .key = idx, .item = item_u16 } };
                    if (id == listDownId(idx, item_i)) return .{ .list_down = .{ .key = idx, .item = item_u16 } };
                    if (id == listRemoveId(idx, item_i)) return .{ .list_remove = .{ .key = idx, .item = item_u16 } };
                }
            },
            .text_input => if (id == inputId(idx)) return .{ .key_input = idx },
            .enum_set => if (id == selectId(idx)) return .{ .key_select = idx },
        }
    }
    return .none;
}

fn updateSliderFromPointer(state: *State, idx: u16, x: f32) bool {
    const rect = state.node_rect.get(sliderId(idx)) orelse return false;
    const raw = slider.ratioFromX(rect, x);
    const rounded = @round(raw * 100.0) / 100.0;
    if (state.slider_values[idx] == rounded) return false;
    state.slider_values[idx] = rounded;
    return true;
}

fn commitSlider(state: *State, idx: u16) void {
    var buf: [32]u8 = undefined;
    const text = formatFloat(state.slider_values[idx], &buf);
    commitValue(state, idx, text);
}

fn isEnumSetKey(idx: u16) bool {
    return row_infos[idx].kind == .enum_set;
}

fn isStepperKey(idx: u16) bool {
    return row_infos[idx].kind == .stepper;
}

fn stepNumber(state: *State, idx: u16, delta: f64) void {
    const info = row_infos[idx];
    if (info.kind != .stepper) return;
    const base = stepperValue(idx, state.activeConfig()) orelse info.min;
    const stepped = std.math.clamp(base + delta, info.min, info.max);
    var buf: [64]u8 = undefined;
    const token = if (info.stepper_is_int)
        formatSigned(@intFromFloat(@round(stepped)), &buf)
    else
        formatFloat(stepped, &buf);
    state.dirty[idx] = false;
    commitValue(state, idx, token);
}

fn toggleSwitch(state: *State, idx: u16) void {
    if (row_infos[idx].kind != .toggle) return;
    const cur = toggleValue(idx, state.activeConfig());
    commitValue(state, idx, if (cur) "false" else "true");
}

fn enumSetMask(idx: u16, cfg: *const Config) u32 {
    @setEvalBranchQuota(keys.eval_branch_quota);
    inline for (keys.table, 0..) |key, i| {
        if (comptime controlKind(key) == .enum_set) {
            if (i == idx) {
                const set = keys.fieldValue(Config, key.field, cfg);
                const E = @TypeOf(set).Key;
                const fields = @typeInfo(E).@"enum".fields;
                var mask: u32 = 0;
                inline for (fields, 0..) |f, f_idx| {
                    const member: E = @enumFromInt(f.value);
                    if (set.contains(member)) {
                        mask |= @as(u32, 1) << @intCast(f_idx);
                    }
                }
                return mask;
            }
        }
    }
    return 0;
}

fn toggleCheckbox(state: *State, idx: u16, bit: u8) void {
    const info = row_infos[idx];
    if (info.kind != .enum_set or bit >= info.labels.len) return;
    const mask = enumSetMask(idx, state.activeConfig()) ^ (@as(u32, 1) << @intCast(bit));
    var buf: [512]u8 = undefined;
    const text = formatEnumSetMask(info.labels, mask, &buf);
    commitValue(state, idx, text);
}

fn chooseSelect(state: *State, idx: u16, choice: usize) void {
    state.open_select = null;
    const info = row_infos[idx];
    if (info.kind == .duration) {
        const unit: DurationUnit = @enumFromInt(@as(u8, @intCast(choice)));
        state.duration_units[idx] = unit;
        if (unit == .none) {
            state.dirty[idx] = false;
            state.inputs[idx].setText(state.gpa, "") catch {};
            commitValue(state, idx, info.null_keyword orelse "none");
        } else {
            if (std.mem.trim(u8, state.inputs[idx].text(), " \t").len == 0) {
                const default_num = switch (unit) {
                    .ms => "500",
                    .s => "30",
                    .m => "15",
                    .h => "1",
                    .none => "",
                };
                state.inputs[idx].setText(state.gpa, default_num) catch {};
            }
            commitDuration(state, idx);
        }
        return;
    }
    if (info.kind == .select and choice < info.labels.len) {
        commitValue(state, idx, info.labels[choice]);
    }
}

fn commitDuration(state: *State, idx: u16) void {
    const info = row_infos[idx];
    const unit = state.duration_units[idx];
    const trimmed = std.mem.trim(u8, state.inputs[idx].text(), " \t");
    if (unit == .none or trimmed.len == 0) {
        if (info.null_keyword) |kw| {
            state.duration_units[idx] = .none;
            state.dirty[idx] = false;
            commitValue(state, idx, kw);
            return;
        }
        setError(state, idx, "enter a number");
        return;
    }
    var dbuf: [128]u8 = undefined;
    const token = std.fmt.bufPrint(&dbuf, "{s}{s}", .{ trimmed, unit.suffix() }) catch {
        setError(state, idx, "value is too long");
        return;
    };
    commitValue(state, idx, token);
}

fn commitInput(state: *State, idx: u16) void {
    const info = row_infos[idx];
    if (info.kind == .duration) {
        commitDuration(state, idx);
        return;
    }
    const raw = state.inputs[idx].text();
    if (info.null_keyword == null and std.mem.trim(u8, raw, " \t").len == 0 and
        info.key_kind != .word_characters and info.key_kind != .text)
    {
        setError(state, idx, "this field is required");
        return;
    }
    var qbuf: [1024]u8 = undefined;
    const formatted = formatForWrite(info, raw, &qbuf) orelse {
        setError(state, idx, "value is too long");
        return;
    };
    commitValue(state, idx, formatted);
}

fn formatForWrite(info: RowInfo, raw: []const u8, buf: []u8) ?[]const u8 {
    if (raw.len == 0) {
        if (info.null_keyword) |kw| return kw;
    }
    switch (info.key_kind) {
        .path, .program_path, .directory_path, .text, .word_characters => {
            if (info.null_keyword) |kw| {
                if (std.mem.eql(u8, raw, kw)) return raw;
            }
            if (std.mem.eql(u8, raw, "default")) return raw;
            if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') return raw;
            var pos: usize = 0;
            if (pos >= buf.len) return null;
            buf[pos] = '"';
            pos += 1;
            for (raw) |c| {
                if (c == '"' or c == '\\') {
                    if (pos + 2 > buf.len) return null;
                    buf[pos] = '\\';
                    buf[pos + 1] = c;
                    pos += 2;
                } else {
                    if (pos + 1 > buf.len) return null;
                    buf[pos] = c;
                    pos += 1;
                }
            }
            if (pos >= buf.len) return null;
            buf[pos] = '"';
            pos += 1;
            return buf[0..pos];
        },
        else => return raw,
    }
}

fn commitValue(state: *State, idx: u16, token: []const u8) void {
    const key = keys.table[idx];
    if (state.config_path.len == 0) return;

    config_writer.writeKey(state.gpa, state.io, state.config_path, key.section, key.name, token) catch |err| {
        setError(state, idx, @errorName(err));
        return;
    };

    reloadAfterWrite(state, idx);
}

fn formatListToken(gpa: Allocator, kind: keys.Kind, raw: []const u8) Allocator.Error![]u8 {
    if (kind != .shell_argument) return gpa.dupe(u8, raw);

    const needs_quotes = std.mem.eql(u8, raw, "none") or
        std.mem.eql(u8, raw, "default") or
        for (raw) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '"' or ch == '\\' or ch == '#' or ch == '=') break true;
        } else false;
    if (!needs_quotes) return gpa.dupe(u8, raw);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '"');
    for (raw) |ch| {
        if (ch == '"' or ch == '\\') try out.append(gpa, '\\');
        try out.append(gpa, ch);
    }
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

fn commitList(state: *State, idx: u16) void {
    const key = keys.table[idx];
    if (state.config_path.len == 0) return;

    const items = state.list_items[idx].items;
    const owned_tokens = state.gpa.alloc([]u8, items.len) catch {
        setError(state, idx, "OutOfMemory");
        return;
    };
    var built: usize = 0;
    defer {
        for (owned_tokens[0..built]) |tok| state.gpa.free(tok);
        state.gpa.free(owned_tokens);
    }
    for (items) |item| {
        owned_tokens[built] = formatListToken(state.gpa, key.kind, item) catch {
            setError(state, idx, "OutOfMemory");
            return;
        };
        built += 1;
    }

    config_writer.writeList(state.gpa, state.io, state.config_path, key.section, key.name, owned_tokens) catch |err| {
        setError(state, idx, @errorName(err));
        return;
    };

    reloadAfterWrite(state, idx);
}

fn addListItem(state: *State, idx: u16) void {
    const trimmed = std.mem.trim(u8, state.inputs[idx].text(), " \t");
    if (trimmed.len == 0) return;
    for (trimmed) |ch| {
        if (ch == '\r' or ch == '\n') {
            setError(state, idx, "Value cannot contain newlines");
            return;
        }
    }
    const copy = state.gpa.dupe(u8, trimmed) catch {
        setError(state, idx, "OutOfMemory");
        return;
    };
    state.list_items[idx].append(state.gpa, copy) catch {
        state.gpa.free(copy);
        setError(state, idx, "OutOfMemory");
        return;
    };
    state.inputs[idx].setText(state.gpa, "") catch {};
    state.dirty[idx] = false;
    commitList(state, idx);
}

fn removeListItem(state: *State, idx: u16, item_idx: u16) void {
    if (item_idx >= state.list_items[idx].items.len) return;
    const removed = state.list_items[idx].orderedRemove(item_idx);
    state.gpa.free(removed);
    commitList(state, idx);
}

fn moveListItem(state: *State, idx: u16, item_idx: u16, delta: i2) void {
    const len = state.list_items[idx].items.len;
    if (item_idx >= len) return;
    const next_signed: isize = @as(isize, item_idx) + delta;
    if (next_signed < 0 or next_signed >= @as(isize, @intCast(len))) return;
    const next: usize = @intCast(next_signed);
    const items = state.list_items[idx].items;
    const tmp = items[item_idx];
    items[item_idx] = items[next];
    items[next] = tmp;
    commitList(state, idx);
}

fn reloadAfterWrite(state: *State, idx: u16) void {
    var reloaded = Loaded.load(
        state.gpa,
        state.io,
        &config_defaults.default,
        state.home_dir,
        &.{ .file(config_paths.system), .file(state.config_path) },
    ) catch |err| {
        setError(state, idx, @errorName(err));
        return;
    };

    var err_buf: [256]u8 = undefined;
    if (firstLayerError(idx, &reloaded, &err_buf)) |msg| {
        setError(state, idx, msg);
        reloaded.deinit(state.gpa);
        return;
    }

    if (state.loaded) |*old| old.deinit(state.gpa);
    state.loaded = reloaded;
    state.dirty[idx] = false;
    if (state.error_key == idx) {
        state.error_key = null;
        state.error_msg.clearRetainingCapacity();
    }
    syncInputs(state) catch {};
}

fn firstLayerError(idx: u16, loaded: *const Loaded, buf: []u8) ?[]const u8 {
    if (loaded.layers.len < 2) return null;
    switch (loaded.layers[1].state) {
        .loaded => |*file| {
            var it = file.iterator();
            if (it.next()) |diag| {
                return switch (diag) {
                    .syntax => |e| @tagName(e.tag),
                    .sema => |e| blk: {
                        var w = std.Io.Writer.fixed(buf);
                        w.print("{s}: expected ", .{@tagName(e.tag)}) catch return @tagName(e.tag);
                        keys.writeExpected(e.key orelse idx, &w) catch return @tagName(e.tag);
                        break :blk w.buffered();
                    },
                };
            }
            return null;
        },
        .unreadable => |err| return @errorName(err),
        .missing => return null,
    }
}

fn setError(state: *State, idx: u16, msg: []const u8) void {
    state.error_key = idx;
    state.error_msg.clearRetainingCapacity();
    state.error_msg.appendSlice(state.gpa, msg) catch {};
}

pub fn view(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const frame = try sidebar.begin(tree, theme, &groups, &state.frame, .{});

    const content_row = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .height = .fill,
    });

    const scroll_area = try tree.open(.{
        .id = scroll_area_id,
        .width = .fill,
        .height = .fill,
        .cross = .center,
        .padding = .symmetric(24, 16),
        .overflow = .clip,
    });
    tree.scrollRegion(scroll_area, state.scroll);

    const content = try tree.open(.{
        .width = .{ .at_most = 800 },
        .gap = 16,
    });

    const page: Page = @enumFromInt(state.frame.current);
    _ = try tree.text(page_titles[@intFromEnum(page)], .{
        .color = theme.foreground,
        .style = .lg_semibold,
    });
    _ = try tree.text(page_descriptions[@intFromEnum(page)], .{
        .color = theme.muted_foreground,
        .style = .sm,
        .width = .fill,
    });
    _ = try tree.leaf(.{
        .width = .fill,
        .height = .{ .fixed = 1 },
        .fill = theme.border,
    });

    try viewPage(state, tree, theme, page);

    tree.close(content);
    tree.close(scroll_area);

    if (state.scroll_max > 0) {
        try viewScrollbar(state, tree, theme);
    }

    tree.close(content_row);
    try sidebar.end(tree, theme, &groups, &state.frame, frame);

    if (state.open_select) |sel| {
        try viewSelectPopup(state, tree, theme, sel.key, sel.highlight);
    }
}

fn viewScrollbar(state: *const State, tree: *Tree, theme: *const Theme) kit.tree.Error!void {
    const rail = try tree.open(.{
        .width = .{ .fixed = 8 },
        .height = .fill,
        .padding = .symmetric(2, 8),
    });
    const track_h = @max(40.0, state.viewport_height - 80.0);
    const total_h = track_h + state.scroll_max;
    const thumb_h = @max(24.0, track_h * (track_h / total_h));
    const travel = @max(0.0, track_h - thumb_h);
    const ratio = if (state.scroll_max > 0) state.scroll / state.scroll_max else 0;
    const top_pad: f32 = travel * std.math.clamp(ratio, 0, 1);

    if (top_pad > 0) {
        _ = try tree.leaf(.{ .height = .{ .fixed = top_pad } });
    }
    _ = try tree.leaf(.{
        .width = .{ .fixed = 4 },
        .height = .{ .fixed = thumb_h },
        .fill = theme.muted_foreground.fade(0.35),
        .radius = 2,
    });
    tree.close(rail);
}

const RowInfo = struct {
    section: keys.Section,
    page: ?Page,
    meta: KeyMeta,
    kind: ControlKind,
    key_kind: keys.Kind,
    null_keyword: ?[]const u8,
    placeholder: []const u8,
    restart_required: bool,
    stepper_is_int: bool,
    min: f64,
    max: f64,
    labels: []const []const u8,
    display_labels: []const []const u8,
};

fn comptimeStepperIsInt(comptime key: keys.Key) bool {
    const T = keys.FieldType(Config, key.field);
    return switch (@typeInfo(T)) {
        .int => true,
        .optional => |opt| @typeInfo(opt.child) == .int,
        else => false,
    };
}

fn comptimeKeyLabels(comptime key: keys.Key, comptime display: bool) []const []const u8 {
    const kind = comptime controlKind(key);
    if (kind == .enum_set) {
        const T = keys.FieldType(Config, key.field);
        const fields = @typeInfo(T.Key).@"enum".fields;
        comptime var list: [fields.len][]const u8 = undefined;
        inline for (fields, 0..) |f, i| {
            list[i] = if (display) comptime humanToken(f.name) else f.name;
        }
        const final = list;
        return &final;
    }
    if (kind != .select) return &.{};
    if (key.kind == .theme) {
        comptime var list: [keys.theme_preset_list.len][]const u8 = undefined;
        inline for (keys.theme_preset_list, 0..) |preset, i| {
            list[i] = if (display) comptime humanToken(preset[0]) else preset[0];
        }
        const final = list;
        return &final;
    }
    if (key.kind == .font_weight) {
        comptime var list: [font_weight_presets.len][]const u8 = undefined;
        inline for (font_weight_presets, 0..) |preset, i| {
            list[i] = if (display) preset.label else preset.value;
        }
        const final = list;
        return &final;
    }
    const T = keys.FieldType(Config, key.field);
    switch (@typeInfo(T)) {
        .@"enum" => |e| {
            comptime var list: [e.fields.len][]const u8 = undefined;
            inline for (e.fields, 0..) |f, i| {
                list[i] = if (display) comptime humanToken(f.name) else f.name;
            }
            const final = list;
            return &final;
        },
        .optional => |opt| {
            const fields = @typeInfo(opt.child).@"enum".fields;
            comptime var list: [fields.len + 1][]const u8 = undefined;
            const kw = if (key.null_keyword) |k| @tagName(k) else "none";
            list[0] = if (display) comptime humanToken(kw) else kw;
            inline for (fields, 0..) |f, i| {
                list[i + 1] = if (display) comptime humanToken(f.name) else f.name;
            }
            const final = list;
            return &final;
        },
        else => return &.{},
    }
}

const row_infos: [keys.table.len]RowInfo = blk: {
    @setEvalBranchQuota(keys.eval_branch_quota);
    var table: [keys.table.len]RowInfo = undefined;
    for (keys.table, 0..) |key, i| {
        table[i] = .{
            .section = key.section,
            .page = pageForSection(key.section),
            .meta = keyMeta(key.section, key.name),
            .kind = controlKind(key),
            .key_kind = key.kind,
            .null_keyword = if (key.null_keyword) |kw| @tagName(kw) else null,
            .placeholder = inputPlaceholder(key),
            .restart_required = key.reload == .restart,
            .stepper_is_int = comptimeStepperIsInt(key),
            .min = key.bounds.min,
            .max = key.bounds.max,
            .labels = comptimeKeyLabels(key, false),
            .display_labels = comptimeKeyLabels(key, true),
        };
    }
    break :blk table;
};

fn viewPage(state: *const State, tree: *Tree, theme: *const Theme, page: Page) kit.tree.Error!void {
    const cfg = state.activeConfig();
    var current_section: ?keys.Section = null;
    var section_open: ?kit.tree.Index = null;
    var first_in_section = true;

    for (row_infos, 0..) |info, i| {
        const idx: u16 = @intCast(i);
        if (keys.availableHere(idx) and info.page == page) {
            if (current_section == null or current_section.? != info.section) {
                if (section_open) |open_box| tree.close(open_box);
                current_section = info.section;
                first_in_section = true;
                _ = try tree.text(section_titles.get(info.section), .{
                    .color = theme.foreground,
                    .style = .sm_medium,
                });
                section_open = try tree.open(.{
                    .width = .fill,
                    .padding = .all(14),
                    .gap = 12,
                    .fill = theme.card,
                    .border = theme.border,
                    .border_width = Theme.border_width,
                    .radius = Theme.radius_md,
                });
            } else if (!first_in_section) {
                _ = try tree.leaf(.{
                    .width = .fill,
                    .height = .{ .fixed = 1 },
                    .fill = theme.border,
                });
            }
            first_in_section = false;
            try viewKeyRow(state, tree, theme, info, idx, cfg);
        }
    }
    if (section_open) |open_box| tree.close(open_box);
}

const pct_labels: [101][]const u8 = blk: {
    @setEvalBranchQuota(20000);
    var labels: [101][]const u8 = undefined;
    for (0..101) |i| {
        labels[i] = std.fmt.comptimePrint("{d}%", .{i});
    }
    break :blk labels;
};

fn pctLabel(ratio: f32) []const u8 {
    const pct: usize = @intFromFloat(@round(std.math.clamp(ratio, 0.0, 1.0) * 100.0));
    return pct_labels[@min(pct, 100)];
}

const GroupEdge = enum { left, right };

fn openGroupSegment(tree: *Tree, theme: *const Theme, options: struct {
    id: Id,
    edge: GroupEdge,
    hovered: bool = false,
    disabled: bool = false,
    width: kit.tree.Size = .fit,
}) kit.tree.Error!kit.tree.Index {
    const seg = try tree.open(.{
        .id = options.id,
        .axis = .row,
        .width = options.width,
        .height = .fill,
        .main = .center,
        .cross = .center,
        .pointer = if (options.disabled) .arrow else .hand,
    });
    if (options.hovered and !options.disabled) {
        const bg = theme.accent;
        // Round all corners concentrically with the outer border, then square
        // off the half adjacent to the group's inner divider.
        _ = try tree.leaf(.{
            .overlay = true,
            .width = .fill,
            .height = .fill,
            .fill = bg,
            .radius = Theme.radius_md - Theme.border_width,
        });
        const mask = try tree.open(.{
            .overlay = true,
            .axis = .row,
            .width = .fill,
            .height = .fill,
        });
        if (options.edge == .left) {
            _ = try tree.leaf(.{ .width = .fill, .height = .fill });
            _ = try tree.leaf(.{ .width = .fill, .height = .fill, .fill = bg });
        } else {
            _ = try tree.leaf(.{ .width = .fill, .height = .fill, .fill = bg });
            _ = try tree.leaf(.{ .width = .fill, .height = .fill });
        }
        tree.close(mask);
    }
    return seg;
}

fn stepperSegment(tree: *Tree, theme: *const Theme, options: struct {
    id: Id,
    edge: GroupEdge,
    label: []const u8,
    hovered: bool = false,
    disabled: bool = false,
}) kit.tree.Error!void {
    const presence: f32 = if (options.disabled) 0.4 else 1.0;
    const cell = try openGroupSegment(tree, theme, .{
        .id = options.id,
        .edge = options.edge,
        .hovered = options.hovered,
        .disabled = options.disabled,
        .width = .{ .fixed = Theme.control_sm },
    });
    _ = try tree.text(options.label, .{
        .color = theme.foreground.fade(presence),
        .style = .sm_medium,
    });
    tree.close(cell);
}

fn groupColors(theme: *const Theme, is_err: bool, focused: bool, hovered: bool) struct {
    ring: Theme.Color,
    border: Theme.Color,
} {
    return .{
        .ring = if (is_err)
            theme.destructive.alpha(Theme.ring_opacity)
        else if (focused)
            theme.ring.alpha(Theme.ring_opacity)
        else
            Theme.Color.transparent,
        .border = if (is_err)
            theme.destructive
        else if (focused)
            theme.ring
        else if (hovered)
            theme.foreground.fade(0.35)
        else
            theme.input,
    };
}

fn toggleValue(idx: u16, cfg: *const Config) bool {
    @setEvalBranchQuota(keys.eval_branch_quota);
    inline for (keys.table, 0..) |key, i| {
        if (comptime controlKind(key) == .toggle) {
            if (idx == i) return keys.fieldValue(Config, key.field, cfg);
        }
    }
    return false;
}

fn stepperValue(idx: u16, cfg: *const Config) ?f64 {
    @setEvalBranchQuota(keys.eval_branch_quota);
    inline for (keys.table, 0..) |key, i| {
        if (comptime controlKind(key) == .stepper) {
            if (idx == i) {
                const v = keys.fieldValue(Config, key.field, cfg);
                return switch (@typeInfo(@TypeOf(v))) {
                    .optional => if (v) |inner| switch (@typeInfo(@TypeOf(inner))) {
                        .float => @as(f64, @floatCast(inner)),
                        .int => @as(f64, @floatFromInt(inner)),
                        else => null,
                    } else null,
                    .float => @as(f64, @floatCast(v)),
                    .int => @as(f64, @floatFromInt(v)),
                    else => null,
                };
            }
        }
    }
    return null;
}

fn selectDisplayValue(idx: u16, cfg: *const Config) []const u8 {
    const info = row_infos[idx];
    if (info.kind != .select) return "";
    if (currentSelectIndex(idx, cfg)) |s| {
        if (s < info.display_labels.len) return info.display_labels[s];
    }
    return "Custom";
}

fn enumSetSummaryValue(idx: u16, cfg: *const Config) []const u8 {
    const info = row_infos[idx];
    if (info.kind != .enum_set) return "None";
    const mask = enumSetMask(idx, cfg);
    var count: usize = 0;
    var single: []const u8 = "None";
    for (info.display_labels, 0..) |lbl, bit| {
        if ((mask & (@as(u32, 1) << @intCast(bit))) != 0) {
            count += 1;
            single = lbl;
        }
    }
    if (count == 0) return "None";
    if (count == 1) return single;
    if (count < selected_count_labels.len) return selected_count_labels[count];
    return "Multiple selected";
}

fn viewKeyRow(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    info: RowInfo,
    idx: u16,
    cfg: *const Config,
) kit.tree.Error!void {
    const meta = info.meta;
    const pane_w = if (state.frame.shown() and !state.frame.narrow)
        state.viewport_width - sidebar.width
    else
        state.viewport_width;
    const compact = pane_w < 540;
    const control_width: kit.tree.Size = if (compact)
        .fill
    else if (pane_w >= 760)
        .{ .fixed = 280 }
    else
        .{ .fixed = 240 };

    const col = try tree.open(.{ .width = .fill, .gap = 4 });
    const row = try tree.open(.{
        .axis = if (compact) .column else .row,
        .width = .fill,
        .cross = if (compact or info.kind == .list) .start else .center,
        .gap = if (compact) 10 else 16,
    });

    const label_box = try tree.open(.{ .width = .fill, .gap = 3 });
    const title_row = try tree.open(.{
        .axis = .row,
        .gap = 8,
        .cross = .center,
    });
    _ = try tree.text(meta.label, .{
        .color = theme.foreground,
        .style = .sm_medium,
    });
    if (info.restart_required) {
        const badge = try tree.open(.{
            .padding = .symmetric(6, 1),
            .fill = theme.muted,
            .radius = Theme.radius_sm,
        });
        _ = try tree.text("Restart required", .{
            .color = theme.muted_foreground,
            .style = .xs,
        });
        tree.close(badge);
    }
    tree.close(title_row);

    _ = try tree.text(meta.description, .{
        .color = theme.muted_foreground,
        .style = .xs,
        .width = .fill,
    });
    tree.close(label_box);

    switch (info.kind) {
        .toggle => {
            const on = toggleValue(idx, cfg);
            try switch_control.view(tree, theme, .{
                .id = switchId(idx),
                .checked = on,
                .focused = std.meta.eql(state.focused, Target{ .key_switch = idx }),
            });
        },
        .slider => {
            const val = state.slider_values[idx];
            const track_w: f32 = if (compact)
                @max(pane_w - 130, 100)
            else if (pane_w >= 760)
                228
            else
                188;
            try slider.view(tree, theme, .{
                .id = sliderId(idx),
                .value = val,
                .value_label = pctLabel(val),
                .track_width = track_w,
                .hovered = std.meta.eql(state.hover, Target{ .key_slider = idx }),
                .focused = std.meta.eql(state.focused, Target{ .key_slider = idx }),
            });
        },
        .stepper => {
            const inp = &state.inputs[idx];
            const is_err = state.error_key == idx;
            const cur_val = stepperValue(idx, cfg);
            const at_min = if (cur_val) |v| v <= info.min else false;
            const at_max = if (cur_val) |v| v >= info.max else false;
            const dec_hovered = std.meta.eql(state.hover, Target{ .stepper_dec = idx });
            const inc_hovered = std.meta.eql(state.hover, Target{ .stepper_inc = idx });
            const input_hovered = std.meta.eql(state.hover, Target{ .key_input = idx });
            const input_focused = std.meta.eql(state.focused, Target{ .key_input = idx });
            const any_focused = input_focused or
                std.meta.eql(state.focused, Target{ .stepper_dec = idx }) or
                std.meta.eql(state.focused, Target{ .stepper_inc = idx });
            const colors = groupColors(theme, is_err, any_focused, input_hovered or dec_hovered or inc_hovered);

            const ring = try tree.open(.{
                .width = control_width,
                .padding = .all(Theme.ring_width),
                .border = colors.ring,
                .border_width = Theme.ring_width,
                .radius = Theme.radius_md + Theme.ring_width,
            });
            const compound = try tree.open(.{
                .axis = .row,
                .width = .fill,
                .height = .{ .fixed = Theme.control_sm },
                .padding = .all(Theme.border_width),
                .cross = .center,
                .fill = theme.background,
                .border = colors.border,
                .border_width = Theme.border_width,
                .radius = Theme.radius_md,
            });
            try stepperSegment(tree, theme, .{
                .id = decId(idx),
                .edge = .left,
                .label = "−",
                .hovered = dec_hovered,
                .disabled = at_min,
            });
            _ = try tree.leaf(.{
                .width = .{ .fixed = 1 },
                .height = .fill,
                .fill = theme.border,
            });
            try input.view(tree, theme, .{
                .id = inputId(idx),
                .value = inp.text(),
                .placeholder = info.placeholder,
                .cursor = inp.cursor,
                .anchor = inp.anchor,
                .width = .fill,
                .hovered = input_hovered,
                .focused = input_focused,
                .invalid = is_err,
                .center = true,
                .borderless = true,
            });
            _ = try tree.leaf(.{
                .width = .{ .fixed = 1 },
                .height = .fill,
                .fill = theme.border,
            });
            try stepperSegment(tree, theme, .{
                .id = incId(idx),
                .edge = .right,
                .label = "+",
                .hovered = inc_hovered,
                .disabled = at_max,
            });
            tree.close(compound);
            tree.close(ring);
        },
        .duration => {
            const inp = &state.inputs[idx];
            const unit = state.duration_units[idx];
            const is_err = state.error_key == idx;
            const input_focused = std.meta.eql(state.focused, Target{ .key_input = idx });
            const input_hovered = std.meta.eql(state.hover, Target{ .key_input = idx });
            const select_hovered = std.meta.eql(state.hover, Target{ .key_select = idx });
            const is_open = if (state.open_select) |sel| sel.key == idx else false;
            const colors = groupColors(theme, is_err, input_focused, input_hovered or select_hovered or is_open);

            const ring = try tree.open(.{
                .width = control_width,
                .padding = .all(Theme.ring_width),
                .border = colors.ring,
                .border_width = Theme.ring_width,
                .radius = Theme.radius_md + Theme.ring_width,
            });
            const compound = try tree.open(.{
                .axis = .row,
                .width = .fill,
                .height = .{ .fixed = Theme.control_sm },
                .padding = .all(Theme.border_width),
                .cross = .center,
                .fill = theme.background,
                .border = colors.border,
                .border_width = Theme.border_width,
                .radius = Theme.radius_md,
            });
            try input.view(tree, theme, .{
                .id = inputId(idx),
                .value = inp.text(),
                .placeholder = if (unit == .none) "—" else "0",
                .cursor = inp.cursor,
                .anchor = inp.anchor,
                .width = .fill,
                .hovered = input_hovered,
                .focused = input_focused,
                .invalid = is_err,
                .disabled = unit == .none,
                .borderless = true,
            });
            _ = try tree.leaf(.{
                .width = .{ .fixed = 1 },
                .height = .fill,
                .fill = theme.border,
            });
            const unit_btn = try openGroupSegment(tree, theme, .{
                .id = selectId(idx),
                .edge = .right,
                .hovered = select_hovered or is_open,
            });
            const unit_pad = try tree.open(.{
                .axis = .row,
                .height = .fill,
                .padding = .symmetric(10, 0),
                .gap = 6,
                .cross = .center,
            });
            _ = try tree.text(unit.shortLabel(), .{
                .color = if (unit == .none) theme.muted_foreground else theme.foreground,
                .style = .sm,
            });
            _ = try tree.icon(.{
                .codepoint = kit.icons.chevron_down,
                .color = theme.muted_foreground,
                .size = Theme.icon,
            });
            tree.close(unit_pad);
            tree.close(unit_btn);
            tree.close(compound);
            tree.close(ring);
        },
        .select => {
            const current_label = selectDisplayValue(idx, cfg);
            const is_open = if (state.open_select) |sel| sel.key == idx else false;
            try select.trigger(tree, theme, .{
                .id = selectId(idx),
                .value = current_label,
                .width = control_width,
                .hovered = std.meta.eql(state.hover, Target{ .key_select = idx }),
                .open = is_open,
                .focused = std.meta.eql(state.focused, Target{ .key_select = idx }),
            });
        },
        .enum_set => {
            const is_open = if (state.open_select) |sel| sel.key == idx else false;
            try select.trigger(tree, theme, .{
                .id = selectId(idx),
                .value = enumSetSummaryValue(idx, cfg),
                .width = control_width,
                .hovered = std.meta.eql(state.hover, Target{ .key_select = idx }),
                .open = is_open,
                .focused = std.meta.eql(state.focused, Target{ .key_select = idx }),
            });
        },
        .list => {
            const items = state.list_items[idx].items;
            const list_col = try tree.open(.{
                .axis = .column,
                .width = control_width,
                .gap = 6,
            });
            for (items, 0..) |item, item_i| {
                const item_u16: u16 = @intCast(item_i);
                const item_pad = try tree.open(.{
                    .width = .fill,
                    .padding = .symmetric(Theme.ring_width, 0),
                });
                const item_row = try tree.open(.{
                    .axis = .row,
                    .width = .fill,
                    .height = .{ .fixed = Theme.control_sm },
                    .padding = .{ .left = 10, .right = 2 },
                    .gap = 2,
                    .cross = .center,
                    .fill = theme.background,
                    .border = theme.input,
                    .border_width = Theme.border_width,
                    .radius = Theme.radius_md,
                });
                const text_clip = try tree.open(.{
                    .axis = .row,
                    .width = .fill,
                    .cross = .center,
                    .overflow = .clip,
                });
                _ = try tree.text(item, .{
                    .color = theme.foreground,
                    .style = .sm,
                });
                tree.close(text_clip);

                const up_disabled = item_i == 0;
                const up_hovered = std.meta.eql(state.hover, Target{ .list_up = .{ .key = idx, .item = item_u16 } });
                const up_btn = try tree.open(.{
                    .id = listUpId(idx, item_i),
                    .axis = .row,
                    .width = .{ .fixed = 24 },
                    .height = .{ .fixed = 24 },
                    .main = .center,
                    .cross = .center,
                    .pointer = if (up_disabled) .arrow else .hand,
                    .fill = if (up_hovered and !up_disabled) theme.accent else .transparent,
                    .radius = Theme.radius_md - 4,
                });
                _ = try tree.text("↑", .{
                    .color = if (up_disabled) theme.muted_foreground.fade(0.4) else theme.muted_foreground,
                    .style = .xs,
                });
                tree.close(up_btn);

                const dn_disabled = item_i + 1 >= items.len;
                const dn_hovered = std.meta.eql(state.hover, Target{ .list_down = .{ .key = idx, .item = item_u16 } });
                const dn_btn = try tree.open(.{
                    .id = listDownId(idx, item_i),
                    .axis = .row,
                    .width = .{ .fixed = 24 },
                    .height = .{ .fixed = 24 },
                    .main = .center,
                    .cross = .center,
                    .pointer = if (dn_disabled) .arrow else .hand,
                    .fill = if (dn_hovered and !dn_disabled) theme.accent else .transparent,
                    .radius = Theme.radius_md - 4,
                });
                _ = try tree.text("↓", .{
                    .color = if (dn_disabled) theme.muted_foreground.fade(0.4) else theme.muted_foreground,
                    .style = .xs,
                });
                tree.close(dn_btn);

                const rm_hovered = std.meta.eql(state.hover, Target{ .list_remove = .{ .key = idx, .item = item_u16 } });
                const rm_btn = try tree.open(.{
                    .id = listRemoveId(idx, item_i),
                    .axis = .row,
                    .width = .{ .fixed = 24 },
                    .height = .{ .fixed = 24 },
                    .main = .center,
                    .cross = .center,
                    .pointer = .hand,
                    .fill = if (rm_hovered) theme.accent else .transparent,
                    .radius = Theme.radius_md - 4,
                });
                _ = try tree.text("×", .{
                    .color = if (rm_hovered) theme.destructive else theme.muted_foreground,
                    .style = .sm,
                });
                tree.close(rm_btn);

                tree.close(item_row);
                tree.close(item_pad);
            }

            const inp = &state.inputs[idx];
            const is_err = state.error_key == idx;
            const input_focused = std.meta.eql(state.focused, Target{ .key_input = idx });
            const input_hovered = std.meta.eql(state.hover, Target{ .key_input = idx });
            const add_hovered = std.meta.eql(state.hover, Target{ .list_add = idx });
            const colors = groupColors(theme, is_err, input_focused, input_hovered or add_hovered);

            const ring = try tree.open(.{
                .width = .fill,
                .padding = .all(Theme.ring_width),
                .border = colors.ring,
                .border_width = Theme.ring_width,
                .radius = Theme.radius_md + Theme.ring_width,
            });
            const compound = try tree.open(.{
                .axis = .row,
                .width = .fill,
                .height = .{ .fixed = Theme.control_sm },
                .padding = .all(Theme.border_width),
                .cross = .center,
                .fill = theme.background,
                .border = colors.border,
                .border_width = Theme.border_width,
                .radius = Theme.radius_md,
            });
            try input.view(tree, theme, .{
                .id = inputId(idx),
                .value = inp.text(),
                .placeholder = info.placeholder,
                .cursor = inp.cursor,
                .anchor = inp.anchor,
                .width = .fill,
                .hovered = input_hovered,
                .focused = input_focused,
                .invalid = is_err,
                .borderless = true,
            });
            _ = try tree.leaf(.{
                .width = .{ .fixed = 1 },
                .height = .fill,
                .fill = theme.border,
            });
            const add_disabled = std.mem.trim(u8, inp.text(), " \t").len == 0;
            try stepperSegment(tree, theme, .{
                .id = listAddId(idx),
                .edge = .right,
                .label = "+",
                .hovered = add_hovered,
                .disabled = add_disabled,
            });
            tree.close(compound);
            tree.close(ring);
            tree.close(list_col);
        },
        .text_input => {
            const inp = &state.inputs[idx];
            const is_err = state.error_key == idx;
            try input.view(tree, theme, .{
                .id = inputId(idx),
                .value = inp.text(),
                .placeholder = info.placeholder,
                .cursor = inp.cursor,
                .anchor = inp.anchor,
                .width = control_width,
                .hovered = std.meta.eql(state.hover, Target{ .key_input = idx }),
                .focused = std.meta.eql(state.focused, Target{ .key_input = idx }),
                .invalid = is_err,
            });
        },
    }

    tree.close(row);

    if (state.error_key == idx and state.error_msg.items.len > 0) {
        _ = try tree.text(state.error_msg.items, .{
            .color = theme.destructive,
            .style = .xs,
            .width = .fill,
        });
    }
    tree.close(col);
}

fn viewSelectPopup(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    key_idx: u16,
    highlight: usize,
) kit.tree.Error!void {
    const cfg = state.activeConfig();
    const info = row_infos[key_idx];
    const card = try popup.open(tree, theme, .{ .layer_id = layer_id, .anchor = selectId(key_idx) });
    switch (info.kind) {
        .duration => {
            const selected_idx: usize = @intFromEnum(state.duration_units[key_idx]);
            const count: usize = if (info.null_keyword != null) 5 else 4;
            for (0..count) |c_idx| {
                const unit: DurationUnit = @enumFromInt(@as(u8, @intCast(c_idx)));
                try popup.item(tree, theme, .{
                    .id = choiceId(c_idx),
                    .label = unit.label(),
                    .highlighted = c_idx == highlight,
                    .selected = c_idx == selected_idx,
                });
            }
        },
        .enum_set => {
            const mask = enumSetMask(key_idx, cfg);
            for (info.display_labels, 0..) |label, c_idx| {
                try popup.item(tree, theme, .{
                    .id = choiceId(c_idx),
                    .label = label,
                    .highlighted = c_idx == highlight,
                    .selected = (mask & (@as(u32, 1) << @intCast(c_idx))) != 0,
                });
            }
        },
        .select => {
            const selected_idx = currentSelectIndex(key_idx, cfg);
            for (info.display_labels, 0..) |label, c_idx| {
                try popup.item(tree, theme, .{
                    .id = choiceId(c_idx),
                    .label = label,
                    .highlighted = c_idx == highlight,
                    .selected = if (selected_idx) |s| c_idx == s else false,
                });
            }
        },
        else => {},
    }
    popup.close(tree, card);
}

fn selectChoiceCount(key_idx: u16) usize {
    const info = row_infos[key_idx];
    return switch (info.kind) {
        .duration => if (info.null_keyword != null) 5 else 4,
        .enum_set, .select => info.display_labels.len,
        else => 0,
    };
}

fn currentSelectIndex(key_idx: u16, cfg: *const Config) ?usize {
    @setEvalBranchQuota(keys.eval_branch_quota);
    inline for (keys.table, 0..) |key, i| {
        if (comptime controlKind(key) == .select) {
            if (i == key_idx) {
                const val = keys.fieldValue(Config, key.field, cfg);
                if (key.kind == .theme) {
                    inline for (keys.theme_preset_list, 0..) |preset, p_idx| {
                        if (std.meta.eql(val, preset[1])) return p_idx;
                    }
                    return null;
                }
                if (key.kind == .font_weight) {
                    for (font_weight_presets, 0..) |preset, p_idx| {
                        if (@abs(val - preset.weight) < 0.5) return p_idx;
                    }
                    return null;
                }
                const T = @TypeOf(val);
                switch (@typeInfo(T)) {
                    .@"enum" => |e| {
                        inline for (e.fields, 0..) |f, f_idx| {
                            if (@intFromEnum(val) == f.value) return f_idx;
                        }
                        return 0;
                    },
                    .optional => |opt| {
                        if (val == null) return 0;
                        const fields = @typeInfo(opt.child).@"enum".fields;
                        inline for (fields, 0..) |f, f_idx| {
                            if (@intFromEnum(val.?) == f.value) return f_idx + 1;
                        }
                        return 0;
                    },
                    else => return 0,
                }
            }
        }
    }
    return null;
}

fn splitDurationMs(maybe_ms: ?u64, buf: []u8) struct { text: []const u8, unit: DurationUnit } {
    const ms = maybe_ms orelse return .{ .text = "", .unit = .none };
    if (ms > 0 and ms % (60 * 60 * 1000) == 0) {
        return .{
            .text = formatSigned(@intCast(ms / (60 * 60 * 1000)), buf),
            .unit = .h,
        };
    }
    if (ms > 0 and ms % (60 * 1000) == 0) {
        return .{
            .text = formatSigned(@intCast(ms / (60 * 1000)), buf),
            .unit = .m,
        };
    }
    if (ms > 0 and ms % 1000 == 0) {
        return .{
            .text = formatSigned(@intCast(ms / 1000), buf),
            .unit = .s,
        };
    }
    return .{
        .text = formatSigned(@intCast(ms), buf),
        .unit = .ms,
    };
}

const selected_count_labels = [_][]const u8{
    "None",
    "1 selected",
    "2 selected",
    "3 selected",
    "4 selected",
    "5 selected",
    "6 selected",
    "7 selected",
    "8 selected",
};

fn formatFloat(val: f64, buf: []u8) []const u8 {
    const s = std.fmt.bufPrint(buf, "{d:.3}", .{val}) catch return "";
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

fn formatEnumSetMask(labels: []const []const u8, mask: u32, buf: []u8) []const u8 {
    var pos: usize = 0;
    var any = false;
    for (labels, 0..) |name_tok, bit| {
        if ((mask & (@as(u32, 1) << @intCast(bit))) != 0) {
            if (any) {
                if (pos + 2 <= buf.len) {
                    @memcpy(buf[pos .. pos + 2], ", ");
                    pos += 2;
                }
            }
            if (pos + name_tok.len <= buf.len) {
                @memcpy(buf[pos .. pos + name_tok.len], name_tok);
                pos += name_tok.len;
            }
            any = true;
        }
    }
    if (!any) return "none";
    return buf[0..pos];
}
