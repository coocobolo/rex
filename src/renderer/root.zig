const std = @import("std");

pub const gl = @import("gl.zig");

pub const Atlas = @import("Atlas.zig");
pub const Window = @import("Window.zig");

pub const Frame = @import("Frame.zig");

pub const Renderer = @import("renderer.zig").Renderer;
pub const Cell = @import("Cell.zig");
pub const Option = @import("renderer.zig").Option;
pub const Scrollbar = @import("Scrollbar.zig");
pub const Cursor = @import("Cursor.zig");
pub const Background = @import("Background.zig");
pub const Decoration = @import("Decoration.zig");
pub const Selection = @import("Selection.zig");
pub const Dimension = @import("dimension.zig").Dimension;
pub const DirtyFlags = @import("dirty.zig").DirtyFlags;

test {
    _ = @import("atlas_test.zig");
    _ = @import("frame_test.zig");
    _ = @import("scrollbar_test.zig");
    _ = @import("shader_test.zig");
    std.testing.refAllDecls(@This());
}
