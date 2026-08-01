#!/usr/bin/env python3

import json
import os
import select
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])


def message(kind, assignment_id="renderer-integration", **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": assignment_id,
        **values,
    }


cat = os.path.join(WORKSHOP, "3351508588")
three_d = os.path.join(WORKSHOP, "3477054430")
gbc_subaru = os.path.join(WORKSHOP, "3448290956")
arknights = os.path.join(WORKSHOP, "3460973721")
persona = os.path.join(WORKSHOP, "3151551777")
for project in (cat, three_d, gbc_subaru, arknights, persona):
    if not os.path.isfile(os.path.join(project, "scene.pkg")):
        raise SystemExit(f"renderer integration fixture missing: {project}")

nonzero_spectrum = [0.0] * 128
nonzero_spectrum[0:4] = [0.1, 0.2, 0.3, 0.4]
nonzero_spectrum[64:68] = [0.5, 0.6, 0.7, 0.8]

commands = [
    message("hello"),
    message("load", path=three_d, assetRoot=ASSETS, visible=False),
    message(
        "load",
        path=cat,
        assetRoot=ASSETS,
        staticContent=True,
        visible=False,
    ),
    message(
        "load",
        path=cat,
        assetRoot=ASSETS,
        fps=True,
        visible=False,
    ),
    message(
        "load",
        path=cat,
        assetRoot=ASSETS,
        policyRevision=True,
        visible=False,
    ),
    message(
        "load",
        path=cat,
        assetRoot=ASSETS,
        fps=24.5,
        visible=False,
    ),
    message(
        "load",
        path=cat,
        assetRoot=ASSETS,
        x=0,
        y=0,
        width=320,
        height=180,
        fps=24,
        policyRevision=7,
        reasonTokens=["profile:battery"],
        visible=False,
    ),
    message(
        "scheduling-policy",
        fpsCeiling=15,
        policyRevision=8,
        reasonTokens=["rule:low-power"],
    ),
    message("audio-spectrum", values=[0.0] * 127),
    message("audio-spectrum", values=[0.0] * 127 + [True]),
    message("audio-spectrum", values=[0.0] * 127 + [1.1]),
    message(
        "audio-spectrum",
        assignment_id="other-assignment",
        values=[1.0] * 128,
    ),
    message("pause", assignment_id="other-assignment"),
    message("mute", assignment_id="other-assignment"),
    message("hide", assignment_id="other-assignment"),
    message("metrics", assignment_id="other-assignment"),
    message("audio-spectrum", values=nonzero_spectrum),
    message("ping"),
    message("metrics"),
    message("unmute"),
    message("pause"),
    message("hide"),
    message("metrics"),
    message("show"),
    message("resume"),
    message("mute"),
    message("metrics"),
    message("ping"),
    message("stop"),
]
result = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in commands),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=20,
    check=True,
)
assert not result.stderr, result.stderr
events = [json.loads(line) for line in result.stdout.splitlines()]
assert [event["type"] for event in events] == [
    "hello",
    "unsupported",
    "fatal",
    "fatal",
    "fatal",
    "fatal",
    "ready",
    "scheduling-policy-applied",
    "warning",
    "warning",
    "warning",
    "warning",
    "warning",
    "warning",
    "warning",
    "warning",
    "audio-spectrum-applied",
    "heartbeat",
    "metrics",
    "unmuted",
    "paused",
    "hidden",
    "metrics",
    "shown",
    "resumed",
    "muted",
    "metrics",
    "heartbeat",
    "stopped",
], events

(
    hello,
    unsupported,
    static_rejected,
    invalid_load_fps_boolean,
    invalid_load_revision_boolean,
    invalid_load_fps_fractional,
    ready,
    scheduling,
) = events[:8]
malformed = events[8:11]
wrong_assignment = events[11]
wrong_controls = events[12:16]
audio_applied = events[16]
initial_metrics = events[18]
paused_metrics = events[22]
resumed_metrics = events[26]
assert hello["backend"] in {"native-opengl", "angle-metal"}, hello
expected = {
    "native-opengl": (
        "opengl-4.1-2d",
        "OpenGL 4.1 core",
        {"language": "GLSL", "profile": "desktop-core", "version": 410},
    ),
    "angle-metal": (
        "angle-metal-es3-2d",
        "OpenGL ES 3.0 via ANGLE Metal",
        {"language": "GLSL", "profile": "embedded", "version": 300},
    ),
}[hello["backend"]]
assert hello["renderer"] == expected[0], hello
assert hello["graphicsAPI"] == expected[1], hello
assert hello["shaderTarget"] == expected[2], hello
assert "render-image" in hello["capabilities"], hello
assert "render-text" in hello["capabilities"], hello
assert "script-text" in hello["capabilities"], hello
assert "script-audio-float-16-average0" in hello["capabilities"], hello
assert "runtime-metrics" in hello["capabilities"], hello
assert "scheduling-policy-v1" in hello["capabilities"], hello
assert "audio-spectrum" in hello["capabilities"], hello
assert "mute-unmute" in hello["capabilities"], hello
assert "sound-volume-properties" in hello["capabilities"], hello
assert "sound-cursor-click" in hello["capabilities"], hello
assert "sound-playback" not in hello["capabilities"], hello
assert unsupported["hardUnsupportedTypes"] == ["model", "light"], unsupported
assert static_rejected["code"] == "static-content-unproven", static_rejected
assert static_rejected["scope"] == "assignment", static_rejected
invalid_loads = (
    invalid_load_fps_boolean,
    invalid_load_revision_boolean,
    invalid_load_fps_fractional,
)
assert all(
    event["code"] == "invalid-scheduling-policy" for event in invalid_loads
), invalid_loads
assert all(event["scope"] == "assignment" for event in invalid_loads), invalid_loads
assert ready["renderer"] == expected[0], ready
assert ready["backend"] == hello["backend"], ready
assert ready["graphicsAPI"] == expected[1], ready
assert ready["shaderTarget"] == hello["shaderTarget"], ready
assert ready["frames"] >= 2, ready
assert ready["range"][0] < ready["range"][1], ready
assert ready["varyingPixels"] > 0, ready
assert ready["drawComplete"] is True, ready
assert ready["targetFPS"] == 24, ready
assert ready["policyRevision"] == 7, ready
assert ready["reasonTokens"] == ["profile:battery"], ready
assert ready["scriptLayers"] == 0, ready
assert ready["scriptUpdates"] == 0, ready
assert ready["scriptTextChanges"] == 0, ready
assert ready["scriptErrors"] == 0, ready
assert ready["width"] >= 320 and ready["height"] >= 180, ready
assert ready["ordered"] is False, ready
assert scheduling["fpsCeiling"] == 15, scheduling
assert scheduling["policyRevision"] == 8, scheduling
assert scheduling["reasonTokens"] == ["rule:low-power"], scheduling
assert all(event["code"] == "invalid-audio-spectrum" for event in malformed), malformed
assert all(event["assignmentID"] == "renderer-integration" for event in malformed), malformed
assert wrong_assignment["code"] == "assignment-mismatch", wrong_assignment
assert wrong_assignment["assignmentID"] == "other-assignment", wrong_assignment
assert all(event["code"] == "assignment-mismatch" for event in wrong_controls), wrong_controls
assert audio_applied["changed"] is True, audio_applied
assert audio_applied["inputs"] == 1, audio_applied
assert audio_applied["changes"] == 1, audio_applied
assert initial_metrics["muted"] is True, initial_metrics
assert initial_metrics["paused"] is False, initial_metrics
assert paused_metrics["paused"] is True, paused_metrics
assert paused_metrics["muted"] is False, paused_metrics
assert paused_metrics["visible"] is False, paused_metrics
assert paused_metrics["backend"] == hello["backend"], paused_metrics
assert paused_metrics["graphicsAPI"] == expected[1], paused_metrics
assert paused_metrics["shaderTarget"] == hello["shaderTarget"], paused_metrics
assert resumed_metrics["paused"] is False, resumed_metrics
assert resumed_metrics["muted"] is True, resumed_metrics
assert resumed_metrics["visible"] is True, resumed_metrics
assert resumed_metrics["targetFPS"] == 15, resumed_metrics
assert resumed_metrics["policyRevision"] == 8, resumed_metrics
assert resumed_metrics["reasonTokens"] == ["rule:low-power"], resumed_metrics
assert not any(
    event.get("type") == "ready" for event in events[:2]
), events

audio_commands = [
    message(
        "load",
        assignment_id="gbc-audio-differential",
        path=gbc_subaru,
        assetRoot=ASSETS,
        width=320,
        height=180,
        visible=True,
        evidenceFrames=120,
    ),
    message(
        "capture-frame-difference",
        assignment_id="gbc-audio-differential",
    ),
    message(
        "audio-spectrum",
        assignment_id="gbc-audio-differential",
        values=[1.0] * 128,
    ),
    message(
        "capture-frame-difference",
        assignment_id="gbc-audio-differential",
    ),
    message(
        "audio-spectrum",
        assignment_id="gbc-audio-differential",
        values=[0.0] * 128,
    ),
    message(
        "capture-frame-difference",
        assignment_id="gbc-audio-differential",
    ),
    message("pause", assignment_id="gbc-audio-differential"),
    message(
        "audio-spectrum",
        assignment_id="gbc-audio-differential",
        values=[1.0] * 128,
    ),
    message("metrics", assignment_id="gbc-audio-differential"),
    message("resume", assignment_id="gbc-audio-differential"),
    message(
        "capture-frame-difference",
        assignment_id="gbc-audio-differential",
    ),
    message(
        "load",
        assignment_id="gbc-audio-differential",
        path=gbc_subaru,
        assetRoot=ASSETS,
        width=320,
        height=180,
        visible=True,
        evidenceFrames=120,
    ),
    message("stop", assignment_id="gbc-audio-differential"),
]
audio_result = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in audio_commands),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=60,
    check=True,
)
assert not audio_result.stderr, audio_result.stderr
audio_events = [json.loads(line) for line in audio_result.stdout.splitlines()]
assert [event["type"] for event in audio_events] == [
    "ready",
    "frame-difference",
    "audio-spectrum-applied",
    "frame-difference",
    "audio-spectrum-applied",
    "frame-difference",
    "paused",
    "audio-spectrum-applied",
    "metrics",
    "resumed",
    "frame-difference",
    "ready",
    "stopped",
], audio_events
(
    audio_ready,
    silence_reference,
    peak_audio_applied,
    audio_difference,
    silence_audio_applied,
    restored_silence,
    _,
    paused_audio_applied,
    paused_audio_metrics,
    _,
    resumed_audio_difference,
    reloaded_audio_ready,
    _,
) = audio_events
assert peak_audio_applied["changed"] is True, peak_audio_applied
assert peak_audio_applied["inputs"] == 1, peak_audio_applied
assert peak_audio_applied["changes"] == 1, peak_audio_applied
assert silence_audio_applied["changed"] is True, silence_audio_applied
assert silence_audio_applied["inputs"] == 2, silence_audio_applied
assert silence_audio_applied["changes"] == 2, silence_audio_applied
assert paused_audio_applied["changed"] is True, paused_audio_applied
assert paused_audio_applied["inputs"] == 3, paused_audio_applied
assert paused_audio_applied["changes"] == 3, paused_audio_applied


def dynamic_float_state(event):
    return {
        value["key"]: (value["value"], value["updates"], value["changes"])
        for value in event["scriptedDynamicFloats"]
    }


dynamic_keys = {
    "animation-rate:179:193",
    "animation-rate:179:200",
}
assert audio_ready["backend"] == hello["backend"], audio_ready
assert audio_ready["scriptLayers"] == 3, audio_ready
assert audio_ready["scriptErrors"] == 0, audio_ready
assert audio_ready["genericPropertyScripts"] == 10, audio_ready
assert audio_ready["genericPropertyScriptUpdates"] == 1209, audio_ready
assert audio_ready["genericPropertyScriptChanges"] == 8, audio_ready
assert audio_ready["genericPropertyScriptErrors"] == 0, audio_ready
assert audio_ready["deferredScriptValues"] == 0, audio_ready
assert not any("SceneScript" in warning for warning in audio_ready["warnings"]), audio_ready
assert not any("puppet secondary motion" in warning for warning in audio_ready["warnings"]), audio_ready
assert not any("sound playback" in warning for warning in audio_ready["warnings"]), (
    audio_ready
)
assert audio_ready["soundVolumeBindings"] == 2, audio_ready
assert audio_ready["soundVolumeProperties"] == 2, audio_ready
assert set(dynamic_float_state(audio_ready)) == dynamic_keys, audio_ready
assert set(dynamic_float_state(silence_reference)) == dynamic_keys, silence_reference
assert set(dynamic_float_state(audio_difference)) == dynamic_keys, audio_difference
assert set(dynamic_float_state(restored_silence)) == dynamic_keys, restored_silence
assert set(dynamic_float_state(paused_audio_metrics)) == dynamic_keys, paused_audio_metrics
assert set(dynamic_float_state(resumed_audio_difference)) == dynamic_keys, resumed_audio_difference
assert set(dynamic_float_state(reloaded_audio_ready)) == dynamic_keys, reloaded_audio_ready
assert all(value == (1.5, 121, 1) for value in dynamic_float_state(audio_ready).values()), audio_ready
assert all(value == (1.5, 122, 1) for value in dynamic_float_state(silence_reference).values()), silence_reference
assert all(value == (10, 123, 2) for value in dynamic_float_state(audio_difference).values()), audio_difference
assert all(value == (1.5, 124, 3) for value in dynamic_float_state(restored_silence).values()), restored_silence
assert dynamic_float_state(paused_audio_metrics) == dynamic_float_state(restored_silence), paused_audio_metrics
assert all(value == (10, 125, 4) for value in dynamic_float_state(resumed_audio_difference).values()), resumed_audio_difference
assert all(value == (1.5, 121, 1) for value in dynamic_float_state(reloaded_audio_ready).values()), reloaded_audio_ready
assert audio_ready["scriptedDynamicFloatUpdates"] == 242, audio_ready
assert audio_ready["scriptedDynamicFloatChanges"] == 2, audio_ready
assert paused_audio_metrics["scriptedDynamicFloatUpdates"] == 248, paused_audio_metrics
assert paused_audio_metrics["scriptedDynamicFloatChanges"] == 6, paused_audio_metrics
assert resumed_audio_difference["scriptedDynamicFloatUpdates"] == 250, resumed_audio_difference
assert resumed_audio_difference["scriptedDynamicFloatChanges"] == 8, resumed_audio_difference
assert reloaded_audio_ready["scriptedDynamicFloatUpdates"] == 242, reloaded_audio_ready
assert reloaded_audio_ready["scriptedDynamicFloatChanges"] == 2, reloaded_audio_ready
assert reloaded_audio_ready["genericPropertyScripts"] == 10, reloaded_audio_ready
assert reloaded_audio_ready["genericPropertyScriptUpdates"] == 1209, (
    reloaded_audio_ready
)
assert reloaded_audio_ready["genericPropertyScriptChanges"] == 8, (
    reloaded_audio_ready
)
assert reloaded_audio_ready["genericPropertyScriptErrors"] == 0, (
    reloaded_audio_ready
)
assert paused_audio_metrics["paused"] is True, paused_audio_metrics
assert resumed_audio_difference["scriptErrors"] == 0, resumed_audio_difference
assert reloaded_audio_ready["scriptErrors"] == 0, reloaded_audio_ready
assert audio_difference["backend"] == hello["backend"], audio_difference
assert silence_reference["changedPixels"] > 1_000, silence_reference
assert silence_reference["maximumChannelDelta"] > 20, silence_reference
assert silence_reference["totalChannelDelta"] > 5_000, silence_reference
assert audio_difference["drawComplete"] is True, audio_difference
assert audio_difference["scriptLayers"] == 3, audio_difference
assert audio_difference["scriptErrors"] == 0, audio_difference
assert audio_difference["changedPixels"] > silence_reference["changedPixels"], (
    silence_reference,
    audio_difference,
)
assert audio_difference["maximumChannelDelta"] > silence_reference[
    "maximumChannelDelta"
], (silence_reference, audio_difference)
assert audio_difference["totalChannelDelta"] > silence_reference[
    "totalChannelDelta"
] * 1.5, (silence_reference, audio_difference)
assert audio_difference["totalChannelDelta"] <= (
    audio_difference["changedPixels"]
    * audio_difference["maximumChannelDelta"]
    * 4
), audio_difference
volume_commands = [
    message(
        "load",
        assignment_id="volume-properties",
        path=gbc_subaru,
        assetRoot=ASSETS,
        width=320,
        height=180,
        visible=False,
        userProperties={
            "newproperty1": {"value": 0.2},
            "newproperty45": {"value": 1.0e300},
            "invalid": {"value": True},
            "unknown": {"value": 0.4},
        },
    ),
    message(
        "user-properties",
        assignment_id="other-assignment",
        properties={"newproperty1": {"value": 0.3}},
    ),
    message(
        "user-properties",
        assignment_id="volume-properties",
        properties={"newproperty1": {"value": False}},
    ),
    message(
        "user-properties",
        assignment_id="volume-properties",
        properties={"unknown": {"value": 0.3}},
    ),
    message(
        "user-properties",
        assignment_id="volume-properties",
        properties={
            "newproperty1": {"value": 0.6},
            "newproperty45": {"value": -4.0},
        },
    ),
    message("cursor-click", assignment_id="volume-properties", objectID=289),
    message("cursor-click", assignment_id="volume-properties", objectID=289),
    message("metrics", assignment_id="volume-properties"),
    message("stop", assignment_id="volume-properties"),
]
volume_result = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in volume_commands),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=30,
    check=True,
)
assert not volume_result.stderr, volume_result.stderr
volume_events = [json.loads(line) for line in volume_result.stdout.splitlines()]
assert [event["type"] for event in volume_events] == [
    "ready",
    "warning",
    "user-properties-applied",
    "user-properties-applied",
    "user-properties-applied",
    "cursor-clicked",
    "cursor-clicked",
    "metrics",
    "stopped",
], volume_events
(
    volume_ready,
    wrong_volume_assignment,
    invalid_volume,
    unknown_volume,
    applied_volume,
    first_cursor_click,
    second_cursor_click,
    volume_metrics,
    _,
) = volume_events
assert volume_ready["soundVolumeBindings"] == 2, volume_ready
assert volume_ready["soundVolumeProperties"] == 2, volume_ready
assert volume_ready["initialUserProperties"]["received"] == 4, volume_ready
assert volume_ready["initialUserProperties"]["appliedProperties"] == 1, volume_ready
assert volume_ready["initialUserProperties"]["appliedSoundLayers"] == 1, volume_ready
assert volume_ready["initialUserProperties"]["ignored"] == 3, volume_ready
assert len(volume_ready["initialUserProperties"]["diagnostics"]) == 3, volume_ready
ready_voice = {
    control["id"]: control for control in volume_ready["soundControls"]
}[283]
assert ready_voice["playRequests"] == 0, ready_voice
assert ready_voice["requestedPlaying"] is False, ready_voice
assert wrong_volume_assignment["code"] == "assignment-mismatch", wrong_volume_assignment
assert invalid_volume["received"] == 1, invalid_volume
assert invalid_volume["appliedSoundLayers"] == 1, invalid_volume
assert invalid_volume["ignored"] == 0, invalid_volume
assert invalid_volume["diagnostics"] == [], invalid_volume
assert unknown_volume["appliedSoundLayers"] == 0, unknown_volume
assert unknown_volume["ignored"] == 1, unknown_volume
assert applied_volume["received"] == 2, applied_volume
assert applied_volume["appliedProperties"] == 1, applied_volume
assert applied_volume["appliedSoundLayers"] == 1, applied_volume
assert applied_volume["ignored"] == 1, applied_volume
assert first_cursor_click == {
    "protocolVersion": 1,
    "type": "cursor-clicked",
    "assignmentID": "volume-properties",
    "objectID": 289,
    "objectIDs": [289],
    "handled": True,
}, first_cursor_click
assert second_cursor_click == first_cursor_click, second_cursor_click
assert volume_metrics["soundVolumeBindings"] == 2, volume_metrics
assert volume_metrics["soundVolumeProperties"] == 2, volume_metrics
voice_control = {
    control["id"]: control for control in volume_metrics["soundControls"]
}[283]
assert voice_control["name"] == "Voice1", voice_control
assert voice_control["playRequests"] == 1, voice_control

persona_commands = [
    message(
        "load",
        assignment_id="persona-volume-properties",
        path=persona,
        assetRoot=ASSETS,
        width=320,
        height=180,
        visible=False,
        userProperties={
            "musicvolume": {"value": 0.3},
            "trainsfxvolume": {"value": 0.8},
        },
    ),
    message("stop", assignment_id="persona-volume-properties"),
]
persona_result = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in persona_commands),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=30,
    check=True,
)
assert not persona_result.stderr, persona_result.stderr
persona_events = [json.loads(line) for line in persona_result.stdout.splitlines()]
assert [event["type"] for event in persona_events] == ["ready", "stopped"], persona_events
persona_ready = persona_events[0]
assert persona_ready["soundVolumeBindings"] == 18, persona_ready
assert persona_ready["soundVolumeProperties"] == 2, persona_ready
assert persona_ready["initialUserProperties"]["received"] == 2, persona_ready
assert persona_ready["initialUserProperties"]["appliedProperties"] == 2, persona_ready
assert persona_ready["initialUserProperties"]["appliedSoundLayers"] == 18, persona_ready
assert persona_ready["initialUserProperties"]["ignored"] == 0, persona_ready


def property_script_state(event, key):
    required = {
        "propertyScriptControllers",
        "propertyScriptInitializations",
        "propertyScriptPropertyApplications",
        "propertyScriptUpdates",
        "propertyScriptErrors",
        "propertyScripts",
    }
    assert required <= event.keys(), event
    matches = [entry for entry in event["propertyScripts"] if entry["key"] == key]
    assert len(matches) == 1, event
    return matches[0]


def sound_control_state(event):
    required = {
        "id",
        "name",
        "playing",
        "requestedPlaying",
        "playRequests",
        "pauseRequests",
        "stopRequests",
    }
    controls = event["soundControls"]
    assert all(required <= control.keys() for control in controls), event
    return {control["id"]: control for control in controls}


def assert_property_sound_lifecycle(
    project,
    assignment_id,
    initial_selection,
    profile,
    key,
    object_id,
    visible,
    evidence_frames,
    selected_sound,
    playlist_sounds,
    ambient_sound=None,
    seeded_delay_seconds=-1,
    delay_property=None,
):
    process = subprocess.Popen(
        [HELPER],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    def exchange(kind, expected, **values):
        command = message(kind, assignment_id=assignment_id, **values)
        process.stdin.write(json.dumps(command) + "\n")
        process.stdin.flush()
        readable, _, _ = select.select([process.stdout], [], [], 60)
        assert readable, (kind, "timed out")
        event = json.loads(process.stdout.readline())
        assert event["type"] == expected, event
        return event

    selected_id, selected_name = selected_sound

    def captures_until_selected(initial_event, maximum=15):
        initial_control = sound_control_state(initial_event)[selected_id]
        if initial_control["requestedPlaying"]:
            return [], initial_event
        events = []
        for _ in range(maximum):
            event = exchange("capture-frame-difference", "frame-difference")
            events.append(event)
            if sound_control_state(event)[selected_id]["requestedPlaying"]:
                return events, event
        raise AssertionError(("selection did not transition", events[-1]))

    initial_user_properties = {"music": {"value": initial_selection}}
    if delay_property is not None:
        name, value = delay_property
        initial_user_properties[name] = {"value": value}

    ready = exchange(
        "load",
        "ready",
        path=project,
        assetRoot=ASSETS,
        width=320,
        height=180,
        visible=True,
        evidenceFrames=evidence_frames,
        userProperties=initial_user_properties,
    )
    initial_frames, initial_frame = captures_until_selected(ready)
    initial_metrics = exchange("metrics", "metrics")
    exchange("pause", "paused")
    paused_baseline = exchange("metrics", "metrics")
    applied = exchange(
        "user-properties",
        "user-properties-applied",
        properties={"music": {"value": "0"}},
    )
    paused_metrics = exchange("metrics", "metrics")
    exchange("resume", "resumed")
    resumed_frame = exchange("capture-frame-difference", "frame-difference")
    resumed_metrics = exchange("metrics", "metrics")
    reloaded_ready = exchange(
        "load",
        "ready",
        path=project,
        assetRoot=ASSETS,
        width=320,
        height=180,
        visible=True,
        evidenceFrames=evidence_frames,
        userProperties=initial_user_properties,
    )
    reloaded_frames, reloaded_frame = captures_until_selected(reloaded_ready)
    reloaded_metrics = exchange("metrics", "metrics")
    exchange("stop", "stopped")
    process.stdin.close()
    process.wait(timeout=10)
    stderr = process.stderr.read()
    assert process.returncode == 0, process.returncode
    assert not stderr, stderr
    initial_state = property_script_state(ready, key)
    metrics_state = property_script_state(initial_metrics, key)
    paused_baseline_state = property_script_state(paused_baseline, key)
    paused_state = property_script_state(paused_metrics, key)
    resumed_state = property_script_state(resumed_metrics, key)
    reloaded_state = property_script_state(reloaded_ready, key)
    expected_identity = {
        "key": key,
        "profile": profile,
        "objectId": object_id,
        "property": "visible",
        "value": visible,
        "initialized": True,
    }
    assert expected_identity.items() <= initial_state.items(), ready
    assert expected_identity.items() <= metrics_state.items(), initial_metrics
    assert expected_identity.items() <= paused_baseline_state.items(), paused_baseline
    assert expected_identity.items() <= paused_state.items(), paused_metrics
    assert expected_identity.items() <= resumed_state.items(), resumed_metrics
    assert expected_identity.items() <= reloaded_state.items(), reloaded_ready
    assert initial_state["seededDelaySeconds"] == seeded_delay_seconds, initial_state
    assert initial_state["targetDelaySeconds"] == seeded_delay_seconds, initial_state
    assert reloaded_state["seededDelaySeconds"] == seeded_delay_seconds, reloaded_state
    assert reloaded_state["targetDelaySeconds"] == seeded_delay_seconds, reloaded_state
    assert ready["propertyScriptControllers"] == 1, ready
    assert ready["propertyScriptInitializations"] == 1, ready
    assert ready["propertyScriptPropertyApplications"] == 1, ready
    assert ready["propertyScriptErrors"] == 0, ready
    assert initial_frame["drawComplete"] is True, initial_frame
    assert initial_state["propertyApplications"] == 1, initial_state
    assert applied["received"] == 1, applied
    assert paused_baseline["propertyScriptPropertyApplications"] == 1, paused_baseline
    assert paused_metrics["propertyScriptPropertyApplications"] == 1, paused_metrics
    assert paused_state["propertyApplications"] == 1, paused_state
    assert paused_state["updates"] == paused_baseline_state["updates"], paused_state
    assert resumed_frame["drawComplete"] is True, resumed_frame
    assert resumed_metrics["propertyScriptControllers"] == 1, resumed_metrics
    assert resumed_metrics["propertyScriptInitializations"] == 1, resumed_metrics
    assert resumed_metrics["propertyScriptPropertyApplications"] == 2, resumed_metrics
    assert resumed_metrics["propertyScriptErrors"] == 0, resumed_metrics
    assert resumed_state["propertyApplications"] == 2, resumed_state
    assert resumed_state["updates"] >= paused_state["updates"], resumed_state

    expected_names = dict(playlist_sounds)
    if ambient_sound is not None:
        expected_names[ambient_sound[0]] = ambient_sound[1]
    initial_controls = sound_control_state(initial_metrics)
    paused_baseline_controls = sound_control_state(paused_baseline)
    paused_controls = sound_control_state(paused_metrics)
    resumed_controls = sound_control_state(resumed_metrics)
    assert {
        sound_id: initial_controls[sound_id]["name"] for sound_id in expected_names
    } == expected_names
    assert initial_controls[selected_id]["name"] == selected_name
    assert initial_controls[selected_id]["playRequests"] == 1, initial_controls
    assert initial_controls[selected_id]["playing"] is False, initial_controls
    assert initial_controls[selected_id]["requestedPlaying"] is True, initial_controls
    assert all(
        initial_controls[sound_id]["playRequests"] == 0
        for sound_id in playlist_sounds
        if sound_id != selected_id
    ), initial_controls
    if seeded_delay_seconds >= 0:
        ready_control = sound_control_state(ready)[selected_id]
        transition_updates = property_script_state(initial_frame, key)["updates"]
        assert ready_control["playRequests"] == 0, ready_control
        assert ready_control["requestedPlaying"] is False, ready_control
        assert initial_frames, initial_frame
        assert all(
            not sound_control_state(frame)[selected_id]["requestedPlaying"]
            for frame in initial_frames[:-1]
        ), initial_frames
        assert 11 <= transition_updates <= 16, transition_updates
    assert paused_baseline_controls[selected_id]["playing"] is False, paused_baseline_controls
    assert paused_baseline_controls[selected_id]["requestedPlaying"] is True, (
        paused_baseline_controls
    )
    assert paused_controls[selected_id]["playing"] is False, paused_controls
    assert paused_controls[selected_id]["requestedPlaying"] is True, paused_controls
    assert all(
        paused_controls[sound_id]["stopRequests"]
        == paused_baseline_controls[sound_id]["stopRequests"]
        for sound_id in playlist_sounds
    ), paused_controls
    assert all(
        resumed_controls[sound_id]["stopRequests"]
        == paused_controls[sound_id]["stopRequests"] + 1
        for sound_id in playlist_sounds
    ), resumed_controls
    assert all(
        resumed_controls[sound_id]["playRequests"]
        == paused_controls[sound_id]["playRequests"]
        for sound_id in playlist_sounds
    ), resumed_controls
    assert resumed_controls[selected_id]["playing"] is False, resumed_controls
    assert resumed_controls[selected_id]["requestedPlaying"] is False, resumed_controls
    if ambient_sound is not None:
        ambient_id, ambient_name = ambient_sound
        assert initial_controls[ambient_id]["name"] == ambient_name, initial_controls
        assert initial_controls[ambient_id]["playRequests"] == 0, initial_controls
        assert initial_controls[ambient_id]["pauseRequests"] == 0, initial_controls
        assert initial_controls[ambient_id]["stopRequests"] == 0, initial_controls

    assert reloaded_ready["propertyScriptInitializations"] == 1, reloaded_ready
    assert reloaded_ready["propertyScriptPropertyApplications"] == 1, reloaded_ready
    assert reloaded_ready["propertyScriptErrors"] == 0, reloaded_ready
    assert reloaded_state["propertyApplications"] == 1, reloaded_state
    assert reloaded_frame["drawComplete"] is True, reloaded_frame
    reloaded_controls = sound_control_state(reloaded_metrics)
    assert reloaded_controls[selected_id]["playRequests"] == 1, reloaded_controls
    assert reloaded_controls[selected_id]["playing"] is False, reloaded_controls
    assert reloaded_controls[selected_id]["requestedPlaying"] is True, reloaded_controls
    if seeded_delay_seconds >= 0:
        reloaded_control = sound_control_state(reloaded_ready)[selected_id]
        reload_updates = property_script_state(reloaded_frame, key)["updates"]
        assert reloaded_control["playRequests"] == 0, reloaded_control
        assert reloaded_control["requestedPlaying"] is False, reloaded_control
        assert reloaded_frames, reloaded_frame
        assert all(
            not sound_control_state(frame)[selected_id]["requestedPlaying"]
            for frame in reloaded_frames[:-1]
        ), reloaded_frames
        assert 11 <= reload_updates <= 16, reload_updates


assert_property_sound_lifecycle(
    arknights,
    "arknights-property-sound",
    "1",
    "bounded-private-music-visibility-v1",
    "visible_95",
    95,
    True,
    2,
    (76, "Storyteller(叙事者)"),
    {
        76: "Storyteller(叙事者)",
        82: "Echoism (Instrumental).flac",
        85: "Silent Tales(未曾讲述之事).flac",
        94: "随机",
    },
    seeded_delay_seconds=0.2,
    delay_property=("newproperty12", "0.2"),
)
assert_property_sound_lifecycle(
    persona,
    "persona-property-sound",
    "2",
    "music-visibility-property-v1",
    "visible_460",
    460,
    False,
    2,
    (604, "Color Your Night.ogg"),
    {
        959: "Shuffle playlist",
        456: "Full Moon Full Life.ogg",
        604: "Color Your Night.ogg",
        751: "Changing Seasons -Reload-.ogg",
        752: "Joy.ogg",
        753: "Memories of you Kimi no Kioku -Reload-.ogg",
        706: "Want To Be Close -Reload-.ogg",
        661: "When The Moon's Reaching Out Stars -Reload-.ogg",
        894: "Peace -Reload-.ogg",
        895: "Iwatodai Dorm -Reload-.ogg",
        891: "I Will Protect You -Reload-.ogg",
        4336: "Memories of the School.ogg",
        6563: "It's Going Down Now.ogg",
        2907: "Disconnected.ogg",
        3671: "Brand New Days -The Beginning-.ogg",
        20138: "Brand New Days -Reload-.ogg",
        4047: "Don't.ogg",
    },
    (
        823,
        "zapsplat_vehicles_train_metro_interior_ride_few_people_distant_chat_"
        "sydney_australia_32726.mp3",
    ),
)


def assert_multi_asset_selection(project, assignment_id, selection, sound_id, extra=None):
    properties = {"music": {"value": selection}}
    properties.update(extra or {})
    commands = [
        message(
            "load",
            assignment_id=assignment_id,
            path=project,
            assetRoot=ASSETS,
            width=320,
            height=180,
            visible=True,
            evidenceFrames=2,
            userProperties=properties,
        ),
        *[
            message("capture-frame-difference", assignment_id=assignment_id)
            for _ in range(15)
        ],
        message("metrics", assignment_id=assignment_id),
        message("stop", assignment_id=assignment_id),
    ]
    result = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in commands),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=True,
    )
    assert not result.stderr, result.stderr
    events = [json.loads(line) for line in result.stdout.splitlines()]
    metrics = events[-2]
    assert metrics["type"] == "metrics", events
    control = sound_control_state(metrics)[sound_id]
    assert control["playRequests"] == 1, control
    assert control["requestedPlaying"] is True, control


assert_multi_asset_selection(
    arknights,
    "arknights-random-sound",
    "4",
    94,
    {"newproperty12": {"value": "0.2"}},
)
assert_multi_asset_selection(
    persona,
    "persona-shuffle-sound",
    "17",
    959,
)

print(
    "renderer helper first-frame, GBC audio and volume, Persona volume, "
    "Arknights and Persona property-sound lifecycle, 3D boundary, lifecycle, "
    "and shutdown checks passed"
)
