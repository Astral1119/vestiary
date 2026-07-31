#!/bin/bash

# Watch an energy-gate run that outlives the session which started it.
#
# Claude Code's own facilities for this — Monitor, CronCreate, /loop — all live
# inside the session and are gone when it exits, and an unattended overnight run
# is exactly the case where the session is gone. This is a detached shell loop
# instead. It survives the terminal closing.
#
# It wakes once a minute to check a pid and read a log, which is cheap enough
# not to appear in the measurement it is watching. That matters here: anything
# that polls harder, or that wakes a language model on a timer, lands in the
# sampled block's own busyProcesses and widens the spread the run exists to
# measure. So this notifies on events and is otherwise silent.
#
# usage: watch-energy-run.sh <store-dir> [pid]

set -u

STORE="${1:?usage: watch-energy-run.sh <store-dir> [pid]}"
RUN_PID="${2:-}"
LOG="$STORE/run.log"
RECORD="$STORE/baseline-repeatability-v1.json"
STATUS="$STORE/watch-status.txt"
REPORT="$STORE/triage-report.md"
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
POLL_SECONDS="${POLL_SECONDS:-60}"

note() {
    local title="$1" message="$2"
    printf '%s  %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$title" "$message" \
        >> "$STATUS"
    osascript -e "display notification \"${message//\"/}\" with title \"${title//\"/}\"" \
        >/dev/null 2>&1 || true
}

running() {
    if [ -n "$RUN_PID" ]; then
        kill -0 "$RUN_PID" 2>/dev/null
    else
        pgrep -f baseline-repeatability.py >/dev/null 2>&1
    fi
}

# grep -c prints 0 and exits non-zero when nothing matches, so `|| echo 0`
# would emit the count twice and the arithmetic below would refuse it.
count_in_log() {
    [ -f "$LOG" ] || { echo 0; return; }
    grep -c "$1" "$LOG" 2>/dev/null || true
}

blocks_done() {
    count_in_log '^block '
}

# Read-only tools and the diagnosis on stdout, so the triage agent needs no
# write permission and cannot sit overnight waiting on a prompt. The timeout is
# the backstop for that anyway.
triage() {
    local reason="$1"
    command -v claude >/dev/null 2>&1 || return 0
    ( cd "$REPO" && timeout 600 claude -p \
"The overnight energy baseline run stopped unexpectedly ($reason).

Read $LOG, $RECORD if it exists, and \
fresco-scene/tools/energy-gate/baseline-repeatability.py.

Write a concise diagnosis covering: how many blocks completed; how many were \
INVALID and for what reason; what stopped the run; and whether the blocks \
already on disk are usable evidence for step 5 baseline repeatability. Cite the \
block indices you rely on. Output the diagnosis only." \
        --allowedTools Read Grep Glob \
        > "$REPORT" 2>"$STORE/triage-claude.log" ) || true
}

seen_invalid=0
note "energy baseline" "watchdog armed against pid ${RUN_PID:-unknown}"

while true; do
    if ! running; then
        done_blocks=$(blocks_done)
        # completedAt is written only by the closing pass, so its absence is
        # what distinguishes a crash from a finish.
        if [ -f "$RECORD" ] && grep -q '"completedAt"' "$RECORD" 2>/dev/null; then
            note "energy baseline finished" \
                "$done_blocks blocks complete, summary in $RECORD"
        else
            note "energy baseline DIED" \
                "stopped after $done_blocks blocks, triaging"
            triage "process exited before writing completedAt"
            note "energy baseline triage" "report written to $REPORT"
        fi
        exit 0
    fi

    invalid=$(count_in_log 'INVALID')
    if [ "$invalid" -gt "$seen_invalid" ]; then
        note "energy baseline INVALID block" \
            "$invalid invalid of $(blocks_done) so far"
        seen_invalid="$invalid"
    fi

    sleep "$POLL_SECONDS"
done
