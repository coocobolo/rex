# Contributing

## Development setup

Rex builds on Linux with Zig 0.16.0 (`minimum_zig_version` in
`build.zig.zon`) and glibc 2.34 or later; `dlopen` and `pthread_*` are
part of libc from 2.34 on, and `build.zig` stops with a message on an
older glibc. GLFW and FreeType come from `build.zig.zon` and GLAD is
vendored; the rest comes from the system:

| Need | For | Debian/Ubuntu package |
| --- | --- | --- |
| X11 headers | GLFW's X11 backend | `libx11-dev libxcursor-dev libxrandr-dev libxinerama-dev libxi-dev libxext-dev` |
| Wayland headers, `wayland-scanner` | GLFW's Wayland backend and its protocol code | `libwayland-dev libwayland-bin` |
| xkbcommon headers | GLFW's Wayland backend | `libxkbcommon-dev` |
| libpng, zlib | FreeType | `libpng-dev zlib1g-dev` |
| Xvfb, Mesa | GL tests without a display, as in CI | `xvfb libgl1-mesa-dri` |
| kcov | `-Dcoverage` | `kcov` |
| xdotool, xclip, pidstat, bc | `scripts/perf-gui.sh`, X11 only | `xdotool xclip sysstat bc` |

To build and test:

    sudo apt install libx11-dev libxcursor-dev libxrandr-dev libxinerama-dev \
        libxi-dev libxext-dev libwayland-dev libwayland-bin libxkbcommon-dev \
        libpng-dev zlib1g-dev
    zig build test

No X11, Wayland, GL or EGL library is linked: GLFW loads them at
runtime, and so does the bell (libX11). A release build depends on
libpng, libm and libc only; Debug builds also keep zlib.

Running Rex needs an X11 or Wayland session and an OpenGL 3.3 core
driver. On Wayland it runs natively;
`window.platform = auto|wayland|x11` in the config overrides the
choice (ADR 0001). The default fonts in `src/main.zig` are the
maintainer's: the upright and italic faces and the emoji font must
exist, or Rex stops at startup, while missing fallbacks are skipped.
`font_family` replaces only the upright face (a file path); change the
other paths in `src/main.zig` locally.

## Code style

Check each file you touch against this list.

- **One concern per file.** A `//!` header says what the file owns and
  what it must not touch. `term/` never imports `renderer/`.
- **A pure parser.** `vt/` turns bytes into actions and holds no
  terminal state.
- **Typed invariants.** Use enums and distinct types, not magic
  integers.
- **One bounds policy for input.** Clamp counts and positions, cap
  buffers, and never write half a result: a reply or string that does
  not fit is dropped whole.
- **Asserts guard internal invariants only,** never bytes from the
  host or the pty.
- **Comptime for tables and layout only,** with a clear
  `@compileError` when a guard fails.
- **Descriptive names.** A builder that does not allocate is
  `make*`, one that does is `create*`.
- **Doc comments.** Every public function has a `///` stating its
  contract. Comment non-obvious constants and spec quirks, citing a
  public spec (xterm ctlseqs, ECMA-48, VT510). Do not restate the code.
- **Tests next to the code,** named after the spec behaviour they
  check, for example `"mode 45: CUB crosses soft wraps one column
  per step"`.

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
| `zig build fuzz` | every fuzz target's seeds and mutations (see Fuzzing) |
| `-Dslow` | also the slow exhaustive tests (about 25 s) |
| `-Doptimize=ReleaseSafe` | tests in another mode (default Debug) |
| `-Dllvm` | build tests with LLVM instead of the self-hosted backend |
| `-Dcoverage` | run tests under kcov, reports in `kcov-out/<binary>/` (implies `-Dllvm`) |

Example: `zig build test-term -Dtest-filter=combining`.

Every test binary uses `tools/test_runner.zig`, the stock runner with
two changes: a failure prints its error return trace, and each fuzz
input gets a fresh `testing.io`.

## Fuzzing

Fuzz targets live in `src/fuzz/`, one per file:

| Target | Feeds | Checks |
| --- | --- | --- |
| `parser` | random bytes to the VT parser | whole, bytewise and split feeds give the same events and state |
| `terminal` | feed, resize, end, drain and viewport ops to a `Terminal` | invariants on both screens; a twin fed in one chunk shows the same screen |
| `strings` | OSC and DCS with random payloads and terminators | invariants; BEL/ST end in ground; a dropped OSC 0/1/2 keeps the title |
| `utf8` | random bytes to `InputEngine` | output matches a table 3-7 reference decoder |
| `grapheme` | code point sequences | `Breaker` matches a reference UAX #29 segmenter |
| `wcwidth` | code points | `wcwidth` matches the UCD oracle |

`harness.zig` holds the shared `Source` (Smith under `--fuzz`, a
seeded PRNG otherwise) and the mutator; `invariants.zig` holds the
terminal checks: no panic, cursor and margins in bounds, the reply
queue and string buffers within capacity, and the grapheme intern
table under its compaction bound.

Each target runs in three ways:

| Command | Runs |
| --- | --- |
| `zig build test`, `zig build fuzz` | seeds, regressions and 64 seeded mutations per seed, once |
| `zig build fuzz-<name>` | the same for one target |
| `zig build fuzz-<name> -Dllvm --fuzz` | fuzz until stopped, one process per `-j` job, web UI on the printed port |
| `zig build fuzz-<name> -Dllvm --fuzz=<runs>` | fuzz `<runs>` inputs in one process, then print a report |

`--fuzz` needs `-Dllvm`: the self-hosted backend emits no coverage
instrumentation. Example, on four cores until it crashes or you stop
it:

    taskset -c 0-3 zig build fuzz-terminal -Dllvm -j4 --fuzz

A crash fails the step and saves its input to `.zig-cache/f/crash`.
The fuzzer's corpus is kept under `.zig-cache/f/`. Stopping the run
by killing it also reports "terminated with signal KILL; input saved";
that input is not a crash, so replay it before promoting it. To keep
a real crash:

1. Promote it: `scripts/corpus/crash.sh -d src/fuzz/testdata/<target>`.
2. Add `@embedFile("testdata/<target>/crash-<hash>.bin")` to the
   target's `regressions`, so `zig build test` replays it.
3. Write a unit test next to the code that fails for the same reason,
   then fix it.

Inputs in `regressions` are raw fuzzer bytes, replayed as they are.
Seeds are plain byte strings: `harness.fuzz` wraps each one as the
target's first `chunk`, and `harness.seeded` mutates them.

CI fuzzes every target too (`.github/workflows/fuzz.yml`): one
million runs per target on each push and fifty million nightly, with
the corpus cached between runs. A crash fails the job and its input
is uploaded as the `crash-<target>` artifact; promote it as above.

To add a target, create `src/fuzz/<name>.zig` with a `run(*Source)`
function and the two tests (`fuzz <name>` and
`fuzz <name>: seeded mutations`), import it in `src/fuzz/root.zig`,
and add its name to `fuzz_targets` in `build.zig` and to the
matrix in `.github/workflows/fuzz.yml`.

## Generated code

Some tables in `src/` are generated; do not edit them by hand. Each
one starts with a header naming the step that wrote it:

    // GENERATED by zig build gen-<name> from UCD <version>. DO NOT EDIT.

| Step                        | Output                             | Inputs                                                  |
|-----------------------------|------------------------------------|---------------------------------------------------------|
| `zig build gen-wcwidth-table`    | `src/unicode/wcwidth_table.zig`    | `EastAsianWidth.txt`, `UnicodeData.txt`                 |
| `zig build gen-wcwidth-expected` | `src/unicode/wcwidth_expected.zig` | `DerivedGeneralCategory.txt`, `EastAsianWidth.txt`, `emoji-data.txt` |
| `zig build gen-grapheme-table`   | `src/term/grapheme_table.zig`      | `GraphemeBreakProperty.txt`, `emoji-data.txt`           |
| `zig build gen-x11-colors`       | `src/color/x11.zig`                | `tools/x11/rgb.txt`                                     |

`zig build gen` runs all of them.

- Generators live in `tools/gen/`, one file per table, named after
  the step (`gen-grapheme-table` is `tools/gen/grapheme_table.zig`).
  Shared UCD parsing and logging helpers are in `tools/gen/ucd.zig`.
- Every generator is run as `<gen> <out.zig> <input>...` and logs
  each file it reads and writes.
- UCD data lives in `tools/ucd/<version>/`; `tools/ucd/VERSION`
  selects the version build.zig uses.
- The steps are driven by the `generators` table in build.zig; a new
  table is one row there plus one file in `tools/gen/`.

To move to a new Unicode version:

    tools/ucd/fetch.sh 18.0.0
    echo 18.0.0 > tools/ucd/VERSION
    zig build gen
    zig build test -Dslow

Review the diff of the generated tables (and any new
`wcwidth_test.zig` oracle disagreements) before committing.