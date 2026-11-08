//! The application configuration. Field defaults are the built-in
//! defaults; `main.zig` passes a base value to `App.init`, which applies
//! the system and user config files on top of it.
//!
//! Strings and slices in an applied config point either at static data or
//! into the arena that applying the files allocated from.

const std = @import("std");

const Background = @import("../renderer/Background.zig");
const Card = @import("../renderer/Card.zig");
const Cursor = @import("../renderer/Cursor.zig");
const Decoration = @import("../renderer/Decoration.zig");
const Atlas = @import("../renderer/Atlas.zig");
const Scrollbar = @import("../renderer/Scrollbar.zig");
const Selection = @import("../renderer/Selection.zig");
const Window = @import("../renderer/Window.zig");
const Dimension = @import("../renderer/dimension.zig").Dimension;
const Toast = @import("../ui/Toast.zig");
const Banner = @import("../ui/Banner.zig");
const Icon = @import("../ui/Icon.zig");
const Modal = @import("../ui/Modal.zig");
const Button = @import("../ui/Button.zig");
const FontConfig = @import("../freetype/Config.zig");
const Binding = @import("../input.zig").Binding;
const WellbeingOption = @import("../builtin/wellbeing/root.zig").Option;
const SpawnOption = @import("../termio/pty.zig").SpawnOption;
const Theme = @import("../color/Theme.zig");
const Tokens = @import("../color/Tokens.zig").Tokens;
const Classifier = @import("../unicode/Classifier.zig");
const PlainVar = @import("../env/root.zig").PlainVar;
const TerminalOption = @import("../term/term.zig").Option;

blink: struct {
    /// Half period of SGR 5 blink, in ms. 0 turns blinking off.
    half_period_ms: u64 = 500,
    /// Half period of SGR 6 rapid blink, in ms. 0 turns it off.
    rapid_half_period_ms: u64 = 250,
},
font: Font,
keymap: []const Binding,
wellbeing: WellbeingOption = .{},
termio: SpawnOption,
/// Bytes read from the pty per read call, default 65534. Bigger
/// reads parse long output in fewer frames; 0 is treated as 1.
read_buffer_size: usize = std.math.maxInt(u16) - 1,
theme: Theme,
/// Optional handcrafted design tokens override for custom surface and border styling.
tokens: ?Tokens = null,
window: struct {
    platform: Window.Platform = .auto,
    background: Background.Option,
    /// Rings the X bell on BEL and on pomodoro phase changes (window
    /// attention only where there is no audible bell).
    bell: enum { on, off } = .on,
    /// XBell volume, as a percent of the X server bell volume.
    bell_volume: u8 = 100,
    scrollbar: Scrollbar.Option,
    cursor: Cursor.Option,
    /// Positions, thicknesses and looks of underline, strikethrough
    /// and overline. The defaults follow the font.
    decoration: Decoration.Option = .{},
    /// Opacity of SGR 2 (dim) text, 0.0 to 1.0.
    dim_alpha: f32 = 0.5,
    /// Glyph atlas texture size, default 2048x2048. Bigger fits more
    /// distinct glyphs (emoji, CJK, large fonts) before it is full.
    atlas: Atlas.Option = .{},
    selection: Selection.Option,
    /// Initial window size, in logical pixels (pixels at 100% scale).
    /// On X11 the window grows by the display scale when it's created;
    /// on Wayland the compositor scales it.
    size: Dimension(u16) = .{ .width = 1920, .height = 1080 },
    /// Window title. A running pomodoro is appended after it.
    title: [:0]const u8 = "rex",
    /// Rounded card surface options for UI modals and overlays.
    card: Card.Option = .{},
    /// In-terminal toast notification options.
    toast: Toast.Option = .{},
    /// Configuration diagnostic notification banner options.
    banner: Banner.Option = .{},
    /// Semantic icon rendering options.
    icon: Icon.Option = .{},
    /// Modal dialog options including dimensions, dimming, and default focus.
    modal: Modal.Option = .{},
    /// Copy and labels for the quit confirmation modal dialog.
    quit_dialog: QuitDialog = .{},
    /// Interactive button primitive options.
    button: Button.Option = .{},
    /// Prompts for confirmation before closing the window while the terminal session is active.
    confirm_quit: bool = true,
},
scroll: struct {
    /// Lines moved by the scroll_up and scroll_down actions.
    lines: u32 = 3,
    /// Lines moved per mouse wheel step.
    wheel_lines: u32 = 3,
} = .{},
selection: struct {
    mouse_double_click_interval_ms: u32 = 500,
    classifier: Classifier.Option,
},
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
