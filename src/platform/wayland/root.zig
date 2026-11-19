//! Test root for the native Wayland backend.

test {
    _ = @import("loader_test.zig");
    _ = @import("egl_test.zig");
    _ = @import("layout_test.zig");
    _ = @import("window_test.zig");
}
