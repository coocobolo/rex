#!/usr/bin/env bash

set -euo pipefail

FONT="${1:-$HOME/.local/share/fonts/JetBrainsMono/JetBrainsMonoNerdFont-Regular.ttf}"
OUTPUT="${2:-nerd-glyphs.txt}"
COLS=6

if [[ ! -f "$FONT" ]]; then
    echo "Error: Font not found: $FONT" >&2
    exit 1
fi

command -v fc-query >/dev/null || {
    echo "Error: fc-query is required." >&2
    exit 1
}

CHARSET=$(fc-query --format='%{charset}\n' "$FONT")

{
    echo "Font: $FONT"
    echo "============================================================"
    printf "%-12s %-5s" "CODEPOINT" "GLYPH"

    count=0

    for range in $CHARSET; do
        start="${range%-*}"
        end="${range#*-}"

        [[ "$range" == *-* ]] || end="$start"

        start=$((16#$start))
        end=$((16#$end))

        for ((cp = start; cp <= end; cp++)); do
            (( cp < 0x20 || (cp >= 0x7F && cp <= 0x9F) )) && continue
            (( cp >= 0xD800 && cp <= 0xDFFF )) && continue

            printf -v glyph '\\U%08x' "$cp"

            if (( count % COLS == 0 )); then
                printf "\n"
            fi

            printf "U+%-8X %-5b" "$cp" "$glyph"

            ((count += 1))
        done
    done

    printf "\n\nTotal glyphs: %d\n" "$count"

} | tee "$OUTPUT"

echo "Saved to: $OUTPUT"