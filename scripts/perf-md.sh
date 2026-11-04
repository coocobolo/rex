#!/usr/bin/env bash
# scripts/perf-md.sh <baselines/name.jsonl> <baselines/name.meta.json> > .ideas/BENCHMARKS.md
#
# Env:
#   PERF_MD_EXCLUDE   regex of variants to hide (default: feed_byte|\+checksum)
#   PERF_MD_VARIANTS  comma list to force column order/subset
set -euo pipefail
export LC_ALL=C

base=${1:?usage: perf-md.sh <baseline.jsonl> <meta.json>}
meta=${2:?usage: perf-md.sh <baseline.jsonl> <meta.json>}
exclude=${PERF_MD_EXCLUDE:-'feed_byte|\+checksum'}
force=${PERF_MD_VARIANTS:-}

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

echo "# Benchmark baseline"
echo
echo "- commit: \`$(jq -r .git "$meta")\`, zig: $(jq -r .zig "$meta")"
echo "- cpu: $(jq -r .cpu "$meta"), governor: $(jq -r .governor "$meta"), pinned core: $(jq -r .pinned_cpu "$meta")"
echo "- values are best-of-N \`min_ns\` per run; compare only on the same machine"
echo "- \`-\` means that case has no such variant"

jq -rs --arg excl "$exclude" --arg force "$force" '
  def uniq_ordered: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);
  def fmt:
    if . == null then "-"
    elif . >= 1000000 then "\((. / 10000 | round) / 100) ms"
    elif . >= 1000    then "\((. / 10 | round) / 100) µs"
    else "\(.) ns" end;

  map(select(.case))
  | map(select(.variant | test($excl) | not))
  | map(. + (if (.case | contains("."))
             then {suite: (.case | split(".")[0]),
                   name:  (.case | split(".")[1:] | join("."))}
             else {suite: "all", name: .case} end)) as $all
  | ($all | map(.suite) | uniq_ordered)[] as $s
  | ($all | map(select(.suite == $s))) as $rows
  | ($rows | map({key: "\(.name)/\(.variant)", value: .min_ns}) | from_entries) as $m
  | ($rows | map(.name) | uniq_ordered) as $cases
  | (if $force != "" then ($force | split(","))
     else ($rows | map(.variant) | uniq_ordered) end) as $variants
  | "",
    "## \($s)",
    "",
    "| case | " + ($variants | join(" | ")) + " |",
    "|---|" + ($variants | map("---:") | join("|")) + "|",
    ($cases[] as $c
      | "| \($c) | " + ($variants | map($m["\($c)/\(.)"] | fmt) | join(" | ")) + " |")
' "$base"

echo
echo "Reproduce: \`scripts/perf-bench.sh\`, then \`scripts/perf-compare.sh perf-results/baseline perf-results/latest/summary.jsonl\`."