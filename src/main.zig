const std = @import("std");
const rex = @import("rex");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

pub const std_options: std.Options = .{
    .log_level = .debug,
};
const log = std.log.scoped(.main);

const font_config: rex.FreeType.FontConfig = .{
    .width = 0,
    .height = 20,
    .min_size = 6,
    .max_size = 196,
    .font = .{
        .family = .{
            // .static = .{
            //     .regular = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
            //     .bold = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
            //     .italic = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Oblique.ttf",
            //     .bold_italic = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-BoldOblique.ttf",
            // },
            .variable = .{
                .upright = "/home/ozy/.local/share/fonts/GoogleSansCode-VariableFont_MONO,wght.ttf",
                .italic = "/home/ozy/.local/share/fonts/GoogleSansCode-Italic-VariableFont_MONO,wght.ttf",
                .bold_weight = 550,
                .regular_weight = 400,
            },
        },
        .emoji = .static("/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf"),
        .fallbacks = &.{
            // General Latin/Greek/Cyrillic and lots of symbols
            .static("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
            // CJK
            .static("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"),
            // Symbols
            .static("/usr/share/fonts/truetype/noto/NotoSansSymbols-Regular.ttf"),
            .static("/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf"),

            // Math
            .static("/usr/share/fonts/truetype/noto/NotoSansMath-Regular.ttf"),
            // Historical / niche scripts
            .static("/usr/share/fonts/truetype/noto/NotoSansRunic-Regular.ttf"),

            // Scripts
            // .static("/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf"),
            // .static("/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf"),
            // .static("/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf"),
            // .static("/usr/share/fonts/truetype/noto/NotoSansBengali-Regular.ttf"),
            // .static("/usr/share/fonts/truetype/noto/NotoSansTamil-Regular.ttf"),
            // .static("/usr/share/fonts/truetype/noto/NotoSansTelugu-Regular.ttf"),
            // .static("/usr/share/fonts/truetype/noto/NotoSansThai-Regular.ttf"),
        },
    },
};

const pomodoro_option: rex.builtin.pomodoro.Option = .{
    .timer_mode = .countdown,
    .long_break_ms = 12 * std.time.ms_per_min,
    .short_break_ms = 6 * std.time.ms_per_min,
    .task_ms = 45 * std.time.ms_per_min,
    .tasks_before_long_break = 4,
    .transition_mode = .manual,
};

const scrollbar_option = rex.renderer.Scrollbar.Option{
    // .auto_hide_alpha = 0.4,
    // .width = 12,
    .auto_hide_alpha = 0,
    .auto_hide = true,
    // .radius = 6.0,
    // .hover_width = 12,
    // .track_color = .{ 15, 16, 1, 1 },
    // .thumb_color = .{ 59, 128, 0, 1 },
    // .thumb_hover_color = .{ 59, 128, 0, 1 },
};

const selection_option = rex.renderer.Selection.Option{
    .border_color = .{ 0.16, 0.16, 0.16, 0.8 },
    .border_style = .unified,
    .border_width = 0.75,
    .fill_color = .{ 0.2, 0.2, 0.2, 0.50 },
    .radius = 4.0,
};

// Every field defaults to the font's own lines, see Decoration.Option.
const decoration_option = rex.renderer.Decoration.Option{};

const background_option = rex.renderer.Background.Option{
    .alpha = 0.98,
};

const cursor_option = rex.renderer.Cursor.Option{
    .alpha = 1.0,
    .hollow_border_width = 3.0,
    .radius = 4.0,
};

pub const BracketPair = struct { open: u21, close: u21 };

const config: rex.App.Config = .{
    .blink = .{ .half_period = 500, .rapid_half_period = 250 },
    .font = font_config,
    .keymap = rex.input.default_keymap,
    .termio = .{
        .argv = &.{ "/bin/bash", null },
        .envp = &.{
            // "SHELL=/bin/bash",
            // "TERM=xterm-256color",
            // "LANG=en_GB.UTF-8",
            // "TERMINFO=/usr/share/terminfo",
            // "COLORTERM=truecolor",
            // "HOME=/home/ozy",
            // "XDG_SESSION_DESKTOP=ubuntu",
            // "XDG_RUNTIME_DIR=/run/user/1000",
        },
        .o_flags = .{ .NONBLOCK = true, .ASYNC = false },
        .cwd = "/home/ozy/.project/rex",
    },
    .theme = .graphite,
    .pomodoro = pomodoro_option,
    .window = .{
        .background = background_option,
        .cursor = cursor_option,
        .decoration = decoration_option,
        .scrollbar = scrollbar_option,
        .selection = selection_option,
    },
    .environments = &.{
        .{ .key = "SHELL", .value = "/bin/bash" },
        .{ .key = "TERM", .value = "xterm-256color" },
        .{ .key = "LANG", .value = "en_GB.UTF-8" },
        .{ .key = "TERMINFO", .value = "/usr/share/terminfo" },
        .{ .key = "COLORTERM", .value = "truecolor" },
    },
    .selection = .{
        .classifier = .{
            .extra_word_chars = &.{ '-', '/', '~', '.', '@' },
        },
    },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const environ = init.minimal.environ;

    var args = init.minimal.args.iterate();
    const argv0 = args.next() orelse "rex";

    var app: rex.App = try .init(allocator, init.io, &environ, argv0, &config);
    defer app.deinit(allocator);

    try app.run();
}
