#!/bin/sh
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
CONTROL="$ROOT/live-preview"
started=0

cleanup() {
  if [ "$started" -eq 1 ]; then "$CONTROL" stop >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT INT TERM HUP

"$CONTROL" start calm-islands sample bottom
started=1

for concept in agent-flightdeck focus-runway space-atlas quiet-signal command-shelf split-horizon chameleon daily-driver calm-islands; do
  "$CONTROL" switch "$concept" sample bottom
done

for scenario in busy agent-waiting meeting-soon warning presentation calm; do
  "$CONTROL" scenario "$scenario"
done

"$CONTROL" next
"$CONTROL" prev

"$CONTROL" mode live
"$CONTROL" status >/dev/null
"$CONTROL" mode sample
"$CONTROL" stop
started=0

printf 'Live smoke test passed.\n'
