#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Promote Zig fuzz crash files into a persistent testdata directory.

Options:
  -s, --source PATH   Crash file or directory (default: .zig-cache/f/crash)
  -d, --dest PATH     Destination directory   (default: testdata/wcwidth)
  -p, --prefix NAME   Output filename prefix  (default: crash)
  -h, --help          Show this help

Examples:
  $0
  $0 --dest testdata/wcwidth
  $0 --source .zig-cache/f/crash --dest testdata/foo
  $0 -s /tmp/crashes -d testdata/bar -p fuzz
EOF
}

source=".zig-cache/f/crash"
dest="testdata/"
prefix="crash"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--source)
            source="$2"
            shift 2
            ;;
        -d|--dest)
            dest="$2"
            shift 2
            ;;
        -p|--prefix)
            prefix="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

mkdir -p "$dest"

save_crash() {
    local src="$1"
    local hash
    local dst

    hash="$(sha256sum "$src" | awk '{print substr($1, 1, 16)}')"
    dst="$dest/${prefix}-${hash}.bin"

    if [[ ! -e "$dst" ]]; then
        cp -- "$src" "$dst"
        printf 'saved %s -> %s\n' "$src" "$dst"
    else
        printf 'already present: %s\n' "$dst"
    fi
}

if [[ -f "$source" ]]; then
    save_crash "$source"
elif [[ -d "$source" ]]; then
    while IFS= read -r -d '' src; do
        save_crash "$src"
    done < <(find "$source" -type f -print0)
else
    echo "error: source does not exist: $source" >&2
    exit 1
fi