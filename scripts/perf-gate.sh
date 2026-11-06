#!/usr/bin/env bash
# scripts/perf-gate.sh <case> [max_pct=15]   exit 0 good, 1 bad, 125 skip

set -uo pipefail

case_=${1:?}; max=${2:-15}
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT

# The `benchmark` step installs zig-out/bin/benchmark; a plain `zig build`
# does not, and a bisect would then time a stale binary.
zig build benchmark -Doptimize=ReleaseFast -Dcpu=native >/dev/null 2>&1 || exit 125

for _ in 1 2 3; do
  taskset --cpu-list "${BENCH_CPU:-2}" zig-out/bin/benchmark --filter "$case_" --save "$tmp.$_" >/dev/null 2>&1 || exit 125
done

cat "$tmp".? > "$tmp"
scripts/perf-compare.sh perf-results/baseline "$tmp" | awk -v c="$case_" -v m="$max" '
  $1 ~ ("\\." c "/feed_byte$") || $1 ~ ("^" c "/feed_byte$") { gsub(/%/,"",$(NF-1)); if ($(NF-1)+0 > m) bad=1 }
  END { exit bad }'