//! Fuzz targets, one per file, all built on harness.zig; see
//! CONTRIBUTING.md, "Fuzzing". Each target's tests run in `zig build
//! test` (seeds, saved regressions and seeded mutations), and
//! `zig build fuzz-<name> --fuzz -Dllvm` fuzzes one of them.
//!
//! Adding a target is one file here, one line in the `test {}` block
//! below and one row in `fuzz_targets` in build.zig.

test {
    _ = @import("config.zig");
    _ = @import("grapheme.zig");
    _ = @import("parser.zig");
    _ = @import("strings.zig");
    _ = @import("terminal.zig");
    _ = @import("utf8.zig");
    _ = @import("wcwidth.zig");
}
