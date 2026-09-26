#!/bin/sh
# grok-build progress. Read-only: parses the current build log and the target tree.
# Liveness is kill -0 on the pid captured at launch. Never match a process by
# its command line: a stray process that carries the same string keeps a gate
# shut forever.
#
# Lives in the checkout (host/). Not for upstream.
LOGDIR="${GROK_BUILD_LOGDIR:-$HOME/grok-build-logs}"
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LOG="$LOGDIR/current.log"          # symlink maintained by run-build.sh
MEMLOG="$LOGDIR/current-mem.log"
HEAD_SHA=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
TOTAL_CACHE="$LOGDIR/total-crates-$HEAD_SHA.txt"   # per commit: the graph changes with upstream

[ -f "$LOG" ] || { echo "no build log at $LOG"; exit 1; }

# --- denominator -----------------------------------------------------------
# Resolved dep graph for THIS target only, so platform-gated crates drop out.
# Offline + timeout so it can never stall the build on the package-cache lock.
# Computed once per commit, then cached; before the build has downloaded the
# new crates, --offline fails and the total shows as unknown until it can.
if [ ! -s "$TOTAL_CACHE" ]; then
    t=$(cd "$ROOT" && timeout 25 cargo tree -p xai-grok-pager-bin \
            -e normal,build --target aarch64-unknown-linux-gnu \
            --prefix none --offline 2>/dev/null \
        | awk 'NF{print $1}' | sort -u | grep -c .)
    [ "${t:-0}" -gt 100 ] && echo "$t" > "$TOTAL_CACHE"
fi
TOTAL=$(cat "$TOTAL_CACHE" 2>/dev/null)

# --- progress --------------------------------------------------------------
UNIQ=$(grep '^ *Compiling ' "$LOG" | awk '{print $2}' | sort -u | grep -c .)
DOWNLOADED=$(grep -c '^ *Downloaded ' "$LOG")
LATEST=$(grep '^ *Compiling ' "$LOG" | tail -1 | sed 's/^ *Compiling //')
START_EPOCH=$(stat -c %Y "$LOGDIR/pids.txt" 2>/dev/null || stat -c %Y "$LOG")
MINS=$(( ($(date +%s) - START_EPOCH) / 60 ))

CARGO_PID=$(awk '/^cargo pid/{print $3}' "$LOGDIR/pids.txt" 2>/dev/null)
if grep -q '=== CARGO EXIT=' "$LOG"; then
    STATE=$(grep '=== CARGO EXIT=' "$LOG" | tail -1)
elif [ -n "$CARGO_PID" ] && kill -0 "$CARGO_PID" 2>/dev/null; then
    STATE="running (pid $CARGO_PID)"
else
    STATE="NOT RUNNING and no exit marker -- check it"
fi

TSIZE=$(du -sh "$ROOT/target" 2>/dev/null | awk '{print $1}')
MEM=$(tail -1 "$MEMLOG" 2>/dev/null)
ERRS=$(grep -c '^error' "$LOG")
WARNS=$(grep -c '^warning' "$LOG")

echo "grok-build $HEAD_SHA  $(date +%H:%M:%S)  ${MINS}m elapsed  [$STATE]"
if [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    PCT=$((UNIQ * 100 / TOTAL)); [ "$PCT" -gt 100 ] && PCT=100
    BAR=$(printf '%*s' "$((PCT * 40 / 100))" '' | tr ' ' '#')
    printf '  crates  %s/%s  %s%%  [%-40s]\n' "$UNIQ" "$TOTAL" "$PCT" "$BAR"
    LEFT=$((TOTAL - UNIQ))
    if [ "$MINS" -gt 0 ] && [ "$UNIQ" -gt 0 ] && [ "$LEFT" -gt 0 ]; then
        echo "  rate    $((UNIQ / MINS))/min  -> ~$((LEFT * MINS / UNIQ))m left (optimistic; the last crates are the slow ones)"
    fi
else
    echo "  crates  $UNIQ started (total unknown until the new crates are downloaded)"
fi
echo "  now     $LATEST"
echo "  fetch   downloaded $DOWNLOADED   target $TSIZE"
echo "  mem     $MEM"
[ "$ERRS" -gt 0 ] && echo "  ERRORS  $ERRS  <-- $(grep -m1 '^error' "$LOG")"
echo "  warn    $WARNS"
