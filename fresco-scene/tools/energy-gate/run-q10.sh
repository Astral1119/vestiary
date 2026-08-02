#!/bin/bash

# Start the Q10 backend comparison: native-opengl against angle-metal, on
# Elaina at 3840x2160 with five 4K players, alternating on both GPU clock
# parities.
#
# The run outlives the session that starts it. It is launched detached and
# watched by watch-energy-run.sh, for the reasons that script's header gives.
#
# What this refuses to do is start a run that cannot produce a valid answer.
# Every check below corresponds to a way an earlier run was lost or corrupted,
# so a failure here is cheaper than discovering it at block 40. The two pmset
# changes need an interactive sudo and are therefore yours to make; everything
# else this script does itself and undoes on the way out.
#
# usage: run-q10.sh [blocks] [sample-seconds] [settle-seconds]

set -u

BLOCKS="${1:-24}"
SAMPLE="${2:-120}"
SETTLE="${3:-60}"

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
NATIVE="$REPO/fresco-scene/build/fresco-scene"
ANGLE="$REPO/.fresco-evidence/q10-angle-head/fresco-scene"
STORE="${Q10_STORE:-$REPO/.fresco-evidence/q10-v1}"
ELAINA=3326873240

fail() { printf 'preflight: %s\n' "$1" >&2; exit 1; }

# --- the two backend binaries -------------------------------------------
#
# That they are built from the same commit is not checkable from the binaries
# and is the operator's to keep true. The 2026-08-02 handoff entry records the
# shas both arms were at when this was written.

[ -x "$NATIVE" ] || fail "no native helper at $NATIVE — cmake --build fresco-scene/build"
[ -x "$ANGLE" ] || fail "no angle helper at $ANGLE — see the 2026-08-02 handoff entry for the configure line"

# ANGLE's @rpath is absolute and points outside the repo, so the build is not
# self-contained and a missing sibling checkout is a dyld failure at launch
# rather than a build error.
for dylib in libEGL.dylib libGLESv2.dylib; do
    [ -f "$HOME/src/fresco-angle/out/fresco-metal/$dylib" ] \
        || fail "angle build needs ~/src/fresco-angle/out/fresco-metal/$dylib"
done

# --- power ---------------------------------------------------------------

pmset -g ps | grep -q "drawing from 'AC Power'" \
    || fail "the machine is on battery; plug it in (a run also does not survive Battery sleep at 1 minute)"

# Read the AC block by name. A range expression works only while pmset happens
# to print AC last, and which section comes first is not something to depend on.
ac_setting() {
    pmset -g custom | awk -v key="$1" '
        /^AC Power:/ { inside = 1; next }
        /^[A-Za-z].*Power:/ { inside = 0 }
        inside && $1 == key { print $2; exit }
    '
}
displaysleep=$(ac_setting displaysleep)
powernap=$(ac_setting powernap)
if [ "$displaysleep" != "0" ] || [ "$powernap" != "0" ]; then
    cat >&2 <<EOF
preflight: two AC settings corrupt an unattended run and need an interactive sudo.

  sudo pmset -c displaysleep 0     # currently $displaysleep — the display switching off
                                   # mid-run is a step change any spanning block measures
  sudo pmset -c powernap 0         # currently $powernap — background work wakes inside
                                   # the sampled windows

Restore them afterwards with the values this machine had:

  sudo pmset -c displaysleep 10
  sudo pmset -c powernap 1
EOF
    exit 1
fi

# --- ownership -----------------------------------------------------------

# One helper is the subject. Any more and the run measures load it did not ask
# for; an earlier ANGLE pass was invalidated by five leaked full-resolution
# helpers, which is this check with the count set to one.
#
# Counted through the harness's own definition rather than a pgrep pattern:
# `pgrep -f fresco-scene` also matches the shell that invoked this script when
# it was invoked by a path containing the string, which is the usual one.
helpers=$(python3 -c "
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    'h', pathlib.Path('$REPO/fresco-scene/tools/energy-gate/baseline-repeatability.py'))
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
print(len(h.helper_processes()))
" 2>/dev/null) || fail "could not enumerate renderer processes"
[ "$helpers" -le 1 ] || fail "$helpers renderer processes are up; quiesce Fresco first"

# The same probe the harness runs at startup, done here so a missing credential
# costs nothing rather than a wallpaper switch first.
python3 -c "
import sys, pathlib
sys.path.insert(0, str(pathlib.Path('$REPO/fresco-scene/tools/common-harness')))
import profiling_sampler
sys.exit(0 if profiling_sampler.sample_powermetrics(
    samples=1, interval_ms=200).get('available') else 1)
" 2>/dev/null \
    || fail "powermetrics is unavailable; it needs a NOPASSWD sudoers rule, and an unattended run cannot answer a prompt"

[ -e "$STORE" ] && fail "$STORE exists; move it or set Q10_STORE"

# --- the subject ---------------------------------------------------------

printf 'setting Elaina (%s) as the subject\n' "$ELAINA"
previous=$(cat "$HOME/.config/fresco/current" 2>/dev/null || true)
fresco set "$ELAINA" >/dev/null 2>&1 || fail "could not set Elaina"

# `fresco set` recompiles and reinstalls the helper, so the installed image is
# native at HEAD from here — which is what the native arm needs and what the
# harness will save as the image to restore.
for _ in $(seq 60); do
    pgrep -f 'config/fresco/bin/fresco-scene' >/dev/null && break
    sleep 1
done
pgrep -f 'config/fresco/bin/fresco-scene' >/dev/null \
    || fail "the helper did not come up on Elaina"

mkdir -p "$STORE"
printf '%s\n' "$previous" > "$STORE/previous-wallpaper.txt"

# --- go ------------------------------------------------------------------

cd "$(dirname "$0")" || exit 1
nohup ./baseline-repeatability.py \
    --blocks "$BLOCKS" --sample-seconds "$SAMPLE" --settle-seconds "$SETTLE" \
    --sub-samples 6 --probe-seconds 15 \
    --subject-helpers 1 --restart-every 1 \
    --backend-cycle native,native,angle,angle \
    --backend-binary "native=$NATIVE" \
    --backend-binary "angle=$ANGLE" \
    --subject-note "Elaina 3840x2160, five 4K players, native-opengl against angle-metal" \
    --store "$STORE" > "$STORE/run.log" 2>&1 &
run_pid=$!

printf 'run %s started: %s blocks, %ss window, %ss settle\n' \
    "$run_pid" "$BLOCKS" "$SAMPLE" "$SETTLE"
printf 'store: %s\n' "$STORE"
printf 'estimated wall clock: %s minutes\n' \
    "$(( (BLOCKS * (SAMPLE + SETTLE) + BLOCKS * 10) / 60 ))"

nohup ./watch-energy-run.sh "$STORE" "$run_pid" >/dev/null 2>&1 &
printf 'watcher started; it notifies on events and is otherwise silent\n'
printf '\nwhen it finishes:\n'
printf '  sudo pmset -c displaysleep 10 && sudo pmset -c powernap 1\n'
if [ -n "$previous" ]; then
    printf '  fresco set %s\n' "$(basename "$previous")"
else
    printf '  fresco set <your wallpaper> — nothing was set before this run\n'
fi
