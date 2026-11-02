#!/usr/bin/env bash
set -eu

zig version

zig build bench \
    -Doptimize=ReleaseFast \
    -Dstrip=false \
    -summary all