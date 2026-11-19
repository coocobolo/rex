//! Test root for the native X11 backend.

test {
    if (@import("builtin").os.tag == .linux) {
        _ = @import("egl_test.zig");
        _ = @import("xlib_test.zig");
        _ = @import("selection_test.zig");
        _ = @import("window_test.zig");
        _ = @import("layout_test.zig");
    }
}
