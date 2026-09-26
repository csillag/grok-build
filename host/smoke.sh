#!/bin/sh
# Sandboxed smoke test of the deployed grok, spawned the way agent-of-empires
# spawns it: environment cleared to AoE's forward list, the daemon's PATH order,
# and grok's OWN sandbox engaged. Never runs grok without --sandbox.
#
# Expected: the first two print an agentVersion; the last two are REFUSED with a
# GROK_BWRAP_PATH error. A refusal also proves the profile really goes through
# bwrap -- if it did not, a bad override would change nothing.
#
# Lives in the checkout (host/). Not for upstream.
set -u
G="${GROK_INSTALL_BIN:-$HOME/local/bin/grok}"
U="${USER:-$(id -un)}"   # AoE passes USER; some shells do not set it
AOE_PATH="$HOME/local/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin:/usr/bin:/bin"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}'
W=$(mktemp -d /tmp/grok-smoke.XXXXXX)   # workspace profile makes the CWD writable
cd "$W" || exit 1
run() {
    label=$1; shift
    # Hold stdin open for a few seconds after the request, as agent-of-empires
    # does for the life of a session. Closing it at once races grok's startup:
    # when startup is slow (the first run after an upgrade does a blocking model
    # fetch and a metadata migration), grok sees EOF, shuts down cleanly and
    # exits 0 WITHOUT answering the request it already read -- a false failure
    # that looks exactly like a broken sandbox.
    out=$( { printf '%s\n' "$INIT"; sleep 6; } \
        | env -i PATH="$AOE_PATH" HOME="$HOME" TERM=xterm USER="$U" LANG=C.UTF-8 "$@" \
            timeout 30 "$G" --sandbox workspace agent stdio 2>"$W/$label.err")
    rc=$?
    ver=$(printf '%s' "$out" | grep -o '"agentVersion":"[^"]*"' | head -1)
    printf '%-26s rc=%-3s stdout=%6sB  %s\n' "$label" "$rc" "${#out}" "${ver:-(no agentVersion)}"
    [ -s "$W/$label.err" ] && sed 's/^/      stderr: /' "$W/$label.err" | head -4
}
echo "grok: $("$G" --sandbox read-only version 2>/dev/null | head -1)"
run aoe-env-path-bwrap
run bwrap-path-good      GROK_BWRAP_PATH="$HOME/local/bin/bwrap"
run bwrap-path-missing   GROK_BWRAP_PATH=/nonexistent/bwrap
run bwrap-path-relative  GROK_BWRAP_PATH=bwrap
echo "scratch dir (safe to delete): $W"
