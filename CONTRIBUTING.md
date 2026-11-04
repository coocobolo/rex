# Contributing

## Tests

Tests live in `<name>_test.zig` next to the code they test. Each
folder's `root.zig` lists its test files in one `test {}` block:

```zig
test {
    _ = @import("screen_test.zig");
}
```

- **Add a test file:** create `foo_test.zig` and add one
  `_ = @import("foo_test.zig");` line to that folder's `root.zig`.
- **Add a suite:** add one row to `suites` in `build.zig`. Its root must
  not import above its own directory; `src/term_tests.zig` exists only
  because `term/` imports `../vt`, `../unicode` and others.
- Implementation files do not import test files. Folder roots import leaf
  files of other folders (`../unicode/utf8.zig`), not their `root.zig`,
  so one suite does not pull in another's tests.

Run them:

| Command | Runs |
| --- | --- |
| `zig build test` | everything, each test once |
| `zig build test-term` | `term/` (screen, dispatcher, input engine) |
| `zig build test-vt` | the VT parser |
| `zig build test-unicode` | width tables and decoders |
| `-Dtest-filter=<substr>` | only tests whose name contains it (repeatable) |
| `-Dslow` | also the slow exhaustive tests (about 25 s) |
| `-Doptimize=ReleaseSafe` | tests in another mode (default Debug) |

Example: `zig build test-term -Dtest-filter=combining`.
