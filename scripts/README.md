# scripts/

Tooling for running, recording and comparing benchmarks. Results live in `perf-results/`; 
the benchmark binary itself is `zig-out/bin/benchmark` (sources in `bench/`).

| script | purpose |
|---|---|
| `perf-bench.sh` | build, run the benchmark, record results, compare against the baseline, `bless` a new baseline |
| `perf-compare.sh` | compare any two `.jsonl` result files |
| `perf-md.sh` | generate a markdown table from a blessed baseline |
| `perf-gui.sh` | measure a running Rex (X11): idle CPU and wakeups, output throughput, memory growth from pastes and font changes |
| `latency-report.sh` | median, p95, p99 and max per stage from a `-Dtrace-latency` trace (`LATENCY_KEYS=N perf-gui.sh` runs one) |

Requirements: `perf`, `zig`, `taskset`, `awk`. `jq` is needed by `perf-compare.sh` and `perf-md.sh`.
`perf-gui.sh` needs an X11 session and `xdotool`, `xclip`, `pidstat`, `bc`, and
`FONT=<variable font file>` (optional; omitted, Rex uses the faces installed
next to the executable, and set, the run names that face;
`FONT_CONF` adds config lines such as fallbacks); it takes over the keyboard
focus while it runs (see the script header).
With `LATENCY_KEYS=N` it only measures input latency, quiet and under output load, with a
`-Dtrace-latency` build; that mode also runs in a Wayland session, with Rex on XWayland.

## Quick start

```bash
scripts/perf-bench.sh                              # full run, prints a delta vs the baseline
PERF_REPEAT=2 scripts/perf-bench.sh --filter htop  # quick look at one case
scripts/perf-bench.sh bless <topic>                # record the latest run as the new baseline
```

## Layout

```
perf-results/
  baselines/<seq>-<sha>-<topic>.jsonl       blessed baselines (committed)
  baselines/<seq>-<sha>-<topic>.meta.json   CPU, governor, zig, git sha (committed)
  baseline -> baselines/<current>           current baseline (committed)
  runs/<ts>_<sha>[-dirty][_<filter>]/       one directory per run (ignored)
    meta.json  timing.N.log  timing.N.jsonl  summary.jsonl
    stat.csv  record.log  perf.data  report.txt
  latest -> runs/<most recent>              (ignored)
```

`.gitignore` should contain:

```
perf-results/runs/
perf-results/latest
perf-results/*.data
```

## Rules

**Runs**
- A run directory is written once and never modified.
- Results are saved only from the clean timing runs, never from `perf stat` or
  `perf record`. `--save` and `--compare` are rejected by `perf-bench.sh`.
- `summary.jsonl` keeps the best `min_ns` per case and variant across the
  repeats. Its `p50` comes from that best run, so treat it as indicative only.
- Differing checksums across repeats mean the benchmark is nondeterministic.
  The script warns; investigate before trusting any timing.
- Only the 3 most recent `perf.data` files are kept (`PERF_KEEP_DATA`).

**Baselines**
- A baseline changes only through `bless`. Never copy over one by hand.
- `bless` refuses partial runs (`--filter`) and dirty trees. `FORCE=1`
  overrides this, but it defeats the guard, so avoid it.
- A name is never reused or overwritten.
- Name format: `<seq>-<sha>-<topic>`. `<seq>` and `<sha>` are filled in
  automatically (the sha is the commit that was measured). `<topic>` is
  lowercase kebab-case, `[a-z0-9-]`, at most 40 characters, for example
  `csi-param-run`.
- Do not put dates, machine names or words like `final` in a topic. Dates are
  in git, and machine details are in `meta.json`.
- Bless only a kept improvement, an accepted regression, or a deliberate reset
  (new machine, new Zig version, renamed cases). Dropped experiments get no
  baseline.

**Comparing**
- Compare only on the same machine, governor and pinned core. The meta file
  records them. On a different machine, bless a new baseline instead.
- `PERF_THRESHOLD` (default 3%) is the line between noise and a change. Rerun
  anything near it before believing it.
- Cases with a baseline under `PERF_MIN_NS` (default 5000 ns) are marked
  `info`. They are too fast to judge.
- `CHECKSUM MISMATCH` means the output changed. Treat it as a correctness
  question before looking at timing.
- `NEW` and `MISSING` rows are listed but do not fail the run, so a filtered
  run compares cleanly against a full baseline.
- Judge the real-traffic cases first: `htop`, `ls_color`, `man_bash`,
  `sgr_normal`. Ignore `feed_byte`, which is only the reference path.

**Case names**
- Saved cases are `<suite>.<case>`, for example `vt.htop`. Console output and
  `--filter` use the bare name.
- Pick suite names before the first bless. Renaming changes every key, so every
  row shows as `NEW` and `MISSING` until you bless again.

## Workflow for a perf change

```bash
git checkout -b perf/<topic>
# edit code, run tests
scripts/perf-bench.sh                 # dirty-tree run, compare against the baseline
```

- Not faster, or a checksum changed: `git checkout -- .`. Nothing is blessed.
- Faster and the checksums match:

```bash
git commit -am "parser: <change>"
scripts/perf-bench.sh                 # clean-tree run, the one that can be blessed
scripts/perf-bench.sh bless <topic>
b=$(ls perf-results/baselines/*.jsonl | tail -1); b=${b%.jsonl}
scripts/perf-md.sh "$b.jsonl" "$b.meta.json"
git add perf-results/baselines perf-results/baseline
git commit -m "perf: bless <topic> (htop -4%, sgr_normal -3%)"
```

The code commit and the baseline commit stay separate. Put the headline deltas
in the baseline commit message; the history of `baselines/` is the performance
changelog.

Do not regenerate the table after a plain run. It documents the blessed
baseline only.

Special cases:
- **Accepted slowdown** (for example a correctness fix): bless it and say so in
  the message, or every later run reports `SLOWER`.
- **Intentional output change:** checksums change. Review the output diff,
  then bless, and say in the message that the output changed.
- **New case or variant:** it shows as `NEW` once. Bless afterwards and the
  table gains the row or column automatically.

## Environment variables

| variable | default | meaning |
|---|---|---|
| `BENCH_CPU` | 2 | core to pin to |
| `PERF_REPEAT` | 5 | clean timing repeats |
| `PERF_STAT_REPEAT` | 3 | `perf stat` repeats |
| `PERF_FREQUENCY` | 2000 | `perf record` rate in Hz |
| `PERF_STACK_SIZE` | 4096 | dwarf stack bytes per sample |
| `PERF_OUTPUT_DIR` | `perf-results` | output directory |
| `PERF_KEEP_DATA` | 3 | number of recent `perf.data` files to keep |
| `PERF_THRESHOLD` | 3 | compare threshold in percent |
| `PERF_MIN_NS` | 5000 | ignore deltas for cases faster than this |
| `PERF_MD_EXCLUDE` | `feed_byte\|\+checksum` | variants `perf-md.sh` hides |
| `PERF_MD_VARIANTS` | (all) | force `perf-md.sh` columns, comma separated |
| `FORCE` | unset | let `bless` accept partial or dirty runs |
| `BENCH_VERBOSE` / `-v` | 0 | print config, commands and live output |
| `BENCH_DEBUG` | 0 | verbose plus `set -x` |