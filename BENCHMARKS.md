# Benchmark baseline

- commit: `234161b`, zig: 0.16.0
- cpu: AMD Ryzen 3 3300X 4-Core Processor, governor: performance, pinned core: 2
- values are best-of-N `min_ns` per run; compare only on the same machine
- `-` means that case has no such variant

## vt

| case | chunked_4096 | chunked_64 | feed_once | random_1_256 | recorded |
|---|---:|---:|---:|---:|---:|
| dcs_passthrough | 21.62 µs | 30.29 µs | 20.8 µs | 25.86 µs | - |
| htop | 30.32 µs | 40.11 µs | 29.02 µs | 34.63 µs | 31.21 µs |
| ls_color | 518.48 µs | 901.41 µs | 488.56 µs | 774.8 µs | 540.94 µs |
| man_bash | 252.19 µs | 413.26 µs | 242 µs | 349.39 µs | 256.61 µs |
| osc_title | 12.89 µs | 17.29 µs | 12.79 µs | 15.39 µs | - |
| plain_ascii_64k | 1.22 µs | 6.02 µs | 913 ns | 3.5 µs | - |
| plain_lines_64k | 8.54 µs | 16.89 µs | 8.62 µs | 11.84 µs | - |
| plain_text | 256 ns | 1.29 µs | 209 ns | 736 ns | - |
| sgr_normal | 31.03 µs | 41.61 µs | 30.58 µs | 36.85 µs | - |
| sgr_overflow | 47.01 µs | 66.4 µs | 46.24 µs | 56.66 µs | - |

Reproduce: `scripts/perf-bench.sh`, then `scripts/perf-compare.sh perf-results/baseline perf-results/latest/summary.jsonl`.
