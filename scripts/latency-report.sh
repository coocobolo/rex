#!/usr/bin/env bash
# Summarizes a latency trace written by a -Dtrace-latency build of Rex
# (src/driver/latency_trace.zig): for each step between two stages and
# for the whole path, the median, p95, p99 and maximum in microseconds.
#
# Usage:
#   latency-report.sh trace.csv
#
# Only keys that reached every stage are summarized; the others are
# counted as unmatched (see "Matching" in latency_trace.zig). Percentiles
# are nearest-rank.
set -Eeuo pipefail

[ $# = 1 ] || { echo "usage: $0 trace.csv" >&2; exit 2; }
csv=$1
header="seq,key,queued,written,echoed,published,picked,drawn,swapped"
[ "$(head -1 "$csv")" = "$header" ] || { echo "error: $csv doesn't start with '$header'" >&2; exit 1; }

total=$(($(wc -l < "$csv") - 1))
complete=$(awk -F, 'NR > 1 { for (i = 2; i <= 9; i++) if ($i == 0) next; n++ } END { print n + 0 }' "$csv")
echo "keys=$total complete=$complete unmatched=$((total - complete))"
[ "$complete" -gt 0 ] || exit 0

# One step: the complete keys' durations from column $1 to column $2, in
# microseconds, sorted, then nearest-rank percentiles.
step() {
    awk -F, -v from="$1" -v to="$2" 'NR > 1 {
        for (i = 2; i <= 9; i++) if ($i == 0) next
        printf "%.1f\n", ($to - $from) / 1000
    }' "$csv" | sort -n | awk -v name="$3" '
        { v[NR] = $1 }
        function rank(p,  r) { r = int(p * NR + 0.999999); if (r < 1) r = 1; return v[r] }
        END { printf "%-21s median %8.1f  p95 %8.1f  p99 %8.1f  max %8.1f us\n", name, rank(0.5), rank(0.95), rank(0.99), v[NR] }'
}

step 2 3 "key -> queued"
step 3 4 "queued -> written"
step 4 5 "written -> echoed"
step 5 6 "echoed -> published"
step 6 7 "published -> picked"
step 7 8 "picked -> drawn"
step 8 9 "drawn -> swapped"
step 2 9 "key -> swapped"
