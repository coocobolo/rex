#!/usr/bin/env bash
# scripts/capture-corpus.sh -- run once, commit the output. Never regenerate in CI.

set -euo pipefail
out=bench/cases/vt/testdata/corpus; mkdir -p "$out"
export TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8

cap() {  # cap <name> <command...>
    local name=$1; shift
    local raw="$out/$name.raw" tm="$out/$name.tm" plan="$out/$name.plan"

    local rc=0
    script --quiet --return --echo=never \
        --log-out="$raw" --log-timing="$tm" \
        --command="stty cols 120 rows 40; $*" || rc=$?

    # 124 is expected for `timeout`; anything else deserves a look.
    [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ] || echo "warn: $name: child exited $rc" >&2
    # Normalize timing, one byte-count per line. Handles classic ("delay count")
    # and advanced ("O delay count") formats; advanced input lines (I) are ignored.

    awk '
        $1 ~ /^[A-Za-z]$/ { if ($1 == "O") print $3; next }
        NF >= 2           { print $2 }
    ' "$tm" | awk '$1 > 0' > "$plan"

    local total hdr
    total=$(awk '{s += $1} END {print s + 0}' "$plan")
    hdr=$(head -n1 "$raw" | wc -c)          # header line incl. newline

    # Keep exactly the child's bytes: skip header, take `total`, drop footer.
    tail -c +$((hdr + 1)) "$raw" | head -c "$total" > "$raw.trim"
    mv "$raw.trim" "$raw"
    rm -f "$tm"

    local got; got=$(wc -c < "$raw")
    [ "$got" -eq "$total" ] || { echo "error: $name: $got bytes != plan $total" >&2; exit 1; }
    printf '%-12s %9d bytes, %6d chunks\n' "$name" "$total" "$(wc -l < "$plan")"
}

cap ls_color  'ls --color=always -laR /usr/share/doc | head -c 1500000'
cap vim_start 'vim -u NONE +qa'
cap htop      'timeout 5 htop'
cap man_bash  'MANPAGER=cat MAN_KEEP_FORMATTING=1 GROFF_SGR=1 man bash'

wc -c "$out"/*.raw