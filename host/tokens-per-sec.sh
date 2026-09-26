#!/bin/sh
# After-the-call provider speed from ~/.grok/logs/unified.jsonl.
#
# main already logs shell.turn.inference_done with tokens_per_sec:
#   completion_tokens * 1000 / (model_elapsed_ms - ttft_ms)
# This script does not measure anything. It reads those lines.
#
# Per session, and for all sessions together, the rate is weighted:
#   sum(completion_tokens) / sum(decode milliseconds)
# A plain average of the per-call rates would let a tiny call count as much
# as a long one. This is model time, not wall clock: two agents decoding at
# once each keep their own rate. Add those rates only for the stretch where
# the calls actually overlapped.
#
# AoE grok processes bind-mount the real ~/.grok, so their lines are already
# in this one file. jq is required.
#
#   ./host/tokens-per-sec.sh                 last 15 minutes
#   ./host/tokens-per-sec.sh --minutes 60
#   ./host/tokens-per-sec.sh --all
#   ./host/tokens-per-sec.sh --log /path/unified.jsonl
set -eu

MINUTES=15
LOG=${GROK_UNIFIED_LOG:-$HOME/.grok/logs/unified.jsonl}

while [ $# -gt 0 ]; do
    case "$1" in
        --minutes)
            MINUTES=${2:?--minutes needs a number}
            shift 2
            ;;
        --all)
            MINUTES=0
            shift
            ;;
        --log)
            LOG=${2:?--log needs a path}
            shift 2
            ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "usage: tokens-per-sec.sh [--minutes N | --all] [--log PATH]" >&2
            exit 2
            ;;
    esac
done

[ -f "$LOG" ] || { echo "no unified log at $LOG" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
case "$MINUTES" in
    ''|*[!0-9]*) echo "--minutes must be a number" >&2; exit 2 ;;
esac

if [ "$MINUTES" -eq 0 ]; then
    CUTOFF=0
    WINDOW="the whole log"
else
    CUTOFF=$(date -d "-$MINUTES minutes" +%s)
    WINDOW="the last $MINUTES minutes"
fi

table=$(jq -nr --argjson cutoff "$CUTOFF" '
  def decode:
    (.model_elapsed_ms // 0) as $el
    | (.ttft_ms // null) as $ttft
    | if ($ttft | type) == "number" and $el > $ttft then $el - $ttft else $el end;
  def rate($tok; $dec):
    if $dec > 0 then ($tok * 1000 / $dec * 10 | round) / 10 else null end;
  def short:
    if . == null or . == "" then "-"
    elif length > 13 then .[0:8] + "…"
    else . end;

  [inputs
    | select(.msg == "shell.turn.inference_done")
    | select((.ctx.completion_tokens // 0) > 0)
    | (.ts | sub("\\.[0-9]+"; "") | fromdateiso8601) as $epoch
    | select($epoch >= $cutoff)
    | .ctx as $c
    | ($c | decode) as $dec
    | select($dec > 0)
    | {
        epoch: $epoch,
        sid: (.sid // "-"),
        tokens: $c.completion_tokens,
        decode: $dec,
        tps: $c.tokens_per_sec
      }
  ] as $rows
  | if ($rows | length) == 0 then
      "0"
    else
      ($rows | length),
      (["session", "calls", "tokens", "last", "tok/s"] | @tsv),
      ($rows | group_by(.sid)[] | . as $g
        | [
            ($g[0].sid | short),
            ($g | length),
            ($g | map(.tokens) | add),
            ($g | max_by(.epoch) | .tps // "-"),
            rate(($g | map(.tokens) | add); ($g | map(.decode) | add))
          ] | @tsv),
      ([
        "all",
        ($rows | length),
        ($rows | map(.tokens) | add),
        ($rows | max_by(.epoch) | .tps // "-"),
        rate(($rows | map(.tokens) | add); ($rows | map(.decode) | add))
      ] | @tsv)
    end
' "$LOG")

count=$(printf '%s\n' "$table" | head -n 1)
if [ "$count" = 0 ]; then
    echo "no inference_done lines in $WINDOW"
    echo "log: $LOG"
    exit 0
fi

echo "provider decode speed, $WINDOW  ($count calls)"
echo "rate = completion tokens / decode time. decode time excludes time-to-first-token."
echo
printf '%s\n' "$table" | tail -n +2 | column -t -s "$(printf '\t')"
