#!/bin/sh
# Detached release build of the current branch (normally kitchensink).
# Survives the launching session (start it with setsid). Writes a per-run log
# and an exit marker, so progress.sh can tell "finished" from "killed".
#
# RUSTFLAGS is deliberately CLEARED. local/host-build-config carries the host's
# rustflags in .cargo/config.toml, and an environment RUSTFLAGS would REPLACE
# them rather than add to them, which would also hide whether that patch works.
#
# Lives in the checkout (host/). Not for upstream.
set -u
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LOGDIR="${GROK_BUILD_LOGDIR:-$HOME/grok-build-logs}"
mkdir -p "$LOGDIR"
TS=$(date +%Y%m%dT%H%M%S)
LOG="$LOGDIR/release-$TS.log"
MEMLOG="$LOGDIR/mem-$TS.log"
cd "$ROOT" || exit 1
ln -sfn "$LOG" "$LOGDIR/current.log"
ln -sfn "$MEMLOG" "$LOGDIR/current-mem.log"
{
    echo "=== grok-build release build $TS"
    echo "=== branch $(git branch --show-current) at $(git rev-parse --short HEAD); main at $(git rev-parse --short main)"
    echo "=== RUSTFLAGS cleared; rustflags come from .cargo/config.toml"
} > "$LOG"

env -u RUSTFLAGS -u CARGO_BUILD_RUSTFLAGS -u CARGO_ENCODED_RUSTFLAGS \
    nice -n 19 cargo build -p xai-grok-pager-bin --release -j 6 >> "$LOG" 2>&1 &
CARGO_PID=$!
printf 'cargo pid: %s\nlog: %s\n' "$CARGO_PID" "$LOG" > "$LOGDIR/pids.txt"

# Log-only memory sampler, scoped to the captured pid. No pkill, no pattern match.
( while kill -0 "$CARGO_PID" 2>/dev/null; do
    printf '%s mem_used=%sM mem_avail=%sM swap_used=%sM home_free=%s\n' "$(date +%T)" \
        "$(free -m | awk '/^Mem:/{print $3}')" "$(free -m | awk '/^Mem:/{print $7}')" \
        "$(free -m | awk '/^Swap:/{print $3}')" "$(df -h /home | awk 'NR==2{print $4}')" >> "$MEMLOG"
    sleep 60
  done ) &
MON_PID=$!
echo "monitor pid: $MON_PID" >> "$LOGDIR/pids.txt"

wait "$CARGO_PID"
EXIT=$?
kill "$MON_PID" 2>/dev/null
echo "=== CARGO EXIT=$EXIT ===" >> "$LOG"
