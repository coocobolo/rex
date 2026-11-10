#!/usr/bin/env bash
# Measures a running Rex: idle CPU and wakeups, end-to-end output
# throughput, and memory growth from pastes and font-size changes.
#
# Usage:
#   perf-gui.sh [ReleaseSafe|ReleaseFast|Debug]      (default ReleaseSafe)
#
# Debug builds check the allocator: with CLEAN_EXIT=1 Rex exits normally
# and reports leaks and invalid frees in its log, summarized at the end.
#
# Needs an X11 session and: xdotool, xclip, pidstat, bc, base64.
#
# Rex windows open on the current display and receive Rex's own
# shortcuts as synthetic key presses (paste, font size), so don't touch
# the keyboard, mouse or clipboard while it runs.
#
# Safety. Nothing is ever typed into a shell. Each Rex runs with its own
# temporary HOME, so neither Rex nor bash reads or writes the user's
# config, history or Rex state. That HOME's .bashrc replaces the shell
# with `cat > /dev/null` before any prompt appears, and the script checks
# in /proc that Rex's child really is that `cat` before it sends any key;
# pasted data can therefore never reach a shell. The clipboard is saved
# and restored, and every window this script opens is closed on exit.
#
# Environment:
#   FONT           optional variable font file. Set, the sandbox config sets
#                  `[font] file` to it. Omitted, Rex uses the faces installed
#                  next to the executable
#   FONT_CONF      a config fragment appended to the sandbox config, such as
#                  `[font]` fallback lines; its keys override the defaults.
#                  Results are comparable only between runs with the same
#                  FONT and FONT_CONF (fonts change startup time and memory)
#   IDLE_SECONDS   idle sampling time (default 60)
#   PASTES         number of pastes (default 20)
#   PASTE_KIB      size of each paste in KiB (default 1024)
#   FONT_CYCLES    font cycles; each is 5 steps up and 5 down (default 10)
#   FONT_SAMPLE_EVERY  record RSS after every N font cycles (default 0, off)
#   PASTE_VERIFY   1: the sink writes to a file instead of /dev/null, and the
#                  pasted bytes are checked against the expected data
#   RELOADS        config reloads (SIGHUP) after the font changes (default 0)
#   CLEAN_EXIT     1: end each Rex by ending its child, so it exits normally
#                  and runs its cleanup, instead of being killed (default 0)
#   SKIP_THROUGHPUT 1: skip the throughput instance (default 0)
#   LATENCY_KEYS   N > 0: run only the input latency measurement, N keys per
#                  scenario, with a -Dtrace-latency build (default 0, off)
#   LATENCY_INTERVAL_MS  pause between keys (default 50); longer than one
#                  round trip, since the trace matches one key in flight
#   LATENCY_LOAD   1: also measure while output streams into the terminal
#                  (default 1)
#
# Latency mode. Rex's child is the same `cat` sink, with the tty in
# canonical mode and echo on, so the kernel echoes each typed key and no
# shell takes part in the round trip. Keys go out in batches of 15 `a`
# and a Return (which ends the kernel's line before its 4095-byte limit),
# and the script checks before each batch that Rex's window has the
# keyboard focus. Rex is always ended through its child so it exits
# normally and writes its trace. In a Wayland session Rex runs on X11
# through XWayland, so that path is what gets measured. Under load the
# first pty read after a key is usually program output rather than the
# echo, so "echoed" there means "first output after the key" and the
# result is a lower bound for the key's own echo.
#
# Output: perf-results/runs/gui-<ts>_<sha>[-dirty]_<mode>/
#   result.txt   the numbers below
#   rex-*.log    Rex's own log for each instance
set -Eeuo pipefail

mode="${1:-ReleaseSafe}"
case "$mode" in ReleaseSafe | ReleaseFast | Debug) ;; *) echo "usage: $0 [ReleaseSafe|ReleaseFast|Debug]" >&2; exit 2 ;; esac

idle_seconds="${IDLE_SECONDS:-60}"
pastes="${PASTES:-20}"
paste_kib="${PASTE_KIB:-1024}"
font_cycles="${FONT_CYCLES:-10}"
font_sample_every="${FONT_SAMPLE_EVERY:-0}"
paste_verify="${PASTE_VERIFY:-0}"
reloads="${RELOADS:-0}"
clean_exit="${CLEAN_EXIT:-0}"
skip_throughput="${SKIP_THROUGHPUT:-0}"
latency_keys="${LATENCY_KEYS:-0}"
latency_interval_ms="${LATENCY_INTERVAL_MS:-50}"
latency_load="${LATENCY_LOAD:-1}"

die() { echo "error: $*" >&2; exit 1; }

font="${FONT:-}"
font_conf="${FONT_CONF:-}"
if [ -n "$font" ]; then
    [ -f "$font" ] || die "FONT: no such file: $font"
fi
[ -z "$font_conf" ] || [ -f "$font_conf" ] || die "FONT_CONF: no such file: $font_conf"

# Latency mode also runs in a Wayland session, with Rex on XWayland.
platform=x11
case "${XDG_SESSION_TYPE:-}" in
x11) ;;
wayland) [ "$latency_keys" -gt 0 ] && platform=xwayland || die "needs an X11 session; only LATENCY_KEYS runs under Wayland (on XWayland)" ;;
*) die "needs an X11 session (XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unset})" ;;
esac

# One run at a time, across all checkouts: two runs would fight over the
# keyboard focus and the CPU, and both would report wrong numbers.
exec 9> "${XDG_RUNTIME_DIR:-/tmp}/rex-perf-gui.lock"
flock -n 9 || die "another perf-gui.sh run is active"

for tool in xdotool xclip pidstat bc base64 flock; do
    command -v "$tool" >/dev/null || die "missing $tool"
done

cd "$(git rev-parse --show-toplevel)"
sha=$(git rev-parse --short HEAD)
git diff --quiet HEAD -- || sha="$sha-dirty"
out="$PWD/perf-results/runs/gui-$(date +%Y%m%dT%H%M%S)_${sha}_${mode}"
data=".bench/gui-data"
prefix=".bench/gui-$mode"
[ "$latency_keys" -gt 0 ] && prefix=".bench/gui-$mode-trace"
mkdir -p "$out" "$data"
result="$out/result.txt"
say() { echo "$*" | tee -a "$result"; }

# The sandbox HOME. `launch` writes its .bashrc, which turns the shell into
# a sink before any prompt: raw mode, so the kernel hands over every byte
# at once instead of holding back unfinished lines, and no echo, so pasted
# data doesn't fill the scrollback.
sandbox="$out/home"
mkdir -p "$sandbox"
sink_target=/dev/null
# State the EXIT trap cleans up. `sink` is Rex's child: it must be killed
# too, because Rex leaks its pty master into the child (a known Rex bug),
# so the pty never hangs up and the child would outlive Rex.
rex=""
sink=""
loader=""
clipboard_saved=0
# Extra environment for the next `launch`, as NAME=value words.
launch_env=()

# Stops the background output writer of the loaded latency scenario.
stop_loader() {
    [ -n "$loader" ] || return 0
    kill "$loader" 2>/dev/null || true
    wait "$loader" 2>/dev/null || true
    loader=""
}

cleanup() {
    stop_loader
    [ -z "$rex" ] || kill "$rex" 2>/dev/null || true
    [ -z "$sink" ] || kill "$sink" 2>/dev/null || true
    if [ "$clipboard_saved" = 1 ]; then
        # xclip stays running to serve the clipboard: detach it from our
        # stdout, stderr and lock, or a pipe reading this script never sees
        # EOF and the lock stays held.
        xclip -selection clipboard -i < "$out/clipboard.saved" >/dev/null 2>&1 9>&- || true
        rm -f "$out/clipboard.saved"
    fi
}
trap cleanup EXIT

if xclip -selection clipboard -o > "$out/clipboard.saved" 2>/dev/null; then
    clipboard_saved=1
fi

if [ "$latency_keys" -gt 0 ]; then
    zig build -Doptimize="$mode" -Dtrace-latency -p "$prefix" >/dev/null
else
    zig build -Doptimize="$mode" -p "$prefix" >/dev/null
fi

# A real config file in the sandbox, so startup and reloads go through the
# config loading path (keymap merging and the rest), not only the defaults.
mkdir -p "$sandbox/.config/rex"
sandbox_config="$sandbox/.config/rex/config"
"$prefix/bin/rex" config defaults > "$sandbox_config"
if [ -n "$font" ]; then
    font_quoted=${font//\\/\\\\}
    font_quoted=${font_quoted//\"/\\\"}
    printf '\n[font]\nfile = "%s"\n' "$font_quoted" >> "$sandbox_config"
fi
if [ -n "$font_conf" ]; then
    printf '\n' >> "$sandbox_config"
    cat "$font_conf" >> "$sandbox_config"
fi
"$prefix/bin/rex" config validate "$sandbox_config" > "$out/config-validate.txt" ||
    die "the sandbox config has errors, see $out/config-validate.txt"
if [ "$platform" = xwayland ]; then
    sed -i 's/^platform = auto$/platform = x11/' "$sandbox_config"
    grep -q '^platform = x11$' "$sandbox_config" || die "couldn't set platform = x11 in the sandbox config"
fi

# Test data, generated once and reused across runs.
plain="$data/plain-100M.txt"
escapes="$data/escapes-100M.txt"
paste_data="$data/paste-${paste_kib}K.txt"
[ -f "$plain" ] || head -c 100M <(base64 -w 76 /dev/urandom) > "$plain"
if [ ! -f "$escapes" ]; then
    while [ "$(stat -c %s "$escapes" 2>/dev/null || echo 0)" -lt 104857600 ]; do
        cat bench/cases/vt/testdata/corpus/*.raw >> "$escapes"
    done
    truncate -s 100M "$escapes"
fi
[ -f "$paste_data" ] || head -c "${paste_kib}K" <(base64 -w 76 /dev/urandom) > "$paste_data"

rss_kb() { awk '/^VmRSS/{print $2}' "/proc/$1/status"; }

# Fails unless Rex's only child is `cat` reading the pty and writing to the
# sink target. Called before any key is sent.
assert_sink() {
    local children child
    children=$(pgrep -P "$rex" || true)
    [ "$(wc -w <<< "$children")" = 1 ] || die "rex $rex has children '$children', expected one cat"
    child=$children
    [ "$(cat "/proc/$child/comm")" = cat ] || die "rex child $child is $(cat "/proc/$child/comm"), not cat"
    [ "$(readlink "/proc/$child/fd/1")" = "$sink_target" ] || die "rex child $child doesn't write to $sink_target"
    [[ "$(readlink "/proc/$child/fd/0")" == /dev/pts/* ]] || die "rex child $child doesn't read a pty"
}

# Starts Rex in the sandbox with its sink writing to $2 and the tty set up
# with `stty $3`, waits for the sink and the window. Sets rex, pts, win and
# sink_target.
launch() {
    local log="$out/rex-$1.log" i child
    sink_target=$2
    printf 'HISTFILE=/dev/null\nstty %s\nexec cat > %q\n' "$3" "$sink_target" > "$sandbox/.bashrc"
    # 9>&-: Rex and everything it starts must not inherit the lock.
    # SHELL: Rex starts $SHELL, and only bash reads the sink .bashrc.
    env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
        HOME="$sandbox" SHELL=/bin/bash "${launch_env[@]}" "$prefix/bin/rex" > "$log" 2>&1 9>&- &
    rex=$!
    pts=""
    for i in $(seq 100); do
        child=$(pgrep -P "$rex" || true)
        if [ -n "$child" ] && [ "$(cat "/proc/$child/comm" 2>/dev/null)" = cat ]; then
            pts=$(readlink "/proc/$child/fd/0" || true)
            break
        fi
        sleep 0.1
    done
    assert_sink
    sink=$child
    # Descriptors the child got beyond stdin, stdout and stderr: anything
    # here leaked from Rex (or from whatever started Rex).
    local extra
    extra=$(find "/proc/$child/fd" -mindepth 1 -maxdepth 1 ! -name 0 ! -name 1 ! -name 2 -printf '%l ' 2>/dev/null || true)
    say "sink_extra_fds=$(wc -w <<< "$extra")${extra:+ ($extra)}"
    win=$(timeout 10 xdotool search --sync --pid "$rex" | head -1) || die "rex $rex has no window"
    sleep 2 # startup settles: glyph warmup, first frames
    # The GLX vendor library Rex loaded, e.g. libGLX_nvidia or libGLX_mesa
    # (selectable with __GLX_VENDOR_LIBRARY_NAME).
    say "glx_vendor=$(grep -o 'libGLX_[a-z]*' "/proc/$rex/maps" | sort -u | tr '\n' ' ')"
}

stop() {
    local status=killed i
    if [ "$clean_exit" = 1 ]; then
        # Ending the child makes Rex leave its loop and run its cleanup
        # (and, in Debug, the allocator's leak check) as on a normal exit.
        kill "$sink" 2>/dev/null || true
        for i in $(seq 150); do # up to 15 s
            kill -0 "$rex" 2>/dev/null || { status=clean; break; }
            sleep 0.1
        done
    fi
    if [ "$status" = clean ]; then
        local code=0
        wait "$rex" 2>/dev/null || code=$?
        status="clean, exit code $code"
    else
        kill "$rex"
        wait "$rex" 2>/dev/null || true
        # Rex is gone, so its pty should hang up and the child exit by
        # itself. A child that still holds the pty master never sees that.
        local survived=yes
        for i in $(seq 20); do # up to 2 s
            kill -0 "$sink" 2>/dev/null || { survived=no; break; }
            sleep 0.1
        done
        say "sink_survived_rex=$survived"
    fi
    kill "$sink" 2>/dev/null || true
    say "rex_exit=$status"
    rex=""
    sink=""
}

# Counts the allocator's reports in a Rex log (Debug builds only).
allocator_report() {
    local log="$out/rex-$1.log"
    say "leaks_reported=$(grep -c 'leaked:' "$log" || true) invalid_frees=$(grep -cE 'Double free detected|does not match free' "$log" || true) panics=$(grep -c 'panic' "$log" || true)"
}

# Sends Rex shortcuts to Rex's window through XTEST, as real key presses.
# Rex handles these itself; none of them produces input for the pty.
keys() {
    assert_sink
    xdotool windowactivate --sync "$win"
    xdotool key --clearmodifiers --delay 30 "$@"
}

say "== perf-gui $mode @ $sha, $(date -Iseconds) =="

# Types LATENCY_KEYS keys into a traced Rex and summarizes its trace.
# $1 is the scenario: quiet, or loaded (output streams in meanwhile).
latency_run() {
    local csv="$out/latency-$1.csv" sent=0 batch i keys_arg
    launch_env=("REX_LATENCY_TRACE=$csv")
    launch "latency-$1" /dev/null "sane echo"
    launch_env=()
    if [ "$1" = loaded ]; then
        # One process, so stopping it leaves nothing behind: 76-column
        # lines of the plain test data, as fast as Rex takes them.
        yes "$(head -1 "$plain")" > "$pts" 2>/dev/null 9>&- &
        loader=$!
        sleep 1
    fi
    say "-- latency $1: $latency_keys keys, ${latency_interval_ms} ms apart"
    while [ "$sent" -lt "$latency_keys" ]; do
        batch=$((latency_keys - sent < 16 ? latency_keys - sent : 16))
        keys_arg="" # batch - 1 times `a`; the last key is Return
        for ((i = 1; i < batch; i++)); do keys_arg+="a "; done
        assert_sink
        xdotool windowactivate --sync "$win"
        [ "$(xdotool getactivewindow)" = "$win" ] || die "Rex's window lost the keyboard focus; stopped typing"
        # shellcheck disable=SC2086 # keys_arg is a list of key names
        xdotool key --clearmodifiers --delay "$latency_interval_ms" $keys_arg Return
        sent=$((sent + batch))
    done
    sleep 1
    stop_loader
    clean_exit=1 stop
    [ -s "$csv" ] || die "Rex wrote no latency trace to $csv; see $out/rex-latency-$1.log"
    scripts/latency-report.sh "$csv" | tee -a "$result"
}

if [ "$latency_keys" -gt 0 ]; then
    say "platform=$platform"
    latency_run quiet
    [ "$latency_load" = 1 ] && latency_run loaded
    say "results: $result"
    exit 0
fi
say "pastes=$pastes x ${paste_kib} KiB, font_cycles=$font_cycles, idle=${idle_seconds}s"

# Instance 1: idle, then pastes, then font changes. Raw mode, so the kernel
# hands every pasted byte to the sink at once instead of holding back an
# unfinished last line. With PASTE_VERIFY=1 the sink keeps what it
# receives, for the check after the pastes.
if [ "$paste_verify" = 1 ]; then
    launch session "$out/received.bin" "raw -echo"
else
    launch session /dev/null "raw -echo"
fi
say "rss_start_kb=$(rss_kb "$rex")"

say "-- idle ${idle_seconds}s"
pidstat -u -w -p "$rex" "$idle_seconds" 1 | awk '
    /^Average/ && /%CPU/   {cpu_col = 0; for (i = 1; i <= NF; i++) if ($i == "%CPU") cpu_col = i; next}
    /^Average/ && /cswch/  {next}
    /^Average/ && cpu_col  {printf "idle_cpu_pct=%s\n", $cpu_col; cpu_col = 0; next}
    /^Average/             {printf "idle_cswch_per_s=%s idle_nvcswch_per_s=%s\n", $4, $5}
' | tee -a "$result"

say "-- pastes"
xclip -selection clipboard -i < "$paste_data" >/dev/null 2>&1 9>&-
rss_before=$(rss_kb "$rex")
for i in $(seq "$pastes"); do
    keys ctrl+shift+v
    sleep 0.5
done
sleep 1
rss_after=$(rss_kb "$rex")
say "paste_rss_before_kb=$rss_before paste_rss_after_kb=$rss_after paste_rss_growth_kb=$((rss_after - rss_before))"
# Old drivers log "failed to write"; since the outbound queue, a refused
# write logs "dropping".
say "paste_write_errors=$(grep -cE 'failed to write|dropping' "$out/rex-session.log" || true)"
if [ "$paste_verify" = 1 ]; then
    expected_size=$((pastes * $(stat -c %s "$paste_data")))
    for i in $(seq 100); do # up to 10 s for the last bytes to arrive
        [ "$(stat -c %s "$sink_target")" -ge "$expected_size" ] && break
        sleep 0.1
    done
    expected_sum=$(for i in $(seq "$pastes"); do cat "$paste_data"; done | sha256sum | cut -c1-16)
    received_sum=$(sha256sum < "$sink_target" | cut -c1-16)
    say "paste_verify_expected=${expected_size}B/${expected_sum} received=$(stat -c %s "$sink_target")B/${received_sum}"
    if [ "$expected_sum" = "$received_sum" ]; then say "paste_verify=OK"; else say "paste_verify=MISMATCH"; fi
fi

say "-- font changes"
rss_before=$(rss_kb "$rex")
for i in $(seq "$font_cycles"); do
    keys ctrl+equal ctrl+equal ctrl+equal ctrl+equal ctrl+equal \
        ctrl+minus ctrl+minus ctrl+minus ctrl+minus ctrl+minus
    if [ "$font_sample_every" -gt 0 ] && [ $((i % font_sample_every)) = 0 ]; then
        say "font_rss cycle=$i changes=$((i * 10)) kb=$(rss_kb "$rex")"
    fi
done
keys ctrl+0
sleep 1
rss_after=$(rss_kb "$rex")
say "font_rss_before_kb=$rss_before font_rss_after_kb=$rss_after font_rss_growth_kb=$((rss_after - rss_before))"
say "font_changes_logged=$(grep -c 'cell=' "$out/rex-session.log" || true)"

if [ "$reloads" -gt 0 ]; then
    say "-- config reloads"
    rss_before=$(rss_kb "$rex")
    for i in $(seq "$reloads"); do
        kill -HUP "$rex"
        sleep 0.3
    done
    sleep 1
    rss_after=$(rss_kb "$rex")
    say "reload_rss_before_kb=$rss_before reload_rss_after_kb=$rss_after reload_rss_growth_kb=$((rss_after - rss_before))"
fi
stop
[ "$mode" = Debug ] && allocator_report session

if [ "$skip_throughput" = 1 ]; then
    say "results: $result"
    exit 0
fi

# Instance 2: end-to-end throughput, written to Rex's pty slave so the
# bytes arrive exactly like program output.
# Cooked mode, as in the 2026-11 baseline: the kernel's output processing
# (ONLCR turns \n into \r\n) is part of what this measures, so changing the
# mode changes the numbers.
launch throughput /dev/null "-echo"
say "-- throughput (100 MiB per run)"
for file in "$plain" "$escapes"; do
    for run in 1 2 3; do
        start=$(date +%s.%N)
        cat "$file" > "$pts"
        end=$(date +%s.%N)
        say "$(printf '%s run%d: %.2fs %.1f MiB/s rss_kb=%s' "$(basename "$file" .txt)" "$run" \
            "$(echo "$end - $start" | bc)" "$(echo "100 / ($end - $start)" | bc -l)" "$(rss_kb "$rex")")"
    done
done
stop
[ "$mode" = Debug ] && allocator_report throughput

say "results: $result"
