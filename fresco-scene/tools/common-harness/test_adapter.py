#!/usr/bin/env python3

import copy
import hashlib
import os
import pathlib
import tempfile
import textwrap
import unittest
import subprocess

import adapter
import contract
import source_manifest


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


FAKE_HELPER = r'''#!/usr/bin/env python3
import json
import os
import sys
import time

MODE = __MODE__
PID_PATH = __PID_PATH__
if PID_PATH:
    with open(PID_PATH, "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()))

frames = 2
evaluations = 1
presentations = 0
decisions = 1
invalidations = 0
changed = False
metric_calls = 0
elapsed = 0
target_fps = 60
load_calls = 0
SCRIPT_MODES = (
    "superficial-script", "early-script", "missing-script",
    "early-deadline-script",
)
PARTICLE_MODES = (
    "superficial-particle", "unbounded-particle", "resource-churn-particle",
    "no-release-particle", "inconsistent-arithmetic-particle",
)

def scheduler():
    return {
        "invalidations": invalidations,
        "decisions": decisions,
        "evaluations": evaluations,
        "presentations": presentations,
        "presentationSuppressions": 0,
        "notEvaluated": 0,
        "externalPresentations": 1,
        "missedDeadlines": 0,
        "scriptTimerDeadlineSchedules": (
            1 if MODE in SCRIPT_MODES
            else 0
        ),
        "scriptTimerDeadlineReleases": 0,
        "particleLeaseAcquisitions": 1 if MODE in PARTICLE_MODES else 0,
        "particleLeaseReleases": (
            1 if MODE in PARTICLE_MODES
            and MODE != "no-release-particle" and metric_calls >= 5 else 0
        ),
        "reasonCounts": [0] * 14,
        "nextWakeNanoseconds": None,
        "lastDecision": None,
        "lastCompletion": None,
    }

def emit(kind, assignment, **values):
    print(json.dumps({
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": assignment,
        **values,
    }), flush=True)

for line in sys.stdin:
    command = json.loads(line)
    assignment = command["assignmentID"]
    kind = command["type"]
    if MODE == "timeout":
        time.sleep(60)
        continue
    if MODE == "malformed":
        print("not-json", flush=True)
        continue
    backend = "wrong-backend" if MODE == "wrong-backend" else "native-opengl"
    graphics_api = "wrong API" if MODE == "wrong-api" else "OpenGL 4.1 core"
    shader_target = (
        {"language": "GLSL", "profile": "embedded", "version": 300}
        if MODE == "wrong-shader" else
        {"language": "GLSL", "profile": "desktop-core", "version": 410}
    )
    if kind == "hello":
        emit(
            "hello", assignment, backend=backend, renderer="opengl-4.1-2d",
            graphicsAPI=graphics_api, shaderTarget=shader_target,
        )
    elif kind == "load":
        load_calls += 1
        target_fps = command.get("fps", 60)
        ready_graphics_api = (
            "wrong ready API" if MODE == "wrong-ready-api" else graphics_api
        )
        script_values = ({
            "genericPropertyScripts": 1,
            "continuousGenericPropertyScripts": 0,
            "deferredScriptValues": 0,
            "scriptTimers": {
                "scheduled": 1, "fired": 0, "cancelled": 0, "pending": 1,
                "lastScheduledDelayMilliseconds": 50,
            },
        } if MODE in SCRIPT_MODES else {})
        if MODE == "early-script":
            script_values["scriptTimers"].update({"fired": 1, "pending": 0})
        particle_values = ({
            "warnings": ([
                "1 particle systems have unknown lifecycle and remain continuously scheduled"
            ] if load_calls == 1 else [])
        } if MODE in PARTICLE_MODES else {})
        emit(
            "ready", assignment, backend=backend, renderer="opengl-4.1-2d",
            graphicsAPI=ready_graphics_api, shaderTarget=shader_target,
            drawComplete=True, schedulingMode=(
                "legacy-continuous" if MODE == "under-speed"
                else "legacy-continuous" if MODE in PARTICLE_MODES and load_calls == 1
                else "tracked-particle-lifecycle" if MODE in PARTICLE_MODES
                else "static-present-on-change"
            ),
            schedulingMechanism="change-index-v1", schedulingEvidence=scheduler(),
            frames=frames, targetFPS=60, policyRevision=1,
            programCacheEntries=1 if MODE in PARTICLE_MODES else 0,
            programCacheInsertions=1 if MODE in PARTICLE_MODES else 0,
            display={
                "logicalWidth": 320, "logicalHeight": 180,
                "pixelWidth": 640, "pixelHeight": 360, "scaleMilli": 2000,
                "maximumRefreshMilliHertz": 60000, "colorSpace": "Synthetic sRGB",
            },
            **script_values,
            **particle_values,
        )
    elif kind == "metrics":
        metrics_graphics_api = (
            "wrong metrics API" if MODE == "wrong-metrics-api" else graphics_api
        )
        if MODE == "under-speed" and metric_calls:
            elapsed += 800
            frames += 2
        if MODE == "under-speed":
            metric_calls += 1
            reason_counts = scheduler()["reasonCounts"]
            reason_counts[6] = 1
            reason_counts[8] = 1
            scheduling_evidence = scheduler()
            scheduling_evidence["reasonCounts"] = reason_counts
        else:
            scheduling_evidence = scheduler()
        particle_metrics = {}
        if MODE in PARTICLE_MODES:
            metric_calls += 1
            unknown_particle = metric_calls == 1
            catch_up = metric_calls >= 4
            quiescent = metric_calls >= 5
            frames = 6 if quiescent else 3 if catch_up else 2
            particle_metrics = {
                "renderAllocations": {
                    "shaders": {
                        "allocations": (
                            2 if MODE == "resource-churn-particle" and catch_up
                            else 1
                        ),
                        "deallocations": 0,
                    },
                },
                "particles": {
                    "systems": 1,
                    "finiteSystems": 0 if unknown_particle else 1,
                    "unknownSystems": 1 if unknown_particle else 0,
                    "minimumSeed": 43 if unknown_particle else 42,
                    "maximumSeed": 43 if unknown_particle else 42,
                    "emitted": 8, "live": 0 if quiescent else 8,
                    "peakLive": 8, "poolCapacity": 16, "poolResizes": 0,
                    "resourceInitializations": 1,
                    "updates": 0 if MODE == "superficial-particle" else (
                        5 if quiescent else 2 if catch_up else 1
                    ),
                    "stateHash": 0 if quiescent else 123,
                    "requestedMilliseconds": (
                        1133 if quiescent else 1033 if catch_up else 33
                    ),
                    "simulatedMilliseconds": (
                        183 if quiescent
                        else 83 if MODE == "inconsistent-arithmetic-particle"
                            and catch_up
                        else 133 if catch_up else 33
                    ),
                    "droppedMilliseconds": 900 if catch_up else 0,
                    "catchUpFrames": 1 if catch_up else 0,
                    "maximumRequestedMilliseconds": 1000 if catch_up else 33,
                    "maximumSimulatedMilliseconds": (
                        1000 if MODE == "unbounded-particle" and catch_up
                        else 100 if catch_up else 33
                    ),
                    "droppedMilliseconds": 900 if catch_up else 0,
                    "continuousRequired": not quiescent,
                    "quiescent": quiescent,
                },
            }
            scheduling_evidence = scheduler()
            scheduling_evidence["reasonCounts"][6] = 1
        if MODE in ("superficial-script", "missing-script"):
            scheduling_evidence["lastDecision"] = {
                "evaluate": True,
                "reasons": {"values": [6]},
                "leaseOccurrences": {"values": [{"id": 1, "mode": 3}]},
            }
        elif MODE == "early-deadline-script":
            scheduling_evidence["lastDecision"] = {
                "evaluate": True,
                "timeNanoseconds": 10_000_000,
                "reasons": {"values": [4]},
                "leaseOccurrences": {"values": [{
                    "id": 2, "mode": 1,
                    "scheduledTimeNanoseconds": 8_000_000,
                }]},
            }
        emit(
            "metrics", assignment, backend=backend,
            graphicsAPI=metrics_graphics_api,
            shaderTarget=shader_target,
            schedulingMechanism="change-index-v1",
            schedulingEvidence=scheduling_evidence,
            frames=frames, targetFPS=target_fps,
            elapsedMilliseconds=(elapsed if MODE == "under-speed" else 1000),
            policyRevision=1, active=True, paused=False,
            programCacheEntries=1 if MODE in PARTICLE_MODES else 0,
            programCacheInsertions=1 if MODE in PARTICLE_MODES else 0,
            **({
                "scriptTimers": {
                    "scheduled": 1,
                    "fired": 0 if MODE == "missing-script" else 1,
                    "cancelled": 0,
                    "pending": 1 if MODE == "missing-script" else 0,
                    "lastScheduledDelayMilliseconds": 50,
                },
            } if MODE in (
                "superficial-script", "missing-script", "early-deadline-script"
            ) else {}),
            **particle_metrics,
        )
        decisions += 1
    elif kind == "scheduling-policy":
        target_fps = command["fpsCeiling"]
        emit(
            "scheduling-policy-applied", assignment,
            fpsCeiling=target_fps, policyRevision=command["policyRevision"],
        )
    elif kind == "user-properties":
        invalidations += 1
        frames += 1
        evaluations += 1
        presentations += 1
        decisions += 1
        emit("user-properties-applied", assignment)
    elif kind == "stop":
        emit("stopped", assignment)
        raise SystemExit(0)
'''


MEDIA_FAKE_HELPER = r'''#!/usr/bin/env python3
import json
import os
import sys

MODE = __MODE__
PID_PATH = __PID_PATH__
if PID_PATH:
    with open(PID_PATH, "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()))

loads = 0
metric_calls = 0
seeks = 0
active = True
paused = False
deadline_releases = 0
deadline_schedules = 1
deadline_replacements = 0
deadline_active = True
terminal_deadline_released = False
inactive_metric_calls = 0
activations = 0
eos_metric_calls = 0

def emit(kind, assignment, **values):
    print(json.dumps({
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": assignment,
        **values,
    }), flush=True)

def scheduler(phase):
    values = {
        0: (0, 0, 1, 0, 0),
        1: (0, 0, 1, 0, metric_calls),
        2: (2, 2, 3, 0, 4),
        3: (5, 5, 6, 0, 8),
        4: (6, 6, 6, 1, 10),
        5: (6, 6, 6, 1, 11),
    }
    invalidations, evaluations, presentations, suppressions, decisions = values[phase]
    if phase == 2:
        invalidations += activations
        evaluations += activations
        presentations += activations
        decisions += activations
    if MODE == "render-stalled-media" and phase >= 4:
        presentations += 1
        suppressions = 0
    return {
        "invalidations": invalidations,
        "decisions": decisions,
        "evaluations": evaluations,
        "presentations": presentations,
        "presentationSuppressions": suppressions,
        "notEvaluated": decisions - evaluations,
        "externalPresentations": 1,
        "missedDeadlines": 0,
        "scriptTimerDeadlineSchedules": 0,
        "scriptTimerDeadlineReleases": 0,
        "particleLeaseAcquisitions": 0,
        "particleLeaseReleases": 0,
        "mediaFrameDeadlineSchedules": deadline_schedules,
        "mediaFrameDeadlineReplacements": deadline_replacements,
        "mediaFrameDeadlineReleases": (
            deadline_releases
            + (max(0, inactive_metric_calls - 1)
               if MODE == "deadline-churn-media" else 0)
        ),
        "mediaFrameDeadlineActive": deadline_active,
        "mediaFrameReadyInvalidations": (
            (
                2 + activations if phase == 2
                else ({3: 5, 4: 6, 5: 6}.get(phase, 0))
            )
            + (1 if MODE == "queued-ready-media" and phase >= 2 else 0)
        ),
        "mediaFrameReadyPresentations": (
            2 + activations if phase == 2
            else ({3: 5, 4: 6, 5: 6}.get(phase, 0))
        ),
        "lastMediaFrameReadyRevision": (
            8 if MODE == "queued-ready-media" and phase >= 2
            else (7 if phase >= 2 else None)
        ),
        "lastPresentedMediaFrameReadyRevision": (
            8 if MODE == "late-ready-media" and phase >= 2
            else (7 if phase >= 2 else None)
        ),
        "lastMediaFrameReadyDecisionSequence": 3 if phase >= 2 else None,
        "reasonCounts": [0] * 14,
        "nextWakeNanoseconds": None,
        "lastDecision": None,
        "lastCompletion": None,
    }

def media(phase):
    frames_by_phase = {0: 1, 1: 1, 2: 3 + activations, 3: 8, 4: 8, 5: 8}
    uploads_by_phase = {0: 1, 1: 1, 2: 3 + activations, 3: 6, 4: 6, 5: 6}
    ready_by_phase = dict(uploads_by_phase)
    if MODE == "queued-ready-media":
        for queued_phase in range(2, 6):
            ready_by_phase[queued_phase] += 1
    if MODE == "superficial-media" and phase >= 2:
        frames_by_phase[phase] += 1
    if MODE == "inactive-churn-media" and not active:
        frames_by_phase[phase] += inactive_metric_calls
    if MODE == "no-ready-media" and phase >= 2:
        ready_by_phase[phase] = 1
    uploads = uploads_by_phase[phase]
    ready = ready_by_phase[phase]
    decoded = max(ready, uploads) + 1
    values = {
        "players": 1,
        "referencedPlayers": 1,
        "decodeAttempts": decoded + (1 if phase >= 4 else 0),
        "decodedFrames": decoded,
        "frameReadyEvents": ready,
        "stalledFrames": 1 if phase >= 4 else 0,
        "frameUploads": uploads,
        "pendingFrames": 1 if phase == 1 else 0,
        "seekRequests": seeks,
        "fallbackPlayers": 0,
        "globalLivePlayers": 1,
        "globalPlayerConstructions": loads,
        "globalPlayerDestructions": loads - 1,
        "lastDecodedFrameHash": 222 if phase >= 3 else 111,
        "decodedFrameSequenceHash": 333 + phase,
        "endOfStreamPlayers": 1 if phase >= 4 else 0,
        "decodeMilliseconds": 1.0,
        "uploadSubmissionMilliseconds": 0.5,
        "lastDecodedPresentationSeconds": (
            1.0 if phase >= 3 else (0.25 + 0.25 * activations)
        ),
        "decodes": uploads,
    }
    if MODE == "reload-leak-media" and loads > 1:
        values["seekRequests"] = 2
        values["decodeAttempts"] = 5
        values["decodedFrames"] = 5
        values["frameUploads"] = 4
        values["frameReadyEvents"] = 4
        values["decodes"] = 4
    if MODE == "conflated-media":
        values.pop("decodeMilliseconds")
    return frames_by_phase[phase], values

for line in sys.stdin:
    command = json.loads(line)
    assignment = command["assignmentID"]
    kind = command["type"]
    candidate = {
        "backend": "native-opengl",
        "renderer": "opengl-4.1-2d",
        "graphicsAPI": "OpenGL 4.1 core",
        "shaderTarget": {
            "language": "GLSL", "profile": "desktop-core", "version": 410,
        },
    }
    if kind == "hello":
        emit("hello", assignment, **candidate)
    elif kind == "load":
        loads += 1
        metric_calls = 0
        seeks = 0
        active = True
        paused = False
        activations = 0
        deadline_releases = 0
        deadline_schedules = 0 if MODE == "missing-acquire-media" else 1
        deadline_replacements = 0
        deadline_active = True
        terminal_deadline_released = False
        emit(
            "ready", assignment, **candidate, drawComplete=True,
            schedulingMode="tracked-media-lifecycle",
            schedulingMechanism="change-index-v1",
            schedulingEvidence=scheduler(0), warnings=[], frames=1,
            targetFPS=30, policyRevision=1,
            programCacheEntries=1, programCacheInsertions=1,
            display={
                "logicalWidth": 320, "logicalHeight": 180,
                "pixelWidth": 640, "pixelHeight": 360, "scaleMilli": 2000,
                "maximumRefreshMilliHertz": 60000,
                "colorSpace": "Synthetic sRGB",
            },
        )
    elif kind == "media-video":
        seeks += 1
        if deadline_active and MODE != "no-replacement-media":
            deadline_replacements += (
                2 if MODE == "extra-replacement-media" else 1
            )
        if seeks == 2:
            eos_metric_calls = 0
        emit("media-video-applied", assignment, action="seek",
             positionSeconds=command["positionSeconds"], players=1)
    elif kind in ("pause", "hide"):
        active = False
        paused = kind == "pause"
        if MODE != "no-release-media":
            deadline_releases += 1
        deadline_active = False
        inactive_metric_calls = 0
        emit("paused" if paused else "hidden", assignment)
    elif kind in ("resume", "show"):
        active = True
        paused = False
        activations += 1
        deadline_schedules += 1
        deadline_active = True
        emit("resumed" if kind == "resume" else "shown", assignment)
    elif kind == "metrics":
        if active:
            metric_calls += 1
        elif MODE == "inactive-churn-media":
            metric_calls += 1
        if not active:
            inactive_metric_calls += 1
        if seeks >= 2:
            eos_metric_calls += 1
        if loads > 1 and seeks >= 1:
            phase = 3
        elif loads > 1:
            phase = 1
        elif seeks >= 2:
            phase = min(5, 3 + eos_metric_calls)
        elif seeks == 1:
            phase = 3
        else:
            phase = 2 if (
                MODE == "busy-poll-media" and metric_calls >= 2
            ) else min(2, max(1, metric_calls - 1))
        if phase >= 4 and not terminal_deadline_released:
            deadline_releases += 1
            deadline_active = False
            terminal_deadline_released = True
        frames, media_values = media(phase)
        if MODE == "render-stalled-media" and phase >= 4:
            frames += 1
        emit(
            "metrics", assignment, **candidate,
            schedulingMechanism="change-index-v1",
            schedulingEvidence=scheduler(phase), frames=frames,
            targetFPS=30, elapsedMilliseconds=1000, policyRevision=1,
            active=active, paused=paused, programCacheEntries=1,
            programCacheInsertions=1, mediaTextures=media_values,
        )
    elif kind == "stop":
        emit("stopped", assignment, mediaTextureLifecycle={
            "livePlayers": 1 if MODE == "teardown-leak-media" else 0,
            "constructions": loads,
            "destructions": loads - (1 if MODE == "teardown-leak-media" else 0),
        })
        raise SystemExit(0)
'''


AUDIO_FAKE_HELPER = r'''#!/usr/bin/env python3
import json
import os
import struct
import sys

MODE = __MODE__
PID_PATH = __PID_PATH__
if PID_PATH:
    with open(PID_PATH, "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()))

loads = 0
exact_metrics = 0
frames = 1
evaluations = 0
presentations = 1
decisions = 0
inputs = 0
input_changes = 0
vector_updates = 1
vector_changes = 1
invalidations = 0
ready_presentations = 0
last_revision = None
presented_revision = None
deadline_schedules = 1
deadline_replacements = 0
deadline_releases = 0
deadline_active = True
paused = False
phase = "initial"
quiescence_observations = 0
vector_value = 0.0
pending_average = 0.0

def float_hash(values):
    value = 1469598103934665603
    for item in values:
        for byte in struct.pack("<f", float(item)):
            value ^= byte
            value = (value * 1099511628211) & ((1 << 64) - 1)
    return value

def vector_evidence(values):
    left = [sum(values[index:index + 4]) / 4.0
            for index in range(0, 64, 4)]
    right = [sum(values[index:index + 4]) / 4.0
             for index in range(64, 128, 4)]
    value = float_hash(left) ^ (
        (float_hash(right) * 1099511628211) & ((1 << 64) - 1)
    )
    return value, (left[0] + right[0]) * 0.5

def emit(kind, assignment, **values):
    print(json.dumps({
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": assignment,
        **values,
    }), flush=True)

def scheduler(unknown=False):
    reason_counts = [0] * 14
    if unknown:
        reason_counts[6] = 1
    return {
        "invalidations": invalidations,
        "decisions": decisions,
        "evaluations": evaluations,
        "presentations": presentations,
        "presentationSuppressions": 0,
        "notEvaluated": max(0, decisions - evaluations),
        "externalPresentations": 1,
        "missedDeadlines": 0,
        "scriptTimerDeadlineSchedules": 0,
        "scriptTimerDeadlineReleases": 0,
        "particleLeaseAcquisitions": 0,
        "particleLeaseReleases": 0,
        "mediaFrameDeadlineSchedules": 0,
        "mediaFrameDeadlineReplacements": 0,
        "mediaFrameDeadlineReleases": 0,
        "mediaFrameDeadlineActive": False,
        "mediaFrameReadyInvalidations": 0,
        "mediaFrameReadyPresentations": 0,
        "lastMediaFrameReadyRevision": None,
        "lastPresentedMediaFrameReadyRevision": None,
        "lastMediaFrameReadyDecisionSequence": None,
        "audioEnvelopeDeadlineSchedules": deadline_schedules,
        "audioEnvelopeDeadlineReplacements": deadline_replacements,
        "audioEnvelopeDeadlineReleases": deadline_releases,
        "audioEnvelopeDeadlineActive": deadline_active,
        "audioReadyInvalidations": invalidations,
        "audioReadyPresentations": ready_presentations,
        "lastAudioReadyRevision": last_revision,
        "lastPresentedAudioReadyRevision": presented_revision,
        "lastAudioReadyDecisionSequence": (
            decisions if ready_presentations else None
        ),
        "reasonCounts": reason_counts,
        "nextWakeNanoseconds": 200000000 if deadline_active else None,
        "lastDecision": None,
        "lastCompletion": None,
    }

def metrics(assignment, unknown=False):
    sound_controls = []
    if MODE == "output-playback-leakage-audio" and loads == 3:
        sound_controls = [{"id": 1, "playRequests": 1}]
    emit(
        "metrics", assignment, backend="native-opengl",
        graphicsAPI="OpenGL 4.1 core",
        shaderTarget={
            "language": "GLSL", "profile": "desktop-core", "version": 410,
        },
        schedulingMechanism="change-index-v1",
        schedulingEvidence=scheduler(unknown), frames=frames, targetFPS=5,
        elapsedMilliseconds=1000, policyRevision=1, active=not paused,
        paused=paused, muted=True, visible=True,
        programCacheEntries=1, programCacheInsertions=1,
        genericPropertyScripts=1, continuousGenericPropertyScripts=1,
        deferredScriptValues=0, audioVectorScripts=1,
        exactTrackedAudioVectorScripts=1 if loads >= 3 else 0,
        audioVectorValueX=vector_value,
        audioVectorScriptUpdates=vector_updates,
        audioVectorScriptChanges=vector_changes,
        audioEnvelopeContinuousRequired=deadline_active,
        audioSpectrumInputs=inputs, audioSpectrumChanges=input_changes,
        audioSpectrumHash=0, audioVectorHash=0, audioVectorAverage0=0,
        genericPropertyScriptErrors=0, scriptErrors=0,
        soundControls=sound_controls, mediaTextures={"players": 0},
    )

for line in sys.stdin:
    command = json.loads(line)
    assignment = command["assignmentID"]
    kind = command["type"]
    candidate = {
        "backend": "native-opengl", "renderer": "opengl-4.1-2d",
        "graphicsAPI": "OpenGL 4.1 core",
        "shaderTarget": {
            "language": "GLSL", "profile": "desktop-core", "version": 410,
        },
    }
    if kind == "hello":
        emit("hello", assignment, **candidate)
    elif kind == "load":
        loads += 1
        exact_metrics = 0
        frames = 1
        evaluations = 0
        presentations = 1
        decisions = 0
        inputs = 2 if MODE == "reload-leakage-audio" and loads == 4 else 0
        input_changes = inputs
        vector_updates = 1
        vector_changes = 1
        invalidations = inputs
        ready_presentations = 0
        last_revision = None
        presented_revision = None
        deadline_schedules = (
            0 if MODE == "missing-schedule-audio" and loads >= 3 else 1
        )
        deadline_replacements = 0
        deadline_releases = 0
        deadline_active = True
        paused = False
        phase = "initial"
        quiescence_observations = 0
        vector_value = 0.0
        pending_average = 0.0
        deadline_active = deadline_schedules > 0
        emit(
            "ready", assignment, **candidate, drawComplete=True,
            schedulingMode=(
                "legacy-continuous" if loads <= 2
                else "tracked-audio-lifecycle"
            ),
            schedulingMechanism="change-index-v1",
            schedulingEvidence=scheduler(loads == 1), warnings=[], frames=1,
            targetFPS=5, policyRevision=1,
            programCacheEntries=1, programCacheInsertions=1,
            display={
                "logicalWidth": 320, "logicalHeight": 180,
                "pixelWidth": 640, "pixelHeight": 360, "scaleMilli": 2000,
                "maximumRefreshMilliHertz": 60000,
                "colorSpace": "Synthetic sRGB",
            },
        )
    elif kind == "audio-spectrum":
        inputs += 1
        input_changes += 1
        invalidations += 0 if MODE == "missing-ready-audio" else 1
        last_revision = invalidations if invalidations else None
        values = command["values"]
        vector_hash, average = vector_evidence(values)
        pending_average = average
        spectrum_hash = float_hash(values)
        if MODE == "wrong-content-audio" and inputs == 3:
            spectrum_hash ^= 1
        if MODE == "frame-only-audio":
            input_changes -= 1
        if MODE == "cadence-coupled-audio" and paused:
            frames += 1
            evaluations += 1
            presentations += 1
        phase = "input-pending"
        emit(
            "audio-spectrum-applied", assignment,
            changed=MODE != "frame-only-audio", inputs=inputs,
            changes=input_changes, spectrumHash=spectrum_hash,
            vectorHash=vector_hash, vectorAverage0=average,
        )
    elif kind == "pause":
        paused = True
        if deadline_active and not (
            MODE == "missing-cancellation-release-audio" and inputs >= 4
        ):
            deadline_releases += 1
        deadline_active = False
        emit("paused", assignment, paused=True)
    elif kind == "resume":
        paused = False
        if phase == "input-pending":
            phase = "accept"
        else:
            phase = "resume-settle"
            deadline_schedules += 1
            deadline_active = True
        emit("resumed", assignment)
    elif kind == "metrics":
        if loads <= 2:
            metrics(assignment, True)
            continue
        exact_metrics += 1
        if phase == "initial" and exact_metrics >= 2:
            frames = 2
            evaluations = 1
            presentations = 2
            decisions += 1
            vector_updates = 2
            deadline_active = False
            phase = "idle"
        elif phase == "accept":
            frames += 1
            evaluations += 1
            presentations += 1
            decisions += 1
            vector_updates += 1
            vector_changes += 1
            if MODE != "stale-graph-audio":
                vector_value = pending_average
            ready_presentations += 1
            presented_revision = (
                (last_revision or 0) + 1
                if MODE == "late-invalidation-audio" else last_revision
            )
            deadline_schedules += 1
            deadline_active = True
            phase = "settle"
        elif phase == "settle":
            frames += 1
            evaluations += 1
            presentations += 1
            decisions += 1
            vector_updates += 1
            deadline_active = False
            if MODE == "deadline-churn-audio":
                deadline_replacements += 1
            phase = "idle"
        elif phase == "input-pending" and not paused:
            phase = "accept"
            frames += 1
            evaluations += 1
            presentations += 1
            decisions += 1
            vector_updates += 1
            vector_changes += 1
            if MODE != "stale-graph-audio":
                vector_value = pending_average
            ready_presentations += 1
            presented_revision = last_revision
            deadline_schedules += 1
            deadline_active = True
            phase = "settle"
        elif phase == "resume-settle":
            frames += 1
            evaluations += 1
            presentations += 1
            decisions += 1
            vector_updates += 1
            deadline_active = False
            phase = "idle"
        elif phase == "idle" and inputs >= 5:
            quiescence_observations += 1
            if (MODE == "false-silence-quiescence-audio"
                    and quiescence_observations >= 1):
                frames += 1
                evaluations += 1
                presentations += 1
        metrics(assignment)
    elif kind == "stop":
        emit("stopped", assignment)
        raise SystemExit(0)
'''


EFFECT_FAKE_HELPER = r'''#!/usr/bin/env python3
import json
import os
import sys

MODE = __MODE__
PID_PATH = __PID_PATH__
if PID_PATH:
    with open(PID_PATH, "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()))

loads = 0
hidden = False
frames = 2
puppet = None
puppet_captures = 0

VISIBLE = {
    "pixelRGBAHash": 6423138637018365467,
    "varyingPixels": 4356,
    "pixelProbes": [{
        "identity": "center", "normalized": [500, 500],
        "pixel": [320, 180], "rgba": [108, 177, 123, 0],
    }],
    "pixelRegions": [{
        "identity": "center-region", "normalized": [450, 450, 550, 550],
        "pixels": [288, 162, 352, 198], "pixelCount": 2304,
        "varyingPixels": 2232, "pixelRGBTotal": 933840,
        "pixelRGBAHash": 13348467752093860867,
    }],
}
HIDDEN = {
    "pixelRGBAHash": 11913877822352892803,
    "varyingPixels": 0,
    "pixelProbes": [{
        "identity": "center", "normalized": [500, 500],
        "pixel": [320, 180], "rgba": [10, 20, 31, 0],
    }],
    "pixelRegions": [{
        "identity": "center-region", "normalized": [450, 450, 550, 550],
        "pixels": [288, 162, 352, 198], "pixelCount": 2304,
        "varyingPixels": 0, "pixelRGBTotal": 140544,
        "pixelRGBAHash": 6020669535967767427,
    }],
}
PASSES = [
    {"objectID": 101, "shader": "genericimage4", "authoredTarget": "<none>",
     "drawTarget": "_rt_imageLayerComposite_101_a", "input": "<texture>",
     "previousInput": False, "blendingMode": 1, "truncatedTokens": 0},
    {"objectID": 101, "shader": "effects/fresco_ordered_a",
     "authoredTarget": "_rt_fresco_order_a", "drawTarget": "_rt_fresco_order_a",
     "input": "_rt_imageLayerComposite_101_a", "previousInput": True,
     "blendingMode": 1, "truncatedTokens": 0},
    {"objectID": 101, "shader": "effects/fresco_ordered_b",
     "authoredTarget": "_rt_fresco_order_b", "drawTarget": "_rt_fresco_order_b",
     "input": "_rt_fresco_order_a", "previousInput": True,
     "blendingMode": 1, "truncatedTokens": 0},
    {"objectID": 101, "shader": "effects/fresco_ordered_composite",
     "authoredTarget": "<none>", "drawTarget": "_rt_FullFrameBuffer",
     "input": "_rt_fresco_order_b", "previousInput": True,
     "blendingMode": 2, "truncatedTokens": 0},
]
PUPPET_MASKED = {
    "pixelRGBAHash": 16300020904919580163, "pixelRGBTotal": 15889920,
    "varyingPixels": 8036,
    "pixelProbes": [
        {"identity": "source", "normalized": [400, 500],
         "pixel": [256, 180], "rgba": [220, 40, 40, 0]},
        {"identity": "target", "normalized": [575, 500],
         "pixel": [367, 180], "rgba": [10, 20, 31, 0]},
    ],
    "pixelRegions": [
        {"identity": "source-region", "normalized": [380, 450, 420, 550],
         "pixels": [243, 162, 269, 198], "pixelCount": 936,
         "varyingPixels": 0, "pixelRGBTotal": 280800,
         "pixelRGBAHash": 7263521872091169731},
        {"identity": "target-region", "normalized": [550, 450, 600, 550],
         "pixels": [352, 162, 384, 198], "pixelCount": 1152,
         "varyingPixels": 0, "pixelRGBTotal": 70272,
         "pixelRGBAHash": 15728483836435003267},
    ],
}
PUPPET_UNMASKED = {
    "pixelRGBAHash": 8502827985783239311, "pixelRGBTotal": 18135374,
    "varyingPixels": 15908,
    "pixelProbes": [PUPPET_MASKED["pixelProbes"][0],
                    {"identity": "target", "normalized": [575, 500],
                     "pixel": [367, 180], "rgba": [40, 220, 80, 0]}],
    "pixelRegions": [PUPPET_MASKED["pixelRegions"][0],
                     {"identity": "target-region",
                      "normalized": [550, 450, 600, 550],
                      "pixels": [352, 162, 384, 198], "pixelCount": 1152,
                      "varyingPixels": 0, "pixelRGBTotal": 391680,
                      "pixelRGBAHash": 2623790397109229443}],
}

def emit(kind, assignment, **values):
    print(json.dumps({"protocolVersion": 1, "type": kind,
                      "assignmentID": assignment, **values}), flush=True)

def candidate():
    return {
        "backend": "native-opengl", "renderer": "opengl-4.1-2d",
        "graphicsAPI": "OpenGL 4.1 core",
        "shaderTarget": {"language": "GLSL", "profile": "desktop-core",
                         "version": 410},
    }

def scheduler(damage=False):
    damage_value = None
    if damage:
        damage_value = {
            "conservativeUnknown": MODE != "bounded-damage-effect",
            "expansion": ("identifiers-only" if MODE == "bounded-damage-effect"
                          else "full-frame"),
            "affectedIDs": {"count": 0, "values": [], "truncated": 0},
        }
    return {
        "invalidations": 1 if hidden else 0, "decisions": 2,
        "evaluations": 1, "presentations": 1,
        "presentationSuppressions": 0, "notEvaluated": 0,
        "externalPresentations": 1, "missedDeadlines": 0,
        "reasonCounts": [0] * 14, "nextWakeNanoseconds": None,
        "lastCompletion": None,
        "lastDecision": ({"damage": damage_value} if damage else None),
    }

def allocations(stopped=False):
    live = 0 if stopped and MODE != "teardown-leak-effect" else 2
    allocated = 4 if loads >= 2 else 2
    deallocated = (allocated if stopped and MODE != "teardown-leak-effect"
                   else 2 if loads >= 2 else 0)
    counts = {"live": live, "peak": 4, "allocations": allocated,
              "deallocations": deallocated}
    empty = {"live": 0, "peak": 0, "allocations": 0, "deallocations": 0}
    return {
        "shaders": empty, "shaderVariables": empty, "passAttributes": empty,
        "passUniforms": empty, "passReferenceUniforms": empty,
        "copiedUniformValues": empty,
        "intermediateFramebuffers": counts,
        "intermediateTextures": counts,
    }

def visible_output():
    value = dict(VISIBLE)
    if MODE == "wrong-pixels-effect" or (MODE == "stale-reload-effect" and loads > 1):
        value["pixelRGBAHash"] += 1
    return value

def pass_graph():
    value = [dict(item) for item in PASSES]
    if MODE == "swapped-order-effect":
        value[1], value[2] = value[2], value[1]
    if MODE == "wrong-blend-effect":
        value[3]["blendingMode"] = 1
    return value

for line in sys.stdin:
    command = json.loads(line)
    kind = command["type"]
    assignment = command["assignmentID"]
    if kind == "hello":
        emit("hello", assignment, **candidate())
    elif kind == "load":
        loads += 1
        frames = 1
        hidden = False
        puppet = ("unmasked" if loads == 4 else "masked") if loads >= 3 else None
        puppet_captures = 0
        output = (PUPPET_UNMASKED if puppet == "unmasked"
                  else PUPPET_MASKED if puppet else visible_output())
        if MODE == "wrong-puppet-pixels-effect" and puppet == "masked":
            output = dict(output)
            output["pixelRGBAHash"] += 1
        emit(
            "ready", assignment, **candidate(), drawComplete=True, warnings=[],
            schedulingMode="legacy-continuous",
            schedulingMechanism="change-index-v1",
            schedulingEvidence=scheduler(), frames=frames, targetFPS=5,
            policyRevision=1, programCacheEntries=4,
            programCacheInsertions=4,
            display={"logicalWidth": 320, "logicalHeight": 180,
                     "pixelWidth": 640, "pixelHeight": 360,
                     "scaleMilli": 2000, "maximumRefreshMilliHertz": 60000,
                     "colorSpace": "Synthetic sRGB"},
            effectRender={"orderedPasses": ([] if puppet else pass_graph()),
                          "truncatedPasses": 0},
            **output,
        )
    elif kind == "metrics":
        emit(
            "metrics", assignment, **candidate(),
            schedulingMechanism="change-index-v1",
            schedulingEvidence=scheduler(damage=hidden), frames=frames,
            targetFPS=5, elapsedMilliseconds=500, policyRevision=1,
            active=True, paused=False, programCacheEntries=1 if puppet else 4,
            programCacheInsertions=1 if puppet else 4,
            renderAllocations=allocations(),
            effectRender={"orderedPasses": ([] if hidden or puppet else pass_graph()),
                          "truncatedPasses": 0},
        )
    elif kind == "capture-frame-difference":
        frames += 1
        output = (PUPPET_UNMASKED if puppet == "unmasked"
                  else PUPPET_MASKED if puppet == "masked"
                  else HIDDEN if hidden else visible_output())
        emit(
            "frame-difference", assignment, **candidate(), presented=True,
            changedPixels=4356 if hidden and not puppet else 0,
            maximumChannelDelta=1 if hidden else 0,
            totalChannelDelta=1 if hidden else 0,
            effectRender={"orderedPasses": ([] if hidden or puppet else pass_graph()),
                          "truncatedPasses": 0},
            **output,
        )
    elif kind == "capture-puppet-evidence":
        masked = puppet == "masked"
        puppet_captures += 1
        mask_passes = puppet_captures if masked else 0
        if (MODE == "excessive-mask-passes-effect" and masked
                and puppet_captures > 1):
            mask_passes += 1
        emit(
            "puppet-evidence", assignment, loadedMeshes=1, loadedVertices=8,
            loadedMasks=1 if masked else 0, loadedAttachments=0,
            simulationEnabledBoneCount=0, activeIKBoneCount=0,
            secondaryMotionSteps=0, secondaryMotionChanges=0,
            deformationUploads=3, deformationChanges=1,
            maskPasses=mask_passes,
            attachmentResolutions=0,
        )
    elif kind == "user-properties":
        hidden = True
        frames += 1
        emit("user-properties-applied", assignment, diagnostics=[])
    elif kind == "stop":
        emit("stopped", assignment, renderAllocations=allocations(stopped=True))
        raise SystemExit(0)
'''


RESOURCE_FAKE_HELPER = r'''#!/usr/bin/env python3
import json
import os
import sys

MODE = __MODE__
PID_PATH = __PID_PATH__
if PID_PATH:
    with open(PID_PATH, "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()))

loads = 0
active_generation = 0
frames = 0
paused = False
A = {"pixelRGBAHash": 6423138637018365467, "varyingPixels": 4356,
     "pixelProbes": [{"identity": "center", "normalized": [500, 500],
                      "pixel": [320, 180], "rgba": [108, 177, 123, 0]}],
     "pixelRegions": [{"identity": "center-region",
                       "normalized": [450, 450, 550, 550],
                       "pixels": [288, 162, 352, 198], "pixelCount": 2304,
                       "varyingPixels": 2232, "pixelRGBTotal": 933840,
                       "pixelRGBAHash": 13348467752093860867}]}
B = {"pixelRGBAHash": 5639477290515245851, "varyingPixels": 4356,
     "pixelProbes": [{"identity": "center", "normalized": [500, 500],
                      "pixel": [320, 180], "rgba": [184, 110, 170, 0]}],
     "pixelRegions": [{"identity": "center-region",
                       "normalized": [450, 450, 550, 550],
                       "pixels": [288, 162, 352, 198], "pixelCount": 2304,
                       "varyingPixels": 2232, "pixelRGBTotal": 1061784,
                       "pixelRGBAHash": 4342270343249504899}]}
PARTIAL = {"pixelRGBAHash": 7047110694911951747, "varyingPixels": 0,
           "pixelProbes": [{"identity": "center", "normalized": [500, 500],
                            "pixel": [320, 180], "rgba": [10, 20, 31, 255]}],
           "pixelRegions": [{"identity": "center-region",
                              "normalized": [450, 450, 550, 550],
                              "pixels": [288, 162, 352, 198],
                              "pixelCount": 2304, "varyingPixels": 0,
                              "pixelRGBTotal": 140544,
                              "pixelRGBAHash": 18096549202534175619}]}

def emit(kind, assignment, **values):
    print(json.dumps({"protocolVersion": 1, "type": kind,
                      "assignmentID": assignment, **values}), flush=True)

def candidate():
    return {"backend": "native-opengl", "renderer": "opengl-4.1-2d",
            "graphicsAPI": "OpenGL 4.1 core",
            "shaderTarget": {"language": "GLSL", "profile": "desktop-core",
                             "version": 410}}

def scheduler():
    return {"invalidations": 0, "decisions": 0, "evaluations": 0,
            "presentations": 1, "presentationSuppressions": 0,
            "externalPresentations": 1, "missedDeadlines": 0,
            "reasonCounts": [0] * 14}

def lifecycle(created, retired, live):
    completed = retired
    if MODE == "missing-completion-resource" and retired:
        completed -= 1
    unordered = 1 if MODE == "wrong-order-resource" and retired else 0
    publications = (
        4 if created == 1 else 5 if created <= 3
        else 5 + 4 * (created - 3)
    )
    if MODE == "publication-on-failure-resource" and created >= 2:
        publications += 1
    active_entries = (
        0 if not live else 1 if created == 2 else 0 if created == 3 else 4
    )
    deletions = publications - active_entries
    if MODE == "program-leak-resource" and retired == 6:
        deletions -= 1
    last_retired = retired
    last_deleted = (
        0 if created == 1 else 1 if created == 2 else 2 if created in (3, 4)
        else 4 if created == 5 else 6 if not live else 5
    )
    rollbacks = 0 if created == 1 else 1 if created == 2 else 2
    if MODE == "missing-rollback-resource" and created >= 2:
        rollbacks -= 1
    return {"generationsCreated": created, "generationsRetired": retired,
            "liveGenerations": live, "completionBarriersRequested": retired,
            "completionBarriersCompleted": completed,
            "completionBarriersFailed": retired - completed,
            "retirementsWithoutCompletion": unordered,
            "programPublications": publications,
            "programDeletions": deletions,
            "programRollbacks": rollbacks,
            "shaderCompileFailures": 0,
            "shaderTranslationFailures": 0,
            "programSetupFailures": 0,
            "objectSetupFailures": 0 if created == 1 else min(2, created - 1),
            "lastCreatedGeneration": created,
            "lastRetiredGeneration": last_retired,
            "lastCompletedGeneration": (
                0 if unordered else last_retired
            ),
            "lastPublishedGeneration": (
                1 if created == 1 else 2 if created <= 3 else created
            ),
            "lastDeletedGeneration": last_deleted,
            "lastObjectSetupFailureGeneration": (
                0 if created == 1 else min(3, created)
            )}

for line in sys.stdin:
    command = json.loads(line)
    kind = command["type"]
    assignment = command["assignmentID"]
    if kind == "hello":
        emit("hello", assignment, **candidate())
    elif kind == "load":
        loads += 1
        active_generation = loads
        frames = 1
        reported_generation = (
            1 if MODE == "reused-generation-resource" and loads == 4
            else active_generation
        )
        retired = 0 if loads == 1 else loads - 1
        entries = 1 if loads == 2 else 0 if loads == 3 else 4
        if MODE == "polluted-rollback-resource" and loads in (2, 3):
            entries += 1
        output = (
            PARTIAL if loads in (2, 3)
            else B if loads == 5 and MODE != "stale-output-resource"
            else A
        )
        emit("ready", assignment, **candidate(), drawComplete=True, warnings=[],
             schedulingMode="legacy-continuous",
             schedulingMechanism="change-index-v1",
             schedulingEvidence=scheduler(), frames=frames, targetFPS=5,
             policyRevision=1, resourceGeneration=reported_generation,
             renderResourceLifecycle=lifecycle(loads, retired, 1),
             programCacheEntries=entries, programCacheInsertions=entries,
             display={"logicalWidth": 320, "logicalHeight": 180,
                      "pixelWidth": 640, "pixelHeight": 360,
                      "scaleMilli": 2000, "maximumRefreshMilliHertz": 60000,
                      "colorSpace": "Synthetic sRGB"}, **output)
    elif kind == "capture-frame-difference":
        frames += 1
        emit("frame-difference", assignment, **candidate(), presented=True,
             changedPixels=0, maximumChannelDelta=0, totalChannelDelta=0, **A)
    elif kind == "pause":
        paused = True
        emit("paused", assignment)
    elif kind == "resume":
        paused = False
        emit("resumed", assignment)
    elif kind == "metrics":
        entries = 1 if loads == 2 else 0 if loads == 3 else 4
        if MODE == "polluted-rollback-resource" and loads in (2, 3):
            entries += 1
        emit("metrics", assignment, **candidate(),
             schedulingMechanism="change-index-v1",
             schedulingEvidence=scheduler(), frames=frames, targetFPS=5,
             elapsedMilliseconds=200, policyRevision=1,
             reasonTokens=["harness:resource-reload"],
             schedulingMode="legacy-continuous", active=not paused,
             paused=paused, resourceGeneration=active_generation,
             renderResourceLifecycle=lifecycle(
                 loads, 0 if loads == 1 else loads - 1, 1),
             programCacheEntries=entries, programCacheInsertions=entries)
    elif kind == "stop":
        stopped = lifecycle(6, 6, 0)
        if MODE == "teardown-leak-resource":
            stopped["generationsRetired"] = 5
            stopped["liveGenerations"] = 1
            stopped["completionBarriersRequested"] = 5
            stopped["completionBarriersCompleted"] = 5
            stopped["lastRetiredGeneration"] = 5
        emit("stopped", assignment, renderResourceLifecycle=stopped)
        raise SystemExit(0)
'''


class AdapterTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fresco-adapter-test.")
        self.root = pathlib.Path(os.path.realpath(self.temporary.name))
        self.assets = self.root / "assets"
        self.assets.mkdir()
        self.store = self.root / "store"
        self.store.mkdir()
        self.source_manifest = self.root / "source-manifest.json"
        source_value = {
            "schemaVersion": 1,
            "files": [{"path": "src/main.mm", "sha256": digest("main")}],
            "dependencies": {"rendererCommit": digest("renderer")},
            "build": {"backend": "native-opengl"},
        }
        self.source_manifest.write_bytes(contract.canonical_json_bytes(source_value))
        self.source_sha256 = contract.canonical_hash(source_value)

    def tearDown(self):
        self.temporary.cleanup()

    def helper(self, mode="static", pid_path=None):
        path = self.root / f"helper-{mode}"
        template = (
            MEDIA_FAKE_HELPER if mode.endswith("-media")
            else AUDIO_FAKE_HELPER if mode.endswith("-audio")
            else EFFECT_FAKE_HELPER if mode.endswith("-effect")
            else RESOURCE_FAKE_HELPER if mode.endswith("-resource")
            else FAKE_HELPER
        )
        source = template.replace("__MODE__", repr(mode)).replace(
            "__PID_PATH__", repr(os.fspath(pid_path) if pid_path else "")
        )
        path.write_text(textwrap.dedent(source), encoding="utf-8")
        path.chmod(path.stat().st_mode | 0o700)
        return path

    def fixture_generator(self):
        path = self.root / "media-fixture-generator"
        path.write_text(
            "#!/bin/sh\nprintf 'synthetic-media-container' > \"$2\"\n",
            encoding="utf-8",
        )
        path.chmod(path.stat().st_mode | 0o700)
        return path

    def configuration(self, helper, timeout=1.0, media_fixture_generator=None):
        return adapter.CandidateConfiguration(
            helper_binary=helper,
            asset_root=self.assets,
            expected_candidate="opengl-4.1-2d",
            expected_backend="native-opengl",
            store_root=self.store,
            source_manifest=self.source_manifest,
            source_sha256=self.source_sha256,
            build_identity="synthetic-build",
            build_commands=("cmake --build build --target fresco-scene",),
            operator="adapter-test",
            agent_role="subagent",
            media_fixture_generator=media_fixture_generator,
            timeout_seconds=timeout,
        )

    def assert_child_reaped(self, pid_path):
        pid = int(pid_path.read_text(encoding="utf-8"))
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_static_record_is_manifest_bound_and_tamper_rejects(self):
        record, path = adapter.run_correctness(
            "static-no-media", self.configuration(self.helper())
        )
        manifest = contract.load_json(
            adapter.WORKLOAD_ROOT / "static-no-media" / "manifest-v1.json"
        )
        contract.validate_result_against_manifest(record, manifest, self.store)
        self.assertTrue(path.is_file())
        self.assertEqual(record["execution"]["invalidations"]["value"], 1)
        self.assertEqual(record["execution"]["presents"]["value"], 3)
        self.assertEqual(record["execution"]["submissions"]["value"], 3)
        self.assertEqual(record["run"]["agentRole"], "subagent")
        self.assertEqual(
            set(record["build"]["artifacts"]),
            {"build-evidence", "source-manifest"},
        )
        source_artifact = next(
            item for item in record["artifacts"]
            if item["name"] == "source-manifest"
        )
        self.assertEqual(source_artifact["sha256"], record["run"]["sourceSha256"])
        semantic_artifact = next(
            item for item in record["artifacts"]
            if item["name"] == "semantic-evidence"
        )
        semantic = contract.load_json(self.store / semantic_artifact["path"])
        final_scheduler = semantic["observations"]["afterPropertyRequiescence"][
            "schedulingEvidence"
        ]
        self.assertEqual(final_scheduler["presentations"], 1)
        self.assertGreater(
            record["execution"]["presents"]["value"],
            final_scheduler["presentations"],
        )
        self.assertEqual(
            semantic["recordDerivations"]["presents"]["source"],
            "helper metrics frames incremented after surface.present",
        )
        tampered = copy.deepcopy(record)
        tampered["run"]["manifestSha256"] = digest("tampered")
        with self.assertRaises(contract.ContractError):
            contract.validate_result_against_manifest(
                tampered, manifest, self.store
            )

    def test_source_manifest_contains_all_root_build_inputs(self):
        source_root = pathlib.Path(__file__).parents[2]
        expected = {
            "CMakeLists.txt",
            "PROTOCOL.md",
            "renderer/CMakeLists.txt",
            "renderer/PuppetIntegration.cmake",
        }
        self.assertTrue(expected <= set(source_manifest.ROOT_FILES))
        included = {
            path.relative_to(source_root).as_posix()
            for path in source_manifest.source_files(source_root)
        }
        self.assertTrue(expected <= included)
        cmake = (source_root / "renderer/cmake/Tests.cmake").read_text(
            encoding="utf-8"
        )
        for required in (
            "angle/REVISION", "FRESCO_SCENE_ANGLE_INCLUDE_DIR",
            "libEGL.dylib", "libGLESv2.dylib", "--pinned-checkout",
            "fresco_scene_harness_pinned_dependency_sources",
        ):
            self.assertIn(required, cmake)
        self.assertNotIn(
            '"${FRESCO_SCENE_ANGLE_LIBRARY_DIR}/${angle_library}" REALPATH',
            cmake,
        )

    def test_pinned_checkout_rejects_commit_drift_and_tracked_modification(self):
        checkout = self.root / "pinned"
        checkout.mkdir()
        subprocess.run(["git", "init", "-q", checkout], check=True)
        subprocess.run(
            ["git", "-C", checkout, "config", "user.email", "test@example.com"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", checkout, "config", "user.name", "test"], check=True
        )
        tracked = checkout / "tracked.txt"
        tracked.write_text("pinned\n", encoding="utf-8")
        subprocess.run(["git", "-C", checkout, "add", "tracked.txt"], check=True)
        subprocess.run(
            ["git", "-C", checkout, "commit", "-qm", "pinned"], check=True
        )
        commit = subprocess.run(
            ["git", "-C", checkout, "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        source_manifest.validate_pinned_checkout("fixture", checkout, commit)
        with self.assertRaisesRegex(ValueError, "required submodule is not exact"):
            source_manifest.validate_pinned_checkout(
                "fixture", checkout, commit, ("missing-submodule",)
            )
        with self.assertRaisesRegex(ValueError, "commit drift"):
            source_manifest.validate_pinned_checkout(
                "fixture", checkout, "0" * 40
            )
        tracked.write_text("dirty\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "tracked modifications"):
            source_manifest.validate_pinned_checkout("fixture", checkout, commit)

    def test_wrong_backend_malformed_event_and_timeout_reap_children(self):
        for mode in (
            "wrong-backend", "wrong-api", "wrong-ready-api",
            "wrong-metrics-api", "wrong-shader", "malformed", "timeout"
        ):
            with self.subTest(mode=mode):
                pid_path = self.root / f"{mode}.pid"
                configuration = self.configuration(
                    self.helper(mode, pid_path),
                    timeout=0.05 if mode == "timeout" else 1.0,
                )
                with self.assertRaises(adapter.AdapterError):
                    adapter.run_correctness("static-no-media", configuration)
                self.assert_child_reaped(pid_path)
        records = self.store / "records"
        self.assertFalse(records.exists())

    def test_audio_record_aggregates_all_session_execution(self):
        record, path = adapter.run_correctness(
            "audio-reactive",
            self.configuration(self.helper("valid-audio"), timeout=2.0),
        )
        self.assertEqual(record["execution"]["invalidations"]["value"], 5)
        self.assertEqual(record["execution"]["evaluations"]["value"], 8)
        self.assertEqual(record["execution"]["submissions"]["value"], 12)
        self.assertEqual(record["execution"]["presents"]["value"], 12)
        self.assertEqual(record["shaders"]["compilations"]["value"], 4)
        self.assertEqual(record["shaders"]["pipelineCreations"]["value"], 4)
        semantic_artifact = next(
            item for item in record["artifacts"]
            if item["name"] == "semantic-evidence"
        )
        semantic = contract.load_json(self.store / semantic_artifact["path"])
        components = semantic["observations"]["sessionExecutionComponents"]
        self.assertEqual(len(components), 4)
        sessions = semantic["recordDerivations"]["sessions"]
        self.assertEqual(len(sessions), 4)
        self.assertEqual(
            [item["submissions"] for item in sessions], [1, 1, 9, 1]
        )
        self.assertEqual(
            [item["shaderCompilations"] for item in sessions], [1, 1, 1, 1]
        )
        self.assertEqual(
            semantic["recordDerivations"]["invalidations"]["value"], 5
        )
        self.assertTrue(path.is_file())

    def test_missing_store_and_unsupported_workload_fail_before_launch(self):
        missing = self.root / "missing-store"
        configuration = self.configuration(self.helper())
        configuration = copy.copy(configuration)
        object.__setattr__(configuration, "store_root", missing)
        with self.assertRaises(adapter.AdapterError):
            adapter.run_correctness("static-no-media", configuration)
        self.assertFalse(missing.exists())
        with self.assertRaises(adapter.AdapterError):
            adapter.run_correctness(
                "unknown-workload", self.configuration(self.helper("unsupported"))
            )

    def test_under_speed_continuous_helper_is_rejected_and_reaped(self):
        pid_path = self.root / "under-speed.pid"
        with self.assertRaisesRegex(adapter.AdapterError, "declared cadence"):
            adapter.run_correctness(
                "continuous-animation",
                self.configuration(self.helper("under-speed", pid_path)),
            )
        self.assert_child_reaped(pid_path)

    def test_superficial_script_timer_without_lease_at_is_rejected(self):
        pid_path = self.root / "superficial-script.pid"
        with self.assertRaisesRegex(adapter.AdapterError, "masked"):
            adapter.run_correctness(
                "script-heavy",
                self.configuration(self.helper("superficial-script", pid_path)),
            )
        self.assert_child_reaped(pid_path)

    def test_early_and_missing_script_timer_fakes_are_rejected(self):
        for mode, message in (
            ("early-script", "pending at ready"),
            ("missing-script", "did not fire"),
        ):
            with self.subTest(mode=mode):
                pid_path = self.root / f"{mode}.pid"
                with self.assertRaisesRegex(adapter.AdapterError, message):
                    adapter.run_correctness(
                        "script-heavy",
                        self.configuration(self.helper(mode, pid_path)),
                    )
                self.assert_child_reaped(pid_path)

    def test_lease_at_timer_before_causal_minimum_is_rejected(self):
        pid_path = self.root / "early-deadline-script.pid"
        with self.assertRaisesRegex(adapter.AdapterError, "coordinator-epoch bound"):
            adapter.run_correctness(
                "script-heavy",
                self.configuration(self.helper("early-deadline-script", pid_path)),
            )
        self.assert_child_reaped(pid_path)

    def test_particle_superficial_unbounded_churn_and_no_release_are_rejected(self):
        for mode, message in (
            ("superficial-particle", "did not advance"),
            ("unbounded-particle", "exceeded its simulation cap"),
            ("resource-churn-particle", "resources churned"),
            ("no-release-particle", "did not release"),
            ("inconsistent-arithmetic-particle", "simulation delta"),
        ):
            with self.subTest(mode=mode):
                pid_path = self.root / f"{mode}.pid"
                with self.assertRaisesRegex(adapter.AdapterError, message):
                    adapter.run_correctness(
                        "particle-heavy",
                        self.configuration(self.helper(mode, pid_path)),
                    )
                self.assert_child_reaped(pid_path)

    def test_media_superficial_readiness_stall_reload_teardown_and_metrics_fakes_are_rejected(self):
        generator = self.fixture_generator()
        for mode, message in (
            ("superficial-media", "gated by real frame uploads"),
            ("no-ready-media", "uploads exceed frame-ready events"),
            ("render-stalled-media", "not suppressed exactly once"),
            ("reload-leak-media", "counters leaked across reload"),
            ("teardown-leak-media", "remained live after stop"),
            ("conflated-media", "metric is missing: decodeMilliseconds"),
            ("inactive-churn-media", "produced decode/render/deadline churn"),
            ("deadline-churn-media", "produced decode/render/deadline churn"),
            ("no-release-media", "did not release exactly one live deadline"),
            ("no-replacement-media", "did not replace exactly one active PTS deadline"),
            ("missing-acquire-media", "initial media deadline lifecycle is not exact"),
            ("extra-replacement-media", "did not replace exactly one active PTS deadline"),
            ("busy-poll-media", "active pre-PTS window"),
            ("late-ready-media", "revisions do not match"),
        ):
            with self.subTest(mode=mode):
                pid_path = self.root / f"{mode}.pid"
                configuration = self.configuration(
                    self.helper(mode, pid_path),
                    timeout=2.0,
                    media_fixture_generator=generator,
                )
                with self.assertRaisesRegex(adapter.AdapterError, message):
                    adapter.run_correctness("media-video", configuration)
                self.assert_child_reaped(pid_path)

    def test_media_accepts_one_queued_ready_revision(self):
        adapter.run_correctness(
            "media-video",
            self.configuration(
                self.helper("queued-ready-media"),
                timeout=2.0,
                media_fixture_generator=self.fixture_generator(),
            ),
        )

    def test_media_record_aggregates_all_session_execution(self):
        record, _path = adapter.run_correctness(
            "media-video",
            self.configuration(
                self.helper("valid-media"),
                timeout=2.0,
                media_fixture_generator=self.fixture_generator(),
            ),
        )
        self.assertEqual(record["execution"]["suppressedPresents"]["value"], 1)
        self.assertEqual(record["execution"]["invalidations"]["value"], 11)
        self.assertEqual(record["execution"]["submissions"]["value"], 16)
        self.assertEqual(record["shaders"]["compilations"]["value"], 2)
        self.assertEqual(record["shaders"]["pipelineCreations"]["value"], 2)
        semantic_artifact = next(
            item for item in record["artifacts"]
            if item["name"] == "semantic-evidence"
        )
        semantic = contract.load_json(self.store / semantic_artifact["path"])
        components = semantic["observations"]["sessionExecutionComponents"]
        self.assertEqual(len(components), 2)
        session_derivations = semantic["recordDerivations"]["sessions"]
        self.assertEqual(len(session_derivations), 2)
        self.assertEqual(
            [item["shaderCompilations"] for item in session_derivations],
            [1, 1],
        )
        self.assertEqual(
            semantic["recordDerivations"]["invalidations"]["value"], 11
        )
        self.assertEqual(
            components[0]["schedulingEvidence"]["presentationSuppressions"],
            1,
        )
        self.assertEqual(
            components[1]["schedulingEvidence"]["presentationSuppressions"],
            0,
        )

    def test_audio_superficial_content_cadence_lifecycle_and_output_fakes_are_rejected(self):
        for mode, message in (
            ("frame-only-audio", "acknowledgement counters"),
            ("wrong-content-audio", "wrong spectrum content"),
            ("cadence-coupled-audio", "coupled to render cadence"),
            ("missing-ready-audio", "queued spectrum input"),
            ("late-invalidation-audio", "causally linked"),
            ("missing-schedule-audio", "constructor audio deadline"),
            ("deadline-churn-audio", "natural envelope settling"),
            ("stale-graph-audio", "authored graph scale"),
            ("missing-cancellation-release-audio", "explicit pause"),
            ("output-playback-leakage-audio", "output playback"),
            ("false-silence-quiescence-audio", "extra render wake"),
            ("reload-leakage-audio", "reload leaked"),
        ):
            with self.subTest(mode=mode):
                pid_path = self.root / f"{mode}.pid"
                with self.assertRaisesRegex(adapter.AdapterError, message):
                    adapter.run_correctness(
                        "audio-reactive",
                        self.configuration(self.helper(mode, pid_path), timeout=2.0),
                    )
                self.assert_child_reaped(pid_path)

    def test_effect_order_blend_pixels_damage_reload_and_teardown_fakes_are_rejected(self):
        for mode, message in (
            ("wrong-pixels-effect", "effect pixels"),
            ("swapped-order-effect", "effect pass order"),
            ("wrong-blend-effect", "effect pass order"),
            ("bounded-damage-effect", "conservatively expanded"),
            ("stale-reload-effect", "reload effect pixels"),
            ("wrong-puppet-pixels-effect", "masked puppet pixels"),
            ("excessive-mask-passes-effect", "exactly one stencil pass"),
            ("teardown-leak-effect", "remained live after stop"),
        ):
            with self.subTest(mode=mode):
                pid_path = self.root / f"{mode}.pid"
                with self.assertRaisesRegex(adapter.AdapterError, message):
                    adapter.run_correctness(
                        "masks-effects",
                        self.configuration(self.helper(mode, pid_path)),
                    )
                self.assert_child_reaped(pid_path)

    def test_effect_record_aggregates_five_session_scoped_components(self):
        record, _path = adapter.run_correctness(
            "masks-effects", self.configuration(self.helper("valid-effect"))
        )
        self.assertEqual(record["execution"]["invalidations"]["value"], 1)
        self.assertEqual(record["execution"]["submissions"]["value"], 9)
        self.assertEqual(record["execution"]["presents"]["value"], 9)
        self.assertEqual(record["shaders"]["compilations"]["value"], 11)
        semantic_artifact = next(
            item for item in record["artifacts"]
            if item["name"] == "semantic-evidence"
        )
        semantic = contract.load_json(self.store / semantic_artifact["path"])
        components = semantic["observations"]["sessionExecutionComponents"]
        self.assertEqual(len(components), 5)
        self.assertEqual(
            [item["frames"] for item in components], [4, 1, 2, 1, 1]
        )
        self.assertEqual(
            [item["programCacheInsertions"] for item in components],
            [4, 4, 1, 1, 1],
        )
        sessions = semantic["recordDerivations"]["sessions"]
        self.assertEqual(len(sessions), 5)
        self.assertEqual(
            sum(item["submissions"] for item in sessions),
            record["execution"]["submissions"]["value"],
        )

    def test_resource_reload_generation_rollback_and_teardown_fakes_are_rejected(self):
        for mode, message in (
            ("reused-generation-resource", "generation or retirement"),
            ("missing-completion-resource", "generation or retirement"),
            ("wrong-order-resource", "generation or retirement"),
            ("publication-on-failure-resource", "generation or retirement"),
            ("missing-rollback-resource", "generation or retirement"),
            ("polluted-rollback-resource", "generation-local programs"),
            ("stale-output-resource", "changed-source reload pixels"),
            ("teardown-leak-resource", "did not retire cleanly"),
            ("program-leak-resource", "did not retire cleanly"),
        ):
            with self.subTest(mode=mode):
                pid_path = self.root / f"{mode}.pid"
                with self.assertRaisesRegex(adapter.AdapterError, message):
                    adapter.run_correctness(
                        "resource-reload",
                        self.configuration(self.helper(mode, pid_path)),
                    )
                self.assert_child_reaped(pid_path)

    def test_resource_reload_record_uses_six_partial_compatible_sessions(self):
        record, _path = adapter.run_correctness(
            "resource-reload", self.configuration(self.helper("valid-resource"))
        )
        self.assertEqual(record["execution"]["submissions"]["value"], 6)
        self.assertEqual(record["shaders"]["compilations"]["value"], 17)
        semantic_artifact = next(
            item for item in record["artifacts"]
            if item["name"] == "semantic-evidence"
        )
        semantic = contract.load_json(self.store / semantic_artifact["path"])
        components = semantic["observations"]["sessionExecutionComponents"]
        self.assertEqual(len(components), 6)
        self.assertEqual(
            [item["resourceGeneration"] for item in components],
            [1, 2, 3, 4, 5, 6],
        )
        self.assertEqual([item["frames"] for item in components], [1] * 6)

    def test_wrapper_normalizes_var_alias_and_configuration_claims(self):
        physical = os.fspath(self.root)
        if physical.startswith("/private/var/"):
            alias = "/var/" + physical.removeprefix("/private/var/")
            self.assertEqual(adapter.normalize_wrapper_path(alias), self.root)

        invalid_role = self.configuration(self.helper("invalid-role"))
        object.__setattr__(invalid_role, "agent_role", "background-agent")
        with self.assertRaisesRegex(adapter.AdapterError, "agent role"):
            adapter.run_correctness("static-no-media", invalid_role)

        bad_digest = self.configuration(self.helper("bad-digest"))
        object.__setattr__(bad_digest, "source_sha256", digest("wrong"))
        with self.assertRaisesRegex(adapter.AdapterError, "digest mismatch"):
            adapter.run_correctness("static-no-media", bad_digest)


if __name__ == "__main__":
    unittest.main()
