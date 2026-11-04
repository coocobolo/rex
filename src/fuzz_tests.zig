//! Root of `zig build fuzz` and `zig build fuzz-<name>`. The targets
//! are listed in fuzz/root.zig; this file only exists because a module
//! cannot import above its root file's directory, and the targets
//! import ../term, ../vt and ../unicode. It goes away once those become
//! named modules.

test {
    _ = @import("fuzz/root.zig");
}
