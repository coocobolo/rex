//! Compile time backend selection. The build option decides which backend the
//! rest of the platform interface sees; no runtime dispatch is involved.

const std = @import("std");
const options = @import("build_options");

pub const selected = if (std.mem.eql(u8, options.platform_backend, "x11"))
    @import("x11/backend.zig")
else
    @import("glfw/backend.zig");
