#!/usr/bin/env python3

import hashlib
import json
import os
import select
import subprocess
import sys
import time


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
HYUGA = os.path.join(WORKSHOP, "3479521040")
GBC = os.path.join(WORKSHOP, "3448290956")
EXPECTED_SHA256 = "c8e35f0ad9b49f882eda411fb0feada0fb1059fa7bb058db79271cae794cf147"
GBC_EXPECTED_SHA256 = "4bac6871f95380c374653c44a903538cfa841a8d17abe310a092543dd9ac6ac1"

package = os.path.join(HYUGA, "scene.pkg")
if not os.path.isfile(package):
    raise SystemExit(f"Hyuga renderer fixture missing: {HYUGA}")
digest = hashlib.sha256()
with open(package, "rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
assert digest.hexdigest() == EXPECTED_SHA256, digest.hexdigest()
with open(os.path.join(GBC, "scene.pkg"), "rb") as handle:
    gbc_digest = hashlib.sha256()
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        gbc_digest.update(chunk)
assert gbc_digest.hexdigest() == GBC_EXPECTED_SHA256, gbc_digest.hexdigest()


def message(kind, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": "puppet-temporal",
        **values,
    }


process = subprocess.Popen(
    [HELPER],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)


def exchange(kind, expected, **values):
    process.stdin.write(json.dumps(message(kind, **values)) + "\n")
    process.stdin.flush()
    readable, _, _ = select.select([process.stdout], [], [], 90)
    assert readable, (kind, "timed out")
    event = json.loads(process.stdout.readline())
    assert event["type"] == expected, event
    return event


def puppet_evidence():
    return exchange("capture-puppet-evidence", "puppet-evidence")


ready = exchange(
    "load",
    "ready",
    path=HYUGA,
    assetRoot=ASSETS,
    width=320,
    height=180,
    visible=True,
    evidenceFrames=2,
)
assert ready["backend"] == EXPECTED_BACKEND, ready
assert ready["drawComplete"] is True, ready
assert ready["range"][0] < ready["range"][1], ready
assert "puppet animation layers are not yet applied" not in ready["warnings"], ready
assert not any("puppet" in warning for warning in ready["warnings"]), ready
assert not any("masks" in warning or "attachments" in warning for warning in ready["warnings"]), ready

loaded = puppet_evidence()
assert loaded["loadedMeshes"] == 2, loaded
assert loaded["loadedVertices"] == 790, loaded
assert loaded["loadedMasks"] == 2, loaded
assert loaded["loadedAttachments"] == 0, loaded
assert loaded["simulationEnabledBoneCount"] == 0, loaded
assert loaded["activeIKBoneCount"] == 0, loaded
assert loaded["deformationUploads"] >= 6, loaded
assert loaded["deformationChanges"] > 0, loaded
assert loaded["maskPasses"] > 0, loaded

time.sleep(0.30)
first = exchange("capture-frame-difference", "frame-difference")
time.sleep(0.30)
second = exchange("capture-frame-difference", "frame-difference")
for difference in (first, second):
    assert difference["changedPixels"] > 100, difference
    assert difference["maximumChannelDelta"] > 0, difference

advanced = puppet_evidence()
assert advanced["deformationUploads"] > loaded["deformationUploads"], advanced
assert advanced["deformationChanges"] > loaded["deformationChanges"], advanced
assert advanced["maskPasses"] > loaded["maskPasses"], advanced

exchange("pause", "paused")
paused = puppet_evidence()
time.sleep(0.15)
assert puppet_evidence() == paused
exchange("resume", "resumed")
exchange("capture-frame-difference", "frame-difference")
resumed = puppet_evidence()
assert resumed["deformationUploads"] > paused["deformationUploads"], resumed
assert resumed["deformationChanges"] > paused["deformationChanges"], resumed

gbc_ready = exchange(
    "load",
    "ready",
    path=GBC,
    assetRoot=ASSETS,
    width=320,
    height=180,
    visible=True,
    evidenceFrames=2,
)
assert gbc_ready["backend"] == EXPECTED_BACKEND, gbc_ready
assert gbc_ready["drawComplete"] is True, gbc_ready
assert not any(
    "puppet secondary motion" in warning for warning in gbc_ready["warnings"]
), gbc_ready
gbc = puppet_evidence()
assert gbc["loadedMeshes"] == 9, gbc
assert gbc["loadedVertices"] == 3019, gbc
assert gbc["loadedMasks"] == 0, gbc
assert gbc["loadedAttachments"] == 4, gbc
assert gbc["simulationEnabledBoneCount"] == 5, gbc
assert gbc["activeIKBoneCount"] == 0, gbc
assert gbc["secondaryMotionChanges"] > 0, gbc
assert gbc["attachmentResolutions"] > 0, gbc
assert gbc["deformationChanges"] > 0, gbc

exchange("stop", "stopped")
process.stdin.close()
process.wait(timeout=10)
stderr = process.stderr.read()
assert not stderr, stderr

print(
    f"Puppet renderer evidence: {EXPECTED_BACKEND} Hyuga deformation/masks, "
    "pause, and GBC attachment resolution passed"
)
