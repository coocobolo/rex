# OSC 8 hyperlinks: terminal benchmark A/B (2026-11-20)

Comparison of `develop` at `6d73788` (before OSC 8) with the hyperlink branch
at `83495b0`. Both trees were built from scratch with `-Dcpu=native`,
`-Doptimize=ReleaseFast` and `-j2`, and every run was pinned to CPU 2 with
`taskset -c 2`.

## Environment

| | |
|---|---|
| CPU | AMD Ryzen 3 3300X, governor `performance`, boost enabled (~4.6 GHz observed) |
| Other load | two unrelated long-running `rex` processes on cores 1 and 4, browser on core 6 |
| Zig | 0.16.0 |
| Benchmark | `zig build -j2 bench-term -Doptimize=ReleaseFast -Dcpu=native -- --suite term --samples 3` |

## Method

An initial non-interleaved run showed ~55% slower `term` cases in the new
tree with identical checksums. Re-running the *old* tree alone produced a
further ~56% slowdown for the same case, so that result was discarded as
environmental drift, not a property of the change.

The result below uses three interleaved pairs (old, new, old, new, …). Each
cell is the median of the three run means per tree. Checksums matched for all
34 cases in every run, so the workloads were identical.

## Result

| Metric across 34 `term` cases | Value |
|---|---|
| Median of per-case deltas | **+2.1%** |
| Range | **−9.1% to +17.2%** |

Largest absolute deltas (old → new, ns/op):

| Case | Before | After | Delta |
|---|---:|---:|---:|
| `reflow/cjk_mixed/height` | 722 | 846 | +17.2% |
| `reflow/cjk_mixed/drag` | 34,846,832 | 40,483,696 | +16.2% |
| `reflow/long_lines/height` | 726 | 821 | +13.1% |
| `reflow/long_lines/drag` | 29,278,130 | 32,485,166 | +11.0% |
| `corpus/ls_color/recorded` | 2,340,497 | 2,595,147 | +10.9% |
| `corpus/man_bash/feed_once` | 924,266 | 839,978 | −9.1% |

Scroll cases and small zero-row cases were within roughly ±5%.

## Interpretation

The new tree adds `link` and padding to each interned `Style` (12 → 16
bytes), a 1024-entry URL table per screen, and per-frame URI copies. The
reflow-heavy cases are the most memory-bound, which matches the largest
deltas being in `reflow/cjk_mixed` and `reflow/long_lines`. A 2.1% median cost
and up to 17% on the worst reflow case is a real but bounded regression; the
negative `man_bash` delta is within run-to-run noise on this host.

## After packing the link ID

The maintainer chose to pack the link ID into the unused high bits of the
three 32-bit color keys instead of growing `Style` from 12 to 16 bytes. The
same interleaved protocol was repeated with three trees: pre-change `develop`,
the un-packed hyperlink branch (`737787d`), and the packed branch. All 34
`term` cases were compared again with matching checksums.

| Tree | Median delta vs `develop` | Worst case |
|---|---:|---:|
| Un-packed | +0.30% | +29.8% |
| Packed | +0.34% | +19.7% |

Packed versus un-packed directly: median **−0.21%** (18 cases faster, 16
slower), largest gain **−7.8%** on `reflow/long_lines/drag`. The largest
remaining delta is still in CJK/long-line reflow but is about 10 points
smaller than before packing. The median is unchanged within noise; packing
buys back the style-table memory without a clear average speed-up.

ReleaseFast was used throughout, as required for meaningful numbers. Real
fuzzing and multi-minute GUI benchmarks were not run.
