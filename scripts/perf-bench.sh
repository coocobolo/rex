#!/usr/bin/env bash

# Usage:
#   perf-bench.sh [-v|--verbose] [--filter <f>] [benchmark args...]
#   perf-bench.sh bless <topic>
#
# Layout:
#   perf-results/
#     baselines/<name>.jsonl     blessed baselines (commit these, read-only)
#     runs/<ts>_<sha>[-dirty][_<filter>]/
#       meta.json  timing.N.log  timing.N.jsonl  summary.jsonl
#       stat.csv  record.log  perf.data  report.txt
#     baseline -> baselines/<current>
#     latest   -> runs/<most recent>
#
# NOTE! --save/--compare are NOT accepted: the script owns them. Results are saved
# only from the clean timing runs, never from perf-instrumented runs, and each
# run directory is written once. A baseline changes only through `bless`.
#
# Environment:
#   BENCH_CPU         core to pin to (default 2)
#   PERF_REPEAT       clean timing repeats (default 5)
#   PERF_STAT_REPEAT  perf stat repeats (default 3)
#   PERF_FREQUENCY    perf record rate in Hz (default 2000)
#   PERF_STACK_SIZE   dwarf stack bytes per sample (default 4096)
#   PERF_OUTPUT_DIR   output directory (default perf-results)
#   PERF_KEEP_DATA    number of recent perf.data files to keep (default 3)
#   PERF_THRESHOLD    compare threshold in percent (default 3)
#   PERF_MIN_NS       ignore deltas for cases faster than this (default 5000)
#   FORCE=1           let `bless` accept partial or dirty runs
#   BENCH_VERBOSE=1   same as -v
#   BENCH_DEBUG=1     implies verbose and turns on `set -x`

set -Eeuo pipefail

cpu="${BENCH_CPU:-2}"
repeat="${PERF_REPEAT:-5}"
stat_repeat="${PERF_STAT_REPEAT:-3}"
frequency="${PERF_FREQUENCY:-2000}"
stack_size="${PERF_STACK_SIZE:-4096}"
output_dir="${PERF_OUTPUT_DIR:-perf-results}"
keep_data="${PERF_KEEP_DATA:-3}"
threshold="${PERF_THRESHOLD:-3}"
min_ns="${PERF_MIN_NS:-5000}"

verbose="${BENCH_VERBOSE:-0}"
if [ "${1:-}" = -v ] || [ "${1:-}" = --verbose ]; then verbose=1; shift; fi
if [ "${BENCH_DEBUG:-0}" = 1 ]; then verbose=1; set -x; fi

# Logging

start=$SECONDS
stage_no=0
stage_start=$SECONDS
stages=6

ts()   { printf '[%4ds]' "$((SECONDS - start))"; }
log()  { printf '%s %s\n' "$(ts)" "$*" >&2; }
vlog() { if [ "$verbose" = 1 ]; then log "$@"; fi; }
warn() { printf '%s warn: %s\n' "$(ts)" "$*" >&2; }
die()  { printf '%s error: %s\n' "$(ts)" "$*" >&2; exit 1; }

stage() {
    stage_no=$((stage_no + 1))
    stage_start=$SECONDS
    log "[$stage_no/$stages] $*"
}
stage_done() { log "      done in $((SECONDS - stage_start))s"; }

on_err() {
    local rc=$?
    printf '%s error: line %s: `%s` (exit %s)\n' "$(ts)" "$1" "$BASH_COMMAND" "$rc" >&2
}
trap 'on_err $LINENO' ERR

# run_logged <logfile> <cmd...>
# Output goes to <logfile>; in verbose mode it is also shown live. On failure
# in quiet mode, the tail of the log is printed so the error isn't swallowed.
run_logged() {
    local logfile=$1
    shift
    vlog "\$ $*"
    if [ "$verbose" = 1 ]; then
        "$@" 2>&1 | tee "$logfile" >&2
    elif ! "$@" >"$logfile" 2>&1; then
        warn "command failed; last lines of $logfile:"
        tail -n 20 "$logfile" >&2
        return 1
    fi
}

sys="/sys/devices/system/cpu"
sys_val() { cat "$1" 2>/dev/null || true; }
cpu_khz() { sys_val "$sys/cpu$cpu/cpufreq/scaling_cur_freq"; }

# Subcommand: bless (must run before argument parsing)

if [ "${1:-}" = bless ]; then
    topic="${2:?usage: perf-bench.sh bless <topic>   (blesses ./latest)}"

    # topic rule: lowercase kebab, so the final name is filename-safe
    [[ "$topic" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] ||
        die "bad topic '$topic': use [a-z0-9-], max 40 chars, start with a letter or digit"

    latest="$output_dir/latest"
    [ -L "$latest" ] || die "no run to bless ($latest missing)"
    run="$(readlink -f "$latest")"
    src="$run/summary.jsonl"
    meta="$run/meta.json"
    [ -s "$src" ]  || die "$src missing or empty"
    [ -f "$meta" ] || die "$meta missing"

    if grep -q '"filtered": true' "$meta" && [ -z "${FORCE:-}" ]; then
        die "latest run is partial (--filter); FORCE=1 to override"
    fi
    if grep -q '"dirty": true' "$meta" && [ -z "${FORCE:-}" ]; then
        die "latest run was on a dirty tree; commit first or FORCE=1"
    fi

    # sha comes from the run itself, so it matches the measured commit
    sha=$(sed -n 's/.*"git": *"\([^"]*\)".*/\1/p' "$meta" | head -n 1)
    [ -n "$sha" ] || die "could not read git sha from $meta"

    # next sequence number from existing baselines (empty dir => 0001)
    last=$(ls "$output_dir/baselines" 2>/dev/null | grep -oE '^[0-9]+' | sort -n | tail -n 1 || true)
    seq=$(printf '%04d' $((10#${last:-0} + 1)))
    name="$seq-$sha-$topic"

    dst="$output_dir/baselines/$name.jsonl"
    [ -e "$dst" ] && die "baseline $name already exists (delete it manually to replace it)"

    mkdir -p "$output_dir/baselines"
    cp "$src"  "$dst"
    cp "$meta" "$output_dir/baselines/$name.meta.json"
    chmod 444 "$dst" "$output_dir/baselines/$name.meta.json"
    ln -sfn "baselines/$name.jsonl" "$output_dir/baseline"
    log "blessed $dst; baseline is set to $name"
    exit 0
fi

# Arguments

filter=""
bench_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --filter)   filter="${2:?--filter needs a value}"; shift 2 ;;
        --filter=*) filter="${1#*=}"; shift ;;
        --save|--save=*|--compare|--compare=*|--bless)
            die "$1 is owned by this script; use: perf-bench.sh bless <name>" ;;
        *) bench_args+=("$1"); shift ;;
    esac
done
if [ -n "$filter" ]; then bench_args+=(--filter "$filter"); fi

# Preflight (warn only, except for missing tools)

command -v perf >/dev/null || die "perf not found in PATH"
command -v zig  >/dev/null || die "zig not found in PATH"

if ! taskset --cpu-list "$cpu" true 2>/dev/null; then
    echo "available CPUs: $(taskset --cpu-list --pid $$)" >&2
    die "invalid or unavailable CPU list: $cpu"
fi

gov=$(sys_val "$sys/cpu$cpu/cpufreq/scaling_governor")
if [ -n "$gov" ] && [ "$gov" != performance ]; then
    warn "governor on cpu$cpu is $gov, not performance"
fi
if [ "$(sys_val "$sys/intel_pstate/no_turbo")" = 0 ]; then warn "turbo enabled"; fi
if [ "$(sys_val "$sys/cpufreq/boost")" = 1 ]; then warn "boost enabled"; fi

paranoid=$(sys_val /proc/sys/kernel/perf_event_paranoid)
vlog "cpu:                 $cpu (governor: ${gov:-unknown}, now: $(cpu_khz) kHz)"
vlog "smt siblings:        $(sys_val "$sys/cpu$cpu/topology/thread_siblings_list")"
vlog "perf_event_paranoid: ${paranoid:-unknown}"
vlog "repeat=$repeat stat_repeat=$stat_repeat frequency=${frequency}Hz stack=$stack_size"
vlog "benchmark args:      ${bench_args[*]:-(none)}"

# Build (before creating the run directory, so a failed build leaves nothing)

stage "building (ReleaseFast, native cpu)"
summary_mode=failures
if [ "$verbose" = 1 ]; then summary_mode=all; fi
# The `benchmark` step installs zig-out/bin/benchmark; a plain `zig build`
# does not (see -Dinstall-bench in build.zig).
zig build benchmark -Doptimize=ReleaseFast -Dcpu=native --summary "$summary_mode"
stage_done

binary="$PWD/zig-out/bin/benchmark"
[ -x "$binary" ] || die "$binary not found"

bench() { taskset --cpu-list "$cpu" "$binary" "$@"; }

# Run directory (write-once)

git_sha=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
git_dirty=""
if ! git diff --quiet HEAD -- 2>/dev/null; then git_dirty="-dirty"; fi

safe_filter="${filter//[^A-Za-z0-9._-]/_}"
run_name="$(date +%Y%m%dT%H%M%S)_${git_sha}${git_dirty}${safe_filter:+_$safe_filter}"
run_dir="$output_dir/runs/$run_name"
mkdir -p "$run_dir"

cpu_model=$(lscpu 2>/dev/null | awk -F: '/Model name/{sub(/^ +/,"",$2); print $2; exit}')
cat >"$run_dir/meta.json" <<EOF
{
  "git": "$git_sha",
  "dirty": $([ -n "$git_dirty" ] && echo true || echo false),
  "filtered": $([ -n "$filter" ] && echo true || echo false),
  "cpu": "$cpu_model",
  "governor": "${gov:-unknown}",
  "pinned_cpu": $cpu,
  "zig": "$(zig version 2>/dev/null || echo unknown)",
  "args": "${bench_args[*]:-}",
  "date": "$(date -Iseconds)"
}
EOF

# Clean timing runs (no perf attached). These are the numbers to trust.

stage "timing runs x$repeat (no perf attached)"
for i in $(seq "$repeat"); do
    tlog="$run_dir/timing.$i.log"
    tjson="$run_dir/timing.$i.jsonl"
    log "      run $i/$repeat (cpu$cpu @ $(cpu_khz) kHz before)"
    run_logged "$tlog" bench "${bench_args[@]}" --save "$tjson"
    [ -s "$tjson" ] || die "run $i produced no results ($tjson empty); see $tlog"
    log "      run $i/$repeat finished, $(grep -c '"case"' "$tjson" || true) result rows"
    if grep -q '^!!' "$tlog"; then
        warn "checksum mismatch in run $i, see $tlog:"
        grep '^!!' "$tlog" >&2
    fi
done
stage_done

# Aggregate: best min_ns per case/variant across repeats

stage "aggregating timing runs (summary.jsonl)"
# The kept row is the one from the best run, so its p50 belongs to that run;
# treat p50 as indicative only. Differing checksums across repeats mean the
# benchmark is nondeterministic, which is reported on stderr.
awk '
    !/"case":/ { next }
    {
        match($0, /"case":"[^"]*","variant":"[^"]*"/)
        key = substr($0, RSTART, RLENGTH)
        match($0, /"min_ns":[0-9]+/)
        mn = substr($0, RSTART + 9, RLENGTH - 9) + 0
        match($0, /"checksum":"[^"]*"/)
        ck = substr($0, RSTART, RLENGTH)
        if (key in chk && chk[key] != ck) bad[key] = 1
        chk[key] = ck
        if (!(key in best) || mn < best[key]) { best[key] = mn; line[key] = $0 }
    }
    END {
        for (k in line) print line[k]
        for (k in bad) print "!! checksum differs across repeats: " k > "/dev/stderr"
    }
' "$run_dir"/timing.*.jsonl | sort >"$run_dir/summary.jsonl"
[ -s "$run_dir/summary.jsonl" ] || die "aggregation produced no rows"
log "      $(wc -l <"$run_dir/summary.jsonl") results"

# Point `latest` at this run as soon as its summary exists, so a later perf
# failure cannot leave it stale.
ln -sfn "runs/$run_name" "$output_dir/latest"
stage_done

# Compare against the blessed baseline (key intersection only)

compare() {
    local base=$1 new=$2
    awk -v thr="$threshold" -v floor="$min_ns" '
        function parse(l) {
            if (!match(l, /"case":"[^"]*"/)) return 0
            c = substr(l, RSTART + 8, RLENGTH - 9)
            match(l, /"variant":"[^"]*"/)
            v = substr(l, RSTART + 11, RLENGTH - 12)
            match(l, /"min_ns":[0-9]+/)
            MN = substr(l, RSTART + 9, RLENGTH - 9) + 0
            match(l, /"checksum":"[^"]*"/)
            CK = substr(l, RSTART + 12, RLENGTH - 13)
            K = c "/" v
            return 1
        }
        NR == FNR { if (parse($0)) { bmn[K] = MN; bck[K] = CK }; next }
        parse($0) {
            seen[K] = 1
            if (!(K in bmn)) { printf "%s\tNEW\n", K; next }
            if (CK != bck[K]) { printf "%s\t!! CHECKSUM MISMATCH\n", K; next }
            d = (MN - bmn[K]) / bmn[K] * 100
            if (bmn[K] < floor)      tag = "info (too fast to judge)"
            else if (d > -thr && d < thr) tag = "~"
            else if (d < 0)          tag = "faster"
            else                     tag = "SLOWER"
            printf "%s\t%+.1f%%\t%s\n", K, d, tag
        }
        END { for (k in bmn) if (!(k in seen)) printf "%s\tMISSING\n", k }
    ' "$base" "$new" | sort
}

base="$output_dir/baseline"
if [ -e "$base" ]; then
    log "compare vs $(readlink "$base") (min_ns, threshold ${threshold}%):"
    if command -v column >/dev/null; then
        compare "$base" "$run_dir/summary.jsonl" | column -t -s$'\t' >&2
    else
        compare "$base" "$run_dir/summary.jsonl" >&2
    fi
else
    log "no baseline yet; after a clean full run: perf-bench.sh bless <topic>"
fi

# perf stat (recorded only, never saved as timing)

stage "perf stat ($stat_repeat runs)"
run_logged "$run_dir/stat.log" \
    perf stat -r "$stat_repeat" -x, -o "$run_dir/stat.csv" \
    --event cycles:u,instructions:u,branches:u,branch-misses:u,cache-misses:u \
    -- taskset --cpu-list "$cpu" "$binary" "${bench_args[@]}"
stage_done

# perf record

stage "perf record (${frequency} Hz, dwarf,$stack_size)"
run_logged "$run_dir/record.log" \
    perf record --output "$run_dir/perf.data" \
    --freq "$frequency" --event cycles:u \
    --call-graph "dwarf,$stack_size" \
    -- taskset --cpu-list "$cpu" "$binary" "${bench_args[@]}"
log "      data file: $(du -h "$run_dir/perf.data" | cut -f1)"
stage_done

# perf report + prune old perf.data (small files always stay)

stage "perf report + prune"
if ! perf report --input "$run_dir/perf.data" \
    --stdio --children --inline >"$run_dir/report.txt" 2>"$run_dir/report.log"; then
    tail -n 20 "$run_dir/report.log" >&2
    die "perf report failed (full log: $run_dir/report.log)"
fi

find "$output_dir/runs" -name perf.data -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | tail -n +$((keep_data + 1)) | cut -d' ' -f2- \
    | while read -r f; do rm -f "$f"; vlog "pruned $f"; done
stage_done

# Summary

log "Done in $((SECONDS - start))s"
log "run:     $run_dir"
log "summary: $run_dir/summary.jsonl"
log "report:  $run_dir/report.txt"
log "bless:   scripts/perf-bench.sh bless <name>"
log "compare: scripts/perf-compare.sh perf-results/baseline $run_dir/summary.jsonl"  
log "one row: grep -hF '\"case\":\"<case>\",\"variant\":\"<variant>\"' perf-results/baseline perf-results/latest/summary.jsonl"