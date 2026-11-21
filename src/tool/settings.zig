//! Settings window (`rex settings`): sidebar-navigated form generated from
//! `config.keys.table`, saving edits immediately via `config.writer.writeKey`
//! and validating through `config.Loaded.load`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const kit = @import("../kit/root.zig");
const host = @import("host.zig");
const Modifiers = @import("../input/key.zig").Modifiers;
const FileWatch = @import("FileWatch.zig");
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
const button_group = kit.button_group;
const card_kit = kit.card;
const collapsible = kit.collapsible;
const field = kit.field;
const focus = kit.focus;
const input_group = kit.input_group;
const scroll_area = kit.scroll_area;
const separator = kit.separator;
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
const Tree = kit.Tree;
const Id = kit.Tree.Id;

const log = std.log.scoped(.tool);

pub const name = "settings";
pub const title = "Rex Settings";

pub const node_max = 1600;
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
    "Terminal color themes, light or dark interface, motion, typography, and cursor.",
    "Window behavior, bell, scrolling, scrollbar, selection, clipboard, and shell.",
    "Toasts, banners, and modal dialogs.",
    "Wellbeing tracking, daily screen time limits, and dashboard charts.",
    "Pomodoro focus intervals, floating focus widget, alerts, and evening wind-down schedule.",
    "Periodic eyesight and movement break reminders, plus fullscreen ASCII overlay.",
};

pub fn pageForSection(section: keys.Section) ?Page {
    return switch (section) {
        .root, .colors, .font, .cursor, .ui, .decoration => .appearance,
        .window, .bell, .scroll, .scrollbar, .selection, .clipboard, .hyperlink, .shell => .window_shell,
        .toast, .banner, .modal, .@"modal.blur", .alert_dialog => .overlays,
        .wellbeing, .@"wellbeing.screen_time", .@"wellbeing.privacy", .@"wellbeing.dashboard" => .wellbeing,
        .@"wellbeing.focus", .@"wellbeing.widget", .@"wellbeing.winddown" => .focus_winddown,
        .@"wellbeing.eyesight", .@"wellbeing.movement", .@"wellbeing.ascii" => .reminders,
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
    .cursor = "Cursor",
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
    .@"wellbeing.widget" = "Focus Widget",
    .@"wellbeing.ascii" = "ASCII Overlay",
    .ui = "Interface",
    .scroll = "Scroll",
    .scrollbar = "Scrollbar",
    .selection = "Selection",
    .clipboard = "Clipboard",
    .hyperlink = "Hyperlinks",
    .decoration = "Text Decorations",
    .shell = "Shell",
    .keybinds = "Keybinds",
    .env = "Environment",
});

const KeyMeta = struct {
    label: []const u8,
    description: []const u8,
};

const KeyMetaEntry = struct {
    section: keys.Section,
    name: []const u8,
    label: []const u8,
    description: []const u8,
};

const key_meta_table = [_]KeyMetaEntry{
    .{ .section = .root, .name = "theme", .label = "Color Theme", .description = "Choose the color palette used inside the terminal." },

    .{ .section = .colors, .name = "background", .label = "Background", .description = "Override the terminal background color, or keep the theme default." },
    .{ .section = .colors, .name = "foreground", .label = "Foreground", .description = "Override the default text color, or keep the theme default." },
    .{ .section = .colors, .name = "selection_background", .label = "Selection Background", .description = "Override the highlight color behind selected text, or keep the theme default." },
    .{ .section = .colors, .name = "selection_foreground", .label = "Selection Foreground", .description = "Override the color of selected text, or keep the theme default." },
    .{ .section = .colors, .name = "accent", .label = "Accent", .description = "Override the cursor and accent color, or keep the theme default." },

    .{ .section = .font, .name = "file", .label = "Regular Font", .description = "Font file used for regular terminal text, or leave blank for the built-in font." },
    .{ .section = .font, .name = "bold_file", .label = "Bold Font", .description = "Custom font file for bold text, or leave blank to thicken the regular font." },
    .{ .section = .font, .name = "italic_file", .label = "Italic Font", .description = "Custom font file for italic text, or leave blank." },
    .{ .section = .font, .name = "bold_italic_file", .label = "Bold Italic Font", .description = "Custom font file for bold italic text, or leave blank." },
    .{ .section = .font, .name = "emoji_file", .label = "Emoji Font", .description = "Font file used for color emoji, or leave blank." },
    .{ .section = .font, .name = "fallback", .label = "Fallback Fonts", .description = "Extra font files checked in order when a character is missing." },
    .{ .section = .font, .name = "size", .label = "Font Size", .description = "Base text size in points for new terminal windows." },
    .{ .section = .font, .name = "size_step", .label = "Zoom Step", .description = "How much the font size changes each time you zoom in or out." },
    .{ .section = .font, .name = "min_size", .label = "Minimum Font Size", .description = "Smallest font size allowed when zooming out." },
    .{ .section = .font, .name = "max_size", .label = "Maximum Font Size", .description = "Largest font size allowed when zooming in." },
    .{ .section = .font, .name = "weight", .label = "Regular Weight", .description = "Thickness for regular text on variable fonts (1–1000)." },
    .{ .section = .font, .name = "bold_weight", .label = "Bold Weight", .description = "Thickness for bold text on variable fonts (1–1000)." },

    .{ .section = .cursor, .name = "opacity", .label = "Opacity", .description = "Opacity of the terminal cursor (0.0–1.0)." },
    .{ .section = .cursor, .name = "radius", .label = "Corner Radius", .description = "Roundness of cursor corners in pixels, clamped to half the cursor's smaller side." },
    .{ .section = .cursor, .name = "underline_thickness", .label = "Underline Thickness", .description = "Height of the underline cursor as a fraction of cell height (0.0–1.0)." },
    .{ .section = .cursor, .name = "underline_position", .label = "Underline Position", .description = "Bottom edge of the underline cursor down from the top of the cell (1.0 sits at the bottom)." },
    .{ .section = .cursor, .name = "beam_thickness", .label = "Beam Thickness", .description = "Width of the vertical bar cursor as a fraction of cell width (0.0–1.0)." },
    .{ .section = .cursor, .name = "hollow_border_width", .label = "Unfocused Border Width", .description = "Outline thickness in pixels when the window is unfocused (0 keeps the cursor filled)." },
    .{ .section = .cursor, .name = "blink_interval", .label = "Blink Interval", .description = "Half-period for blinking cursors and blinking text (50ms–5s)." },
    .{ .section = .cursor, .name = "rapid_blink_interval", .label = "Rapid Blink Interval", .description = "Half-period for SGR 6 rapid blinking text (50ms–5s)." },

    .{ .section = .ui, .name = "motion", .label = "Animations", .description = "Play smooth transitions in menus and overlays, or switch immediately." },
    .{ .section = .ui, .name = "color_scheme", .label = "Interface Theme", .description = "Light or dark look for settings, dialogs, and overlays, or match your terminal theme." },
    .{ .section = .ui, .name = "tooltip_padding_x", .label = "Tooltip Horizontal Padding", .description = "Horizontal padding inside tooltip cards, in logical pixels." },
    .{ .section = .ui, .name = "tooltip_padding_y", .label = "Tooltip Vertical Padding", .description = "Vertical padding inside tooltip cards, in logical pixels." },
    .{ .section = .ui, .name = "tooltip_gap", .label = "Tooltip Gap", .description = "Spacing between tooltip rows and their swatches, in logical pixels." },
    .{ .section = .ui, .name = "animation_duration", .label = "Animation Duration", .description = "How long UI enter and leave animations take (50ms–5s)." },
    .{ .section = .ui, .name = "focus_ring_width", .label = "Focus Ring Width", .description = "Width of the focus ring drawn outside a control's border." },
    .{ .section = .ui, .name = "focus_ring_opacity", .label = "Focus Ring Opacity", .description = "Opacity of the focus ring, in percent." },

    .{ .section = .window, .name = "background_opacity", .label = "Background Opacity", .description = "How solid the terminal background is, from 0.0 (see-through) to 1.0 (opaque)." },
    .{ .section = .window, .name = "dim_text_opacity", .label = "Dim Text Opacity", .description = "Brightness multiplier for dimmed terminal text (0.0–1.0)." },
    .{ .section = .window, .name = "on_inactive", .label = "On Inactive Window", .description = "Visual effects applied while the terminal window is unfocused." },
    .{ .section = .window, .name = "inactive_background_opacity", .label = "Inactive Background Opacity", .description = "Window background opacity while unfocused when Opacity is enabled in On Inactive Window (0.0–1.0)." },
    .{ .section = .window, .name = "inactive_dim_opacity", .label = "Inactive Dim Opacity", .description = "How strongly terminal content fades toward the background when Dim is enabled in On Inactive Window (0.0–1.0)." },
    .{ .section = .window, .name = "inactive_blur_radius", .label = "Inactive Blur Radius", .description = "Blur strength in pixels while unfocused when Blur is enabled in On Inactive Window (1–64)." },
    .{ .section = .window, .name = "mouse_auto_hide", .label = "Auto-hide Pointer", .description = "Whether to hide the mouse pointer automatically when typing in the terminal." },
    .{ .section = .window, .name = "mouse_idle_timeout", .label = "Pointer Idle Timeout", .description = "Hide the mouse pointer after a period of inactivity (or none)." },
    .{ .section = .window, .name = "on_close", .label = "Close Behavior", .description = "Whether to confirm before closing when child processes are active." },
    .{ .section = .window, .name = "platform", .label = "Window Platform", .description = "Window system to use on Linux (Automatic, Wayland, or X11)." },
    .{ .section = .window, .name = "width", .label = "Initial Width", .description = "Default window width in logical pixels on startup." },
    .{ .section = .window, .name = "height", .label = "Initial Height", .description = "Default window height in logical pixels on startup." },
    .{ .section = .window, .name = "decorations", .label = "Window Decorations", .description = "Show standard window titlebar and borders (Full) or borderless (None)." },
    .{ .section = .window, .name = "padding_x", .label = "Horizontal Padding", .description = "Inner horizontal space around the terminal grid in logical pixels (0–128)." },
    .{ .section = .window, .name = "padding_y", .label = "Vertical Padding", .description = "Inner vertical space around the terminal grid in logical pixels (0–128)." },
    .{ .section = .window, .name = "title", .label = "Window Title", .description = "Static window title, or auto to follow the running program." },

    .{ .section = .bell, .name = "enabled", .label = "Audible Bell", .description = "Play a chime when a program triggers the terminal bell." },
    .{ .section = .bell, .name = "volume", .label = "Bell Volume", .description = "Playback volume for the terminal bell (0.0–1.0)." },

    .{ .section = .scroll, .name = "step_lines", .label = "Keyboard Scroll Lines", .description = "Lines scrolled per keyboard scroll-up or scroll-down action." },
    .{ .section = .scroll, .name = "wheel_lines", .label = "Wheel Scroll Lines", .description = "Lines scrolled per mouse wheel notch." },

    .{ .section = .scrollbar, .name = "width", .label = "Bar Width", .description = "Scrollbar thickness when idle in pixels (0 hides the bar)." },
    .{ .section = .scrollbar, .name = "hover_width", .label = "Hover Width", .description = "Expanded scrollbar thickness when the pointer hovers over it." },
    .{ .section = .scrollbar, .name = "gap", .label = "Edge Gap", .description = "Space between the scrollbar and the right window edge in pixels." },
    .{ .section = .scrollbar, .name = "min_thumb_height", .label = "Minimum Thumb Height", .description = "Shortest height the draggable scrollbar thumb can shrink to in pixels." },
    .{ .section = .scrollbar, .name = "radius", .label = "Corner Radius", .description = "Roundness of the scrollbar track and thumb corners in pixels." },
    .{ .section = .scrollbar, .name = "animation_speed", .label = "Animation Speed", .description = "How quickly the scrollbar eases to its width and opacity." },
    .{ .section = .scrollbar, .name = "auto_hide", .label = "Auto-hide at Bottom", .description = "Fade the scrollbar down when viewing the latest output." },
    .{ .section = .scrollbar, .name = "auto_hide_opacity", .label = "Idle Opacity", .description = "Opacity of the faded scrollbar while at the bottom (0.0–1.0)." },
    .{ .section = .scrollbar, .name = "track_color", .label = "Track Color", .description = "Background color of the scrollbar track." },
    .{ .section = .scrollbar, .name = "track_opacity", .label = "Track Opacity", .description = "Opacity of the scrollbar track background (0.0–1.0)." },
    .{ .section = .scrollbar, .name = "thumb_color", .label = "Thumb Color", .description = "Color of the draggable scrollbar thumb." },
    .{ .section = .scrollbar, .name = "thumb_opacity", .label = "Thumb Opacity", .description = "Opacity of the scrollbar thumb (0.0–1.0)." },
    .{ .section = .scrollbar, .name = "thumb_hover_color", .label = "Thumb Hover Color", .description = "Color of the scrollbar thumb while hovered." },
    .{ .section = .scrollbar, .name = "thumb_hover_opacity", .label = "Thumb Hover Opacity", .description = "Opacity of the scrollbar thumb while hovered (0.0–1.0)." },

    .{ .section = .selection, .name = "double_click_interval", .label = "Double-Click Interval", .description = "Maximum time between clicks to select a word or line (100ms–2s)." },
    .{ .section = .selection, .name = "extra_word_characters", .label = "Extra Word Characters", .description = "Additional ASCII symbols treated as part of a word on double-click." },
    .{ .section = .selection, .name = "opacity", .label = "Selection Opacity", .description = "Fill opacity of the selection highlight (0.0–1.0)." },
    .{ .section = .selection, .name = "foreground_opacity", .label = "Foreground Opacity", .description = "How strongly the selection text color tints selected characters (0 keeps text colors, 1 replaces them)." },
    .{ .section = .selection, .name = "border_color", .label = "Border Color", .description = "Outline color drawn around selected text." },
    .{ .section = .selection, .name = "border_opacity", .label = "Border Opacity", .description = "Opacity of the selection outline (0.0–1.0)." },
    .{ .section = .selection, .name = "border_width", .label = "Border Width", .description = "Outline thickness around selected text (0 hides the outline)." },
    .{ .section = .selection, .name = "border_style", .label = "Border Style", .description = "Selection border appearance: unified perimeter, split rows, underline, or left bar." },
    .{ .section = .selection, .name = "radius", .label = "Corner Radius", .description = "Roundness of selection corners in pixels (0 keeps corners sharp)." },
    .{ .section = .selection, .name = "blur_radius", .label = "Blur Radius", .description = "Frosted glass blur strength behind selected text (0 turns blur off)." },

    .{ .section = .clipboard, .name = "osc52_write", .label = "Clipboard Write (OSC 52)", .description = "Allow programs inside the terminal to copy text to your clipboard." },
    .{ .section = .clipboard, .name = "osc52_read", .label = "Clipboard Read (OSC 52)", .description = "Allow programs inside the terminal to read text from your clipboard." },
    .{ .section = .hyperlink, .name = "enabled", .label = "Enable Links", .description = "Let Ctrl+click open OSC 8 hyperlinks in the terminal." },
    .{ .section = .hyperlink, .name = "underline", .label = "Underline Links", .description = "Underline added to linked text: never, always, or only on hover." },
    .{ .section = .hyperlink, .name = "underline_style", .label = "Underline Style", .description = "Style of the underline Rex adds to linked text; explicit SGR underlines keep their own style." },
    .{ .section = .hyperlink, .name = "show_targets", .label = "Show Targets", .description = "When to show the target URI while hovering a link." },
    .{ .section = .hyperlink, .name = "target_style", .label = "Target Style", .description = "How a long target URI is shown: multiline, head and tail, or one wide line." },
    .{ .section = .hyperlink, .name = "tooltip_head_bytes", .label = "Tooltip Head Bytes", .description = "How many leading bytes of a long URI the head+tail layout keeps." },
    .{ .section = .hyperlink, .name = "tooltip_tail_bytes", .label = "Tooltip Tail Bytes", .description = "How many trailing bytes of a long URI the head+tail layout keeps." },
    .{ .section = .hyperlink, .name = "tooltip_line_bytes", .label = "Tooltip Line Bytes", .description = "Bytes per line in the multiline URI tooltip." },
    .{ .section = .hyperlink, .name = "tooltip_max_lines", .label = "Tooltip Max Lines", .description = "Maximum number of lines in the multiline URI tooltip." },
    .{ .section = .hyperlink, .name = "tooltip_width", .label = "Tooltip Width", .description = "Maximum width of the multiline tooltip in logical pixels." },
    .{ .section = .hyperlink, .name = "tooltip_wide_width", .label = "Wide Tooltip Width", .description = "Maximum width of the one-line tooltip in logical pixels." },
    .{ .section = .hyperlink, .name = "underline_color", .label = "Link Underline Color", .description = "Underline color for OSC 8 links; none uses the decoration underline or text color." },
    .{ .section = .hyperlink, .name = "open_command", .label = "Open Command", .description = "Command that opens a URI; empty uses the system default." },
    .{ .section = .hyperlink, .name = "schemes", .label = "Allowed Schemes", .description = "URI schemes a link may open; file is disabled by default." },
    .{ .section = .decoration, .name = "skip_ink", .label = "Skip Ink Under Descenders", .description = "Break decoration lines where a letter's descender crosses them." },
    .{ .section = .decoration, .name = "skip_ink_styles", .label = "Styles That Skip Ink", .description = "Underline styles that break around descenders; none keeps every line whole." },
    .{ .section = .decoration, .name = "skip_ink_threshold", .label = "Ink Coverage Threshold", .description = "How much of a pixel must be covered to count as ink, from 0.0 to 1.0." },
    .{ .section = .decoration, .name = "skip_ink_gap_px", .label = "Ink Gap", .description = "Extra pixels kept between ink and a line; none follows the line thickness." },
    .{ .section = .decoration, .name = "skip_ink_min_segment_px", .label = "Minimum Ink Segment", .description = "Drop line pieces shorter than this many pixels; none follows the thickness." },
    .{ .section = .decoration, .name = "order", .label = "Draw Decorations Over Text", .description = "When off, glyphs cover the lines instead of the lines crossing the glyphs." },
    .{ .section = .decoration, .name = "alpha", .label = "Decoration Opacity", .description = "Opacity of every decoration line, from 0.0 to 1.0." },
    .{ .section = .decoration, .name = "dim", .label = "Dim Lines With Dim Text", .description = "Dim SGR 2 text also dims its underline, strikethrough and overline." },
    .{ .section = .decoration, .name = "blink", .label = "Blink Lines With Blinking Text", .description = "Blinking SGR 5 and 6 text also blinks its decoration lines." },
    .{ .section = .decoration, .name = "underline_color", .label = "Text Underline Color", .description = "Fixed color for ordinary underlines; none uses the text color." },
    .{ .section = .decoration, .name = "strikethrough_color", .label = "Strikethrough Color", .description = "Fixed strikethrough color; none uses the text color." },
    .{ .section = .decoration, .name = "overline_color", .label = "Overline Color", .description = "Fixed overline color; none uses the text color." },
    .{ .section = .decoration, .name = "underline_offset_px", .label = "Underline Offset", .description = "Move the underline down by this many pixels; negative moves it up." },
    .{ .section = .decoration, .name = "strikethrough_offset_px", .label = "Strikethrough Offset", .description = "Move the strikethrough down by this many pixels; negative moves it up." },
    .{ .section = .decoration, .name = "overline_offset_px", .label = "Overline Offset", .description = "Move the overline down by this many pixels; negative moves it up." },
    .{ .section = .decoration, .name = "underline_thickness_px", .label = "Underline Thickness", .description = "Underline thickness in pixels; none uses the font's own thickness." },
    .{ .section = .decoration, .name = "strikethrough_thickness_px", .label = "Strikethrough Thickness", .description = "Strikethrough thickness in pixels; none uses the font's own thickness." },
    .{ .section = .decoration, .name = "overline_thickness_px", .label = "Overline Thickness", .description = "Overline thickness in pixels; none uses the resolved underline thickness." },
    .{ .section = .decoration, .name = "underline_thickness_scale", .label = "Underline Thickness Scale", .description = "Multiply the resolved underline thickness by this factor." },
    .{ .section = .decoration, .name = "double_gap_px", .label = "Double Underline Gap", .description = "Gap between the two lines of a double underline; none uses the thickness." },
    .{ .section = .decoration, .name = "curly_amplitude_px", .label = "Curly Underline Amplitude", .description = "Amplitude of the curly underline wave in pixels; none derives it from the font." },
    .{ .section = .decoration, .name = "curly_wavelength_px", .label = "Curly Underline Wavelength", .description = "Length of one curly underline wave; none uses one wave per cell." },
    .{ .section = .decoration, .name = "dot_length_px", .label = "Dot Length", .description = "Length of each dot in a dotted underline; none fits whole dots to the cell." },
    .{ .section = .decoration, .name = "dot_gap_px", .label = "Dot Gap", .description = "Space after each dot; none matches the dot length." },
    .{ .section = .decoration, .name = "dash_length_px", .label = "Dash Length", .description = "Length of each dash in a dashed underline; none uses half a cell." },
    .{ .section = .decoration, .name = "dash_gap_px", .label = "Dash Gap", .description = "Space after each dash; none derives it from the cell width." },
    .{ .section = .decoration, .name = "phase", .label = "Pattern Phase", .description = "Start dotted, dashed and curly patterns at the window grid or at each run." },

    .{ .section = .shell, .name = "program", .label = "Shell Program", .description = "Path to your preferred shell executable, or Automatic for your default shell." },
    .{ .section = .shell, .name = "argument", .label = "Shell Arguments", .description = "Arguments passed to the shell on startup." },
    .{ .section = .shell, .name = "working_directory", .label = "Working Directory", .description = "Starting folder for new shells, or inherit from where Rex was launched." },

    .{ .section = .toast, .name = "enabled", .label = "Enable Toasts", .description = "Show brief pop-up notifications inside the terminal." },
    .{ .section = .toast, .name = "duration", .label = "Display Duration", .description = "How long a toast remains visible before dismissing." },
    .{ .section = .toast, .name = "position", .label = "Position", .description = "Corner or edge where toast notifications stack." },
    .{ .section = .toast, .name = "layout", .label = "Stack Layout", .description = "Arrange multiple toasts as a collapsed deck that expands on hover, or as a vertical list." },
    .{ .section = .toast, .name = "width", .label = "Card Width", .description = "Width of toast notification cards in pixels." },
    .{ .section = .toast, .name = "margin", .label = "Edge Margin", .description = "Distance between the toast stack and window edges in pixels." },
    .{ .section = .toast, .name = "padding", .label = "Inner Padding", .description = "Space inside each toast card in pixels." },
    .{ .section = .toast, .name = "gap", .label = "Stack Gap", .description = "Vertical spacing between expanded toast cards in pixels." },
    .{ .section = .toast, .name = "peek", .label = "Stack Peek", .description = "Visible vertical strip of each card peeking behind the front toast in pixels (0–32)." },
    .{ .section = .toast, .name = "scale_step", .label = "Stack Scale Step", .description = "Width shrink fraction per card behind the front toast when stacked (0.0–0.25)." },
    .{ .section = .toast, .name = "rise_distance", .label = "Rise Distance", .description = "How far a toast slides in from its resting place, in pixels." },
    .{ .section = .toast, .name = "glide_ms", .label = "Glide Time Constant", .description = "How quickly a toast glides to a new place, in milliseconds." },

    .{ .section = .banner, .name = "enabled", .label = "Enable Banners", .description = "Show persistent status banners inside the terminal." },
    .{ .section = .banner, .name = "placement", .label = "Placement", .description = "Display as a rounded floating card or a full-width docked bar." },
    .{ .section = .banner, .name = "position", .label = "Position", .description = "Window edge anchor where status banners appear." },
    .{ .section = .banner, .name = "max_width", .label = "Maximum Width", .description = "Maximum width of floating banners in pixels." },
    .{ .section = .banner, .name = "margin", .label = "Edge Margin", .description = "Distance between floating banners and window edges in pixels." },
    .{ .section = .banner, .name = "padding", .label = "Inner Padding", .description = "Space inside each status banner in pixels." },
    .{ .section = .banner, .name = "slide_distance", .label = "Slide Distance", .description = "How far the banner slides in from the edge, in pixels." },

    .{ .section = .modal, .name = "backdrop_opacity", .label = "Backdrop Opacity", .description = "Dimming opacity of the backdrop behind modal dialogs (0.0–1.0)." },
    .{ .section = .modal, .name = "on_outside_click", .label = "Outside Click", .description = "Whether clicking outside a modal dialog dismisses it." },
    .{ .section = .modal, .name = "position", .label = "Position", .description = "Vertical placement of modal dialogs over the backdrop." },
    .{ .section = .modal, .name = "margin", .label = "Edge Margin", .description = "Minimum distance between modal dialogs and window edges in pixels." },
    .{ .section = .modal, .name = "padding", .label = "Inner Padding", .description = "Space inside modal dialog cards in pixels." },
    .{ .section = .modal, .name = "gap", .label = "Section Gap", .description = "Vertical spacing between header, body, and buttons in pixels." },

    .{ .section = .@"modal.blur", .name = "enabled", .label = "Backdrop Blur", .description = "Blur the terminal grid behind modal dialogs." },
    .{ .section = .@"modal.blur", .name = "radius", .label = "Blur Radius", .description = "Blur strength in pixels behind modal dialogs." },

    .{ .section = .alert_dialog, .name = "default_focus", .label = "Default Focus", .description = "Which button receives initial keyboard focus in confirmation alert dialogs." },
    .{ .section = .alert_dialog, .name = "width", .label = "Dialog Width", .description = "Maximum width of confirmation alert dialogs in pixels." },
    .{ .section = .alert_dialog, .name = "icon", .label = "Dialog Icon", .description = "Icon badge displayed above the title in confirmation alert dialogs." },

    .{ .section = .wellbeing, .name = "enabled", .label = "Enable Wellbeing", .description = "Track screen time and enable focus timers, reminders, and wind-down." },

    .{ .section = .@"wellbeing.screen_time", .name = "daily_limit", .label = "Daily Screen Limit", .description = "Maximum daily terminal time before limit actions trigger (or none)." },
    .{ .section = .@"wellbeing.screen_time", .name = "idle_threshold", .label = "Idle Threshold", .description = "Inactivity duration before screen time tracking pauses." },
    .{ .section = .@"wellbeing.screen_time", .name = "on_limit", .label = "On Daily Limit", .description = "Actions triggered when you reach your daily screen time limit." },
    .{ .section = .@"wellbeing.screen_time", .name = "grayscale_transition", .label = "Grayscale Transition", .description = "Duration over which the screen fades to grayscale on limit." },

    .{ .section = .@"wellbeing.privacy", .name = "track_foreground_apps", .label = "Track Foreground Apps", .description = "Record which foreground programs you spend time in." },

    .{ .section = .@"wellbeing.dashboard", .name = "timer_chart", .label = "Timer Chart Style", .description = "Visualization style for the focus timer on the dashboard." },
    .{ .section = .@"wellbeing.dashboard", .name = "program_chart", .label = "Program Chart Style", .description = "Visualization style for per-program usage on the dashboard." },

    .{ .section = .@"wellbeing.focus", .name = "task", .label = "Focus Duration", .description = "Length of a single focused work interval (e.g. 25m)." },
    .{ .section = .@"wellbeing.focus", .name = "short_break", .label = "Short Break", .description = "Length of a short break between focus intervals (e.g. 5m)." },
    .{ .section = .@"wellbeing.focus", .name = "long_break", .label = "Long Break", .description = "Length of a longer break after a full cycle (e.g. 15m)." },
    .{ .section = .@"wellbeing.focus", .name = "tasks_before_long_break", .label = "Intervals Before Long Break", .description = "Number of focus intervals completed before taking a long break." },
    .{ .section = .@"wellbeing.focus", .name = "timer", .label = "Timer Display", .description = "Where the focus countdown is shown while active." },
    .{ .section = .@"wellbeing.focus", .name = "on_phase_end", .label = "On Phase End", .description = "Automatically advance to the next phase or wait for confirmation." },
    .{ .section = .@"wellbeing.focus", .name = "during_task", .label = "During Focus", .description = "UI indicators or behaviors active during a focus interval." },
    .{ .section = .@"wellbeing.focus", .name = "on_break", .label = "On Break", .description = "Actions triggered when a focus interval transitions into a break." },
    .{ .section = .@"wellbeing.focus", .name = "on_alert", .label = "On Alert", .description = "Notification cues played when a focus phase ends." },

    .{ .section = .@"wellbeing.widget", .name = "default_visible", .label = "Show on Startup", .description = "Show the floating focus widget automatically when opening a terminal window." },
    .{ .section = .@"wellbeing.widget", .name = "anchor", .label = "Screen Anchor", .description = "Default corner or edge where the floating focus widget docks before being dragged." },
    .{ .section = .@"wellbeing.widget", .name = "width", .label = "Default Width", .description = "Initial width of the floating focus widget in logical pixels (96–320)." },
    .{ .section = .@"wellbeing.widget", .name = "height", .label = "Default Height", .description = "Initial height of the floating focus widget in logical pixels (72–160)." },
    .{ .section = .@"wellbeing.widget", .name = "progress_style", .label = "Progress Style", .description = "Focus progress look on the widget (Automatic, Bar, Ring, Border, Half rings, or Coil)." },
    .{ .section = .@"wellbeing.widget", .name = "tooltip", .label = "Mini Hover Tooltip", .description = "Show the phase badge and cycle count tooltip when hovering the compact widget." },

    .{ .section = .@"wellbeing.ascii", .name = "enabled", .label = "ASCII Overlay", .description = "Display a fullscreen ASCII animation behind a compact bottom HUD during wellbeing breaks and reminders." },
    .{ .section = .@"wellbeing.ascii", .name = "scene", .label = "Animation Scene", .description = "Built-in procedural animation (3D spin, Torus, Breathe, Wave) or external UTF-8 frame file." },
    .{ .section = .@"wellbeing.ascii", .name = "file", .label = "ASCII Frame File", .description = "Path to a frame-delimited UTF-8 ASCII art file used when Scene is set to File." },
    .{ .section = .@"wellbeing.ascii", .name = "fps", .label = "Frame Rate", .description = "Playback cadence in frames per second (1–30); pauses when minimized." },
    .{ .section = .@"wellbeing.ascii", .name = "cell_aspect", .label = "Cell Aspect", .description = "Render cells as 1:1 squares or match the terminal's native monospace cell pitch." },
    .{ .section = .@"wellbeing.ascii", .name = "trigger", .label = "Overlay Trigger", .description = "Show the ASCII overlay on all wellbeing reminders or only when input is locked." },

    .{ .section = .@"wellbeing.winddown", .name = "enabled", .label = "Evening Wind-down", .description = "Shift terminal colors warmer during your scheduled wind-down hours." },
    .{ .section = .@"wellbeing.winddown", .name = "start", .label = "Start Time", .description = "24-hour clock time when wind-down begins (HH:MM)." },
    .{ .section = .@"wellbeing.winddown", .name = "end", .label = "End Time", .description = "24-hour clock time when wind-down ends (HH:MM)." },
    .{ .section = .@"wellbeing.winddown", .name = "warmth", .label = "Warmth Intensity", .description = "Color temperature shift intensity from 0.0 to 1.0." },
    .{ .section = .@"wellbeing.winddown", .name = "during_window", .label = "During Wind-down", .description = "Additional effects active during the wind-down schedule." },
};

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

fn parseAnsiColorIndex(comptime key_name: []const u8) ?usize {
    if (!std.mem.startsWith(u8, key_name, "color")) return null;
    const index = std.fmt.parseUnsigned(usize, key_name["color".len..], 10) catch return null;
    return if (index < ansi_color_names.len) index else null;
}

const ReminderKey = enum { enabled, interval, duration, during_reminder, animation };

fn reminderMeta(comptime kind: []const u8, comptime key_name: []const u8) KeyMeta {
    const tag = std.meta.stringToEnum(ReminderKey, key_name) orelse
        @compileError("unmapped reminder key: " ++ key_name);
    return switch (tag) {
        .enabled => .{
            .label = "Enable " ++ kind ++ " Reminders",
            .description = "Show periodic " ++ kind ++ " break reminders while active.",
        },
        .interval => .{
            .label = "Reminder Interval",
            .description = "How often the " ++ kind ++ " reminder triggers (e.g. 20m).",
        },
        .duration => .{
            .label = "Break Duration",
            .description = "How long the " ++ kind ++ " break lasts (e.g. 20s).",
        },
        .during_reminder => .{
            .label = "During Reminder",
            .description = "Effects and cues active while the reminder is displayed.",
        },
        .animation => .{
            .label = "Reminder Animation",
            .description = "Visual animation style for the reminder overlay.",
        },
    };
}

fn keyMeta(comptime section: keys.Section, comptime key_name: []const u8) KeyMeta {
    @setEvalBranchQuota(20000);
    switch (section) {
        .@"wellbeing.eyesight" => return reminderMeta("Eyesight", key_name),
        .@"wellbeing.movement" => return reminderMeta("Movement", key_name),
        .colors => if (parseAnsiColorIndex(key_name)) |i| return .{
            .label = std.fmt.comptimePrint("Color {d} · {s}", .{ i, ansi_color_names[i] }),
            .description = std.fmt.comptimePrint("Override ANSI color {d} ({s}), or keep the theme default.", .{ i, ansi_color_names[i] }),
        },
        else => {},
    }
    for (key_meta_table) |entry| {
        if (entry.section == section and std.mem.eql(u8, entry.name, key_name)) {
            return .{ .label = entry.label, .description = entry.description };
        }
    }
    @compileError("unmapped key in key_meta_table: " ++ @tagName(section) ++ "." ++ key_name);
}

comptime {
    @setEvalBranchQuota(50000);
    for (key_meta_table, 0..) |entry, i| {
        if (keys.lookup(entry.section, entry.name) == null) {
            @compileError("stale entry in key_meta_table: " ++ @tagName(entry.section) ++ "." ++ entry.name);
        }
        for (key_meta_table[i + 1 ..]) |other| {
            if (other.section == entry.section and std.mem.eql(u8, other.name, entry.name)) {
                @compileError("duplicate entry in key_meta_table: " ++ @tagName(entry.section) ++ "." ++ entry.name);
            }
        }
    }
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

const token_label_overrides = std.StaticStringMap([]const u8).initComptime(.{
    .{ "auto", "Automatic" },
    .{ "allow_always", "Always allow" },
    .{ "grayscale", "Grayscale screen" },
    .{ "break_screen", "Show break screen" },
});

fn humanToken(comptime token: []const u8) []const u8 {
    if (token_label_overrides.get(token)) |label| return label;

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
    key_reset: u16,
    stepper_dec: u16,
    stepper_inc: u16,
    list_add: u16,
    list_up: struct { key: u16, item: u16 },
    list_down: struct { key: u16, item: u16 },
    list_remove: struct { key: u16, item: u16 },
    ansi_colors_toggle,
    decoration_group: DecorationGroup,
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
const popup_card_id = Id.of("settings.popup_card");
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

fn resetId(idx: u16) Id {
    return Id.of("settings.key_reset").item(idx);
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

const multi_click_ms: i64 = 400;
const multi_click_dist: f32 = 6.0;

const InputDrag = union(enum) {
    idle,
    chars: u16,
    words: struct { key: u16, base_start: usize, base_end: usize },
};

const InputClick = struct {
    key: u16 = 0,
    count: u8 = 0,
    last_ms: i64 = 0,
    last_x: f32 = 0,
};

pub const State = struct {
    gpa: Allocator,
    io: std.Io,
    config_path: []const u8,
    home_dir: []const u8,
    clipboard: host.Clipboard,
    node_rect: host.NodeRect = .{},
    input_origin: host.InputOrigin = .{},
    text_measurer: ?kit.text.Measurer = null,
    initial_config: *const Config,
    loaded: ?Loaded = null,
    frame: sidebar.State = .{},
    scroll: f32 = 0,
    viewport_width: f32 = 960,
    viewport_height: f32 = 600,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    pointer_mods: Modifiers = .none,
    hover: Target = .none,
    pressed: Target = .none,
    focused: Target = .none,
    dragging_slider: ?u16 = null,
    input_drag: InputDrag = .idle,
    input_click: InputClick = .{},
    open_select: ?struct { key: u16, highlight: usize, scroll_y: f32 = 0 } = null,
    inputs: [keys.table.len]input.State = [_]input.State{.{}} ** keys.table.len,
    color_placeholders: [color_slot_count][7]u8 = [_][7]u8{.{ '#', '0', '0', '0', '0', '0', '0' }} ** color_slot_count,
    list_items: [keys.table.len]std.ArrayListUnmanaged([]u8) = [_]std.ArrayListUnmanaged([]u8){.empty} ** keys.table.len,
    duration_units: [keys.table.len]DurationUnit = [_]DurationUnit{.ms} ** keys.table.len,
    slider_values: [keys.table.len]f32 = [_]f32{0} ** keys.table.len,
    dirty: [keys.table.len]bool = [_]bool{false} ** keys.table.len,
    ansi_colors_open: bool = false,
    /// Open state for the four advanced decoration groups (ink, geometry,
    /// patterns, colors). The basics group is always visible.
    decoration_groups_open: [4]bool = .{ false, false, false, false },
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
    /// Linux only; watches `config_path` for changes saved by another process.
    config_watch: ?*FileWatch = null,

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
        .input_origin = context.input_origin,
        .text_measurer = context.text_measurer,
        .initial_config = context.config,
    };
    errdefer deinit(&state);
    try syncInputs(&state);
    syncPreviewOptions(&state);
    state.config_watch = startConfigWatch(state.gpa, state.config_path, context.wake_loop);
    return state;
}

pub fn deinit(state: *State) void {
    if (state.config_watch) |watch| {
        watch.destroy(state.gpa);
        state.config_watch = null;
    }
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
            if (i == idx) {
                const val = keys.fieldValue(Config, key.field, cfg);
                return switch (@typeInfo(@TypeOf(val))) {
                    .optional => if (val) |v| @floatCast(v) else 0,
                    else => @floatCast(val),
                };
            }
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
    // These are config-only colors: when unset they follow the text color.
    if (comptime std.mem.eql(u8, key_name, "underline_color") or
        std.mem.eql(u8, key_name, "underline_color") or
        std.mem.eql(u8, key_name, "strikethrough_color") or
        std.mem.eql(u8, key_name, "overline_color")) return theme.foreground;
    if (comptime @hasField(ThemePreset, key_name)) {
        const value = @field(theme, key_name);
        if (@TypeOf(value) == Rgb) return value;
    }
    if (comptime parseAnsiColorIndex(key_name)) |n| return theme.ansi[n];
    @compileError("unmapped color slot: " ++ key_name);
}

const ColorInfo = struct {
    resolved: Rgb,
    overridden: bool,
    reset_token: []const u8,
};

/// True when a reset-capable field differs from the built-in default.
fn isOverridden(idx: u16, cfg: *const Config) bool {
    @setEvalBranchQuota(keys.eval_branch_quota);
    inline for (keys.table, 0..) |key, i| {
        if (comptime (key.kind == .color or key.null_keyword != null)) {
            if (idx == i) {
                const value = keys.fieldValue(Config, key.field, cfg);
                const fallback = keys.fieldValue(Config, key.field, &config_defaults.default);
                return !std.meta.eql(value, fallback);
            }
        }
    }
    return false;
}

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
                    if (!std.mem.eql(u8, state.inputs[i].text(), text)) {
                        try state.inputs[i].setText(state.gpa, text);
                    }
                }
            },
            .duration => if (!state.dirty[i]) {
                const parsed = splitDurationMs(durationMs(idx, cfg), &buf);
                state.duration_units[i] = parsed.unit;
                if (!std.mem.eql(u8, state.inputs[i].text(), parsed.text)) {
                    try state.inputs[i].setText(state.gpa, parsed.text);
                }
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

    if (state.preview_toast.option.position != win.toast.position or
        state.preview_toast.option.layout != win.toast.layout)
    {
        state.preview_table = .empty;
    }
    state.preview_toast.option = .{
        .width = win.toast.width,
        .scale_step = win.toast.scale_step,
        .position = win.toast.position,
        .layout = win.toast.layout,
        .margin = win.toast.margin,
        .padding = win.toast.padding,
        .gap = win.toast.gap,
        .peek = win.toast.peek,
    };
    state.preview_banner.option = .{
        .max_width = win.banner.max_width,
        .placement = win.banner.placement,
        .position = win.banner.position,
        .margin = win.banner.margin,
        .padding = win.banner.padding,
    };
    state.preview_dialog.option = .{
        .width = win.alert_dialog.width,
        .position = win.modal.position,
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
    var changed = reloadExternalConfig(state);
    if (wakePreview(state)) changed = true;
    if (wakeStepperHold(state)) changed = true;
    return changed;
}

fn startConfigWatch(gpa: Allocator, config_path: []const u8, wake_loop: *const fn () void) ?*FileWatch {
    if (comptime builtin.os.tag != .linux) return null;
    if (config_path.len == 0) return null;
    const dir = std.fs.path.dirname(config_path) orelse ".";
    const base = std.fs.path.basename(config_path);
    if (base.len == 0) return null;
    return FileWatch.create(gpa, dir, base, wake_loop) catch |err| {
        if (err == error.FileNotFound) {
            log.debug("not watching {s} for config changes ({t})", .{ dir, err });
        } else {
            log.warn("not watching {s} for config changes ({t})", .{ dir, err });
        }
        return null;
    };
}

fn userLayerBytes(loaded: *const Loaded) ?[]const u8 {
    if (loaded.layers.len < 2) return null;
    return switch (loaded.layers[1].state) {
        .loaded => |*file| file.source,
        else => null,
    };
}

fn reloadExternalConfig(state: *State) bool {
    const watch = state.config_watch orelse return false;
    if (!watch.takeChanged()) return false;
    if (state.config_path.len == 0) return false;

    var reloaded = Loaded.load(
        state.gpa,
        state.io,
        &config_defaults.default,
        if (state.home_dir.len > 0) state.home_dir else null,
        &.{ .file(config_paths.system), .file(state.config_path) },
    ) catch |err| {
        log.warn("cannot reload config: {t}", .{err});
        return false;
    };
    if (reloaded.firstError() != null) {
        reloaded.deinit(state.gpa);
        return false;
    }
    if (state.loaded) |*current| {
        const prev = userLayerBytes(current);
        const next = userLayerBytes(&reloaded);
        if (prev != null and next != null and std.mem.eql(u8, prev.?, next.?)) {
            reloaded.deinit(state.gpa);
            return false;
        }
    }

    if (state.loaded) |*old| old.deinit(state.gpa);
    state.loaded = reloaded;
    syncInputs(state) catch |err| {
        log.warn("cannot sync settings inputs after reload: {t}", .{err});
    };
    syncPreviewOptions(state);
    return true;
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
            if (card.parent != kit.Tree.none) {
                kit.alert.place(&state.preview_banner, tree, card.parent);
            }
        }
    }
    const visible = state.preview_toast.visible();
    if (visible.len > 0) {
        if (tree.find(kit.toast.cardId(visible[0].serial))) |card| {
            if (card.parent != kit.Tree.none) {
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
            state.pointer_y = pointer.y;
            state.pointer_mods = pointer.mods;
            if (state.dragging_slider) |idx| {
                return updateSliderFromPointer(state, idx, pointer.x);
            }
            if (state.input_drag != .idle) {
                return updateInputDrag(state, pointer.x);
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
            const toast_hover_changes = state.preview_toast.pointer != toast_over and
                state.preview_toast.option.layout == .stacked and
                state.preview_toast.visible().len > 1;
            var preview_ticked = false;
            if (toast_hover_changes) {
                preview_ticked = wakePreview(state);
                state.preview_glide_ms = 0;
            }
            const toast_changed = kit.toast.update(&state.preview_toast, .{ .pointer = toast_over });
            if (toast_changed and state.preview_last_ms == null) state.preview_last_ms = previewNowMs(state);
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
            return sb or h_changed or alert_changed or preview_ticked or toast_changed;
        },
        .press => |id| {
            state.stepper_hold = .idle;
            state.input_drag = .idle;
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
                .none, .stack => {},
            }
            if (state.open_select) |sel| {
                if (id == layer_id) {
                    if (selectUnderPoint(state, state.pointer_x, state.pointer_y)) |other_idx| {
                        if (other_idx != sel.key) {
                            state.open_select = null;
                            state.pressed = .none;
                            return activate(state, .{ .key_select = other_idx });
                        }
                    }
                    state.open_select = null;
                    state.pressed = .none;
                    return true;
                }
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
            if (target == .key_input) {
                const idx = target.key_input;
                const was_focused = state.focused == .key_input and state.focused.key_input == idx;
                if (!was_focused) {
                    blurFocused(state);
                    state.focused = target;
                }
                state.pressed = target;
                const now_ms = previewNowMs(state);
                const same_spot = !state.pointer_mods.shift and
                    state.input_click.count > 0 and
                    state.input_click.key == idx and
                    now_ms - state.input_click.last_ms <= multi_click_ms and
                    @abs(state.pointer_x - state.input_click.last_x) <= multi_click_dist;
                const clicks: u8 = if (same_spot) (if (state.input_click.count >= 3) 1 else state.input_click.count + 1) else 1;
                state.input_click = if (state.pointer_mods.shift) .{} else .{
                    .key = idx,
                    .count = clicks,
                    .last_ms = now_ms,
                    .last_x = state.pointer_x,
                };
                if (inputOffsetAtX(state, idx, state.pointer_x)) |offset| {
                    if (clicks == 3) {
                        _ = state.inputs[idx].apply(.select_all);
                        state.input_drag = .idle;
                    } else if (clicks == 2) {
                        _ = state.inputs[idx].selectWordAt(offset);
                        const range = state.inputs[idx].selectionRange();
                        state.input_drag = .{ .words = .{
                            .key = idx,
                            .base_start = range.start,
                            .base_end = range.end,
                        } };
                    } else {
                        _ = state.inputs[idx].setCursor(offset, was_focused and state.pointer_mods.shift);
                        state.input_drag = .{ .chars = idx };
                    }
                }
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
            if (state.input_drag != .idle) {
                state.input_drag = .idle;
                state.pressed = .none;
                return false;
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
                const max_y = if (wheel.id == popup_card_id) wheel.max_y else popupScrollMax(selectChoiceCount(sel.key));
                const next = std.math.clamp(sel.scroll_y + wheel.dy, 0, max_y);
                if (next == sel.scroll_y) return false;
                sel.scroll_y = next;
                return true;
            }
            if (wheel.id != scroll_area_id) return false;
            const next = std.math.clamp(state.scroll + wheel.dy, 0, wheel.max_y);
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

fn popupScrollMax(count: usize) f32 {
    const content_h = @as(f32, @floatFromInt(count)) * popup.item_height + 2 * popup.padding;
    return @max(0, content_h - popup.default_max_height);
}

fn fitPopupScroll(highlight: usize, count: usize, prev_scroll: f32) f32 {
    const max_y = popupScrollMax(count);
    if (max_y <= 0) return 0;
    const view_h: f32 = popup.default_max_height - 2 * popup.padding;
    const current = std.math.clamp(prev_scroll, 0, max_y);
    const item_y = @as(f32, @floatFromInt(highlight)) * popup.item_height - current;
    return Tree.Scroll.ensureVisibleAxis(current, max_y, 0, view_h, item_y, popup.item_height, 0);
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
                sel.scroll_y = fitPopupScroll(sel.highlight, count, sel.scroll_y);
                return true;
            },
            .down => {
                if (count > 0) {
                    sel.highlight = @min(sel.highlight + 1, count - 1);
                    sel.scroll_y = fitPopupScroll(sel.highlight, count, sel.scroll_y);
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
            return switch (press.key) {
                .a => inp.apply(.select_all),
                .c, .insert => blk: {
                    copySelection(state, inp);
                    break :blk false;
                },
                .x => blk: {
                    copySelection(state, inp);
                    const changed = inp.deleteSelection();
                    if (changed) state.dirty[idx] = true;
                    break :blk changed;
                },
                .v => pasteIntoInput(state, idx),
                .left => inp.apply(if (press.mods.shift) .select_word_left else .word_left),
                .right => inp.apply(if (press.mods.shift) .select_word_right else .word_right),
                .home => inp.apply(if (press.mods.shift) .select_home else .home),
                .end => inp.apply(if (press.mods.shift) .select_end else .end),
                .backspace, .w => blk: {
                    const changed = inp.apply(.delete_word_backward);
                    if (changed) state.dirty[idx] = true;
                    break :blk changed;
                },
                .delete => blk: {
                    const changed = inp.apply(.delete_word_forward);
                    if (changed) state.dirty[idx] = true;
                    break :blk changed;
                },
                .u => blk: {
                    const changed = inp.apply(.delete_to_start);
                    if (changed) state.dirty[idx] = true;
                    break :blk changed;
                },
                .k => blk: {
                    const changed = inp.apply(.delete_to_end);
                    if (changed) state.dirty[idx] = true;
                    break :blk changed;
                },
                else => false,
            };
        }
        switch (press.key) {
            .insert => return if (press.mods.shift) pasteIntoInput(state, idx) else false,
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
        .decoration_group => |group| switch (press.key) {
            .enter, .space => return activate(state, .{ .decoration_group = group }),
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
        if (state.focused != .sidebar) state.focused = .none;
    }
    if (!state.frame.shown() and state.focused == .sidebar) {
        state.focused = .none;
    }
    return moved;
}

const max_section_count = @typeInfo(keys.Section).@"enum".fields.len;

// These keys are declared in keys.zig, so the lookups are comptime invariants.
const on_inactive_idx = keys.lookup(.window, "on_inactive") orelse unreachable;
const inactive_bg_opacity_idx = keys.lookup(.window, "inactive_background_opacity") orelse unreachable;
const inactive_dim_opacity_idx = keys.lookup(.window, "inactive_dim_opacity") orelse unreachable;
const inactive_blur_radius_idx = keys.lookup(.window, "inactive_blur_radius") orelse unreachable;
const ascii_file_idx = keys.lookup(.@"wellbeing.ascii", "file") orelse unreachable;

const inactive_sub_rows = [_]u16{
    inactive_bg_opacity_idx,
    inactive_dim_opacity_idx,
    inactive_blur_radius_idx,
};

fn isInactiveSubRow(idx: u16) bool {
    return switch (idx) {
        inactive_bg_opacity_idx,
        inactive_dim_opacity_idx,
        inactive_blur_radius_idx,
        => true,
        else => false,
    };
}

pub fn rowCfgVisible(idx: u16, cfg: *const Config) bool {
    const info = row_infos[idx];
    // Tooltip dimensions only apply to the selected target layout.
    if (info.section == .hyperlink and std.mem.startsWith(u8, info.name, "tooltip_")) {
        const style = cfg.hyperlink.target_style;
        if (std.mem.eql(u8, info.name, "tooltip_head_bytes") or
            std.mem.eql(u8, info.name, "tooltip_tail_bytes")) return style == .head_tail;
        if (std.mem.eql(u8, info.name, "tooltip_wide_width")) return style == .wide;
        return style == .multiline;
    }
    return switch (idx) {
        inactive_bg_opacity_idx => cfg.window.on_inactive.contains(.opacity),
        inactive_dim_opacity_idx => cfg.window.on_inactive.contains(.dim),
        inactive_blur_radius_idx => cfg.window.on_inactive.contains(.blur),
        ascii_file_idx => cfg.window.wellbeing_ascii.scene == .file,
        else => true,
    };
}

pub fn rowVisible(state: *const State, idx: u16, cfg: *const Config) bool {
    if (decorationGroup(idx)) |group| {
        if (!state.decoration_groups_open[@intFromEnum(group)]) return false;
    }
    return rowCfgVisible(idx, cfg);
}

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

fn pageFocusTargets(state: *const State, page: Page, ansi_open: bool, cfg: *const Config, out: []Target) usize {
    var count: usize = 0;
    var sec_buf: [max_section_count]keys.Section = undefined;
    var row_buf: [keys.table.len]u16 = undefined;
    for (pageSections(page, &sec_buf)) |sec| {
        var ansi_toggle_added = false;
        var decoration_toggles_added = false;
        for (sectionRows(page, sec, &row_buf)) |idx| {
            if (sec == .decoration and !decoration_toggles_added) {
                inline for ([_]DecorationGroup{ .ink, .geometry, .patterns, .colors }) |group| {
                    out[count] = .{ .decoration_group = group };
                    count += 1;
                }
                decoration_toggles_added = true;
            }
            if (!rowVisible(state, idx, cfg)) continue;
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
                    if (info.null_keyword != null and isOverridden(idx, cfg)) {
                        out[count] = .{ .key_reset = idx };
                        count += 1;
                    }
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
                .stepper => {
                    out[count] = .{ .key_input = idx };
                    count += 1;
                    if (info.null_keyword != null and isOverridden(idx, cfg)) {
                        out[count] = .{ .key_reset = idx };
                        count += 1;
                    }
                },
                .text_input, .list, .color => {
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
    count += pageFocusTargets(state, page, state.ansi_colors_open, state.activeConfig(), targets[count..]);
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
        .key_reset => |idx| resetId(idx),
        .stepper_dec => |idx| decId(idx),
        .stepper_inc => |idx| incId(idx),
        .list_add => |idx| listAddId(idx),
        .ansi_colors_toggle => ansi_toggle_id,
        .decoration_group => |group| decorationGroupId(group),
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
    state.scroll = Tree.Scroll.ensureVisibleAxis(state.scroll, null, area.y, area.h, rect.y, rect.h, 24);
}

fn copySelection(state: *State, inp: *const input.State) void {
    const sel = inp.selectedText();
    if (sel.len == 0) return;
    const z = state.gpa.dupeZ(u8, sel) catch return;
    defer state.gpa.free(z);
    state.clipboard.set(z);
}

fn pasteIntoInput(state: *State, idx: u16) bool {
    const clip = state.clipboard.get() orelse return false;
    const changed = state.inputs[idx].insertSlice(state.gpa, clip) catch false;
    if (changed) state.dirty[idx] = true;
    return changed;
}

fn inputOffsetAtX(state: *const State, idx: u16, x: f32) ?usize {
    const measurer = state.text_measurer orelse return null;
    const origin_x = state.input_origin.get(inputId(idx)) orelse return null;
    return state.inputs[idx].offsetAtX(measurer, x - origin_x);
}

fn updateInputDrag(state: *State, x: f32) bool {
    return switch (state.input_drag) {
        .idle => false,
        .chars => |idx| blk: {
            const offset = inputOffsetAtX(state, idx, x) orelse break :blk false;
            break :blk state.inputs[idx].setCursor(offset, true);
        },
        .words => |w| blk: {
            const offset = inputOffsetAtX(state, w.key, x) orelse break :blk false;
            break :blk state.inputs[w.key].extendWordSelection(w.base_start, w.base_end, offset);
        },
    };
}

fn blurFocused(state: *State) void {
    state.input_drag = .idle;
    state.input_click = .{};
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
            const center_offset = @as(f32, @floatFromInt(highlight)) * popup.item_height -
                (popup.default_max_height - 2 * popup.padding - popup.item_height) * 0.5;
            state.open_select = .{
                .key = idx,
                .highlight = highlight,
                .scroll_y = fitPopupScroll(highlight, count, @max(0, center_offset)),
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
        .key_reset => |idx| {
            if (row_infos[idx].null_keyword == null) return false;
            blurFocused(state);
            state.dirty[idx] = false;
            commitValue(state, idx, row_infos[idx].null_keyword.?);
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
        .decoration_group => |group| {
            const g = @intFromEnum(group);
            blurFocused(state);
            state.decoration_groups_open[g] = !state.decoration_groups_open[g];
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
        .toast, .stack => return .none,
        .none => {},
    }
    if (id == layer_id) return .layer;
    if (id == ansi_toggle_id) return .ansi_colors_toggle;
    inline for ([_]DecorationGroup{ .ink, .geometry, .patterns, .colors }) |group| {
        if (id == decorationGroupId(group)) return .{ .decoration_group = group };
    }
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
            .slider => {
                if (id == sliderId(idx)) return .{ .key_slider = idx };
                if (id == resetId(idx) and info.null_keyword != null and isOverridden(idx, state.activeConfig())) return .{ .key_reset = idx };
            },
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
                if (id == resetId(idx) and info.null_keyword != null and isOverridden(idx, state.activeConfig())) return .{ .key_reset = idx };
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
                if (id == colorResetId(idx) and isOverridden(idx, state.activeConfig())) {
                    return .{ .color_reset = idx };
                }
            },
            .enum_set => if (id == selectId(idx)) return .{ .key_select = idx },
        }
    }
    return .none;
}

fn selectUnderPoint(state: *const State, x: f32, y: f32) ?u16 {
    if (state.node_rect.get(scroll_area_id)) |area| {
        if (!area.contains(x, y)) return null;
    }
    for (row_infos, 0..) |info, i| {
        const idx: u16 = @intCast(i);
        switch (info.kind) {
            .select, .duration, .enum_set => {
                if (state.node_rect.get(selectId(idx))) |rect| {
                    if (rect.contains(x, y)) return idx;
                }
            },
            else => {},
        }
    }
    return null;
}

fn updateSliderFromPointer(state: *State, idx: u16, x: f32) bool {
    const rect = state.node_rect.get(sliderId(idx)) orelse return false;
    const raw = slider.ratioFromX(rect, x, state.activeConfig().ui.focus_ring_width);
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
    const unit: f64 = if (!info.stepper_is_int and info.max <= 1.0) 0.01 else 1.0;
    const clamped = std.math.clamp(base + delta * unit, info.min, info.max);
    const stepped = if (unit < 1.0) @round(clamped * 100.0) / 100.0 else clamped;
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

pub fn setError(state: *State, idx: u16, msg: []const u8) void {
    if (row_infos[idx].is_ansi_color) state.ansi_colors_open = true;
    if (decorationGroup(idx)) |group| state.decoration_groups_open[@intFromEnum(group)] = true;
    state.error_key = idx;
    state.error_msg.clearRetainingCapacity();
    state.error_msg.appendSlice(state.gpa, msg) catch {};
}

pub fn view(state: *const State, tree: *Tree, theme: *const Theme) kit.Tree.Error!void {
    const cfg = state.activeConfig();
    const frame = try sidebar.begin(tree, theme, &groups, &state.frame, .{});

    const scroll_box = try scroll_area.open(tree, .{
        .id = scroll_area_id,
        .offset = .{ .y = state.scroll },
        .cross = .center,
        .padding = .symmetric(24, 16),
    });

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
    try separator.horizontal(tree, theme);

    try viewPage(state, tree, theme, page);

    tree.close(content);
    try scroll_area.close(tree, theme, scroll_box);
    try sidebar.end(tree, theme, &groups, &state.frame, frame);

    if (state.open_select) |sel| {
        try viewSelectPopup(state, tree, theme, sel.key, sel.highlight);
    } else if (state.hover == .key_segment) {
        const seg = state.hover.key_segment;
        const info = row_infos[seg.key];
        if (seg.idx < info.display_labels.len) {
            const card = try tooltip.open(tree, theme, .{
                .anchor = segmentId(seg.key, seg.idx),
                .metrics = .{
                    .pad_x = cfg.ui.tooltip_padding_x,
                    .pad_y = cfg.ui.tooltip_padding_y,
                    .gap = cfg.ui.tooltip_gap,
                },
            });
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

const RowInfo = struct {
    name: []const u8,
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

pub const DecorationGroup = enum(u8) {
    ink,
    geometry,
    patterns,
    colors,
};

const decoration_group_titles = [_][]const u8{
    "Ink Skipping",
    "Line Geometry",
    "Pattern Shapes",
    "Decoration Colors",
};

const decoration_group_descriptions = [_][]const u8{
    "Where underlines break around descenders",
    "Offsets, thicknesses and gaps for each line",
    "Curly, dotted and dashed underline shapes",
    "Fixed colors for each kind of decoration line",
};

fn decorationGroup(idx: u16) ?DecorationGroup {
    const info = row_infos[idx];
    if (info.section != .decoration) return null;
    const key_name = info.name;
    if (std.mem.eql(u8, key_name, "skip_ink") or std.mem.eql(u8, key_name, "order") or
        std.mem.eql(u8, key_name, "alpha") or std.mem.eql(u8, key_name, "dim") or
        std.mem.eql(u8, key_name, "blink")) return null;
    if (std.mem.startsWith(u8, key_name, "skip_ink_")) return .ink;
    if (std.mem.startsWith(u8, key_name, "curly_") or std.mem.startsWith(u8, key_name, "dot_") or
        std.mem.startsWith(u8, key_name, "dash_") or std.mem.eql(u8, key_name, "phase")) return .patterns;
    if (std.mem.endsWith(u8, key_name, "_color")) return .colors;
    return .geometry;
}

fn decorationGroupId(group: DecorationGroup) Id {
    return Id.of("settings.decoration_group").item(@intFromEnum(group));
}

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
            .name = key.name,
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

const modified_labels: [keys.table.len + 1][]const u8 = blk: {
    @setEvalBranchQuota(keys.eval_branch_quota);
    var labels: [keys.table.len + 1][]const u8 = undefined;
    for (&labels, 0..) |*label, i| label.* = std.fmt.comptimePrint("{d} modified", .{i});
    break :blk labels;
};

/// One wording for every "changed from default" badge in Settings.
fn modifiedBadge(count: usize) []const u8 {
    if (count == 0) return "";
    return modified_labels[@min(count, modified_labels.len - 1)];
}

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
) kit.Tree.Error!void {
    const hovered = std.meta.eql(state.hover, Target.ansi_colors_toggle);
    const focused = std.meta.eql(state.focused, Target.ansi_colors_toggle);
    const ansi = cfg.resolvedTheme().ansi;

    var overridden_count: usize = 0;
    for (row_infos, 0..) |info, i| {
        if (info.is_ansi_color and colorInfo(@intCast(i), cfg).overridden) {
            overridden_count += 1;
        }
    }

    const card = try collapsible.open(tree, theme, .{});
    const trigger = try collapsible.openTrigger(tree, theme, .{
        .id = ansi_toggle_id,
        .title = "ANSI Palette",
        .description = "Terminal palette colors 0–15",
        .badge = modifiedBadge(overridden_count),
        .open = state.ansi_colors_open,
        .hovered = hovered,
        .focused = focused,
    });

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

    try collapsible.closeTrigger(tree, theme, trigger);

    if (state.ansi_colors_open) {
        const body = try collapsible.openContent(tree, theme, .{});
        var first = true;
        for (row_infos, 0..) |info, i| {
            const idx: u16 = @intCast(i);
            if (keys.availableHere(idx) and info.is_ansi_color) {
                if (!first) {
                    try separator.horizontal(tree, theme);
                }
                first = false;
                try viewKeyRow(state, tree, theme, info, idx, cfg);
            }
        }
        collapsible.closeContent(tree, body);
    }

    collapsible.close(tree, card);
}

fn viewDecorationSection(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    cfg: *const Config,
) kit.Tree.Error!void {
    var row_buf: [keys.table.len]u16 = undefined;
    const rows = sectionRows(.appearance, .decoration, &row_buf);

    try field.legend(tree, theme, "Text Decorations");
    const basics = try card_kit.open(tree, theme, .{ .padding = .all(14), .gap = 12, .radius = Theme.radius_md });
    var first_basic = true;
    for (rows) |idx| {
        if (decorationGroup(idx) != null) continue;
        if (!first_basic) try separator.horizontal(tree, theme);
        first_basic = false;
        try viewKeyRow(state, tree, theme, row_infos[idx], idx, cfg);
    }
    card_kit.close(tree, basics);

    inline for ([_]DecorationGroup{ .ink, .geometry, .patterns, .colors }) |group| {
        const g = @intFromEnum(group);
        var modified: usize = 0;
        for (rows) |idx| {
            if (decorationGroup(idx) == group and isOverridden(idx, cfg)) modified += 1;
        }
        const card = try collapsible.open(tree, theme, .{});
        const target: Target = .{ .decoration_group = group };
        const trigger = try collapsible.openTrigger(tree, theme, .{
            .id = decorationGroupId(group),
            .title = decoration_group_titles[g],
            .description = decoration_group_descriptions[g],
            .badge = modifiedBadge(modified),
            .open = state.decoration_groups_open[g],
            .hovered = std.meta.eql(state.hover, target),
            .focused = std.meta.eql(state.focused, target),
        });
        if (group == .colors and paneWidth(state) >= 520) {
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
            const color_indices = [_]u16{
                @intCast(keys.lookup(.decoration, "underline_color").?),
                @intCast(keys.lookup(.decoration, "strikethrough_color").?),
                @intCast(keys.lookup(.decoration, "overline_color").?),
            };
            for (color_indices) |color_idx| {
                const rgb = colorInfo(color_idx, cfg).resolved;
                _ = try tree.leaf(.{
                    .width = .{ .fixed = 10 },
                    .height = .{ .fixed = 14 },
                    .fill = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b },
                    .radius = 2,
                });
            }
            tree.close(strip);
        }
        try collapsible.closeTrigger(tree, theme, trigger);
        if (state.decoration_groups_open[g]) {
            const body = try collapsible.openContent(tree, theme, .{});
            var first = true;
            for (rows) |idx| {
                if (decorationGroup(idx) != group) continue;
                if (!first) try separator.horizontal(tree, theme);
                first = false;
                try viewKeyRow(state, tree, theme, row_infos[idx], idx, cfg);
            }
            collapsible.closeContent(tree, body);
        }
        collapsible.close(tree, card);
    }
}

fn viewPage(state: *const State, tree: *Tree, theme: *const Theme, page: Page) kit.Tree.Error!void {
    const cfg = state.activeConfig();
    var sec_buf: [max_section_count]keys.Section = undefined;
    var row_buf: [keys.table.len]u16 = undefined;
    for (pageSections(page, &sec_buf)) |sec| {
        if (sec == .decoration) {
            try viewDecorationSection(state, tree, theme, cfg);
            continue;
        }
        var section_open: ?kit.Tree.Index = null;
        var first_in_section = true;
        var ansi_drawn = false;

        for (sectionRows(page, sec, &row_buf)) |idx| {
            if (isInactiveSubRow(idx) or !rowVisible(state, idx, cfg)) continue;
            const info = row_infos[idx];
            if (info.is_ansi_color) {
                if (!ansi_drawn) {
                    if (section_open) |open_box| {
                        card_kit.close(tree, open_box);
                        section_open = null;
                    }
                    try viewAnsiCollapsible(state, tree, theme, cfg);
                    ansi_drawn = true;
                }
                continue;
            }
            if (section_open == null) {
                try field.legend(tree, theme, section_titles.get(sec));
                section_open = try card_kit.open(tree, theme, .{
                    .padding = .all(14),
                    .gap = 12,
                    .radius = Theme.radius_md,
                });
            } else if (!first_in_section) {
                try separator.horizontal(tree, theme);
            }
            first_in_section = false;
            try viewKeyRow(state, tree, theme, info, idx, cfg);

            if (idx == on_inactive_idx and !cfg.window.on_inactive.eql(.empty)) {
                const sub_group = try tree.open(.{
                    .width = .fill,
                    .axis = .column,
                    .padding = .all(12),
                    .gap = 10,
                    .fill = theme.background,
                    .border = theme.border,
                    .border_width = Theme.border_width,
                    .radius = Theme.radius_sm,
                });
                var first_sub = true;
                for (inactive_sub_rows) |sub_idx| {
                    if (!rowVisible(state, sub_idx, cfg)) continue;
                    if (!first_sub) {
                        try separator.horizontal(tree, theme);
                    }
                    first_sub = false;
                    try viewKeyRow(state, tree, theme, row_infos[sub_idx], sub_idx, cfg);
                }
                tree.close(sub_group);
            }
        }
        if (section_open) |open_box| {
            if (page == .overlays and (sec == .toast or sec == .banner or sec == .alert_dialog)) {
                try separator.horizontal(tree, theme);
                try viewPreviewRow(state, tree, theme, sec);
            }
            card_kit.close(tree, open_box);
        }
    }
}

fn viewPreviewRow(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    sec: keys.Section,
) kit.Tree.Error!void {
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

    const hovered = std.meta.eql(state.hover, tgt);
    const pressed = std.meta.eql(state.pressed, tgt);
    const focused = std.meta.eql(state.focused, tgt);
    const btn_state: button.State = if (pressed and hovered)
        .pressed
    else if (hovered)
        .hovered
    else
        .normal;

    const row = try field.open(tree, theme, .{
        .label = "Preview",
        .description = desc,
        .orientation = .responsive,
        .compact = paneWidth(state) < 540,
    });

    try button.view(tree, theme, .{
        .id = id,
        .label = btn_label,
        .variant = .outline,
        .size = .sm,
        .state = btn_state,
        .focused = focused,
    });
    try field.close(tree, theme, row);
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

const segment_icons = std.StaticStringMap(u21).initComptime(.{
    .{ "auto", kit.icons.monitor },
    .{ "dark", kit.icons.moon },
    .{ "light", kit.icons.sun },
});

fn segmentIcon(token: []const u8) u21 {
    return segment_icons.get(token) orelse kit.icons.none;
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
) kit.Tree.Error!void {
    const meta = info.meta;
    const pane_w = paneWidth(state);
    const compact = pane_w < 540;
    const control_px: f32 = if (pane_w >= 760) 280 else 240;
    // Every field gets one right-hand column, right-aligned. Controls fill
    // it; only Reset takes a fixed slot when the field actually has one.
    const reset_slot: f32 = 64;
    const cluster_gap: f32 = 8;
    const cluster_px: f32 = control_px + cluster_gap + reset_slot;
    const cluster_width: kit.Tree.Size = if (compact) .fill else .{ .fixed = cluster_px };

    const row = try field.open(tree, theme, .{
        .label = meta.label,
        .description = meta.description,
        .badge = if (info.restart_required) "Restart required" else "",
        .err = if (state.error_key == idx) state.error_msg.items else "",
        .orientation = .responsive,
        .compact = compact,
        .align_top = info.kind == .list,
    });

    const reset_target: ?Target = if (info.kind == .color)
        .{ .color_reset = idx }
    else if (info.null_keyword != null)
        .{ .key_reset = idx }
    else
        null;

    const cluster = try tree.open(.{
        .axis = .row,
        .width = cluster_width,
        .gap = cluster_gap,
        .cross = .center,
        .main = .end,
    });

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
            // The slider's total width is track + focus ring + gap + readout;
            // make that exactly the shared control column width.
            const slider_extra = @as(f32, theme.ring_width) * 2 + slider.readout_gap + slider.readout_width;
            const reset_taken: f32 = if (reset_target != null) cluster_gap + reset_slot else 0;
            const track_w: f32 = if (compact)
                @max(pane_w - 130 - reset_taken - slider_extra, 60)
            else
                cluster_px - reset_taken - slider_extra;
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

            const group = try input_group.open(tree, theme, .{
                .width = .fill,
                .focused = any_focused,
                .hovered = input_hovered or dec_hovered or inc_hovered,
                .invalid = is_err,
            });
            try input_group.addonButton(tree, theme, .{
                .id = decId(idx),
                .label = "−",
                .hovered = dec_hovered,
                .disabled = at_min,
            });
            try input_group.separator(tree, theme);
            try input_group.textInput(tree, theme, .{
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
            });
            try input_group.separator(tree, theme);
            try input_group.addonButton(tree, theme, .{
                .id = incId(idx),
                .label = "+",
                .hovered = inc_hovered,
                .disabled = at_max,
            });
            input_group.close(tree, group);
        },
        .duration => {
            const inp = &state.inputs[idx];
            const unit = state.duration_units[idx];
            const is_err = state.error_key == idx;
            const input_focused = std.meta.eql(state.focused, Target{ .key_input = idx });
            const input_hovered = std.meta.eql(state.hover, Target{ .key_input = idx });
            const select_hovered = std.meta.eql(state.hover, Target{ .key_select = idx });
            const is_open = if (state.open_select) |sel| sel.key == idx else false;

            const group = try input_group.open(tree, theme, .{
                .width = .fill,
                .focused = input_focused,
                .hovered = input_hovered or select_hovered or is_open,
                .invalid = is_err,
            });
            try input_group.textInput(tree, theme, .{
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
            });
            try input_group.separator(tree, theme);
            const unit_btn = try input_group.openAddon(tree, theme, .{
                .id = selectId(idx),
                .hovered = select_hovered or is_open,
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
            input_group.closeAddon(tree, unit_btn);
            input_group.close(tree, group);
        },
        .select => {
            const current_label = selectDisplayValue(idx, cfg);
            const is_open = if (state.open_select) |sel| sel.key == idx else false;
            try select.trigger(tree, theme, .{
                .id = selectId(idx),
                .value = current_label,
                .width = .fill,
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

            const group = try button_group.open(tree, theme, .{
                .focused = focused_any,
                .hovered = hovered_any,
            });
            for (0..count) |seg_i| {
                if (seg_i > 0) {
                    try button_group.separator(tree, theme);
                }
                const seg_target: Target = .{ .key_segment = .{ .key = idx, .idx = @intCast(seg_i) } };
                try button_group.iconSegment(tree, theme, segmentIcon(info.labels[seg_i]), .{
                    .id = segmentId(idx, seg_i),
                    .selected = if (current_idx) |cur| cur == seg_i else false,
                    .hovered = std.meta.eql(state.hover, seg_target),
                    .focused = std.meta.eql(state.focused, seg_target),
                });
            }
            button_group.close(tree, group);
        },
        .enum_set => {
            const is_open = if (state.open_select) |sel| sel.key == idx else false;
            try select.trigger(tree, theme, .{
                .id = selectId(idx),
                .value = enumSetSummaryValue(idx, cfg),
                .width = .fill,
                .hovered = std.meta.eql(state.hover, Target{ .key_select = idx }),
                .open = is_open,
                .focused = std.meta.eql(state.focused, Target{ .key_select = idx }),
            });
        },
        .list => {
            const items = state.list_items[idx].items;
            const list_col = try tree.open(.{
                .axis = .column,
                .width = .fill,
                .gap = 6,
            });
            for (items, 0..) |item, item_i| {
                const item_u16: u16 = @intCast(item_i);
                const item_pad = try tree.open(.{
                    .width = .fill,
                    .padding = .symmetric(theme.ring_width, 0),
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
                _ = try tree.text(item, .{
                    .color = theme.foreground,
                    .style = .sm,
                    .width = .fill,
                    .wrap = .ellipsis,
                });

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
                _ = try tree.icon(.{
                    .codepoint = kit.icons.x,
                    .color = if (rm_hovered) theme.destructive else theme.muted_foreground,
                    .size = 14,
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

            const group = try input_group.open(tree, theme, .{
                .width = .fill,
                .focused = input_focused,
                .hovered = input_hovered or add_hovered,
                .invalid = is_err,
            });
            try input_group.textInput(tree, theme, .{
                .id = inputId(idx),
                .value = inp.text(),
                .placeholder = info.placeholder,
                .cursor = inp.cursor,
                .anchor = inp.anchor,
                .width = .fill,
                .hovered = input_hovered,
                .focused = input_focused,
                .invalid = is_err,
            });
            try input_group.separator(tree, theme);
            const add_disabled = std.mem.trim(u8, inp.text(), " \t").len == 0;
            try input_group.addonButton(tree, theme, .{
                .id = listAddId(idx),
                .label = "+",
                .hovered = add_hovered,
                .disabled = add_disabled,
            });
            input_group.close(tree, group);
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
            const color_row = try tree.open(.{
                .axis = .row,
                .width = .fill,
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
                .width = .fill,
                .hovered = std.meta.eql(state.hover, Target{ .key_input = idx }),
                .focused = std.meta.eql(state.focused, Target{ .key_input = idx }),
                .invalid = is_err,
            });
        },
    }

    if (reset_target) |target| {
        const reset_pressed = std.meta.eql(state.pressed, target);
        const reset_hovered = std.meta.eql(state.hover, target);
        const disabled = !isOverridden(idx, cfg);
        try button.view(tree, theme, .{
            .id = targetId(target).?,
            .label = "Reset",
            .variant = .outline,
            .size = .sm,
            .state = if (disabled) .disabled else if (reset_pressed and reset_hovered) .pressed else if (reset_hovered) .hovered else .normal,
        });
    }
    tree.close(cluster);

    try field.close(tree, theme, row);
}

fn viewSelectPopup(
    state: *const State,
    tree: *Tree,
    theme: *const Theme,
    key_idx: u16,
    highlight: usize,
) kit.Tree.Error!void {
    const cfg = state.activeConfig();
    const info = row_infos[key_idx];
    const card = try select.openList(tree, theme, .{
        .layer_id = layer_id,
        .anchor = selectId(key_idx),
        .id = popup_card_id,
        .max_height = popup.default_max_height,
        .scroll_y = state.open_select.?.scroll_y,
    });
    switch (info.kind) {
        .duration => {
            const selected_idx: usize = @intFromEnum(state.duration_units[key_idx]);
            const count: usize = if (info.null_keyword != null) 5 else 4;
            for (0..count) |c_idx| {
                const unit: DurationUnit = @enumFromInt(@as(u8, @intCast(c_idx)));
                try select.item(tree, theme, .{
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
                try select.item(tree, theme, .{
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
                try select.item(tree, theme, .{
                    .id = choiceId(c_idx),
                    .label = label,
                    .highlighted = c_idx == highlight,
                    .selected = if (selected_idx) |s| c_idx == s else false,
                });
            }
        },
        else => {},
    }
    try select.closeScrollableList(tree, theme, card);
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
