//! The UI kit of ADR 0009: design tokens, a flat node array a view
//! builds from its state, and the layout that turns it into rectangles.
//! It draws nothing itself and depends on neither `term/`, the driver nor
//! the renderer, so it runs in any process and is tested without GL.

pub const Theme = @import("Theme.zig");
pub const text = @import("text.zig");
pub const tree = @import("tree.zig");
pub const layout = @import("layout.zig");

test {
    _ = @import("kit_test.zig");
    _ = Theme;
}
