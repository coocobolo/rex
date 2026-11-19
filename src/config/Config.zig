//! The application configuration. Field defaults are the built-in
//! defaults; `main.zig` passes a base value to `App.init`, which applies
//! the system and user config files on top of it.
//!
//! Strings and slices in an applied config point either at static data or
//! into the arena that applying the files allocated from.

const window_types = @import("window.zig");
const selection_types = @import("selection.zig");
const overlay = @import("overlay.zig");
const font_config = @import("font.zig");
const Binding = @import("../input/binding.zig").Binding;
const WellbeingOption = @import("wellbeing.zig").Wellbeing;
const Theme = @import("../color/Theme.zig");
const Rgb = @import("../color/Rgb.zig");
const Classifier = @import("../unicode/Classifier.zig");
const PlainVar = @import("../env/root.zig").PlainVar;
const Motion = @import("../kit/motion.zig").Mode;
const ColorScheme = @import("../kit/Theme.zig").ColorScheme;

font: Font,
keymap: []const Binding,
wellbeing: WellbeingOption = .{},
shell: Shell = .{},
ui: Ui = .{},
theme: Theme,
colors: Colors = .{},
cursor: Cursor = .{},
window: Window,
scroll: struct {
    /// Lines moved by the scroll_up and scroll_down actions.
    lines: u32 = 3,
    /// Lines moved per mouse wheel step.
    wheel_lines: u32 = 3,
} = .{},
scrollbar: Scrollbar = .{},
selection: Selection,
clipboard: Clipboard = .{},
/// Stores list of plain environment variable using "KEY=VALUE" format
environments: []const PlainVar,

/// Returns `theme` with any non-null `[colors]` overrides layered on top.
pub fn resolvedTheme(self: *const @This()) Theme {
    return self.colors.resolve(self.theme);
}

/// Optional per-slot overrides layered over `theme` (`[colors]`).
pub const Colors = struct {
    background: ?Rgb = null,
    foreground: ?Rgb = null,
    selection_background: ?Rgb = null,
    selection_foreground: ?Rgb = null,
    accent: ?Rgb = null,
    color0: ?Rgb = null,
    color1: ?Rgb = null,
    color2: ?Rgb = null,
    color3: ?Rgb = null,
    color4: ?Rgb = null,
    color5: ?Rgb = null,
    color6: ?Rgb = null,
    color7: ?Rgb = null,
    color8: ?Rgb = null,
    color9: ?Rgb = null,
    color10: ?Rgb = null,
    color11: ?Rgb = null,
    color12: ?Rgb = null,
    color13: ?Rgb = null,
    color14: ?Rgb = null,
    color15: ?Rgb = null,

    /// Applies any overridden fields onto `base` without mutating it.
    pub fn resolve(self: Colors, base: Theme) Theme {
        var out = base;
        if (self.background) |c| out.background = c;
        if (self.foreground) |c| out.foreground = c;
        if (self.selection_background) |c| out.selection_background = c;
        if (self.selection_foreground) |c| out.selection_foreground = c;
        if (self.accent) |c| out.accent = c;
        inline for (0..16) |i| {
            const name = @import("std").fmt.comptimePrint("color{d}", .{i});
            if (@field(self, name)) |c| out.ansi[i] = c;
        }
        return out;
    }
};

/// What programs may do with the clipboard through OSC 52 (ADR 0006).
pub const Clipboard = struct {
    /// Whether an OSC 52 write replaces the clipboard, or prompts first.
    osc52_write: Policy = .allow,
    /// Whether an OSC 52 read gets the clipboard's content, is refused
    /// with an empty reply, or prompts first.
    osc52_read: Policy = .deny,

    pub const Policy = enum { allow, deny, ask };
};

/// The window and the UI drawn in it.
/// The UI kit's own settings (`[ui]`).
pub const Ui = struct {
    /// Whether toasts and dialogs fade and slide.
    motion: Motion = .full,
    /// Dark or light UI, or whichever reads well over the terminal.
    color_scheme: ColorScheme = .auto,
};

pub const Window = struct {
    /// The title while `title` is `auto` and no program has set one.
    pub const default_title: [:0]const u8 = "rex";

    platform: window_types.Platform = .auto,
    background: window_types.Background,
    bell: Bell = .{},
    /// Opacity of SGR 2 (dim) text, 0.0 to 1.0.
    dim_alpha: f32 = 0.5,
    /// Initial window size, in logical pixels (pixels at 100% scale).
    /// On X11 the window grows by the display scale when it's created;
    /// on Wayland the compositor scales it.
    size: window_types.Size = .{ .width = 1920, .height = 1080 },
    /// Window titlebar and border decorations.
    decorations: window_types.Decorations = .full,
    /// Horizontal inner padding around the terminal grid, in logical pixels.
    padding_x: u16 = 0,
    /// Vertical inner padding around the terminal grid, in logical pixels.
    padding_y: u16 = 0,
    /// Window title; null (`auto`) shows the title programs set with OSC 0
    /// and 2, or `default_title` until they set one.
    title: ?[:0]const u8 = null,
    /// In-terminal toast notification options.
    toast: overlay.Toast = .{},
    /// Configuration diagnostic notification banner options.
    banner: overlay.Banner = .{},
    /// Modal dialog container options including backdrop opacity, blur, and layout.
    modal: overlay.Modal = .{},
    /// Alert confirmation dialog options including width and initial focus.
    alert_dialog: overlay.AlertDialog = .{},
    /// What closing the window does.
    on_close: OnClose = .ask_if_running,
    /// Visual effects applied while the window is unfocused.
    on_inactive: window_types.InactiveSet = .empty,
    /// Window background opacity when unfocused and `on_inactive` contains `opacity`.
    inactive_background_alpha: f32 = 0.85,
    /// Content dimming opacity toward the background color when unfocused and `on_inactive` contains `dim`.
    inactive_dim_alpha: f32 = 0.3,
    /// Blur radius in pixels when unfocused and `on_inactive` contains `blur`.
    inactive_blur_radius: u8 = 8,
    /// When to hide the mouse pointer over the terminal.
    mouse_auto_hide: window_types.MouseAutoHide = .on_typing,
    /// Inactivity duration in milliseconds before hiding the mouse pointer, or null to disable.
    mouse_idle_timeout_ms: ?u64 = null,

    pub const OnClose = enum {
        /// Show the quit dialog first.
        ask,
        /// Show it only while a program other than the shell is in the
        /// foreground; background jobs don't count.
        ask_if_running,
        close,
    };
    pub const Decorations = window_types.Decorations;
    pub const InactiveEffect = window_types.InactiveEffect;
    pub const InactiveSet = window_types.InactiveSet;
    pub const MouseAutoHide = window_types.MouseAutoHide;

    /// Neutral values: every option's own preset.
    pub const default: Window = .{
        .background = .default,
    };

    /// Returns the active window background opacity for `focused`.
    pub fn effectiveBackgroundAlpha(self: *const Window, focused: bool) f32 {
        return if (!focused and self.on_inactive.contains(.opacity))
            self.inactive_background_alpha
        else
            self.background.alpha;
    }

    /// Returns the inactive content dim opacity for `focused` (0 when focused or `dim` is not enabled).
    pub fn effectiveInactiveDimAlpha(self: *const Window, focused: bool) f32 {
        return if (!focused and self.on_inactive.contains(.dim))
            self.inactive_dim_alpha
        else
            0.0;
    }

    /// Returns whether the inactive content blur effect is active for `focused`.
    pub fn effectiveInactiveBlur(self: *const Window, focused: bool) bool {
        return !focused and self.on_inactive.contains(.blur);
    }
};

/// What runs in the terminal (`[shell]`). Read once, when Rex starts.
pub const Shell = struct {
    /// An absolute path. Null starts `$SHELL`, then the login shell from
    /// the passwd database, then /bin/sh.
    program: ?[:0]const u8 = null,
    /// argv[1] and on; argv[0] is the program.
    arguments: []const [:0]const u8 = &.{},
    /// Null: the directory Rex was started in.
    working_directory: ?[:0]const u8 = null,
};

/// How selecting text behaves and renders.
pub const Selection = struct {
    mouse_double_click_interval_ms: u32 = 500,
    classifier: Classifier.Option,
    opacity: f32 = 1.0,
    foreground_opacity: f32 = 1.0,
    border_opacity: f32 = 1.0,
    border_width: f32 = 1.5,
    radius: f32 = 3.0,
    border_color: Rgb = .{ .r = 0x66, .g = 0x66, .b = 0x66 },
    border_style: selection_types.BorderStyle = .unified,
    blur_radius: u8 = 0,

    pub const default: Selection = .{ .classifier = .default };
};

/// How the terminal scrollbar looks and fades (`[scrollbar]`).
pub const Scrollbar = struct {
    width: f32 = 5.0,
    hover_width: f32 = 8.0,
    gap: f32 = 2.0,
    min_thumb_height: f32 = 20.0,
    radius: f32 = 4.0,
    auto_hide_opacity: f32 = 0.25,
    track_opacity: f32 = 1.0,
    thumb_opacity: f32 = 0.85,
    thumb_hover_opacity: f32 = 0.95,
    track_color: Rgb = .{ .r = 0x0D, .g = 0x0D, .b = 0x0D },
    thumb_color: Rgb = .{ .r = 0xB3, .g = 0xB3, .b = 0xB3 },
    thumb_hover_color: Rgb = .{ .r = 0xE6, .g = 0xE6, .b = 0xE6 },
    auto_hide: bool = true,

    pub const default: Scrollbar = .{};
};

/// The terminal's identity for programs started in it; the rest of their
/// environment is inherited.
pub const default_environments: []const PlainVar = &.{
    .{ .key = "TERM", .value = "xterm-256color" },
    .{ .key = "COLORTERM", .value = "truecolor" },
};

/// The terminal font. Sizes are in logical pixels (pixels at 100% scale);
/// the rasterizer gets `pixelSize(size, content_scale)` device pixels
/// (`freetype/Config.zig`).
pub const Font = struct {
    faces: font_config.Faces,
    size: u32,
    /// Smallest and largest size that increase_font_size and
    /// decrease_font_size reach.
    min_size: u32,
    max_size: u32,
    /// Step of increase_font_size and decrease_font_size.
    size_step: u32 = 2,

    /// Neutral values. An omitted `file` is filled at startup from the
    /// faces installed next to the executable (`builtin_font.zig`).
    pub const default: Font = .{ .faces = .default, .size = 14, .min_size = 6, .max_size = 196 };
};

/// How the terminal cursor renders and blinks (`[cursor]`).
pub const Cursor = struct {
    /// Cursor opacity, 0.0 to 1.0.
    opacity: f32 = 1.0,
    /// Corner radius in pixels, clamped to half the cursor's smaller side.
    radius: f32 = 5.0,
    /// Height of the underline cursor as a fraction of cell height.
    underline_thickness: f32 = 0.16,
    /// Bottom edge of the underline cursor as a fraction down from cell top.
    underline_position: f32 = 1.0,
    /// Width of the beam cursor as a fraction of cell width.
    beam_thickness: f32 = 0.16,
    /// Outline width in pixels when unfocused; 0 keeps the cursor filled.
    hollow_border_width: f32 = 3.0,
    /// Half-period of cursor and SGR 5 blink in milliseconds.
    blink_interval_ms: u32 = 500,

    pub const default: Cursor = .{};
};

/// The bell on BEL and on pomodoro phase changes: the X bell on X11, window
/// attention only where there is no audible bell.
pub const Bell = struct {
    enabled: bool = true,
    /// Fraction of the X server's bell volume, 0 to 1.
    volume: f32 = 1.0,
};
