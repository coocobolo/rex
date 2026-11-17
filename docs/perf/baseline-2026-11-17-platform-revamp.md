# GLFW-build baseline for the platform revamp (2026-11-17)

Reference numbers for A/B judgement while replacing the window/platform backend
(ADR 0011). Measured on `develop` at `9a89251`, ReleaseFast. The run labels say
`9a89251-dirty` because an ADR status line was edited in the working tree; no
source or build file differs from that commit.

**These numbers are a within-harness reference, not a replacement for
`baseline-2026-11.md`.** The old baseline ran on a real X11 desktop with the
NVIDIA driver; this one runs on a private Xvfb with Mesa software GL, so absolute
values (idle CPU, throughput, RSS) are not comparable across the two pages.
Compare later revamp measurements only against this page, with the same harness.

## Environment and commands

| | |
|---|---|
| CPU | AMD Ryzen 3 3300X, governor `performance`, pinned to CPU 2 for all benchmark runs |
| GPU path | Mesa software renderer (`glx_vendor=libGLX_mesa`), private Xvfb `:99`, 1600x1000x24 |
| Display harness | bare Xvfb, no window manager; `xdotool windowactivate` mapped to `windowfocus` through a local shim, as in the documented bare-Xvfb recipe |
| Zig | 0.16.0 |
| OS | Ubuntu 24.04 |

```sh
scripts/perf-bench.sh                                  # ReleaseFast, native cpu, 5 timing repeats
DISPLAY=:99 XDG_SESSION_TYPE=x11 \
  scripts/perf-gui.sh ReleaseFast                      # default recipe, private Xvfb
```

`perf-bench.sh` also ran `perf stat` (3 repeats) and `perf record` (2000 Hz);
only its clean timing runs are the numbers below. Raw run data is in
`perf-results/runs/` (ignored); all 83 aggregate rows are preserved in
`baseline-2026-11-17-platform-revamp.jsonl` next to this file. No input-latency
trace was run (`LATENCY_KEYS` was not set).

## Parser and terminal benchmarks

ReleaseFast, 91-case suite was 83 cases at this commit (families: `vt` parser and
`term` corpus, reflow, scroll, zero-row). `min_ns` is the best of five clean
repeats per case/variant; `p50_ns` comes from that best run and is indicative.

| Case / variant | min_ns |
|---|---|
| `term.corpus.htop / feed_once` | 76,130 |
| `term.corpus.htop / recorded` | 79,289 |
| `term.corpus.ls_color / feed_once` | 2,361,522 |
| `term.reflow.prompt_only / zoom` | 12,231 |
| `term.reflow.prompt_only / drag` | 231,023 |
| `term.reflow.long_lines / zoom` | 1,969,076 |
| `term.scroll / primary/full` | 16 |
| `vt.plain_text / feed_once` | see companion JSONL |

The full table, with `p50_ns`, `stddev_ns`, `drift` and checksums, is in
`baseline-2026-11-17-platform-revamp.jsonl`. The script's comparison against the
older blessed baseline is not meaningful for this page (different commit and
harness) and is not reported here.

## Running application (ReleaseFast)

`perf-gui.sh` uses a sandbox `HOME` with a `cat` sink as Rex's child; no shell or
user config is involved. Default parameters: 60 s idle, 20 pastes of 1 MiB,
10 cycles of 5 font steps up and down (100 changes), then a separate throughput
instance with 100 MiB files.

| Metric | Value |
|---|---|
| RSS at start | 206,944 KiB |
| Idle CPU (60 s average) | 5.50% |
| Idle context switches | 18.57/s voluntary, 3.88/s involuntary |
| 20 pastes of 1 MiB | RSS +3,016 KiB; `paste_write_errors=0` |
| 100 font changes | RSS +64 KiB (one-time warmup), 100 changes logged |
| Throughput, plain | 47.5 / 59.5 / 66.8 MiB/s (3 runs) |
| Throughput, escapes | 53.3 / 51.8 / 57.1 MiB/s (3 runs) |
| Exit | `rex_exit=killed` (`CLEAN_EXIT` is off by default); sink did not survive Rex |

Notes for later A/B runs:

- Idle CPU is much higher than the 2026-11 page's 0.05%. That page measured a real
  display and GPU; this one measures software GL under Xvfb. Do not read it as a
  regression.
- `paste_write_errors=0` here, while the 2026-11 page recorded all pastes as
  truncated (`WouldBlock`). Code between those commits added an outbound write
  queue; this page records the current behaviour, not an explanation of it.
- To be a valid comparison, a later run must use the same Xvfb size, the same
  `windowfocus` shim, the same mode (ReleaseFast) and the same script defaults.
