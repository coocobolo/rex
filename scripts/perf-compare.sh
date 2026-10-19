#!/usr/bin/env bash
# Usage: perf-compare.sh <baseline.jsonl> <new.jsonl> [-v]
#   -v  also print rows with no baseline counterpart
set -euo pipefail

old="${1:?usage: perf-compare.sh <baseline> <new> [-v]}"
new="${2:?usage: perf-compare.sh <baseline> <new> [-v]}"
verbose="${3:-}"

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

# Emit "case/variant<TAB>min_ns<TAB>checksum" per row, join on the key.
norm() { jq -r 'select(.case) | "\(.case)/\(.variant)\t\(.min_ns)\t\(.checksum // "-")"' "$1" | sort; }

join -t $'\t' -1 1 -2 1 <(norm "$old") <(norm "$new") |
awk -F'\t' '{
    key=$1; bmin=$2; bchk=$3; nmin=$4; nchk=$5
    if (bchk != "-" && nchk != "-" && bchk != nchk)
        printf "%-45s CHECKSUM CHANGED (%s -> %s)\n", key, bchk, nchk
    else {
        pct = (nmin - bmin) / bmin * 100
        flag = (pct > 3) ? "  <<< slower" : (pct < -3) ? "  <<< faster" : ""
        printf "%-45s %10.0f -> %10.0f ns  %+6.1f%%%s\n", key, bmin, nmin, pct, flag
    }
}'

if [[ "$verbose" == "-v" ]]; then
    join -t $'\t' -j1 -v2 <(norm "$old") <(norm "$new") \
    | awk -F'\t' '{printf "%-45s (new) %10.0f ns\n", $1, $2}'
    join -t $'\t' -j1 -v1 <(norm "$old") <(norm "$new") \
    | awk -F'\t' '{printf "%-45s (missing) %10.0f ns\n", $1, $2}'
fi