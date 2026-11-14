//! Tool windows (ADR 0008): processes of the same binary that draw only
//! the UI kit, one window each.

pub const host = @import("host.zig");
pub const placeholder = @import("placeholder.zig");
pub const dashboard = @import("dashboard.zig");

test {
    _ = placeholder;
    _ = @import("dashboard_test.zig");
    _ = @import("file_watch_test.zig");
}
