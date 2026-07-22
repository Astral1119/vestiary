#!/usr/bin/env python3

import copy
import hashlib
import json
import pathlib
import struct
import sys


WORKSHOP = pathlib.Path(sys.argv[1])
RENDERER = pathlib.Path(__file__).resolve().parents[1]
CONVERTER_SOURCE = RENDERER / "CMakeLists.txt"
INSPECTOR_SOURCE = RENDERER.parent / "src" / "main.mm"
CANONICAL_SIZE = "1000 1000"
CANONICAL_IMAGE = "models/fresco_procedural_quad.json"
FIXTURES = {
    "3299228616": {
        "sha256": "9e0c1e26523d1a434330f0b1d039783a8031d77715cecb0e53e23b73d7b2e346",
        "ids": {259, 565, 601, 1170, 1529, 1959},
    },
    "3460973721": {
        "sha256": "1dca928a8f1acf64e1f13aa7d2a7bc54631d452c7f613887030c1c972a2eb807",
        "ids": {53},
    },
}
ALLOWED_FIELDS = {
    "shape",
    "effects",
    "id",
    "name",
    "dependencies",
    "parent",
    "origin",
    "scale",
    "angles",
    "visible",
    "locktransforms",
    "disablepropagation",
    "castshadow",
    "alpha",
    "color",
    "horizontalalign",
    "alignment",
    "parallaxDepth",
    "colorBlendMode",
    "brightness",
}
REJECTED_GEOMETRY_FIELDS = {"depth", "light", "camera", "model"}


def package_scene(project):
    package = project / "scene.pkg"
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    with package.open("rb") as handle:
        def u32():
            return struct.unpack("<I", handle.read(4))[0]

        def string():
            return handle.read(u32()).decode("utf-8")

        revision = string()
        entries = [(string(), u32(), u32()) for _ in range(u32())]
        base = handle.tell()
        _, offset, length = next(
            entry for entry in entries if entry[0] == "scene.json"
        )
        handle.seek(base + offset)
        return revision, digest, json.loads(handle.read(length))


def canonical_quad(value):
    if set(value) - ALLOWED_FIELDS:
        return None
    if value.get("shape") != "quad":
        return None
    if not isinstance(value.get("effects"), list) or not value["effects"]:
        return None
    if value.get("castshadow", False):
        return None

    result = copy.deepcopy(value)
    result["image"] = CANONICAL_IMAGE
    result["size"] = CANONICAL_SIZE
    return result


synthetic = {
    "shape": "quad",
    "id": 7001,
    "name": "Synthetic bounded quad",
    "parent": 99,
    "origin": {"value": "17.25 -8.5 0"},
    "scale": "1.25 0.75 1",
    "angles": "0 0 13.5",
    "visible": {"user": "quad-visible", "value": True},
    "locktransforms": True,
    "disablepropagation": False,
    "alpha": {"user": "quad-alpha", "value": 0.625},
    "color": {"user": "quad-color", "value": "0.1 0.2 0.3"},
    "horizontalalign": "left",
    "alignment": "center",
    "parallaxDepth": "0.125 -0.25",
    "colorBlendMode": {"user": "quad-blend", "value": 2},
    "brightness": {"user": "quad-brightness", "value": 0.75},
    "effects": [
        {
            "file": "effects/lightshafts/effect.json",
            "id": 7002,
            "visible": {"user": "effect-visible", "value": True},
            "passes": [
                {
                    "id": 7003,
                    "combos": {"DIRECTDRAW": 1, "RENDERING": 1},
                    "constantshadervalues": {
                        "point0": "0.125 0.25",
                        "point1": "0.875 0.75",
                    },
                    "textures": [None, "masks/synthetic"],
                    "usertextures": {"g_Texture2": "quad-texture"},
                }
            ],
        }
    ],
}
authored = copy.deepcopy(synthetic)
converted = canonical_quad(synthetic)
assert converted is not None
assert synthetic == authored
for field in (
    "origin",
    "scale",
    "angles",
    "visible",
    "horizontalalign",
    "alignment",
    "parallaxDepth",
    "effects",
):
    assert converted[field] == authored[field], (field, converted, authored)
assert converted["effects"][0]["passes"] == authored["effects"][0]["passes"]
assert converted["image"] == CANONICAL_IMAGE
assert converted["size"] == CANONICAL_SIZE
assert list(converted).count("size") == 1

for rejected_field, rejected_value in {
    "size": "640 360",
    "depth": 1.0,
    "light": "point",
    "camera": "default",
    "model": "models/volume.json",
    "futureUnknownField": True,
}.items():
    candidate = copy.deepcopy(authored)
    candidate[rejected_field] = rejected_value
    assert canonical_quad(candidate) is None, (rejected_field, candidate)

for mutation in (
    {"shape": "triangle"},
    {"effects": []},
    {"castshadow": True},
):
    candidate = copy.deepcopy(authored)
    candidate.update(mutation)
    assert canonical_quad(candidate) is None, candidate

corpus_quads = []
for item_id, expected in FIXTURES.items():
    project = WORKSHOP / item_id
    if not (project / "scene.pkg").is_file():
        raise SystemExit(f"procedural quad fixture missing: {project}")
    revision, observed_digest, scene = package_scene(project)
    assert revision in {"PKGV0021", "PKGV0022", "PKGV0023", "PKGV0024"}, revision
    assert observed_digest == expected["sha256"], (item_id, observed_digest)
    quads = [item for item in scene["objects"] if item.get("shape") == "quad"]
    assert {item["id"] for item in quads} == expected["ids"], quads
    for quad in quads:
        assert "size" not in quad, quad
        assert not REJECTED_GEOMETRY_FIELDS & set(quad), quad
        canonical = canonical_quad(quad)
        assert canonical is not None, quad
        assert canonical["size"] == CANONICAL_SIZE, canonical
        assert canonical["effects"] == quad["effects"], canonical
    corpus_quads.extend(quads)
assert len(corpus_quads) == 7, corpus_quads

converter_source = CONVERTER_SOURCE.read_text()
allowlist_start = converter_source.index("bool effectOnlyFields = true;")
allowlist_end = converter_source.index(
    r"\tconst bool effectQuad = effectOnlyFields", allowlist_start
)
converter_allowlist = converter_source[allowlist_start:allowlist_end]
assert r'key != \"size\"' not in converter_allowlist, (
    "ObjectParser procedural-quad allowlist must reject authored size",
    converter_allowlist,
)
for rejected_field in REJECTED_GEOMETRY_FIELDS | {"futureUnknownField"}:
    escaped_field = f'key != "{rejected_field}"'.replace('"', r'\"')
    assert escaped_field not in converter_allowlist
assert converter_source.count(r'image[\"size\"] = \"1000 1000\";') == 1
assert converter_source.count(
    r'image[\"image\"] = \"models/fresco_procedural_quad.json\";'
) == 1

inspector_source = INSPECTOR_SOURCE.read_text()
inspector_start = inspector_source.index("NSSet* effectQuadFields")
inspector_end = inspector_source.index("]]", inspector_start)
inspector_allowlist = inspector_source[inspector_start:inspector_end]
assert '@"size"' not in inspector_allowlist, (
    "protocol effectQuad classification must match ObjectParser size rejection",
    inspector_allowlist,
)

print(
    "procedural quad boundary: 7 corpus quads accepted; authored size, "
    "depth/light/camera/model, and unknown fields rejected; canonical payload retained"
)
