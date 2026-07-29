#!/usr/bin/env python3

"""A video texture keeps decoding after it reaches the end of its asset.

Elaina's animations stalled some tens of seconds after load while the frame loop
carried on drawing: a video texture that reached end-of-stream latched terminal
and was never asked to decode again, so it held its final frame for the rest of
the scene's life. The playback clock folds position back to the start at the
asset duration, so the latch has to clear on that fold.

Reaching the end by waiting costs the asset's full duration, and only lands in
the sub-frame gap past the final presentation time about half the time. Seeking
into that gap puts the player on the terminal path in one frame, which is both
deterministic and fast; the fold that follows is the same one a natural
playthrough performs."""

import json
import os
import select
import subprocess
import sys
import time


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
ELAINA = os.path.join(WORKSHOP, "3326873240")

# The display=1 variant is 19.983333s of 60fps video, so its last frame presents
# at 19.966667s. Anything in between decodes past the final sample.
DEAD_WINDOW_SECONDS = 19.98
RECOVERY_DEADLINE_SECONDS = 3.0

if not os.path.isfile(os.path.join(ELAINA, "scene.pkg")):
    raise SystemExit(f"Elaina renderer fixture missing: {ELAINA}")


process = subprocess.Popen(
    [HELPER],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)


def exchange(kind, expected, **values):
    process.stdin.write(json.dumps({
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": "elaina-video-loop",
        **values,
    }) + "\n")
    process.stdin.flush()
    readable, _, _ = select.select([process.stdout], [], [], 90)
    assert readable, (kind, "timed out")
    event = json.loads(process.stdout.readline())
    assert event["type"] == expected, event
    return event


def media():
    return exchange("metrics", "metrics")["mediaTextures"]


ready = exchange(
    "load",
    "ready",
    path=ELAINA,
    assetRoot=ASSETS,
    width=320,
    height=180,
    visible=True,
    evidenceFrames=2,
    # The supervisor runs live scenes on the real-time clock, and the stall only
    # appears there: on the fixed step the decode cadence steps over the gap.
    realtimeClock=True,
    userProperties={
        "timevarying": {"value": False},
        "display": {"value": "1"},
    },
)
assert ready["drawComplete"] is True, ready

time.sleep(1.0)
playing = media()
assert playing["players"] > 0, playing
assert playing["decodes"] > 1, playing
assert playing["endOfStreamPlayers"] == 0, playing

exchange(
    "media-video",
    "media-video-applied",
    action="seek",
    positionSeconds=DEAD_WINDOW_SECONDS,
)

# The seek lands past the final frame, so the next decode ends the stream.
latched = None
deadline = time.monotonic() + RECOVERY_DEADLINE_SECONDS
while time.monotonic() < deadline:
    time.sleep(0.05)
    sample = media()
    if sample["endOfStreamPlayers"] > 0:
        latched = sample
        break
assert latched is not None, (
    "seeking past the final frame did not reach end-of-stream, so this test no "
    "longer exercises the latch"
)

# Position folds back to the start at the duration, and the player has to resume
# decoding from there rather than holding its last frame.
recovered = None
deadline = time.monotonic() + RECOVERY_DEADLINE_SECONDS
while time.monotonic() < deadline:
    time.sleep(0.05)
    sample = media()
    if sample["endOfStreamPlayers"] == 0:
        recovered = sample
        break
assert recovered is not None, (
    f"video texture stayed at end-of-stream for {RECOVERY_DEADLINE_SECONDS}s "
    f"after the playback clock wrapped: {latched}"
)

time.sleep(0.5)
looping = media()
assert looping["endOfStreamPlayers"] == 0, looping
assert looping["decodes"] > recovered["decodes"], (recovered, looping)
assert looping["lastDecodedPresentationSeconds"] < DEAD_WINDOW_SECONDS, looping

exchange("stop", "stopped")
process.stdin.close()
process.wait(timeout=10)
stderr = process.stderr.read()
assert not stderr, stderr

print(
    "Elaina video texture: end-of-stream cleared on the playback clock wrap and "
    f"decoding resumed ({recovered['decodes']} -> {looping['decodes']} decodes)"
)
