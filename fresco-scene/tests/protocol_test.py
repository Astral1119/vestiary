#!/usr/bin/env python3

import json
import os
import signal
import struct
import subprocess
import sys
import tempfile


HELPER = os.path.abspath(sys.argv[1])
MANIFEST = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else None
WORKSHOP = os.environ.get(
    "FRESCO_WORKSHOP_DIR",
    os.path.expanduser(
        "~/Library/Application Support/Steam/steamapps/workshop/content/431960"
    ),
)
ASSET_FILES = (
    "shaders/generic4.vert",
    "shaders/generic4.frag",
    "shaders/genericimage2.vert",
    "shaders/genericimage2.frag",
    "shaders/genericimage3.vert",
    "shaders/genericimage3.frag",
    "shaders/genericimage4.vert",
    "shaders/genericimage4.frag",
    "shaders/genericparticle.vert",
    "shaders/genericparticle.frag",
    "materials/particle/halo.tex",
)


def package_bytes(documents, version="PKGV0024"):
    encoded = [
        (name.encode("utf-8"), json.dumps(document).encode("utf-8"))
        for name, document in documents
    ]
    table_bytes = sum(4 + len(name) + 8 for name, _ in encoded)
    offset = 0
    table = bytearray()
    payload = bytearray()
    for name, data in encoded:
        table += struct.pack("<I", len(name)) + name
        table += struct.pack("<II", offset, len(data))
        payload += data
        offset += len(data)
    header = version.encode("utf-8")
    return (
        struct.pack("<I", len(header))
        + header
        + struct.pack("<I", len(encoded))
        + table
        + payload
    )


def write_package(root, scene, extra=()):
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "scene.pkg"), "wb") as handle:
        handle.write(package_bytes([("scene.json", scene), *extra]))


def exchange(messages):
    process = subprocess.run(
        [HELPER],
        input="".join(json.dumps(message) + "\n" for message in messages),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=True,
    )
    assert not process.stderr, process.stderr
    return [json.loads(line) for line in process.stdout.splitlines()]


def message(kind, assignment, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": assignment,
        **values,
    }


def assert_envelope(event, kind, assignment):
    assert event["protocolVersion"] == 1, event
    assert event["type"] == kind, event
    assert event["assignmentID"] == assignment, event


with tempfile.TemporaryDirectory(prefix="fresco-scene-test.") as temporary:
    two_d = os.path.join(temporary, "two-d")
    write_package(
        two_d,
        {
            "objects": [
                {"image": "models/background.json", "effects": [{}, {}]},
                {"particle": "particles/stars.json"},
                {"text": {"script": "clock.js"}},
                {"sound": ["sounds/loop.ogg"]},
                {"camera": "default"},
                {
                    "shape": "quad",
                    "castshadow": False,
                    "effects": [{"file": "effects/procedural.json"}],
                },
            ]
        },
        extra=(
            ("models/puppet.json", {"puppet": "models/puppet.mdl"}),
            ("shaders/custom.vert", {}),
            ("shaders/custom.frag", {}),
            ("sounds/loop.ogg", {}),
        ),
    )

    three_d = os.path.join(temporary, "three-d")
    write_package(
        three_d,
        {
            "objects": [
                {"model": "models/planet/planet.mdl"},
                {"light": "point"},
                {"shape": "cone"},
                {"shape": "quad", "effects": [{}], "depth": 1},
                {"camera": "default"},
            ]
        },
    )

    sized_quad = os.path.join(temporary, "sized-quad")
    write_package(
        sized_quad,
        {
            "objects": [{
                "shape": "quad",
                "size": "640 360",
                "effects": [{"file": "effects/procedural.json"}],
            }]
        },
    )

    malformed_package = os.path.join(temporary, "malformed")
    os.makedirs(malformed_package)
    with open(os.path.join(malformed_package, "scene.pkg"), "wb") as handle:
        handle.write(struct.pack("<I", 8) + b"PKGV0024" + struct.pack("<I", 0xFFFFFFFF))

    wallpaper_engine = os.path.join(temporary, "wallpaper_engine")
    asset_root = os.path.join(wallpaper_engine, "assets")
    for relative in ASSET_FILES:
        target = os.path.join(asset_root, relative)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as handle:
            handle.write(b"fixture")
    asset_snapshot = sorted(
        os.path.relpath(os.path.join(root, name), wallpaper_engine)
        for root, _, names in os.walk(wallpaper_engine)
        for name in names
    )

    incomplete_assets = os.path.join(temporary, "incomplete-assets")
    os.makedirs(incomplete_assets)
    asset_events = exchange(
        [
            message("validate-assets", "assets-valid", path=wallpaper_engine),
            message("validate-assets", "assets-invalid", path=incomplete_assets),
            message(
                "validate-assets",
                "assets-missing",
                path=os.path.join(temporary, "does-not-exist"),
            ),
            message("stop", "assets-stop"),
        ]
    )
    assert_envelope(asset_events[0], "assets-validated", "assets-valid")
    assert asset_events[0]["valid"] is True, asset_events[0]
    assert asset_events[0]["path"] == os.path.realpath(asset_root), asset_events[0]
    assert asset_events[0]["missing"] == [], asset_events[0]
    assert asset_events[0]["required"] == list(ASSET_FILES), asset_events[0]
    assert_envelope(asset_events[1], "assets-invalid", "assets-invalid")
    assert asset_events[1]["valid"] is False, asset_events[1]
    assert asset_events[1]["missing"] == list(ASSET_FILES), asset_events[1]
    assert_envelope(asset_events[2], "assets-invalid", "assets-missing")
    assert asset_events[2]["valid"] is False, asset_events[2]
    assert_envelope(asset_events[3], "stopped", "assets-stop")
    assert asset_snapshot == sorted(
        os.path.relpath(os.path.join(root, name), wallpaper_engine)
        for root, _, names in os.walk(wallpaper_engine)
        for name in names
    )

    platform_hello = exchange(
        [message("hello", "platform"), message("stop", "platform-stop")]
    )[0]
    if "probe-opengl-4.1" in platform_hello["capabilities"]:
        opengl_events = exchange(
            [
                message("probe-opengl", "opengl"),
                message("stop", "opengl-stop"),
            ]
        )
        assert_envelope(opengl_events[0], "opengl-probed", "opengl")
        assert opengl_events[0]["major"] == 4, opengl_events[0]
        assert opengl_events[0]["minor"] >= 1, opengl_events[0]
        assert opengl_events[0]["coreProfile"] is True, opengl_events[0]
        assert opengl_events[0]["framebufferComplete"] is True, opengl_events[0]
        assert opengl_events[0]["glError"] == 0, opengl_events[0]
        red, green, blue, alpha = opengl_events[0]["pixel"]
        assert 55 <= red <= 75, opengl_events[0]
        assert 115 <= green <= 140, opengl_events[0]
        assert 175 <= blue <= 205, opengl_events[0]
        assert alpha == 255, opengl_events[0]
        assert opengl_events[0]["ordered"] is False, opengl_events[0]
        assert_envelope(opengl_events[1], "stopped", "opengl-stop")

    hello_probe = exchange(
        [message("hello", "hello-probe"), message("stop", "hello-probe-stop")]
    )[0]
    renderer_available = hello_probe["renderer"] != "unavailable"
    commands = [
        message("hello", "a"),
        message("inspect", "b", path=two_d),
        message("inspect", "sized-quad", path=sized_quad),
        message("inspect", "c", path=os.path.join(three_d, "scene.pkg")),
        message("ping", "d"),
    ]
    expected_types = [
        "hello",
        "inspected",
        "inspected",
        "unsupported",
        "heartbeat",
    ]
    if not renderer_available:
        commands.append(message("load", "e", path=two_d))
        expected_types.append("fatal")
    commands.append(message("stop", "f"))
    expected_types.append("stopped")
    events = exchange(commands)
    assert [event["type"] for event in events] == expected_types, events
    assert_envelope(events[0], "hello", "a")
    assert (events[0]["renderer"] != "unavailable") == renderer_available, events[0]
    if renderer_available:
        assert "render-text" in events[0]["capabilities"], events[0]
        assert "script-text" in events[0]["capabilities"], events[0]
        assert "runtime-metrics" in events[0]["capabilities"], events[0]
        assert "audio-spectrum" in events[0]["capabilities"], events[0]
        assert "script-audio-float-16-average0" in events[0]["capabilities"], events[0]
        assert "sound-cursor-click" in events[0]["capabilities"], events[0]
        sound_enabled = os.environ.get("FRESCO_SCENE_SOUND_EXPERIMENTAL") not in {
            None,
            "",
            "0",
        } and os.environ.get("FRESCO_SCENE_AUDIO_DISABLED") in {None, "", "0"}
        assert (
            "sound-playback" in events[0]["capabilities"]
        ) is sound_enabled, events[0]

    inspected = events[1]
    assert_envelope(inspected, "inspected", "b")
    assert inspected["supported2D"] is True, inspected
    expected_deferred = ["camera"]
    if not renderer_available:
        expected_deferred.append("sound")
        expected_deferred.append("puppetAnimation")
    else:
        expected_deferred.append("puppetSimulation")
    assert inspected["deferredTypes"] == expected_deferred, inspected
    assert inspected["package"]["packageVersion"] == "PKGV0024", inspected
    assert inspected["package"]["objects"] == 6, inspected
    assert inspected["package"]["effects"] == 3, inspected
    assert inspected["package"]["objectTypes"]["effectQuad"] == 1, inspected
    assert inspected["package"]["shaderFiles"] == 2, inspected
    assert inspected["package"]["puppetModels"] == 1, inspected
    assert inspected["package"]["audioFiles"] == 1, inspected
    assert inspected["package"]["scriptValues"] == 1, inspected
    assert inspected["package"]["textScriptValues"] == 1, inspected
    assert inspected["package"]["audioFloatScriptValues"] == 0, inspected
    assert inspected["package"]["deferredScriptValues"] == 0, inspected

    sized = events[2]
    assert_envelope(sized, "inspected", "sized-quad")
    assert sized["supported2D"] is True, sized
    assert "effectQuad" not in sized["package"]["objectTypes"], sized
    assert sized["deferredTypes"] == ["volumeLight"], sized
    assert sized["warnings"] == [
        "volume-light shape objects are not yet rendered"
    ], sized

    unsupported = events[3]
    assert_envelope(unsupported, "unsupported", "c")
    assert unsupported["supported2D"] is False, unsupported
    assert unsupported["hardUnsupportedTypes"] == ["model", "light"], unsupported
    assert unsupported["deferredTypes"] == ["camera", "volumeLight"], unsupported
    if not renderer_available:
        renderer_failure = next(
            event for event in events if event["assignmentID"] == "e"
        )
        assert renderer_failure["code"] == "renderer-unavailable", renderer_failure
    assert not any(event["type"] == "ready" for event in events), events

    invalid_package_events = exchange(
        [
            message("inspect", "invalid-package", path=malformed_package),
            message("ping", "after-invalid-package"),
            message("stop", "invalid-package-stop"),
        ]
    )
    assert_envelope(invalid_package_events[0], "fatal", "invalid-package")
    assert invalid_package_events[0]["code"] == "inspect-failed"
    assert_envelope(
        invalid_package_events[1], "heartbeat", "after-invalid-package"
    )
    assert_envelope(
        invalid_package_events[2], "stopped", "invalid-package-stop"
    )

    malformed = subprocess.run(
        [HELPER],
        input="not-json\n" + json.dumps(message("stop", "z")) + "\n",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=True,
    )
    malformed_events = [json.loads(line) for line in malformed.stdout.splitlines()]
    assert malformed_events[0]["type"] == "warning", malformed_events
    assert malformed_events[0]["code"] == "invalid-json", malformed_events
    assert_envelope(malformed_events[1], "stopped", "z")

    contract_events = exchange(
        [
            {"protocolVersion": 1, "type": "hello"},
            {"protocolVersion": 2, "type": "hello", "assignmentID": "v2"},
            message("unknown", "unknown"),
            message("stop", "contract-stop"),
        ]
    )
    assert contract_events[0]["code"] == "invalid-message", contract_events
    assert_envelope(contract_events[1], "fatal", "v2")
    assert contract_events[1]["scope"] == "assignment", contract_events
    assert_envelope(contract_events[2], "warning", "unknown")
    assert contract_events[2]["code"] == "unknown-command", contract_events
    assert_envelope(contract_events[3], "stopped", "contract-stop")

    process = subprocess.Popen(
        [HELPER],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    process.stdin.write(json.dumps(message("hello", "crash")) + "\n")
    process.stdin.flush()
    assert_envelope(json.loads(process.stdout.readline()), "hello", "crash")
    process.send_signal(signal.SIGKILL)
    assert process.wait(timeout=10) == -signal.SIGKILL

    restarted = exchange(
        [
            message("inspect", "restart", path=two_d),
            message("stop", "restart-stop"),
        ]
    )
    assert_envelope(restarted[0], "inspected", "restart")


if MANIFEST and os.path.isfile(MANIFEST):
    with open(MANIFEST, encoding="utf-8") as handle:
        fixtures = json.load(handle)["items"]

    installed = []
    requests = []
    for fixture in fixtures:
        path = os.path.join(WORKSHOP, fixture["id"], "scene.pkg")
        if not os.path.isfile(path):
            continue
        installed.append(fixture)
        requests.append(message("inspect", fixture["id"], path=path))
    requests.append(message("stop", "fixture-stop"))

    events = exchange(requests)
    fixture_events = events[:-1]
    assert len(fixture_events) == len(installed), (fixture_events, installed)
    for fixture, event in zip(installed, fixture_events):
        expected = fixture["package"]
        actual = event["package"]
        assert actual["packageVersion"] == expected["header"], (fixture["id"], event)
        for key in ("bytes", "files", "objects"):
            assert actual[key] == expected[key], (fixture["id"], key, actual, expected)
        authored_object_types = dict(actual["objectTypes"])
        supported_cameras = authored_object_types.pop("camera2D", 0)
        if supported_cameras:
            authored_object_types["camera"] = (
                authored_object_types.get("camera", 0) + supported_cameras
            )
        assert authored_object_types == expected["objectTypes"], (
            fixture["id"], "objectTypes", actual, expected
        )
        for key in (
            "effects", "shaderFiles", "puppetModels", "audioFiles", "scriptValues"
        ):
            assert actual[key] == expected[key], (fixture["id"], key, actual, expected)

        if fixture["id"] == "3448290956":
            assert actual["textScriptValues"] == 3, event
            assert actual["audioFloatScriptValues"] == 2, event
            assert actual["deferredScriptValues"] == 11, event
            assert (
                "11 other SceneScript dynamic values are not yet evaluated"
                in event["warnings"]
            ), event

        unsupported_role = fixture["role"].startswith("unsupported-3d")
        assert (event["type"] == "unsupported") == unsupported_role, (
            fixture["id"],
            event,
        )
    assert_envelope(events[-1], "stopped", "fixture-stop")
    print(f"fresco-scene protocol and package checks passed: {len(installed)} fixtures")
else:
    print("fresco-scene protocol checks passed; fixture manifest unavailable")
