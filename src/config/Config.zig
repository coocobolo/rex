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
window: Window,
scroll: struct {
    /// Lines moved by the scroll_up and scroll_down actions.
    lines: u32 = 3,
    /// Lines moved per mouse wheel step.
    wheel_lines: u32 = 3,
} = .{},
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
    /// Whether an OSC 52 write replaces the clipboard.
    osc52_write: Policy = .allow,
    /// Whether an OSC 52 read gets the clipboard's content; refused reads
    /// get an empty reply.
    osc52_read: Policy = .deny,

    pub const Policy = enum { allow, deny };
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
    /// Window title; null (`auto`) shows the title programs set with OSC 0
    /// and 2, or `default_title` until they set one.
    title: ?[:0]const u8 = null,
    /// In-terminal toast notification options.
    toast: overlay.Toast = .{},
    /// Configuration diagnostic notification banner options.
    banner: overlay.Banner = .{},
    /// Modal dialog options including backdrop opacity, blur, and focus.
    modal: overlay.Modal = .{},
    /// What closing the window does.
    on_close: OnClose = .ask_if_running,

    pub const OnClose = enum {
        /// Show the quit dialog first.
        ask,
        /// Show it only while a program other than the shell is in the
        /// foreground; background jobs don't count.
        ask_if_running,
        close,
    };

    /// Neutral values: every option's own preset.
    pub const default: Window = .{
        .background = .default,
    };
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

/// The bell on BEL and on pomodoro phase changes: the X bell on X11, window
/// attention only where there is no audible bell.
pub const Bell = struct {
    enabled: bool = true,
    /// Fraction of the X server's bell volume, 0 to 1.
    volume: f32 = 1.0,
};
