//! Test root for the native Wayland backend.

test {
    if (@import("builtin").os.tag == .linux) {
        _ = @import("loader_test.zig");
        _ = @import("egl_test.zig");
        _ = @import("layout_test.zig");
        _ = @import("input_test.zig");
        _ = @import("ime_scale_test.zig");
        _ = @import("selection_test.zig");
        _ = @import("window_test.zig");
    }
}
