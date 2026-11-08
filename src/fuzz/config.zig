//! Config fuzz target: any bytes through the new config front end,
//! `Ast.parse` (and so the `Tokenizer`) and then `Sema.apply` onto the
//! shared test config.
//!
//! Invariants:
//!   - no panic, safety check or leak;
//!   - the token list ends with exactly one `eof`, and every Ast and Sema
//!     error points at a token of the tree;
//!   - provenance records only name tokens;
//!   - every key the file set holds a value within its row's bounds
//!     (fractions 0 to 1, minimums and maximums), and font.min_size stays
//!     at most font.max_size;
//!   - every error message renders.

const std = @import("std");
const testing = std.testing;

const harness = @import("harness.zig");
const Source = harness.Source;
const Ast = @import("../config/Ast.zig");
const Sema = @import("../config/Sema.zig");
const keys = @import("../config/keys.zig");
const Config = @import("../config/Config.zig");
const test_config = @import("../config/test_fixtures.zig").test_config;

var input_buf: [harness.max_input]u8 = undefined;

fn run(src: *Source) !void {
    var len: usize = 0;
    while (len < input_buf.len) {
        const piece = src.chunk("bytes", input_buf[len..]);
        std.mem.copyForwards(u8, input_buf[len..][0..piece.len], piece);
        len += piece.len;
        if (src.done("more bytes", 3)) break;
    }
    const source = input_buf[0..len];

    const gpa = testing.allocator;
    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);

    const tags = tree.tokens.items(.tag);
    try testing.expect(tags.len > 0 and tags[tags.len - 1] == .eof);
    for (tags[0 .. tags.len - 1]) |tag| try testing.expect(tag != .eof);
    for (tree.errors) |err| try testing.expect(err.token < tags.len);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var config = test_config;
    var result = try Sema.apply(gpa, &tree, &config, .{
        .defaults = &test_config,
        .arena = arena.allocator(),
        .dir = "/etc/rex",
        .home = if (src.chance("home", 1, 3)) "/home/user" else null,
    });
    defer result.deinit(gpa);

    for (result.errors) |err| try testing.expect(err.token < tags.len);
    for (result.set_by) |token| {
        if (token) |t| try testing.expectEqual(.name, tags[t]);
    }
    try expectSetKeysInBounds(&config, &result);
    try testing.expect(config.font.min_size <= config.font.max_size);

    var buf: [2 * harness.max_input]u8 = undefined;
    for (tree.errors) |err| {
        var w: std.Io.Writer = .fixed(&buf);
        try tree.renderError(err, &w);
    }
    for (result.errors) |err| {
        var w: std.Io.Writer = .fixed(&buf);
        try Sema.renderError(&tree, err, &w);
    }
}

fn expectSetKeysInBounds(config: *const Config, result: *const Sema.Result) !void {
    @setEvalBranchQuota(keys.eval_branch_quota);
    inline for (keys.table, 0..) |key, i| {
        if (result.set_by[i] != null and key.kind != .theme) {
            const bounds: keys.Bounds = if (key.kind == .fraction) .{ .min = 0, .max = 1 } else key.bounds;
            const value = keys.fieldValue(Config, key.field, config);
            const present = switch (@typeInfo(@TypeOf(value))) {
                .optional => value,
                else => @as(?@TypeOf(value), value),
            };
            if (present) |v| {
                const number: ?f64 = switch (@typeInfo(@TypeOf(v))) {
                    .int => @floatFromInt(v),
                    .float => @floatCast(v),
                    else => null,
                };
                if (number) |n| {
                    errdefer std.debug.print("{s} = {d} outside [{d}, {d}]\n", .{ keys.qualified_names[i], n, bounds.min, bounds.max });
                    try testing.expect(n >= bounds.min and n <= bounds.max);
                }
            }
        }
    }
}

const seeds = [_][]const u8{
    "theme = graphite\n[font]\nsize = 16\nmin_size = 8\nmax_size = 64\n",
    "[font]\nfallback = /a.ttf\nfallback = none\nfallback = b.ttc\nfallback = default\nfallback = ~/c.ttf\n",
    "[surface]\ncorner_radius = 12\nborder_shape = sharp\n[toast]\nborder_style = subtle\ncorner_radius = inherit\n[banner]\nborder_width = default\n",
    "[font]\nitalic_file = i.ttf\nemoji_file = ~/e.ttf\nitalic_file = none\nemoji_file = default\n",
    "[font]\nbold_file = b.ttf\nbold_italic_file = ~/bi.ttf\nfile = r.ttf\nbold_file = none\nweight = 300\n",
    "[window]\nbackground_opacity = 0.9\ndim_text_opacity = 0.5\nwidth = 800\nheight = 600\nplatform = wayland\n",
    "[bell]\nenabled = false\nvolume = 0.25\n[modal]\ncols = 60\nbackdrop_opacity = 0.7\nborder_style = inherit\n[modal.blur]\nenabled = true\nradius = 12\n",
    "[toast]\nposition = bottom_right\nduration = 3s\nmin_cols = 20\nmax_cols = 40\n[banner]\nplacement = docked\n",
    "[wellbeing.screen_time]\ndaily_limit = none\nidle_threshold = 3m\n[wellbeing.focus]\ntask = 25m\nshort_break = 5m\nlong_break = 1h\ntasks_before_long_break = 4\n",
    "[wellbeing.winddown]\nenabled = true\nstart = 21:30\nend = 06:00\nwarmth = 0.5\nduring_window = warm_colors\nstart = 24:00\nend = 9:00\n",
    "[wellbeing.eyesight]\nenabled = false\ninterval = 20m\nduration = 20s\nduring_reminder = lock_input\nanimation = sparkle\n[wellbeing.movement]\ninterval = 0s\nanimation = none\n[wellbeing.routines]\nhydration_interval = none\nposture_interval = default\nduring_reminder = none\n",
    "[wellbeing.screen_time]\non_limit = grayscale, lock_input\ngrayscale_transition = 0s\non_limit = none\n[wellbeing.focus]\ntimer = countup\non_phase_end = start_next\non_break = prompt,,animation\non_alert = pause, pause\nduring_task = \tmute_bell \n[wellbeing.privacy]\ntrack_foreground_apps = false\nstrict_local = true\n",
    "[wellbeing.winddown]\nstart = 22:00\nend = 22:00\nend = default\n",
    "[shell]\nprogram = /bin/bash\nargument = --login\nargument = \"none\"\nargument = none\nargument = default\nworking_directory = ~/src\nprogram = bash\nworking_directory = inherit\n",
    "[env]\nLANG = en_GB.UTF-8\nEDITOR = \"nvim -u NONE\"\n1X = a\nGONE = none\nNUL = \"a\\x00b\"\nEMPTY =\nLANG = C\n",
    "[selection]\nextra_word_characters = \"-./~@\"\nextra_word_characters = \"a b\"\nextra_word_characters = -./\nextra_word_characters = \"\\xff\"\n",
    "[keybinds]\nctrl+shift+c = copy_selection\nctrl+shift+v = paste_clipboard\nctrl+f13 = quit\nctrl+a b = quit\nctrl+q = none\n",
    "[font]\nfile = \"~/fonts/a \\\"b\\\".ttf\"\nweight = 350\nbold_weight = 700\nfile = rel/x.ttf\n",
    "# comment\r\n[fonts]\r\nsize = 1\r\n[terminal]\r\nx = 1\r\n[font]\r\nsise = 12\r\nsize = 0\r\nsize = 99999999999999999999\r\n",
    "\xEF\xBB\xBF[card]\ncorner_radius = 4.5\nborder_width = 1e3\nborder_style = subtle # c\ncolor = #ff0000\n[]\n= v\n[a] b\n",
    "[window]\ntitle = rex\n[wellbeing]\neyesight_interval = 20m\nenabled = yes\n[scroll]\nstep_lines = 3\nwheel_lines =\n",
};

const regressions = [_][]const u8{};

test "fuzz config" {
    try harness.fuzz(run, &seeds, &regressions);
}

test "fuzz config: seeded mutations" {
    try harness.seeded(run, &seeds, 0x00C0_F16E);
}
