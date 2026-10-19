# Benchmark baseline

- commit: `5ed8961`, zig: 0.16.0
- cpu: AMD Ryzen 3 3300X 4-Core Processor, governor: performance, pinned core: 2
- values are best-of-N `min_ns` per run; compare only on the same machine
- `-` means that case has no such variant

## vt

| case | chunked_4096 | chunked_64 | feed_once | random_1_256 | recorded |
|---|---:|---:|---:|---:|---:|
| dcs_passthrough | 23.33 µs | 33.15 µs | 22.68 µs | 28.02 µs | - |
| htop | 32.37 µs | 41.36 µs | 30.98 µs | 36.14 µs | 32.5 µs |
| ls_color | 521.29 µs | 928.41 µs | 493.6 µs | 792.94 µs | 547.11 µs |
| man_bash | 250.89 µs | 417.78 µs | 244.21 µs | 356.77 µs | 262.2 µs |
| osc_title | 14.25 µs | 20.45 µs | 13.48 µs | 17.58 µs | - |
| plain_ascii_64k | 875 ns | 5.57 µs | 742 ns | 3.6 µs | - |
| plain_lines_64k | 8.35 µs | 18.35 µs | 8.5 µs | 12.66 µs | - |
| plain_text | 196 ns | 1.2 µs | 160 ns | 756 ns | - |
| sgr_normal | 31.42 µs | 41.39 µs | 30.88 µs | 37.11 µs | - |
| sgr_overflow | 48.62 µs | 64.08 µs | 47.63 µs | 56.25 µs | - |

Reproduce: `scripts/perf-bench.sh`, then `scripts/perf-compare.sh perf-results/baseline perf-results/latest/summary.jsonl`.
