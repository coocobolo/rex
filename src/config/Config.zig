//! The application configuration. Field defaults are the built-in
//! defaults; `main.zig` passes a base value to `App.init`, which applies
//! the system and user config files on top of it.
//!
//! Strings and slices in an applied config point either at static data or
//! into the arena that applying the files allocated from.

const std = @import("std");

const window_types = @import("window.zig");
const overlay = @import("overlay.zig");
const FontConfig = @import("../freetype/Config.zig");
const Binding = @import("../input/binding.zig").Binding;
const WellbeingOption = @import("../builtin/wellbeing/root.zig").Option;
const SpawnOption = @import("../termio/pty.zig").SpawnOption;
const Theme = @import("../color/Theme.zig");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Classifier = @import("../unicode/Classifier.zig");
const PlainVar = @import("../env/root.zig").PlainVar;
const TerminalOption = @import("../term/term.zig").Option;
const Motion = @import("../kit/motion.zig").Mode;
const ColorScheme = @import("../kit/Theme.zig").ColorScheme;

blink: Blink,
font: Font,
keymap: []const Binding,
wellbeing: WellbeingOption = .{},
termio: SpawnOption,
shell: Shell = .{},
ui: Ui = .{},
theme: Theme,
/// Optional handcrafted design tokens override for custom surface and border styling.
tokens: ?Tokens = null,
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
/// Grid limits and identity: max_rows (200), max_cols (220),
/// tab_width (8), max_scrollback (3896), ambiguous_width (.narrow),
/// name ("rex") and version ("0.1.0"). Rows plus scrollback should
/// be a power of two so the ring wastes nothing, see
/// TerminalOption.optimized.
///
/// These size the screen at compile time, so the types below read
/// them from the root file: main.zig declares
/// `pub const rex_terminal_option = config.terminal;`. App.init
/// fails to compile when the two differ.
terminal: TerminalOption = default_terminal,
/// Threading configuration: .single for in-loop synchronous execution,
/// or .multi for dedicated background worker thread with wait-free triple buffer.
threading: Threading = .{},

/// What programs may do with the clipboard through OSC 52 (ADR 0006).
pub const Clipboard = struct {
    /// Whether an OSC 52 write replaces the clipboard.
    osc52_write: Policy = .allow,
    /// Whether an OSC 52 read gets the clipboard's content; refused reads
    /// get an empty reply.
    osc52_read: Policy = .deny,

    pub const Policy = enum { allow, deny };
};

/// Blink timing of SGR 5 and SGR 6 text.
pub const Blink = struct {
    /// Half period of SGR 5 blink, in ms. 0 turns blinking off.
    half_period_ms: u64 = 500,
    /// Half period of SGR 6 rapid blink, in ms. 0 turns it off.
    rapid_half_period_ms: u64 = 250,

    pub const default: Blink = .{};
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
    scrollbar: window_types.Scrollbar,
    cursor: window_types.Cursor,
    /// Positions, thicknesses and looks of underline, strikethrough
    /// and overline. The defaults follow the font.
    decoration: window_types.Decoration = .{},
    /// Opacity of SGR 2 (dim) text, 0.0 to 1.0.
    dim_alpha: f32 = 0.5,
    /// Glyph atlas texture size, default 2048x2048. Bigger fits more
    /// distinct glyphs (emoji, CJK, large fonts) before it is full.
    atlas: window_types.Atlas = .{},
    /// How a selection looks (`window.selection`), not how it behaves
    /// (`selection`).
    selection: window_types.SelectionStyle,
    /// Initial window size, in logical pixels (pixels at 100% scale).
    /// On X11 the window grows by the display scale when it's created;
    /// on Wayland the compositor scales it.
    size: window_types.Size = .{ .width = 1920, .height = 1080 },
    /// Window title; null (`auto`) shows the title programs set with OSC 0
    /// and 2, or `default_title` until they set one.
    title: ?[:0]const u8 = null,
    /// The default look of every surface (`[surface]`): cards, toasts,
    /// banners and dialogs.
    surface: Surface = .{},
    /// Each component's own look over `surface`; read through `surfaceFor`.
    surfaces: Surfaces = .{},
    /// In-terminal toast notification options.
    toast: overlay.Toast = .{},
    /// Configuration diagnostic notification banner options.
    banner: overlay.Banner = .{},
    /// Semantic icon rendering options.
    icon: overlay.Icon = .{},
    /// Modal dialog options including dimensions, dimming, and default focus.
    modal: overlay.Modal = .{},
    /// Copy and labels for the quit confirmation modal dialog.
    quit_dialog: QuitDialog = .{},
    /// Interactive button primitive options.
    button: overlay.Button = .{},
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

    pub const Surfaces = struct {
        card: SurfaceOverride = .inherit,
        toast: SurfaceOverride = .inherit,
        banner: SurfaceOverride = .inherit,
        modal: SurfaceOverride = .inherit,
    };

    pub const Component = std.meta.FieldEnum(Surfaces);

    /// The look of `component`: its own settings, the rest from `surface`.
    pub fn surfaceFor(window: *const Window, comptime component: Component) Surface {
        return @field(window.surfaces, @tagName(component)).resolve(window.surface);
    }

    /// Neutral values: every option's own preset.
    pub const default: Window = .{
        .background = .default,
        .scrollbar = .default,
        .cursor = .default,
        .selection = .default,
    };
};

/// The look of a surface: corner radius, border width, shape and style.
pub const Surface = window_types.Surface;

/// A component's own surface settings; null takes the value from
/// `Window.surface` (CF11, naming doc §6.1). Resolved on read, so every
/// layer and reload sees the same rule and nothing derived can go stale.
pub const SurfaceOverride = struct {
    corner_radius: ?f32 = null,
    border_width: ?f32 = null,
    border_shape: ?Surface.BorderShape = null,
    border_style: ?Surface.BorderStyle = null,

    pub const inherit: SurfaceOverride = .{};

    pub fn resolve(override: SurfaceOverride, base: Surface) Surface {
        return .{
            .corner_radius = override.corner_radius orelse base.corner_radius,
            .border_width = override.border_width orelse base.border_width,
            .border_shape = override.border_shape orelse base.border_shape,
            .border_style = override.border_style orelse base.border_style,
        };
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

/// How selecting text behaves.
pub const Selection = struct {
    mouse_double_click_interval_ms: u32 = 500,
    classifier: Classifier.Option,

    pub const default: Selection = .{ .classifier = .default };
};

/// The terminal's identity for programs started in it; the rest of their
/// environment is inherited.
pub const default_environments: []const PlainVar = &.{
    .{ .key = "TERM", .value = "xterm-256color" },
    .{ .key = "COLORTERM", .value = "truecolor" },
};

/// The terminal font. Sizes are in logical pixels (pixels at 100% scale);
/// the rasterizer gets `FontConfig.pixelSize(size, content_scale)` device
/// pixels.
pub const Font = struct {
    faces: FontConfig.Faces,
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

/// Copy and labels of the quit confirmation dialog.
pub const QuitDialog = struct {
    title: []const u8 = "QUIT TERMINAL?",
    line1: []const u8 = "Active terminal session is still running.",
    line2: []const u8 = "Close this window and terminate the session?",
    confirm_label: []const u8 = "Quit terminal",
    cancel_label: []const u8 = "Cancel and stay",
};

pub const Threading = struct {
    mode: Mode = .multi,
    sync_output_timeout_ms: u32 = 150,

    pub const Mode = enum {
        single,
        multi,
    };
};

/// Terminal limits used when the root file sets none, as in tests.
/// 200 rows plus 3896 scrollback lines fill a 4096 row ring.
pub const default_terminal: TerminalOption = .{
    .max_rows = 200,
    .max_cols = 220,
    .tab_width = 8,
    .max_scrollback = 3896,
    .name = "rex",
    .version = "0.1.0",
};
