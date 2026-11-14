//! Settings window (`rex settings`): sidebar-navigated form generated from
//! `config.keys.table`, saving edits immediately via `config.writer.writeKey`
//! and validating through `config.Loaded.load`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const kit = @import("../kit/root.zig");
const host = @import("host.zig");
const Config = @import("../config/Config.zig");
const overlay = @import("../config/overlay.zig");
const Loaded = @import("../config/Loaded.zig");
const keys = @import("../config/keys.zig");
const config_defaults = @import("../config/default.zig");
const config_paths = @import("../config/paths.zig");
const config_writer = @import("../config/writer.zig");
const config_font = @import("../config/font.zig");
const Rgb = @import("../color/Rgb.zig");
const ThemePreset = @import("../color/Theme.zig");
const theme_presets = @import("../color/presets.zig");

const button = kit.button;
const sidebar = kit.sidebar;
const popup = kit.popup;
const switch_control = kit.switch_control;
const checkbox = kit.checkbox;
const toggle = kit.toggle;
const select = kit.select;
const slider = kit.slider;
const input = kit.input;
const tooltip = kit.tooltip;
const Theme = kit.Theme;
const Tree = kit.tree.Tree;
const Id = kit.tree.Id;

pub const name = "settings";
pub const title = "Rex Settings";

pub const node_max = 1600;
pub const line_max = 1024;
const popup_max_items: usize = 10;

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
    "Terminal color themes, light or dark interface, motion, and typography.",
    "Window behavior, bell, scrolling, scrollbar, selection, clipboard, and shell.",
    "Toasts, banners, and modal dialogs.",
    "Wellbeing tracking, daily screen time limits, and dashboard charts.",
    "Pomodoro focus intervals, alerts, and evening wind-down schedule.",
    "Periodic eyesight and movement break reminders.",
};

pub fn pageForSection(section: keys.Section) ?Page {
    return switch (section) {
        .root, .colors, .font, .ui => .appearance,
        .window, .bell, .scroll, .scrollbar, .selection, .clipboard, .shell => .window_shell,
        .toast, .banner, .modal, .@"modal.blur", .alert_dialog => .overlays,
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
    .colors = "Theme Overrides",
    .font = "Font",
    .window = "Window",
    .bell = "Bell",
    .toast = "Toast",
    .banner = "Banner",
    .modal = "Modal",
    .@"modal.blur" = "Modal Blur",
    .alert_dialog = "Alert Dialog",
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
    .scrollbar = "Scrollbar",
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
            .description = "Choose the color palette used inside the terminal.",
        } else @compileError("unmapped root key: " ++ key_name),

        .font => if (std.mem.eql(u8, key_name, "file")) .{
            .label = "Regular Font",
            .description = "Font file used for regular terminal text, or leave blank for the built-in font.",
        } else if (std.mem.eql(u8, key_name, "bold_file")) .{
            .label = "Bold Font",
            .description = "Custom font file for bold text, or leave blank to thicken the regular font.",
        } else if (std.mem.eql(u8, key_name, "italic_file")) .{
            .label = "Italic Font",
            .description = "Custom font file for italic text, or leave blank.",
        } else if (std.mem.eql(u8, key_name, "bold_italic_file")) .{
            .label = "Bold Italic Font",
            .description = "Custom font file for bold italic text, or leave blank.",
        } else if (std.mem.eql(u8, key_name, "emoji_file")) .{
            .label = "Emoji Font",
            .description = "Font file used for color emoji, or leave blank.",
        } else if (std.mem.eql(u8, key_name, "fallback")) .{
            .label = "Fallback Fonts",
            .description = "Extra font files checked in order when a character is missing.",
        } else if (std.mem.eql(u8, key_name, "size")) .{
            .label = "Font Size",
            .description = "Base text size in points for new terminal windows.",
        } else if (std.mem.eql(u8, key_name, "size_step")) .{
            .label = "Zoom Step",
            .description = "How much the font size changes each time you zoom in or out.",
        } else if (std.mem.eql(u8, key_name, "min_size")) .{
            .label = "Minimum Font Size",
            .description = "Smallest font size allowed when zooming out.",
        } else if (std.mem.eql(u8, key_name, "max_size")) .{
            .label = "Maximum Font Size",
            .description = "Largest font size allowed when zooming in.",
        } else if (std.mem.eql(u8, key_name, "weight")) .{
            .label = "Regular Weight",
            .description = "Thickness for regular text on variable fonts (1–1000).",
        } else if (std.mem.eql(u8, key_name, "bold_weight")) .{
            .label = "Bold Weight",
            .description = "Thickness for bold text on variable fonts (1–1000).",
        } else @compileError("unmapped font key: " ++ key_name),

        .ui => if (std.mem.eql(u8, key_name, "motion")) .{
            .label = "Animations",
            .description = "Play smooth transitions in menus and overlays, or switch immediately.",
        } else if (std.mem.eql(u8, key_name, "color_scheme")) .{
            .label = "Interface Theme",
            .description = "Light or dark look for settings, dialogs, and overlays, or match your terminal theme.",
        } else @compileError("unmapped ui key: " ++ key_name),

        .window => if (std.mem.eql(u8, key_name, "background_opacity")) .{
            .label = "Background Opacity",
            .description = "How solid the terminal background is, from 0.0 (see-through) to 1.0 (opaque).",
        } else if (std.mem.eql(u8, key_name, "dim_text_opacity")) .{
            .label = "Dim Text Opacity",
            .description = "Brightness multiplier for dimmed terminal text (0.0–1.0).",
        } else if (std.mem.eql(u8, key_name, "on_close")) .{
            .label = "Close Behavior",
            .description = "Whether to confirm before closing when child processes are active.",
        } else if (std.mem.eql(u8, key_name, "platform")) .{
            .label = "Window Platform",
            .description = "Window system to use on Linux (Automatic, Wayland, or X11).",
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
            .description = "Play a chime when a program triggers the terminal bell.",
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

        .scrollbar => scrollbarMeta(key_name),

        .selection => if (std.mem.eql(u8, key_name, "extra_word_characters")) .{
            .label = "Extra Word Characters",
            .description = "Additional ASCII symbols treated as part of a word on double-click.",
        } else if (std.mem.eql(u8, key_name, "opacity")) .{
            .label = "Selection Opacity",
            .description = "Fill opacity of the selection highlight (0.0–1.0).",
        } else if (std.mem.eql(u8, key_name, "foreground_opacity")) .{
            .label = "Foreground Opacity",
            .description = "How strongly the selection text color tints selected characters (0 keeps text colors, 1 replaces them).",
        } else if (std.mem.eql(u8, key_name, "border_color")) .{
            .label = "Border Color",
            .description = "Outline color drawn around selected text.",
        } else if (std.mem.eql(u8, key_name, "border_opacity")) .{
            .label = "Border Opacity",
            .description = "Opacity of the selection outline (0.0–1.0).",
        } else if (std.mem.eql(u8, key_name, "border_width")) .{
            .label = "Border Width",
            .description = "Outline thickness around selected text (0 hides the outline).",
        } else if (std.mem.eql(u8, key_name, "border_style")) .{
            .label = "Border Style",
            .description = "Selection border appearance: unified perimeter, split rows, underline, or left bar.",
        } else if (std.mem.eql(u8, key_name, "radius")) .{
            .label = "Corner Radius",
            .description = "Roundness of selection corners in pixels (0 keeps corners sharp).",
        } else if (std.mem.eql(u8, key_name, "blur_radius")) .{
            .label = "Blur Radius",
            .description = "Frosted glass blur strength behind selected text (0 turns blur off).",
        } else @compileError("unmapped selection key: " ++ key_name),

        .clipboard => if (std.mem.eql(u8, key_name, "osc52_write")) .{
            .label = "Clipboard Write (OSC 52)",
            .description = "Allow programs inside the terminal to copy text to your clipboard.",
        } else if (std.mem.eql(u8, key_name, "osc52_read")) .{
            .label = "Clipboard Read (OSC 52)",
            .description = "Allow programs inside the terminal to read text from your clipboard.",
        } else @compileError("unmapped clipboard key: " ++ key_name),

        .shell => if (std.mem.eql(u8, key_name, "program")) .{
            .label = "Shell Program",
            .description = "Path to your preferred shell executable, or Automatic for your default shell.",
        } else if (std.mem.eql(u8, key_name, "argument")) .{
            .label = "Shell Arguments",
            .description = "Arguments passed to the shell on startup.",
        } else if (std.mem.eql(u8, key_name, "working_directory")) .{
            .label = "Working Directory",
            .description = "Starting folder for new shells, or inherit from where Rex was launched.",
        } else @compileError("unmapped shell key: " ++ key_name),

        .toast, .banner, .modal, .alert_dialog => overlayMeta(section, key_name),

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
        .colors => colorMeta(key_name),
        else => @compileError("unmapped section in keyMeta: " ++ @tagName(section)),
    };
}

const ansi_color_names = [16][]const u8{
    "Black",
    "Red",
    "Green",
    "Yellow",
    "Blue",
    "Magenta",
    "Cyan",
    "White",
    "Bright Black",
    "Bright Red",
    "Bright Green",
    "Bright Yellow",
    "Bright Blue",
    "Bright Magenta",
    "Bright Cyan",
    "Bright White",
};

fn colorMeta(comptime key_name: []const u8) KeyMeta {
    if (std.mem.eql(u8, key_name, "background")) return .{
        .label = "Background",
        .description = "Override the terminal background color, or keep the theme default.",
    };
    if (std.mem.eql(u8, key_name, "foreground")) return .{
        .label = "Foreground",
        .description = "Override the default text color, or keep the theme default.",
    };
    if (std.mem.eql(u8, key_name, "selection_background")) return .{
        .label = "Selection Background",
        .description = "Override the highlight color behind selected text, or keep the theme default.",
    };
    if (std.mem.eql(u8, key_name, "selection_foreground")) return .{
        .label = "Selection Foreground",
        .description = "Override the color of selected text, or keep the theme default.",
    };
    if (std.mem.eql(u8, key_name, "accent")) return .{
        .label = "Accent",
        .description = "Override the cursor and accent color, or keep the theme default.",
    };
    inline for (ansi_color_names, 0..) |color_name, i| {
        if (std.mem.eql(u8, key_name, std.fmt.comptimePrint("color{d}", .{i}))) return .{
            .label = std.fmt.comptimePrint("Color {d} · {s}", .{ i, color_name }),
            .description = std.fmt.comptimePrint("Override ANSI color {d} ({s}), or keep the theme default.", .{ i, color_name }),
        };
    }
    @compileError("unmapped colors key: " ++ key_name);
}

fn scrollbarMeta(comptime key_name: []const u8) KeyMeta {
    if (std.mem.eql(u8, key_name, "width")) return .{
        .label = "Bar Width",
        .description = "Scrollbar thickness when idle in pixels (0 hides the bar).",
    };
    if (std.mem.eql(u8, key_name, "hover_width")) return .{
        .label = "Hover Width",
        .description = "Expanded scrollbar thickness when the pointer hovers over it.",
    };
    if (std.mem.eql(u8, key_name, "gap")) return .{
        .label = "Edge Gap",
        .description = "Space between the scrollbar and the right window edge in pixels.",
    };
    if (std.mem.eql(u8, key_name, "min_thumb_height")) return .{
        .label = "Minimum Thumb Height",
        .description = "Shortest height the draggable scrollbar thumb can shrink to in pixels.",
    };
    if (std.mem.eql(u8, key_name, "radius")) return .{
        .label = "Corner Radius",
        .description = "Roundness of the scrollbar track and thumb corners in pixels.",
    };
    if (std.mem.eql(u8, key_name, "auto_hide")) return .{
        .label = "Auto-hide at Bottom",
        .description = "Fade the scrollbar down when viewing the latest output.",
    };
    if (std.mem.eql(u8, key_name, "auto_hide_opacity")) return .{
        .label = "Idle Opacity",
        .description = "Opacity of the faded scrollbar while at the bottom (0.0–1.0).",
    };
    if (std.mem.eql(u8, key_name, "track_color")) return .{
        .label = "Track Color",
        .description = "Background color of the scrollbar track.",
    };
    if (std.mem.eql(u8, key_name, "track_opacity")) return .{
        .label = "Track Opacity",
        .description = "Opacity of the scrollbar track background (0.0–1.0).",
    };
    if (std.mem.eql(u8, key_name, "thumb_color")) return .{
        .label = "Thumb Color",
        .description = "Color of the draggable scrollbar thumb.",
    };
    if (std.mem.eql(u8, key_name, "thumb_opacity")) return .{
        .label = "Thumb Opacity",
        .description = "Opacity of the scrollbar thumb (0.0–1.0).",
    };
    if (std.mem.eql(u8, key_name, "thumb_hover_color")) return .{
        .label = "Thumb Hover Color",
        .description = "Color of the scrollbar thumb while hovered.",
    };
    if (std.mem.eql(u8, key_name, "thumb_hover_opacity")) return .{
        .label = "Thumb Hover Opacity",
        .description = "Opacity of the scrollbar thumb while hovered (0.0–1.0).",
    };
    @compileError("unmapped scrollbar key: " ++ key_name);
}

fn overlayMeta(comptime section: keys.Section, comptime key_name: []const u8) KeyMeta {
    if (std.mem.eql(u8, key_name, "enabled")) return .{
        .label = if (section == .toast) "Enable Toasts" else "Enable Banners",
        .description = if (section == .toast)
            "Show brief pop-up notifications inside the terminal."
        else
            "Show persistent status banners inside the terminal.",
    };
    if (std.mem.eql(u8, key_name, "duration")) return .{
        .label = "Display Duration",
        .description = "How long a toast remains visible before dismissing.",
    };
    if (std.mem.eql(u8, key_name, "placement")) return .{
        .label = "Placement",
        .description = "Display as a rounded floating card or a full-width docked bar.",
    };
    if (std.mem.eql(u8, key_name, "position")) return switch (section) {
        .toast => .{
            .label = "Position",
            .description = "Corner or edge where toast notifications stack.",
        },
        .banner => .{
            .label = "Position",
            .description = "Window edge anchor where status banners appear.",
        },
        .modal => .{
            .label = "Position",
            .description = "Vertical placement of modal dialogs over the backdrop.",
        },
        else => @compileError("unexpected position section: " ++ @tagName(section)),
    };
    if (std.mem.eql(u8, key_name, "width")) return switch (section) {
        .toast => .{
            .label = "Card Width",
            .description = "Width of toast notification cards in pixels.",
        },
        .alert_dialog => .{
            .label = "Dialog Width",
            .description = "Maximum width of confirmation alert dialogs in pixels.",
        },
        else => @compileError("unexpected width section: " ++ @tagName(section)),
    };
    if (std.mem.eql(u8, key_name, "max_width")) return .{
        .label = "Maximum Width",
        .description = "Maximum width of floating banners in pixels.",
    };
    if (std.mem.eql(u8, key_name, "margin")) return switch (section) {
        .toast => .{
            .label = "Edge Margin",
            .description = "Distance between the toast stack and window edges in pixels.",
        },
        .banner => .{
            .label = "Edge Margin",
            .description = "Distance between floating banners and window edges in pixels.",
        },
        .modal => .{
            .label = "Edge Margin",
            .description = "Minimum distance between modal dialogs and window edges in pixels.",
        },
        else => @compileError("unexpected margin section: " ++ @tagName(section)),
    };
    if (std.mem.eql(u8, key_name, "padding")) return switch (section) {
        .toast => .{
            .label = "Inner Padding",
            .description = "Space inside each toast card in pixels.",
        },
        .banner => .{
            .label = "Inner Padding",
            .description = "Space inside each status banner in pixels.",
        },
        .modal => .{
            .label = "Inner Padding",
            .description = "Space inside modal dialog cards in pixels.",
        },
        else => @compileError("unexpected padding section: " ++ @tagName(section)),
    };
    if (std.mem.eql(u8, key_name, "gap")) return switch (section) {
        .toast => .{
            .label = "Stack Gap",
            .description = "Vertical spacing between stacked toast cards in pixels.",
        },
        .modal => .{
            .label = "Section Gap",
            .description = "Vertical spacing between header, body, and buttons in pixels.",
        },
        else => @compileError("unexpected gap section: " ++ @tagName(section)),
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
        .description = "Which button receives initial keyboard focus in confirmation alert dialogs.",
    };
    if (std.mem.eql(u8, key_name, "icon")) return .{
        .label = "Dialog Icon",
        .description = "Icon badge displayed above the title in confirmation alert dialogs.",
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
    segmented,
    enum_set,
    list,
    color,
    text_input,
};

fn controlKind(comptime key: keys.Key) ControlKind {
    if (key.section == .ui and std.mem.eql(u8, key.name, "color_scheme")) return .segmented;
    if (key.kind == .theme or key.kind == .font_weight) return .select;
    if (key.kind == .fraction) return .slider;
    if (key.kind == .duration) return .duration;
    if (key.kind == .font_fallback or key.kind == .shell_argument) return .list;
    if (key.kind == .color) return .color;
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
    key_segment: struct { key: u16, idx: u8 },
    select_choice: usize,
    key_checkbox: struct { key: u16, bit: u8 },
    key_input: u16,
    color_reset: u16,
    stepper_dec: u16,
    stepper_inc: u16,
    list_add: u16,
    list_up: struct { key: u16, item: u16 },
    list_down: struct { key: u16, item: u16 },
    list_remove: struct { key: u16, item: u16 },
    ansi_colors_toggle,
    preview_toast,
    preview_banner,
    preview_dialog,
    preview_banner_close,
    preview_toast_close: u32,
    preview_dialog_action: u8,
    preview_dialog_card,
    preview_dialog_scrim,
    layer,
};

const layer_id = Id.of("settings.layer");
const scroll_area_id = Id.of("settings.scroll_area");
const ansi_toggle_id = Id.of("settings.ansi_toggle");
const preview_toast_id = Id.of("settings.preview_toast");
const preview_banner_id = Id.of("settings.preview_banner");
const preview_dialog_id = Id.of("settings.preview_dialog");

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

fn segmentId(idx: u16, seg: usize) Id {
    return Id.of("settings.segment").item(@as(u32, idx) * 8 + @as(u32, @intCast(seg)));
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

fn colorResetId(idx: u16) Id {
    return Id.of("settings.color_reset").item(idx);
}

const color_slot_count: usize = blk: {
    var n: usize = 0;
    for (keys.table) |key| {
        if (key.kind == .color) n += 1;
    }
    break :blk n;
};

const color_slot_index: [keys.table.len]?u8 = blk: {
    var map: [keys.table.len]?u8 = .{null} ** keys.table.len;
    var slot: u8 = 0;
    for (keys.table, 0..) |key, i| {
        if (key.kind == .color) {
            map[i] = slot;
            slot += 1;
        }
    }
    break :blk map;
};

const stepper_hold_delay_ms: u32 = 350;
const stepper_repeat_ms: u32 = 75;

const StepperHold = union(enum) {
    idle,
    holding: struct {
        target: Target,
        last_ms: i64,
        until_step_ms: u32,
        repeated: bool,
    },
};

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
    open_select: ?struct { key: u16, highlight: usize, top: usize = 0 } = null,
    inputs: [keys.table.len]input.State = [_]input.State{.{}} ** keys.table.len,
    color_placeholders: [color_slot_count][7]u8 = [_][7]u8{.{ '#', '0', '0', '0', '0', '0', '0' }} ** color_slot_count,
    list_items: [keys.table.len]std.ArrayListUnmanaged([]u8) = [_]std.ArrayListUnmanaged([]u8){.empty} ** keys.table.len,
    duration_units: [keys.table.len]DurationUnit = [_]DurationUnit{.ms} ** keys.table.len,
    slider_values: [keys.table.len]f32 = [_]f32{0} ** keys.table.len,
    dirty: [keys.table.len]bool = [_]bool{false} ** keys.table.len,
    ansi_colors_open: bool = false,
    error_key: ?u16 = null,
    error_msg: std.ArrayListUnmanaged(u8) = .empty,
    preview_toast: kit.toast.State = .empty,
    preview_banner: kit.alert.State = .empty,
    preview_dialog: kit.alert_dialog.State = .empty,
    preview_table: kit.memory.Table = .empty,
    preview_toast_motion: kit.toast.Motion = .settled,
    preview_last_ms: ?i64 = null,
    preview_glide_ms: u32 = 0,
    stepper_hold: StepperHold = .idle,

    pub fn activeConfig(self: *const State) *const Config {
        if (self.loaded) |*l| return &l.config;
        return self.initial_config;
    }
};

/// Live UI kit theme for the settings window, tracking the active `[ui]
/// color_scheme` and terminal background so light/dark switches immediately.
pub fn currentTheme(state: *const State) *const Theme {
    const cfg = state.activeConfig();
    const background = cfg.resolvedTheme().background;
    return cfg.ui.color_scheme.variant(.{ background.r, background.g, background.b }).theme();
}

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
    syncPreviewOptions(&state);
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

fn formatHexRgb(rgb: Rgb, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b }) catch "";
}

fn resolvedColorSlot(comptime key_name: []const u8, theme: ThemePreset) Rgb {
    if (comptime std.mem.eql(u8, key_name, "background")) return theme.background;
    if (comptime std.mem.eql(u8, key_name, "foreground")) return theme.foreground;
    if (comptime std.mem.eql(u8, key_name, "selection_background")) return theme.selection_background;
    if (comptime std.mem.eql(u8, key_name, "selection_foreground")) return theme.selection_foreground;
    if (comptime std.mem.eql(u8, key_name, "accent")) return theme.accent;
    inline for (0..16) |n| {
        if (comptime std.mem.eql(u8, key_name, std.fmt.comptimePrint("color{d}", .{n}))) {
            return theme.ansi[n];
        }
    }
    @compileError("unmapped color slot: " ++ key_name);
}

const ColorInfo = struct {
    resolved: Rgb,
    overridden: bool,
    reset_token: []const u8,
};

fn colorInfo(idx: u16, cfg: *const Config) ColorInfo {
    @setEvalBranchQuota(keys.eval_branch_quota);
    const theme = cfg.resolvedTheme();
    inline for (keys.table, 0..) |key, i| {
        if (comptime key.kind == .color) {
            if (i == idx) {
                const val = keys.fieldValue(Config, key.field, cfg);
                if (@typeInfo(@TypeOf(val)) == .optional) {
                    return .{
                        .resolved = resolvedColorSlot(key.name, theme),
                        .overridden = val != null,
                        .reset_token = "inherit",
                    };
                }
                const default_val = keys.fieldValue(Config, key.field, &config_defaults.default);
                return .{
                    .resolved = val,
                    .overridden = !std.meta.eql(val, default_val),
                    .reset_token = "default",
                };
            }
        }
    }
    return .{ .resolved = .{ .r = 0, .g = 0, .b = 0 }, .overridden = false, .reset_token = "inherit" };
}

fn readInputValue(idx: u16, cfg: *const Config, buf: []u8) []const u8 {
    @setEvalBranchQuota(keys.eval_branch_quota);
    inline for (keys.table, 0..) |key, i| {
        if (comptime controlKind(key) == .text_input or controlKind(key) == .stepper or controlKind(key) == .color) {
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
    if (kind == .color) return formatHexRgb(val, buf);
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
            .text_input, .stepper, .color => {
                if (info.kind == .color) {
                    if (color_slot_index[i]) |slot| {
                        _ = formatHexRgb(colorInfo(idx, cfg).resolved, &state.color_placeholders[slot]);
                    }
                }
                if (!state.dirty[i]) {
                    const text = readInputValue(idx, cfg, &buf);
                    try state.inputs[i].setText(state.gpa, text);
                }
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

const preview_dialog_actions = [_]kit.alert_dialog.Action{
    .{ .label = "Cancel", .role = .dismiss, .key_cap = "Esc" },
    .{ .label = "Close window", .variant = .destructive },
};

fn overlayAnchor(pos: overlay.Position) kit.tree.ScreenAnchor {
    return switch (pos) {
        .top_left => .top_left,
        .top_center => .top_center,
        .top_right => .top_right,
        .bottom_left => .bottom_left,
        .bottom_center => .bottom_center,
        .bottom_right => .bottom_right,
    };
}

fn alertDialogMedia(icon: overlay.AlertDialog.Icon) kit.alert_dialog.Media {
    return switch (icon) {
        .warning => .warning,
        .info => .info,
        .@"error" => .err,
        .none => .none,
    };
}

fn syncPreviewOptions(state: *State) void {
    const cfg = state.activeConfig();
    const win = cfg.window;
    state.preview_toast.motion = cfg.ui.motion;
    state.preview_banner.motion = cfg.ui.motion;
    state.preview_dialog.motion = cfg.ui.motion;

    const next_toast_pos = overlayAnchor(win.toast.position);
    if (state.preview_toast.option.position != next_toast_pos) {
        state.preview_table = .empty;
    }
    state.preview_toast.option = .{
        .width = win.toast.width,
        .position = next_toast_pos,
        .margin = win.toast.margin,
        .padding = win.toast.padding,
        .gap = win.toast.gap,
    };
    state.preview_banner.option = .{
        .max_width = win.banner.max_width,
        .placement = switch (win.banner.placement) {
            .floating => .floating,
            .docked => .docked,
        },
        .position = overlayAnchor(win.banner.position),
        .margin = win.banner.margin,
        .padding = win.banner.padding,
    };
    state.preview_dialog.option = .{
        .width = win.alert_dialog.width,
        .position = switch (win.modal.position) {
            .center => .center,
            .top_center => .top_center,
            .bottom_center => .bottom_center,
        },
        .margin = win.modal.margin,
        .padding = win.modal.padding,
        .gap = win.modal.gap,
        .scrim_alpha = @intFromFloat(@round(std.math.clamp(win.modal.backdrop_opacity, 0.0, 1.0) * 255.0)),
        .media = alertDialogMedia(win.alert_dialog.icon),
    };
}

fn previewNowMs(state: *const State) i64 {
    return std.Io.Clock.Timestamp.now(state.io, .awake).raw.toMilliseconds();
}

fn anyPreviewActive(state: *const State) bool {
    return state.preview_dialog.phase != .closed or
        state.preview_banner.phase != .closed or
        state.preview_toast.len > 0 or
        state.preview_toast_motion == .moving;
}

fn minOptMs(a: ?u32, b: ?u32) ?u32 {
    const bv = b orelse return a;
    const av = a orelse return bv;
    return @min(av, bv);
}

fn triggerPreviewToast(state: *State) void {
    syncPreviewOptions(state);
    _ = kit.toast.update(&state.preview_toast, .{ .push = .{
        .title = "Sample toast notification",
        .description = "Positioned and timed from [toast].",
        .kind = .info,
        .duration_ms = state.activeConfig().window.toast.duration_ms,
    } });
    if (state.preview_last_ms == null) state.preview_last_ms = previewNowMs(state);
}

fn triggerPreviewBanner(state: *State) void {
    syncPreviewOptions(state);
    _ = kit.alert.update(&state.preview_banner, .{ .show = .{
        .kind = .info,
        .title = "Sample status banner",
        .description = "Placement, width, and spacing follow [banner].",
    } });
    if (state.preview_last_ms == null) state.preview_last_ms = previewNowMs(state);
}

fn triggerPreviewDialog(state: *State) void {
    syncPreviewOptions(state);
    state.open_select = null;
    const focus_idx: u8 = switch (state.activeConfig().window.alert_dialog.default_focus) {
        .cancel => 0,
        .confirm => 1,
    };
    _ = kit.alert_dialog.update(&state.preview_dialog, .{ .open = .{
        .media = alertDialogMedia(state.activeConfig().window.alert_dialog.icon).codepoint(kit.icons.none),
        .title = "Close this window?",
        .body = "Previewing [modal] & [alert_dialog] layout, separator, and focus.",
        .actions = &preview_dialog_actions,
        .focus = focus_idx,
    } });
    if (state.preview_last_ms == null) state.preview_last_ms = previewNowMs(state);
}

fn stepperHoldWakeMs(state: *const State) ?u32 {
    return switch (state.stepper_hold) {
        .idle => null,
        .holding => |hold| if (state.preview_dialog.phase == .closed and
            state.open_select == null and
            std.meta.eql(state.pressed, hold.target) and
            std.meta.eql(state.hover, hold.target))
            hold.until_step_ms
        else
            null,
    };
}

pub fn wait(state: *const State) ?f64 {
    var min_ms: ?u32 = null;
    if (state.preview_dialog.phase != .closed) {
        min_ms = minOptMs(min_ms, state.preview_dialog.phase.wakeMs());
    } else {
        min_ms = minOptMs(min_ms, state.preview_banner.wakeMs());
        const toast_ms: ?u32 = if (state.preview_toast_motion == .moving)
            kit.motion.frame_ms
        else
            state.preview_toast.wakeMs();
        min_ms = minOptMs(min_ms, toast_ms);
        min_ms = minOptMs(min_ms, stepperHoldWakeMs(state));
    }
    const ms = min_ms orelse return null;
    return @as(f64, @floatFromInt(ms)) / std.time.ms_per_s;
}

pub fn wake(state: *State) bool {
    var changed = wakePreview(state);
    if (wakeStepperHold(state)) changed = true;
    return changed;
}

fn wakePreview(state: *State) bool {
    if (!anyPreviewActive(state)) {
        state.preview_last_ms = null;
        state.preview_glide_ms = 0;
        return false;
    }
    const now = previewNowMs(state);
    const prev = state.preview_last_ms orelse {
        state.preview_last_ms = now;
        return false;
    };
    const raw = now - prev;
    if (raw <= 0) return false;
    state.preview_last_ms = now;
    const dt_ms: u32 = @intCast(@min(raw, std.math.maxInt(u32)));
    state.preview_glide_ms +|= @min(dt_ms, 500);

    var changed = false;
    if (state.preview_dialog.phase != .closed) {
        if (kit.alert_dialog.update(&state.preview_dialog, .{ .tick = dt_ms }) != .quiet) {
            changed = true;
        }
    } else {
        if (kit.alert.update(&state.preview_banner, .{ .tick = dt_ms })) changed = true;
        if (kit.toast.update(&state.preview_toast, .{ .tick = dt_ms })) changed = true;
        if (state.preview_toast_motion == .moving) changed = true;
    }
    if (!anyPreviewActive(state)) {
        state.preview_last_ms = null;
        state.preview_glide_ms = 0;
    }
    return changed;
}

fn wakeStepperHold(state: *State) bool {
    switch (state.stepper_hold) {
        .idle => return false,
        .holding => |*hold| {
            if (state.preview_dialog.phase != .closed or
                state.open_select != null or
                !std.meta.eql(state.pressed, hold.target) or
                !std.meta.eql(state.hover, hold.target))
            {
                hold.last_ms = previewNowMs(state);
                return false;
            }
            const now = previewNowMs(state);
            const raw = now - hold.last_ms;
            if (raw <= 0) return false;
            hold.last_ms = now;
            var elapsed: u32 = @intCast(@min(raw, std.math.maxInt(u32)));
            var changed = false;
            var steps: u32 = 0;
            while (elapsed >= hold.until_step_ms and steps < 8) {
                elapsed -= hold.until_step_ms;
                hold.until_step_ms = stepper_repeat_ms;
                hold.repeated = true;
                steps += 1;
                if (activate(state, hold.target)) changed = true;
            }
            if (elapsed < hold.until_step_ms) {
                hold.until_step_ms -= elapsed;
            } else {
                hold.until_step_ms = stepper_repeat_ms;
            }
            return changed;
        },
    }
}

/// Applies enter/leave/glide motion to any active preview overlay after layout.
pub fn place(state: *State, tree: *Tree) void {
    if (state.preview_dialog.phase != .closed) return;
    if (state.preview_banner.phase != .closed) {
        if (tree.find(kit.alert.card_id)) |card| {
            if (card.parent != kit.tree.none) {
                kit.alert.place(&state.preview_banner, tree, card.parent);
            }
        }
    }
    const visible = state.preview_toast.visible();
    if (visible.len > 0) {
        if (tree.find(kit.toast.cardId(visible[0].serial))) |card| {
            if (card.parent != kit.tree.none) {
                const dt = state.preview_glide_ms;
                state.preview_glide_ms = 0;
                state.preview_toast_motion = kit.toast.place(
                    &state.preview_toast,
                    tree,
                    card.parent,
                    &state.preview_table,
                    dt,
                ) catch .settled;
                return;
            }
        }
    }
    state.preview_glide_ms = 0;
    state.preview_toast_motion = .settled;
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
            if (state.preview_dialog.phase != .closed) {
                const over_btn: u8 = switch (kit.alert_dialog.hit(pointer.id) orelse .scrim) {
                    .action => |btn_idx| btn_idx,
                    .scrim, .card => kit.alert_dialog.no_action,
                };
                const dialog_changed = kit.alert_dialog.update(&state.preview_dialog, .{ .pointer = over_btn }) == .redraw;
                const next_hover = over(state, pointer.id);
                const h_changed = !std.meta.eql(state.hover, next_hover);
                state.hover = next_hover;
                return dialog_changed or h_changed;
            }
            const alert_over: kit.alert.Pointer = if (state.preview_banner.hit(pointer.id) == .close) .close else .away;
            const alert_changed = kit.alert.update(&state.preview_banner, .{ .pointer = alert_over });
            const toast_over: kit.toast.Pointer = if (state.preview_toast.hit(pointer.id) != .none) .over else .away;
            _ = kit.toast.update(&state.preview_toast, .{ .pointer = toast_over });
            const sb = state.frame.update(page_count, .{ .pointer = sidebar.hit(pointer.id, page_count) });
            const next_hover = over(state, pointer.id);
            const h_changed = !std.meta.eql(state.hover, next_hover);
            switch (state.stepper_hold) {
                .holding => |*hold| {
                    if (std.meta.eql(next_hover, hold.target) and !std.meta.eql(state.hover, hold.target)) {
                        hold.last_ms = previewNowMs(state);
                    }
                },
                .idle => {},
            }
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
            return sb or h_changed or alert_changed;
        },
        .press => |id| {
            state.stepper_hold = .idle;
            if (state.preview_dialog.phase != .closed) {
                switch (kit.alert_dialog.hit(id) orelse .scrim) {
                    .action => |btn_idx| {
                        state.pressed = .{ .preview_dialog_action = btn_idx };
                        return kit.alert_dialog.update(&state.preview_dialog, .{ .press = btn_idx }) == .redraw;
                    },
                    .card => {
                        state.pressed = .preview_dialog_card;
                        return kit.alert_dialog.update(&state.preview_dialog, .blur) == .redraw;
                    },
                    .scrim => {
                        if (state.activeConfig().window.modal.on_outside_click == .close) {
                            state.pressed = .none;
                            return kit.alert_dialog.update(&state.preview_dialog, .dismiss) != .quiet;
                        }
                        state.pressed = .preview_dialog_scrim;
                        return false;
                    },
                }
            }
            switch (state.preview_banner.hit(id)) {
                .close => {
                    state.pressed = .preview_banner_close;
                    return kit.alert.update(&state.preview_banner, .press);
                },
                .card => {
                    state.pressed = .none;
                    return false;
                },
                .none => {},
            }
            switch (state.preview_toast.hit(id)) {
                .close => |serial| {
                    state.pressed = .none;
                    return kit.toast.update(&state.preview_toast, .{ .dismiss = serial });
                },
                .toast => {
                    state.pressed = .none;
                    return false;
                },
                .none => {},
            }
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
                switch (target) {
                    .stepper_dec, .stepper_inc => {
                        state.stepper_hold = .{ .holding = .{
                            .target = target,
                            .last_ms = previewNowMs(state),
                            .until_step_ms = stepper_hold_delay_ms,
                            .repeated = false,
                        } };
                    },
                    else => {},
                }
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
            const target = state.pressed;
            const already_repeated = switch (state.stepper_hold) {
                .holding => |hold| hold.repeated and std.meta.eql(hold.target, target),
                .idle => false,
            };
            state.stepper_hold = .idle;
            if (state.preview_dialog.phase != .closed) {
                state.pressed = .none;
                return kit.alert_dialog.update(&state.preview_dialog, .release) != .quiet;
            }
            if (state.preview_banner.touch == .pressed) {
                const over_close: kit.alert.Pointer = if (state.hover == .preview_banner_close) .close else .away;
                state.pressed = .none;
                return kit.alert.update(&state.preview_banner, .{ .release = over_close });
            }
            if (state.dragging_slider) |idx| {
                state.dragging_slider = null;
                commitSlider(state, idx);
                return true;
            }
            const sb = state.frame.update(page_count, .release);
            state.pressed = .none;
            if (std.meta.eql(target, state.hover) and !already_repeated) {
                if (activate(state, target)) return true;
            }
            return sb;
        },
        .scroll => |wheel| {
            if (state.open_select) |*sel| {
                const count = selectChoiceCount(sel.key);
                if (count > popup_max_items) {
                    const max_top = count - popup_max_items;
                    const step: usize = @max(1, @as(usize, @intFromFloat(@abs(wheel.dy) / popup.item_height)));
                    const next_top = if (wheel.dy > 0)
                        @min(sel.top + step, max_top)
                    else if (wheel.dy < 0)
                        sel.top -| step
                    else
                        sel.top;
                    if (next_top == sel.top) return false;
                    sel.top = next_top;
                    return true;
                }
                return false;
            }
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

fn fitPopupTop(highlight: usize, count: usize, prev_top: usize) usize {
    if (count <= popup_max_items) return 0;
    const max_top = count - popup_max_items;
    var top = @min(prev_top, max_top);
    if (highlight < top) top = highlight;
    if (highlight >= top + popup_max_items) top = highlight - popup_max_items + 1;
    return @min(top, max_top);
}

fn handleKey(state: *State, press: host.KeyPress) bool {
    if (state.preview_dialog.phase.acceptsInput()) {
        return switch (press.key) {
            .escape => kit.alert_dialog.update(&state.preview_dialog, .dismiss) != .quiet,
            .left => kit.alert_dialog.update(&state.preview_dialog, .{ .focus = .previous }) != .quiet,
            .right => kit.alert_dialog.update(&state.preview_dialog, .{ .focus = .next }) != .quiet,
            .tab => kit.alert_dialog.update(&state.preview_dialog, .{
                .focus = if (press.mods.shift) .previous else .next,
            }) != .quiet,
            .enter, .space => kit.alert_dialog.update(&state.preview_dialog, .activate) != .quiet,
            else => false,
        };
    }
    if (state.open_select) |*sel| {
        const count = selectChoiceCount(sel.key);
        switch (press.key) {
            .up => {
                sel.highlight -|= 1;
                sel.top = fitPopupTop(sel.highlight, count, sel.top);
                return true;
            },
            .down => {
                if (count > 0) {
                    sel.highlight = @min(sel.highlight + 1, count - 1);
                    sel.top = fitPopupTop(sel.highlight, count, sel.top);
                }
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
        .key_segment => |seg| switch (press.key) {
            .enter, .space => return activate(state, .{ .key_segment = seg }),
            .left => {
                if (seg.idx > 0) {
                    state.focused = .{ .key_segment = .{ .key = seg.key, .idx = seg.idx - 1 } };
                    ensureFocusedVisible(state);
                    return true;
                }
            },
            .right => {
                if (@as(usize, seg.idx) + 1 < row_infos[seg.key].display_labels.len) {
                    state.focused = .{ .key_segment = .{ .key = seg.key, .idx = seg.idx + 1 } };
                    ensureFocusedVisible(state);
                    return true;
                }
            },
            .escape => {
                state.focused = .none;
                return true;
            },
            else => {},
        },
        .ansi_colors_toggle => switch (press.key) {
            .enter, .space => return activate(state, .ansi_colors_toggle),
            .escape => {
                state.focused = .none;
                return true;
            },
            else => {},
        },
        .preview_toast, .preview_banner, .preview_dialog => switch (press.key) {
            .enter, .space => return activate(state, state.focused),
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

const max_section_count = @typeInfo(keys.Section).@"enum".fields.len;

fn pageSections(page: Page, out: *[max_section_count]keys.Section) []const keys.Section {
    var seen = std.EnumSet(keys.Section).initEmpty();
    var count: usize = 0;
    for (row_infos, 0..) |info, i| {
        const idx: u16 = @intCast(i);
        if (keys.availableHere(idx) and info.page == page and !seen.contains(info.display_section)) {
            seen.insert(info.display_section);
            out[count] = info.display_section;
            count += 1;
        }
    }
    return out[0..count];
}

fn sectionRows(page: Page, sec: keys.Section, out: *[keys.table.len]u16) []const u16 {
    var count: usize = 0;
    // Show promoted segmented controls (Interface Theme) first inside their
    // display section while preserving keys.table order everywhere else.
    for (row_infos, 0..) |info, i| {
        const idx: u16 = @intCast(i);
        if (keys.availableHere(idx) and info.page == page and info.display_section == sec and info.kind == .segmented) {
            out[count] = idx;
            count += 1;
        }
    }
    for (row_infos, 0..) |info, i| {
        const idx: u16 = @intCast(i);
        if (keys.availableHere(idx) and info.page == page and info.display_section == sec and info.kind != .segmented) {
            out[count] = idx;
            count += 1;
        }
    }
    return out[0..count];
}

fn pageFocusTargets(page: Page, ansi_open: bool, out: []Target) usize {
    var count: usize = 0;
    var sec_buf: [max_section_count]keys.Section = undefined;
    var row_buf: [keys.table.len]u16 = undefined;
    for (pageSections(page, &sec_buf)) |sec| {
        var ansi_toggle_added = false;
        for (sectionRows(page, sec, &row_buf)) |idx| {
            const info = row_infos[idx];
            if (info.is_ansi_color) {
                if (!ansi_toggle_added) {
                    out[count] = .ansi_colors_toggle;
                    count += 1;
                    ansi_toggle_added = true;
                }
                if (!ansi_open) continue;
            }
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
                .segmented => {
                    for (0..info.display_labels.len) |seg_i| {
                        out[count] = .{ .key_segment = .{ .key = idx, .idx = @intCast(seg_i) } };
                        count += 1;
                    }
                },
                .duration => {
                    out[count] = .{ .key_input = idx };
                    count += 1;
                    out[count] = .{ .key_select = idx };
                    count += 1;
                },
                .stepper, .text_input, .list, .color => {
                    out[count] = .{ .key_input = idx };
                    count += 1;
                },
            }
        }
        if (page == .overlays) {
            switch (sec) {
                .toast => {
                    out[count] = .preview_toast;
                    count += 1;
                },
                .banner => {
                    out[count] = .preview_banner;
                    count += 1;
                },
                .alert_dialog => {
                    out[count] = .preview_dialog;
                    count += 1;
                },
                else => {},
            }
        }
    }
    return count;
}

fn cycleFocus(state: *State, reverse: bool) bool {
    const page: Page = @enumFromInt(state.frame.current);
    var targets: [keys.table.len * 2 + 8]Target = undefined;
    var count: usize = 0;
    if (state.frame.shown()) {
        targets[0] = .sidebar;
        count = 1;
    }
    count += pageFocusTargets(page, state.ansi_colors_open, targets[count..]);
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
        .key_segment => |seg| segmentId(seg.key, seg.idx),
        .key_input => |idx| inputId(idx),
        .color_reset => |idx| colorResetId(idx),
        .stepper_dec => |idx| decId(idx),
        .stepper_inc => |idx| incId(idx),
        .list_add => |idx| listAddId(idx),
        .ansi_colors_toggle => ansi_toggle_id,
        .preview_toast => preview_toast_id,
        .preview_banner => preview_banner_id,
        .preview_dialog => preview_dialog_id,
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
        .none,
        .sidebar,
        .layer,
        .preview_banner_close,
        .preview_toast_close,
        .preview_dialog_action,
        .preview_dialog_card,
        .preview_dialog_scrim,
        => return false,
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
            const highlight = if (keys.table[idx].kind == .duration)
                @intFromEnum(state.duration_units[idx])
            else
                currentSelectIndex(idx, state.activeConfig()) orelse 0;
            const count = selectChoiceCount(idx);
            state.open_select = .{
                .key = idx,
                .highlight = highlight,
                .top = fitPopupTop(highlight, count, highlight -| (popup_max_items / 2)),
            };
            return true;
        },
        .key_segment => |seg| {
            if (!std.meta.eql(state.focused, target)) blurFocused(state);
            chooseSelect(state, seg.key, seg.idx);
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
        .color_reset => |idx| {
            const ci = colorInfo(idx, state.activeConfig());
            if (!ci.overridden) return false;
            if (state.focused == .key_input and state.focused.key_input == idx) {
                state.dirty[idx] = false;
            }
            blurFocused(state);
            state.dirty[idx] = false;
            commitValue(state, idx, ci.reset_token);
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
        .ansi_colors_toggle => {
            if (state.focused != .ansi_colors_toggle) blurFocused(state);
            state.ansi_colors_open = !state.ansi_colors_open;
            return true;
        },
        .preview_toast => {
            if (state.focused != .preview_toast) blurFocused(state);
            triggerPreviewToast(state);
            return true;
        },
        .preview_banner => {
            if (state.focused != .preview_banner) blurFocused(state);
            triggerPreviewBanner(state);
            return true;
        },
        .preview_dialog => {
            if (state.focused != .preview_dialog) blurFocused(state);
            triggerPreviewDialog(state);
            return true;
        },
    }
}

fn over(state: *const State, id: Id) Target {
    if (id == .none) return .none;
    if (state.preview_dialog.phase != .closed) {
        if (kit.alert_dialog.hit(id)) |hit| return switch (hit) {
            .action => |idx| .{ .preview_dialog_action = idx },
            .card => .preview_dialog_card,
            .scrim => .preview_dialog_scrim,
        };
    }
    switch (state.preview_banner.hit(id)) {
        .close => return .preview_banner_close,
        .card => return .none,
        .none => {},
    }
    switch (state.preview_toast.hit(id)) {
        .close => |serial| return .{ .preview_toast_close = serial },
        .toast => return .none,
        .none => {},
    }
    if (id == layer_id) return .layer;
    if (id == ansi_toggle_id) return .ansi_colors_toggle;
    if (id == preview_toast_id) return .preview_toast;
    if (id == preview_banner_id) return .preview_banner;
    if (id == preview_dialog_id) return .preview_dialog;
    if (state.open_select) |sel| {
        for (0..selectChoiceCount(sel.key)) |choice_idx| {
            if (id == choiceId(choice_idx)) return .{ .select_choice = choice_idx };
        }
    }
    for (row_infos, 0..) |info, i| {
        const idx: u16 = @intCast(i);
        switch (info.kind) {
            .toggle => if (id == switchId(idx)) return .{ .key_switch = idx },
            .slider => if (id == sliderId(idx)) return .{ .key_slider = idx },
            .select => if (id == selectId(idx)) return .{ .key_select = idx },
            .segmented => {
                for (0..info.display_labels.len) |seg_i| {
                    if (id == segmentId(idx, seg_i)) {
                        return .{ .key_segment = .{ .key = idx, .idx = @intCast(seg_i) } };
                    }
                }
            },
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
            .color => {
                if (id == inputId(idx)) return .{ .key_input = idx };
                if (id == colorResetId(idx) and colorInfo(idx, state.activeConfig()).overridden) {
                    return .{ .color_reset = idx };
                }
            },
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
    if ((info.kind == .select or info.kind == .segmented) and choice < info.labels.len) {
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
        .color => {
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "inherit")) return "inherit";
            const needs_quotes = for (trimmed) |ch| {
                if (ch == ' ' or ch == '\t' or ch == '"' or ch == '\\') break true;
            } else false;
            if (!needs_quotes) return trimmed;
            var pos: usize = 0;
            if (pos >= buf.len) return null;
            buf[pos] = '"';
            pos += 1;
            for (trimmed) |c| {
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
    syncPreviewOptions(state);
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
    if (row_infos[idx].is_ansi_color) state.ansi_colors_open = true;
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
    } else if (state.hover == .key_segment) {
        const seg = state.hover.key_segment;
        const info = row_infos[seg.key];
        if (seg.idx < info.display_labels.len) {
            const card = try tooltip.open(tree, theme, segmentId(seg.key, seg.idx));
            _ = try tree.text(info.display_labels[seg.idx], .{
                .color = theme.foreground,
                .style = .xs,
            });
            tooltip.close(tree, card);
        }
    }

    if (state.preview_dialog.phase != .closed) {
        _ = try kit.alert_dialog.view(&state.preview_dialog, tree, theme);
    } else {
        _ = try kit.alert.view(&state.preview_banner, tree, theme);
        _ = try kit.toast.view(&state.preview_toast, tree, theme);
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
    display_section: keys.Section,
    page: ?Page,
    meta: KeyMeta,
    kind: ControlKind,
    key_kind: keys.Kind,
    is_ansi_color: bool,
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
    if (kind != .select and kind != .segmented) return &.{};
    if (key.kind == .theme) {
        comptime var list: [keys.theme_preset_list.len][]const u8 = undefined;
        list[0] = if (display) "Default" else "default";
        inline for (theme_presets.entries, 1..) |entry, i| {
            list[i] = if (display) entry.title else entry.slug;
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
                list[i] = if (display)
                    if (kind == .segmented and std.mem.eql(u8, f.name, "auto"))
                        "Match terminal theme"
                    else
                        comptime humanToken(f.name)
                else
                    f.name;
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

fn displaySection(comptime key: keys.Key) keys.Section {
    if (key.section == .ui and std.mem.eql(u8, key.name, "color_scheme")) return .root;
    return key.section;
}

const row_infos: [keys.table.len]RowInfo = blk: {
    @setEvalBranchQuota(keys.eval_branch_quota);
    var table: [keys.table.len]RowInfo = undefined;
    for (keys.table, 0..) |key, i| {
        table[i] = .{
            .section = key.section,
            .display_section = displaySection(key),
            .page = pageForSection(key.section),
            .meta = keyMeta(key.section, key.name),
            .kind = controlKind(key),
            .key_kind = key.kind,
            .is_ansi_color = key.section == .colors and std.mem.startsWith(u8, key.name, "color"),
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

const ansi_overridden_labels: [17][]const u8 = blk: {
    @setEvalBranchQuota(20000);
    var labels: [17][]const u8 = undefined;
    for (0..17) |i| {
        labels[i] = std.fmt.comptimePrint("{d} overridden", .{i});
    }
    break :blk labels;
};

fn paneWidth(state: *const State) f32 {
    return if (state.frame.shown() and !state.frame.narrow)
        state.viewport_width - sidebar.width
    else
        state.viewport_width;
}

fn viewAnsiCollapsible(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    cfg: *const Config,
) kit.tree.Error!void {
    const hovered = std.meta.eql(state.hover, Target.ansi_colors_toggle);
    const focused = std.meta.eql(state.focused, Target.ansi_colors_toggle);
    const ansi = cfg.resolvedTheme().ansi;

    var overridden_count: usize = 0;
    for (row_infos, 0..) |info, i| {
        if (info.is_ansi_color and colorInfo(@intCast(i), cfg).overridden) {
            overridden_count += 1;
        }
    }

    const card = try tree.open(.{
        .width = .fill,
        .fill = theme.card,
        .border = theme.border,
        .border_width = Theme.border_width,
        .radius = Theme.radius_md,
    });

    const ring_slot = try tree.open(.{
        .id = ansi_toggle_id,
        .pointer = .hand,
        .width = .fill,
        .padding = .all(Theme.ring_width),
        .border = if (focused) theme.ring.alpha(Theme.ring_opacity) else .transparent,
        .border_width = Theme.ring_width,
        .radius = Theme.radius_md - Theme.border_width,
    });

    const header = try tree.open(.{
        .axis = .row,
        .width = .fill,
        .padding = .symmetric(14 - Theme.ring_width, 10 - Theme.ring_width),
        .gap = 12,
        .cross = .center,
        .fill = if (hovered) theme.accent else .transparent,
        .border = if (focused) theme.ring else .transparent,
        .border_width = Theme.border_width,
        .radius = Theme.radius_sm,
    });

    const label_box = try tree.open(.{ .width = .fill, .gap = 2 });
    const title_row = try tree.open(.{
        .axis = .row,
        .gap = 8,
        .cross = .center,
    });
    _ = try tree.text("ANSI Palette", .{
        .color = theme.foreground,
        .style = .sm_medium,
    });
    if (overridden_count > 0) {
        const badge = try tree.open(.{
            .padding = .symmetric(6, 1),
            .fill = theme.muted,
            .radius = Theme.radius_sm,
        });
        _ = try tree.text(ansi_overridden_labels[@min(overridden_count, 16)], .{
            .color = theme.muted_foreground,
            .style = .xs,
        });
        tree.close(badge);
    }
    tree.close(title_row);
    _ = try tree.text("Terminal palette colors 0–15", .{
        .color = theme.muted_foreground,
        .style = .xs,
    });
    tree.close(label_box);

    if (paneWidth(state) >= 520) {
        const strip = try tree.open(.{
            .axis = .row,
            .gap = 2,
            .cross = .center,
            .padding = .all(3),
            .fill = theme.background,
            .border = theme.border,
            .border_width = Theme.border_width,
            .radius = Theme.radius_sm,
        });
        for (ansi) |rgb| {
            _ = try tree.leaf(.{
                .width = .{ .fixed = 10 },
                .height = .{ .fixed = 14 },
                .fill = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b },
                .radius = 2,
            });
        }
        tree.close(strip);
    }

    _ = try tree.icon(.{
        .codepoint = if (state.ansi_colors_open) kit.icons.chevron_down else kit.icons.chevron_right,
        .color = theme.muted_foreground,
        .size = Theme.icon,
    });

    tree.close(header);
    tree.close(ring_slot);

    if (state.ansi_colors_open) {
        _ = try tree.leaf(.{
            .width = .fill,
            .height = .{ .fixed = 1 },
            .fill = theme.border,
        });
        const body = try tree.open(.{
            .width = .fill,
            .padding = .all(14),
            .gap = 12,
        });
        var first = true;
        for (row_infos, 0..) |info, i| {
            const idx: u16 = @intCast(i);
            if (keys.availableHere(idx) and info.is_ansi_color) {
                if (!first) {
                    _ = try tree.leaf(.{
                        .width = .fill,
                        .height = .{ .fixed = 1 },
                        .fill = theme.border,
                    });
                }
                first = false;
                try viewKeyRow(state, tree, theme, info, idx, cfg);
            }
        }
        tree.close(body);
    }

    tree.close(card);
}

fn viewPage(state: *const State, tree: *Tree, theme: *const Theme, page: Page) kit.tree.Error!void {
    const cfg = state.activeConfig();
    var sec_buf: [max_section_count]keys.Section = undefined;
    var row_buf: [keys.table.len]u16 = undefined;
    for (pageSections(page, &sec_buf)) |sec| {
        var section_open: ?kit.tree.Index = null;
        var first_in_section = true;
        var ansi_drawn = false;

        for (sectionRows(page, sec, &row_buf)) |idx| {
            const info = row_infos[idx];
            if (info.is_ansi_color) {
                if (!ansi_drawn) {
                    if (section_open) |open_box| {
                        tree.close(open_box);
                        section_open = null;
                    }
                    try viewAnsiCollapsible(state, tree, theme, cfg);
                    ansi_drawn = true;
                }
                continue;
            }
            if (section_open == null) {
                _ = try tree.text(section_titles.get(sec), .{
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
        if (section_open) |open_box| {
            if (page == .overlays and (sec == .toast or sec == .banner or sec == .alert_dialog)) {
                _ = try tree.leaf(.{
                    .width = .fill,
                    .height = .{ .fixed = 1 },
                    .fill = theme.border,
                });
                try viewPreviewRow(state, tree, theme, sec);
            }
            tree.close(open_box);
        }
    }
}

fn viewPreviewRow(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    sec: keys.Section,
) kit.tree.Error!void {
    const id: Id, const tgt: Target, const btn_label: []const u8, const desc: []const u8 = switch (sec) {
        .toast => .{
            preview_toast_id,
            .preview_toast,
            "Test Toast",
            "Show a sample toast notification inside this window.",
        },
        .banner => .{
            preview_banner_id,
            .preview_banner,
            "Test Banner",
            "Show a sample status banner inside this window.",
        },
        .alert_dialog => .{
            preview_dialog_id,
            .preview_dialog,
            "Test Alert Dialog",
            "Open a sample alert dialog using these modal and dialog settings.",
        },
        else => unreachable,
    };

    const compact = paneWidth(state) < 540;
    const hovered = std.meta.eql(state.hover, tgt);
    const pressed = std.meta.eql(state.pressed, tgt);
    const focused = std.meta.eql(state.focused, tgt);
    const btn_state: button.State = if (pressed and hovered)
        .pressed
    else if (hovered)
        .hovered
    else
        .normal;

    const row = try tree.open(.{
        .axis = if (compact) .column else .row,
        .width = .fill,
        .cross = if (compact) .start else .center,
        .gap = if (compact) 10 else 16,
    });
    const label_box = try tree.open(.{ .width = .fill, .gap = 3 });
    _ = try tree.text("Preview", .{
        .color = theme.foreground,
        .style = .sm_medium,
    });
    _ = try tree.text(desc, .{
        .color = theme.muted_foreground,
        .style = .xs,
        .width = .fill,
    });
    tree.close(label_box);

    try button.view(tree, theme, .{
        .id = id,
        .label = btn_label,
        .variant = .outline,
        .size = .sm,
        .state = btn_state,
        .focused = focused,
    });
    tree.close(row);
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

const GroupEdge = enum { left, middle, right };

fn openGroupSegment(tree: *Tree, theme: *const Theme, options: struct {
    id: Id,
    edge: GroupEdge,
    fill: ?Theme.Color = null,
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
    const bg: ?Theme.Color = if (options.disabled)
        null
    else
        options.fill orelse if (options.hovered) theme.accent else null;
    if (bg) |fill_color| {
        if (options.edge == .middle) {
            _ = try tree.leaf(.{
                .overlay = true,
                .width = .fill,
                .height = .fill,
                .fill = fill_color,
            });
        } else {
            // Round all corners concentrically with the outer border, then square
            // off the half adjacent to the group's inner divider.
            _ = try tree.leaf(.{
                .overlay = true,
                .width = .fill,
                .height = .fill,
                .fill = fill_color,
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
                _ = try tree.leaf(.{ .width = .fill, .height = .fill, .fill = fill_color });
            } else {
                _ = try tree.leaf(.{ .width = .fill, .height = .fill, .fill = fill_color });
                _ = try tree.leaf(.{ .width = .fill, .height = .fill });
            }
            tree.close(mask);
        }
    }
    return seg;
}

fn segmentIcon(token: []const u8) u21 {
    if (std.mem.eql(u8, token, "auto")) return kit.icons.monitor;
    if (std.mem.eql(u8, token, "dark")) return kit.icons.moon;
    if (std.mem.eql(u8, token, "light")) return kit.icons.sun;
    return kit.icons.none;
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
    const pane_w = paneWidth(state);
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
        .segmented => {
            const current_idx = currentSelectIndex(idx, cfg);
            const count = info.display_labels.len;
            var hovered_any = false;
            var focused_any = false;
            for (0..count) |seg_i| {
                const seg_target: Target = .{ .key_segment = .{ .key = idx, .idx = @intCast(seg_i) } };
                if (std.meta.eql(state.hover, seg_target)) hovered_any = true;
                if (std.meta.eql(state.focused, seg_target)) focused_any = true;
            }
            const colors = groupColors(theme, false, focused_any, hovered_any);

            const ring = try tree.open(.{
                .padding = .all(Theme.ring_width),
                .border = colors.ring,
                .border_width = Theme.ring_width,
                .radius = Theme.radius_md + Theme.ring_width,
            });
            const compound = try tree.open(.{
                .axis = .row,
                .height = .{ .fixed = Theme.control_sm },
                .padding = .all(Theme.border_width),
                .cross = .center,
                .fill = theme.background,
                .border = colors.border,
                .border_width = Theme.border_width,
                .radius = Theme.radius_md,
            });
            for (0..count) |seg_i| {
                if (seg_i > 0) {
                    _ = try tree.leaf(.{
                        .width = .{ .fixed = 1 },
                        .height = .fill,
                        .fill = theme.border,
                    });
                }
                const seg_target: Target = .{ .key_segment = .{ .key = idx, .idx = @intCast(seg_i) } };
                const is_selected = if (current_idx) |cur| cur == seg_i else false;
                const is_hovered = std.meta.eql(state.hover, seg_target);
                const is_focused = std.meta.eql(state.focused, seg_target);
                const edge: GroupEdge = if (seg_i == 0)
                    .left
                else if (seg_i + 1 == count)
                    .right
                else
                    .middle;
                const seg_fill: ?Theme.Color = if (is_selected)
                    theme.accent
                else if (is_hovered or is_focused)
                    theme.muted
                else
                    null;

                const cell = try openGroupSegment(tree, theme, .{
                    .id = segmentId(idx, seg_i),
                    .edge = edge,
                    .fill = seg_fill,
                    .width = .{ .fixed = Theme.control_sm },
                });
                _ = try tree.icon(.{
                    .codepoint = segmentIcon(info.labels[seg_i]),
                    .color = if (is_selected or is_hovered or is_focused) theme.foreground else theme.muted_foreground,
                    .size = Theme.icon,
                });
                tree.close(cell);
            }
            tree.close(compound);
            tree.close(ring);
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
        .color => {
            const inp = &state.inputs[idx];
            const is_err = state.error_key == idx;
            const ci = colorInfo(idx, cfg);
            const swatch: Theme.Color = .{ .r = ci.resolved.r, .g = ci.resolved.g, .b = ci.resolved.b };
            const placeholder: []const u8 = if (color_slot_index[idx]) |slot|
                &state.color_placeholders[slot]
            else
                info.placeholder;
            const reset_hovered = std.meta.eql(state.hover, Target{ .color_reset = idx });
            const reset_pressed = std.meta.eql(state.pressed, Target{ .color_reset = idx });
            const reset_state: button.State = if (!ci.overridden)
                .disabled
            else if (reset_pressed and reset_hovered)
                .pressed
            else if (reset_hovered)
                .hovered
            else
                .normal;

            const color_row = try tree.open(.{
                .axis = .row,
                .width = control_width,
                .gap = 8,
                .cross = .center,
            });
            _ = try tree.leaf(.{
                .width = .{ .fixed = 24 },
                .height = .{ .fixed = 24 },
                .fill = swatch,
                .border = theme.border,
                .border_width = Theme.border_width,
                .radius = Theme.radius_sm,
            });
            try input.view(tree, theme, .{
                .id = inputId(idx),
                .value = inp.text(),
                .placeholder = placeholder,
                .cursor = inp.cursor,
                .anchor = inp.anchor,
                .width = .fill,
                .hovered = std.meta.eql(state.hover, Target{ .key_input = idx }),
                .focused = std.meta.eql(state.focused, Target{ .key_input = idx }),
                .invalid = is_err,
            });
            try button.view(tree, theme, .{
                .id = colorResetId(idx),
                .label = "Reset",
                .variant = .outline,
                .size = .sm,
                .state = reset_state,
            });
            tree.close(color_row);
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
            const count = info.display_labels.len;
            const start = if (count > popup_max_items) @min(state.open_select.?.top, count - popup_max_items) else 0;
            const end = @min(count, start + popup_max_items);
            for (start..end) |c_idx| {
                try popup.item(tree, theme, .{
                    .id = choiceId(c_idx),
                    .label = info.display_labels[c_idx],
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
        if (comptime controlKind(key) == .select or controlKind(key) == .segmented) {
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
