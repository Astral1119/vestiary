#!/usr/bin/env python3

import argparse
import copy
import hashlib
import json
import pathlib
import subprocess
import tempfile


class EvidenceError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def exact(value, keys, path):
    require(isinstance(value, dict), f"{path} must be an object")
    require(set(value) == set(keys), f"{path} schema changed")


def load(path):
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def run_json(arguments):
    result = subprocess.run(arguments, check=True, text=True, capture_output=True)
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    require(len(lines) == 1, "spike did not emit one JSON evidence record")
    return json.loads(lines[0])


def validate_probe(value, reference):
    exact(value, {"schemaVersion", "mode", "sdlVersion", "driver", "support"}, "probe")
    exact(value["support"], reference["depthProbe"], "probe.support")
    require(value == {
        "schemaVersion": 1,
        "mode": "depth-probe",
        "sdlVersion": reference["implementation"]["sdlVersion"],
        "driver": reference["implementation"]["driver"],
        "support": reference["depthProbe"],
    }, "depth probe evidence changed")


def rectangle_colors(raw, width, rect):
    x, y, rect_width, rect_height = rect
    x0, x1 = x * width // 1000, (x + rect_width) * width // 1000
    height = len(raw) // (width * 4)
    y0, y1 = y * height // 1000, (y + rect_height) * height // 1000
    colors = set()
    for row in range(y0, y1):
        for column in range(x0, x1):
            offset = (row * width + column) * 4
            colors.add(raw[offset:offset + 4].hex())
    return sorted(colors)


def validate_render(value, reference, minimal_reference, output_root):
    exact(value, {"schemaVersion", "mode", "sdlVersion", "driver", "depthFormat", "colorFormat", "offscreen", "debugMode", "outputs", "lifecycle"}, "render")
    implementation = reference["implementation"]
    require({key: value[key] for key in implementation} == implementation, "implementation evidence changed")
    require(value["schemaVersion"] == 1 and value["mode"] == "render", "render identity changed")
    require(value["lifecycle"] == reference["lifecycle"], "lifecycle evidence changed")
    require(len(value["outputs"]) == len(reference["outputs"]), "output count changed")

    raw_by_identity = {}
    for actual, expected in zip(value["outputs"], reference["outputs"]):
        exact(actual, {"identity", "transform", "cull", "path", "width", "height", "indexed"}, f"output {expected['identity']}")
        require({key: actual[key] for key in actual if key != "path"} == {key: expected[key] for key in actual if key != "path"}, f"output metadata changed: {expected['identity']}")
        path = pathlib.Path(actual["path"])
        require(path == output_root / f"{expected['identity']}.bgra", f"output path escaped gate directory: {expected['identity']}")
        raw = path.read_bytes()
        require(len(raw) == expected["bytes"], f"output size changed: {expected['identity']}")
        require(hashlib.sha256(raw).hexdigest() == expected["sha256"], f"output hash changed: {expected['identity']}")
        raw_by_identity[expected["identity"]] = raw

    clear = raw_by_identity["static-render-foundation-clear"]
    require(set(clear[index:index + 4] for index in range(0, len(clear), 4)) == {bytes.fromhex("000000ff")}, "static foundation clear is not exact opaque black")
    rects = {probe["identity"]: probe["normalizedMilliRect"] for probe in minimal_reference["probes"]}
    widths = {output["identity"]: output["width"] for output in reference["outputs"]}
    for probe in reference["probeColors"]:
        actual_colors = rectangle_colors(raw_by_identity[probe["checkpoint"]], widths[probe["checkpoint"]], rects[probe["identity"]])
        require(actual_colors == probe["bgra8"], f"probe colors changed: {probe['identity']} at {probe['checkpoint']}")


def require_rejected(action, message):
    try:
        action()
    except EvidenceError:
        return
    raise EvidenceError(f"adversarial evidence was accepted: {message}")


def adversarial_checks(render, reference, minimal_reference, output_root):
    changed = copy.deepcopy(render)
    changed["lifecycle"]["fencesWaited"] -= 1
    require_rejected(lambda: validate_render(changed, reference, minimal_reference, output_root), "unwaited fence")
    changed = copy.deepcopy(render)
    changed["outputs"][2]["cull"] = "none"
    require_rejected(lambda: validate_render(changed, reference, minimal_reference, output_root), "cull drift")
    changed = copy.deepcopy(render)
    changed["depthFormat"] = "depth16unorm"
    require_rejected(lambda: validate_render(changed, reference, minimal_reference, output_root), "depth drift")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("probe", "gate"), required=True)
    parser.add_argument("--executable", type=pathlib.Path, required=True)
    parser.add_argument("--reference-root", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    reference = load(pathlib.Path(__file__).with_name("reference-v1.json"))
    minimal_reference = load(arguments.reference_root / "reference-v1.json")
    if arguments.mode == "probe":
        validate_probe(run_json([arguments.executable, "--probe-depth"]), reference)
        return
    with tempfile.TemporaryDirectory(prefix="fresco-sdl3-gpu-") as directory:
        output_root = pathlib.Path(directory)
        render = run_json([arguments.executable, "--depth", "depth32float", "--output", output_root])
        validate_render(render, reference, minimal_reference, output_root)
        adversarial_checks(render, reference, minimal_reference, output_root)


if __name__ == "__main__":
    main()
