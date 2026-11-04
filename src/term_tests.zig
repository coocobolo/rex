//! Root of `zig build test-term`. The term tests are listed in
//! term/root.zig; this file only exists because a module cannot import
//! above its root file's directory, and term/ imports ../vt, ../unicode,
//! ../color and ../renderer.

test {
    _ = @import("term/root.zig");
}
