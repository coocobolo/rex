//! The UI kit of ADR 0009: design tokens, a flat node array a view
//! builds from its state, and the layout that turns it into rectangles.
//! It draws nothing itself and depends on neither `term/`, the driver nor
//! the renderer, so it runs in any process and is tested without GL.

pub const Theme = @import("Theme.zig");
pub const text = @import("text.zig");
pub const icons = @import("icons.zig");
pub const tree = @import("tree.zig");
pub const layout = @import("layout.zig");
pub const memory = @import("memory.zig");
pub const motion = @import("motion.zig");
pub const kbd = @import("kbd.zig");
pub const button = @import("button.zig");
pub const focus = @import("focus.zig");
pub const dialog = @import("dialog.zig");
pub const toast = @import("toast.zig");
pub const alert_dialog = @import("alert_dialog.zig");
pub const sidebar = @import("sidebar.zig");
pub const popup = @import("popup.zig");
pub const tabs = @import("tabs.zig");
pub const chart = @import("chart.zig");
pub const tooltip = @import("tooltip.zig");
pub const switch_control = @import("switch.zig");
pub const checkbox = @import("checkbox.zig");
pub const select = @import("select.zig");

test {
    _ = @import("kit_test.zig");
    _ = @import("memory_test.zig");
    _ = @import("toast_test.zig");
    _ = @import("alert_dialog_test.zig");
    _ = @import("button_test.zig");
    _ = @import("sidebar_test.zig");
    _ = @import("popup_test.zig");
    _ = @import("tabs_test.zig");
    _ = @import("chart_test.zig");
    _ = @import("tooltip_test.zig");
    _ = @import("switch_test.zig");
    _ = @import("checkbox_test.zig");
    _ = @import("select_test.zig");
    _ = Theme;
    _ = motion;
    _ = focus;
}
