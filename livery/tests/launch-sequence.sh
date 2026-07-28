#!/bin/sh
# The cold launch path must not open the app while launchd still holds the
# retiring instance's service record. An `open` issued inside that window
# queues as launch-job demand and fires late, which is the shape of the
# duplicate launches in the July 19 logs. `run` used to sleep a constant 0.3 s,
# which is both longer than the 5 ms the process takes to exit and shorter than
# the 0.26 s the record took to disappear when it was measured.
#
# Driven with stubs rather than a real instance, because the interesting cases
# are a record that lingers and a record that never goes away, and neither is
# producible on demand from a live app.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/livery-launch.XXXXXX")
READY="/tmp/livery-$(id -u).ready"
READY_BACKUP="$TMP/ready.backup"

# `run` clears the readiness file by its real path, so a run here would retire
# the readiness of the operator's live instance. Put it back.
[ ! -f "$READY" ] || cp "$READY" "$READY_BACKUP"
restore() {
  status=$?
  if [ -f "$READY_BACKUP" ]; then
    cp "$READY_BACKUP" "$READY"
  fi
  rm -rf "$TMP"
  exit "$status"
}
trap restore EXIT HUP INT TERM

mkdir -p "$TMP/bin"

cat > "$TMP/bin/pgrep" <<'STUB'
#!/bin/sh
calls=$(cat "$STATE/pgrep.calls" 2>/dev/null || echo 0)
calls=$((calls + 1))
printf '%s\n' "$calls" > "$STATE/pgrep.calls"
printf 'pgrep\n' >> "$STATE/events"
if [ "$calls" -le "$PGREP_ALIVE" ]; then
  printf '4242\n'
  exit 0
fi
exit 1
STUB

cat > "$TMP/bin/launchctl" <<'STUB'
#!/bin/sh
calls=$(cat "$STATE/launchctl.calls" 2>/dev/null || echo 0)
calls=$((calls + 1))
printf '%s\n' "$calls" > "$STATE/launchctl.calls"
printf 'launchctl\n' >> "$STATE/events"
if [ "$calls" -le "$LAUNCHCTL_ALIVE" ]; then
  printf '4242\t0\tapplication.local.vestiary.lvry.1.2\n'
fi
exit 0
STUB

cat > "$TMP/bin/sleep" <<'STUB'
#!/bin/sh
printf 'sleep\n' >> "$STATE/events"
exit 0
STUB

cat > "$TMP/bin/open" <<'STUB'
#!/bin/sh
printf 'open\n' >> "$STATE/events"
exit 0
STUB

cat > "$TMP/bin/swiftc" <<'STUB'
#!/bin/sh
for argument in "$@"; do
  output=$argument
done
: > "$output"
chmod +x "$output"
exit 0
STUB

chmod +x "$TMP"/bin/*

# The bound in `run`. Pinned so a retune is a deliberate edit here rather than
# an unnoticed change to how long a wedged teardown blocks a launch.
BOUND=80

drive() {
  STATE="$TMP/state-$1"
  rm -rf "$STATE"
  mkdir -p "$STATE"
  : > "$STATE/events"
  export STATE
  export PGREP_ALIVE="$2"
  export LAUNCHCTL_ALIVE="$3"
  XDG_CACHE_HOME="$STATE/cache" PATH="$TMP/bin:$PATH" sh "$ROOT/run" >/dev/null 2>&1
}

count() {
  grep -c "^$2$" "$TMP/state-$1/events" || true
}

# A record that lingers past the process. `open` waits for it. The SIGTERM
# itself is unobservable here — `kill` is a shell builtin, so a PATH stub never
# sees it — but only the retirement branch waits at all, so a sleep is proof
# the script took it.
drive lingering 1 3
events="$TMP/state-lingering/events"
[ "$(count lingering open)" -eq 1 ]
[ "$(tail -n 1 "$events")" = "open" ]
launchctl_before_open=$(sed -n '1,/^open$/p' "$events" | grep -c '^launchctl$')
[ "$launchctl_before_open" -ge 3 ]
[ "$(count lingering sleep)" -ge 3 ]

# A record that never goes away. The wait is bounded and the app opens anyway,
# because a late instance beats none.
drive wedged 99999 99999
[ "$(count wedged open)" -eq 1 ]
[ "$(count wedged sleep)" -eq "$BOUND" ]
[ "$(tail -n 1 "$TMP/state-wedged/events")" = "open" ]

# Nothing running. No wait at all, which is the hot path this must not slow.
drive cold 0 0
[ "$(count cold open)" -eq 1 ]
[ "$(count cold sleep)" -eq 0 ]

echo "livery launch sequence checks passed"
