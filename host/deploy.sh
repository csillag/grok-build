#!/bin/sh
# Deploy a finished release to ~/local/bin/grok.
# Refuses unless the current build log ends in CARGO EXIT=0 and the binary holds
# no SVE code (which would mean local/host-build-config did not take, and the
# binary would SIGILL on this Cortex-A76 host). Keeps the previous binary as
# grok.prev and replaces atomically, so a grok already running keeps its inode.
#
# Lives in the checkout (host/). Not for upstream.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LOGDIR="${GROK_BUILD_LOGDIR:-$HOME/grok-build-logs}"
BIN="$ROOT/target/release/xai-grok-pager"
DEST="${GROK_INSTALL_BIN:-$HOME/local/bin/grok}"

grep -q '^=== CARGO EXIT=0 ===$' "$LOGDIR/current.log" \
    || { echo "refusing: $LOGDIR/current.log has no 'CARGO EXIT=0'"; exit 1; }
[ -x "$BIN" ] || { echo "refusing: $BIN is missing"; exit 1; }

SVE=$(objdump -d "$BIN" | grep -cE '\b(ptrue|whilelo|z[0-9]+\.[bhsd])\b' || true)
[ "$SVE" -eq 0 ] \
    || { echo "refusing: $SVE SVE-style instructions -- the target-cpu patch did not take"; exit 1; }
echo "SVE check: 0 SVE-style instructions"

[ -f "$DEST" ] && cp -p "$DEST" "$DEST.prev"
TMP="$(dirname "$DEST")/.grok.new.$$"
cp "$BIN" "$TMP" && chmod 755 "$TMP" && mv -f "$TMP" "$DEST"
cmp -s "$BIN" "$DEST" || { echo "ERROR: $DEST differs from $BIN after install"; exit 1; }
echo "deployed: $(ls -la "$DEST")"
[ -f "$DEST.prev" ] && echo "rollback:  mv -f $DEST.prev $DEST"
