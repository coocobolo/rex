//! Test root for the GLFW backend. Kept separate from the native-free
//! `platform/root.zig` so its imports do not count as interface dependencies.

test {
    _ = @import("choice_test.zig");
    _ = @import("key_test.zig");
    _ = @import("window_test.zig");
}
