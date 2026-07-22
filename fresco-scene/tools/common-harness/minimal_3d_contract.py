#!/usr/bin/env python3

import hashlib
import math
import pathlib
import struct

import contract


WORKLOAD = "minimal-3d"
MANIFEST = "manifest-v1.json"
FIXTURE = "fixture-v1.json"
TRACE = "trace-v1.json"
REFERENCE = "reference-v1.json"

PARTS = [
    {"identity": "cube", "firstIndex": 0, "indexCount": 36},
    {"identity": "far-overlap", "firstIndex": 36, "indexCount": 6},
    {"identity": "perspective-near", "firstIndex": 42, "indexCount": 6},
    {"identity": "perspective-far", "firstIndex": 48, "indexCount": 6},
    {"identity": "cull-diagnostic", "firstIndex": 54, "indexCount": 3},
]

EXPECTED_ROLES = {
    "depth-overlap-near": {"cull-back-landscape-t0": "cube-near"},
    "far-nonoverlap-visible": {"cull-back-landscape-t0": "far-overlap"},
    "cull-diagnostic": {
        "cull-none-landscape-t0": "cull-diagnostic",
        "cull-back-landscape-t0": "clear",
    },
    "perspective-near-extent": {
        "cull-back-landscape-t0": "perspective-near"
    },
    "perspective-far-extent": {"cull-back-landscape-t0": "perspective-far"},
    "texture-top-left": {"cull-back-landscape-t0": "cube-near"},
    "texture-bottom-right": {"cull-back-landscape-t0": "cube-near"},
}

EXPECTED_ASSERTION_EVIDENCE = {
    "nonsequential-shared-indices": [
        "exact-index-bytes", "issued-indexed-draw",
        "analytically-proven-index-mutations",
    ],
    "depth-order-independent": [
        "depth-overlap-near", "near-indices-issued-before-far-indices",
        "analytic-less-depth-winner",
    ],
    "far-geometry-issued": [
        "far-nonoverlap-visible", "issued-indexed-draw",
        "far-only-analytic-coverage",
    ],
    "cull-none-diagnostic": [
        "cull-none-landscape-t0", "cull-diagnostic-visible",
    ],
    "back-face-culling": [
        "cull-back-landscape-t0", "cull-diagnostic-clear",
        "paired-identical-geometry-and-transform", "issued-indexed-draw",
    ],
    "perspective-foreshortening": [
        "equal-object-size", "spatially-isolated-near-far",
        "frozen-projected-bounds", "near-projected-extent-greater-than-far",
    ],
    "texture-orientation": [
        "texture-top-left", "texture-bottom-right", "top-left-image-edge-origin",
    ],
    "logical-transform-update": [
        "landscape-t0-resolved-bytes", "landscape-t1-resolved-bytes",
        "one-logical-constant-update",
    ],
    "stable-geometry-resources": [
        "vertex-hash-stable", "index-hash-stable", "texture-hash-stable",
        "pipeline-state-stable",
    ],
    "resize-extent-atomicity": [
        "new-presentation-extent", "new-depth-attachment",
        "new-resolved-transform", "no-stale-old-extent-output",
    ],
    "resize-depth-lifecycle": [
        "completion-before-old-depth-retirement",
        "zero-live-extent-dependent-attachments",
    ],
    "aspect-correct-projection": [
        "portrait-t1-resolved-bytes", "pixel-width-divided-by-height-aspect",
    ],
}

EXPECTED_CHECKPOINTS = [
    {
        "identity": "cull-none-landscape-t0",
        "atNanoseconds": 0,
        "extent": {"pixelWidth": 640, "pixelHeight": 360},
        "transform": "landscape-t0",
        "rasterCullMode": "none",
        "geometryState": "landscape-t0-shared-indexed-geometry",
        "assertions": [
            "nonsequential-shared-indices", "cull-none-diagnostic",
            "texture-orientation",
        ],
    },
    {
        "identity": "cull-back-landscape-t0",
        "atNanoseconds": 1,
        "extent": {"pixelWidth": 640, "pixelHeight": 360},
        "transform": "landscape-t0",
        "rasterCullMode": "back",
        "geometryState": "landscape-t0-shared-indexed-geometry",
        "assertions": [
            "nonsequential-shared-indices", "depth-order-independent",
            "far-geometry-issued", "back-face-culling",
            "perspective-foreshortening", "texture-orientation",
        ],
    },
    {
        "identity": "cull-back-landscape-t1",
        "atNanoseconds": 250000000,
        "extent": {"pixelWidth": 640, "pixelHeight": 360},
        "transform": "landscape-t1",
        "rasterCullMode": "back",
        "geometryState": "landscape-t1-shared-indexed-geometry",
        "assertions": [
            "logical-transform-update", "stable-geometry-resources",
            "perspective-foreshortening",
        ],
    },
    {
        "identity": "cull-back-portrait-t1",
        "atNanoseconds": 250000001,
        "extent": {"pixelWidth": 360, "pixelHeight": 640},
        "transform": "portrait-t1",
        "rasterCullMode": "back",
        "geometryState": "portrait-t1-shared-indexed-geometry",
        "assertions": [
            "resize-extent-atomicity", "resize-depth-lifecycle",
            "aspect-correct-projection", "stable-geometry-resources",
        ],
    },
]


def _require(condition, message):
    if not condition:
        raise contract.ContractError(message)


def _exact(value, keys, path):
    _require(isinstance(value, dict), f"{path} must be an object")
    actual = set(value)
    expected = set(keys)
    _require(actual == expected, f"{path} schema changed: {sorted(actual ^ expected)}")
    return value


def _numbers(value, length, path):
    _require(isinstance(value, list) and len(value) == length, f"{path} shape changed")
    _require(
        all(isinstance(item, (int, float)) and not isinstance(item, bool) for item in value),
        f"{path} contains a non-number",
    )
    return value


def _f32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


def _matmul_f32(left, right):
    result = []
    for column in range(4):
        for row in range(4):
            total = _f32(0)
            for inner in range(4):
                product = _f32(_f32(left[inner * 4 + row]) * _f32(right[column * 4 + inner]))
                total = _f32(total + product)
            result.append(total)
    return result


def _sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def _file_identity(path):
    value = path.read_bytes()
    return _sha256_bytes(value), len(value)


def _rect(value, identity):
    _numbers(value, 4, f"probe {identity}")
    _require(
        all(isinstance(item, int) and not isinstance(item, bool) for item in value),
        f"probe {identity} must use integer milli-units",
    )
    x, y, width, height = value
    _require(
        x >= 0 and y >= 0 and width > 0 and height > 0
        and x + width <= 1000 and y + height <= 1000,
        f"probe {identity} is outside the normalized frame",
    )
    return x, y, width, height


def _disjoint(first, second):
    ax, ay, aw, ah = first
    bx, by, bw, bh = second
    return ax + aw <= bx or bx + bw <= ax or ay + ah <= by or by + bh <= ay


def _project(vertex, matrix):
    position = [*vertex[:3], 1]
    clip = [
        sum(matrix[column * 4 + row] * position[column] for column in range(4))
        for row in range(4)
    ]
    _require(clip[3] > 0, "fixture geometry is behind the canonical camera")
    inverse_w = 1 / clip[3]
    return (
        (clip[0] * inverse_w + 1) / 2,
        (1 - clip[1] * inverse_w) / 2,
        clip[2] * inverse_w,
        vertex[3], vertex[4], inverse_w,
    )


def _barycentric(first, second, third, point):
    denominator = (
        (second[1] - third[1]) * (first[0] - third[0])
        + (third[0] - second[0]) * (first[1] - third[1])
    )
    if abs(denominator) < 1e-15:
        return None
    a = (
        (second[1] - third[1]) * (point[0] - third[0])
        + (third[0] - second[0]) * (point[1] - third[1])
    ) / denominator
    b = (
        (third[1] - first[1]) * (point[0] - third[0])
        + (first[0] - third[0]) * (point[1] - third[1])
    ) / denominator
    weights = (a, b, 1 - a - b)
    return weights if min(weights) >= -1e-9 else None


def _samples_for_rect(rect):
    x, y, width, height = rect
    inset = 0.001
    left, right = x / 1000 + inset, (x + width) / 1000 - inset
    top, bottom = y / 1000 + inset, (y + height) / 1000 - inset
    return [
        (left, top), (right, top), (left, bottom), (right, bottom),
        ((left + right) / 2, (top + bottom) / 2),
    ]


def _raster_hits(vertices, indices, matrix, point, cull_mode):
    hits = []
    for part in PARTS:
        start = part["firstIndex"]
        end = start + part["indexCount"]
        for offset in range(start, end, 3):
            projected = [_project(vertices[indices[offset + item]], matrix) for item in range(3)]
            area = (
                (projected[1][0] - projected[0][0])
                * (projected[2][1] - projected[0][1])
                - (projected[1][1] - projected[0][1])
                * (projected[2][0] - projected[0][0])
            )
            if cull_mode == "back" and area <= 0:
                continue
            weights = _barycentric(*projected, point)
            if weights is None:
                continue
            inverse_w = sum(weights[i] * projected[i][5] for i in range(3))
            uv = tuple(
                sum(
                    weights[i] * projected[i][5] * projected[i][3 + axis]
                    for i in range(3)
                ) / inverse_w
                for axis in range(2)
            )
            depth = sum(weights[i] * projected[i][2] for i in range(3))
            hits.append((depth, part["identity"], offset // 3, uv))
    return sorted(hits)


def _visible_sample(vertices, indices, matrix, point, cull_mode):
    hits = _raster_hits(vertices, indices, matrix, point, cull_mode)
    return hits[0] if hits else None


def _role(sample):
    if sample is None:
        return "clear"
    return "cube-near" if sample[1] == "cube" else sample[1]


def _same_sample(first, second):
    if first is None or second is None:
        return first is second
    return (
        first[1:3] == second[1:3]
        and math.isclose(first[0], second[0], abs_tol=1e-12)
        and all(math.isclose(a, b, abs_tol=1e-12) for a, b in zip(first[3], second[3]))
    )


def _validate_fixture(fixture):
    _exact(
        fixture,
        {"schemaVersion", "workload", "coordinateConvention", "camera", "vertexLayout", "geometry", "texture", "logicalConstantBinding", "transforms"},
        "fixture",
    )
    _require(fixture["schemaVersion"] == 1 and fixture["workload"] == WORKLOAD, "fixture identity changed")
    convention = _exact(fixture["coordinateConvention"], {"world", "clip", "framebuffer", "texture"}, "fixture coordinateConvention")
    _require(convention["world"] == {"handedness": "left", "positiveZ": "forward"}, "fixture world convention changed")
    _require(convention["clip"] == {"ndcYDirection": "up", "minimumZ": 0, "maximumZ": 1}, "fixture clip convention changed")
    _require(convention["framebuffer"] == {"origin": "top-left", "positiveX": "right", "positiveY": "down"}, "fixture framebuffer convention changed")
    _require(convention["texture"] == {"origin": "top-left-image-edge", "positiveU": "right", "positiveV": "down"}, "fixture texture convention changed")

    camera = _exact(fixture["camera"], {"verticalFieldOfViewDegrees", "nearZ", "farZ", "viewMatrixColumnMajor"}, "fixture camera")
    _require(camera["verticalFieldOfViewDegrees"] == 60 and camera["nearZ"] == 0.1 and camera["farZ"] == 100, "fixture camera changed")
    view = _numbers(camera["viewMatrixColumnMajor"], 16, "fixture view matrix")

    _require(fixture["vertexLayout"] == {
        "strideBytes": 20, "stepMode": "vertex",
        "attributes": [
            {"identity": "position", "location": 0, "format": "float32x3", "offsetBytes": 0},
            {"identity": "texture-coordinate", "location": 1, "format": "float32x2", "offsetBytes": 12},
        ],
    }, "fixture vertex layout changed")

    geometry = _exact(fixture["geometry"], {"vertexEncoding", "vertices", "vertexBytes", "vertexSha256", "indexEncoding", "indices", "indexBytesHex", "indexSha256", "parts"}, "fixture geometry")
    vertices = geometry["vertices"]
    _require(isinstance(vertices, list) and len(vertices) == 39, "fixture vertex count changed")
    for index, vertex in enumerate(vertices):
        _numbers(vertex, 5, f"fixture vertex {index}")
    vertex_bytes = struct.pack(f"<{len(vertices) * 5}f", *(item for vertex in vertices for item in vertex))
    _require(geometry["vertexEncoding"] == "little-endian-interleaved-float32" and geometry["vertexBytes"] == len(vertex_bytes) and geometry["vertexSha256"] == _sha256_bytes(vertex_bytes), "fixture vertex bytes contradict the declaration")
    indices = geometry["indices"]
    _require(isinstance(indices, list) and len(indices) == 57, "fixture index count changed")
    _require(all(isinstance(item, int) and 0 <= item < len(vertices) for item in indices), "fixture index is invalid")
    _require(indices != sorted(indices) and len(set(indices)) < len(indices), "fixture indices must be nonsequential and shared")
    index_bytes = struct.pack(f"<{len(indices)}H", *indices)
    _require(geometry["indexEncoding"] == "little-endian-uint16" and geometry["indexBytesHex"] == index_bytes.hex() and geometry["indexSha256"] == _sha256_bytes(index_bytes), "fixture index bytes contradict the declaration")
    _require(geometry["parts"] == PARTS, "fixture geometry parts changed")

    texture = _exact(fixture["texture"], {"width", "height", "format", "filter", "addressMode", "rgbaBytesHex", "sha256"}, "fixture texture")
    texture_bytes = bytes.fromhex(texture["rgbaBytesHex"])
    _require(texture["width"] == 2 and texture["height"] == 2 and texture["format"] == "rgba8unorm" and texture["filter"] == "nearest" and texture["addressMode"] == "clamp-to-edge" and len(texture_bytes) == 16 and texture["sha256"] == _sha256_bytes(texture_bytes), "fixture texture changed")
    _require(fixture["logicalConstantBinding"] == {"identity": "resolved-transform", "stage": "vertex", "slot": 0, "byteLength": 64, "semantic": "resolved-mvp-float32x4x4"}, "fixture logical constant binding changed")

    transforms = fixture["transforms"]
    expected_ids = ["landscape-t0", "landscape-t1", "portrait-t1"]
    _require(isinstance(transforms, list) and [item.get("identity") for item in transforms] == expected_ids, "fixture transform sequence changed")
    expected_extents = [(640, 360), (640, 360), (360, 640)]
    resolved_hashes = []
    by_transform = {}
    for transform, (width, height) in zip(transforms, expected_extents):
        identity = transform.get("identity")
        _exact(transform, {"identity", "extent", "modelMatrixColumnMajor", "projectionMatrixColumnMajor", "resolvedFloat32ColumnMajor", "resolvedBytesHex", "resolvedSha256"}, f"fixture transform {identity}")
        _require(transform["extent"] == {"pixelWidth": width, "pixelHeight": height}, f"fixture transform extent changed: {identity}")
        model = _numbers(transform["modelMatrixColumnMajor"], 16, "fixture model matrix")
        projection = _numbers(transform["projectionMatrixColumnMajor"], 16, "fixture projection matrix")
        _require(math.isclose(projection[0], projection[5] / (width / height), rel_tol=1e-7), "fixture projection aspect contradicts its extent")
        recomputed = _matmul_f32(projection, _matmul_f32(view, model))
        resolved = _numbers(transform["resolvedFloat32ColumnMajor"], 16, "fixture resolved transform")
        _require(resolved == recomputed, f"fixture resolved transform contradicts float32 MVP: {identity}")
        resolved_bytes = struct.pack("<16f", *resolved)
        digest = _sha256_bytes(resolved_bytes)
        _require(len(resolved_bytes) == 64 and transform["resolvedBytesHex"] == resolved_bytes.hex() and transform["resolvedSha256"] == digest, f"fixture resolved transform bytes contradict the declaration: {identity}")
        resolved_hashes.append(digest)
        by_transform[identity] = transform
    _require(len(set(resolved_hashes)) == 3, "fixture transforms are not distinct")

    matrix = by_transform["landscape-t0"]["resolvedFloat32ColumnMajor"]
    def area(offset):
        points = [_project(vertices[indices[offset + item]], matrix) for item in range(3)]
        return (points[1][0] - points[0][0]) * (points[2][1] - points[0][1]) - (points[1][1] - points[0][1]) * (points[2][0] - points[0][0])
    _require(area(0) > 0 and area(36) > 0 and area(42) > 0 and area(48) > 0 and area(54) < 0, "fixture does not isolate canonical and opposite framebuffer winding")
    return geometry, by_transform


def _validate_trace(trace, geometry, transforms):
    _exact(trace, {"schemaVersion", "workload", "profile", "seed", "depthFormatResolution", "drawContract", "checkpoints", "resizeTransition", "teardown"}, "trace")
    _require(trace["schemaVersion"] == 1 and trace["workload"] == WORKLOAD and trace["profile"] == "sdl3-depth-frozen" and trace["seed"] == 0, "trace identity changed")
    resolution = _exact(trace["depthFormatResolution"], {"status", "acceptableFormats", "requiredBefore", "selectionRule", "selectedFormat", "evidence"}, "trace depthFormatResolution")
    _exact(resolution["evidence"], {"candidate", "sdlVersion", "driver", "query", "usage", "support"}, "trace depthFormatResolution.evidence")
    _exact(resolution["evidence"]["support"], {"depth32float", "depth24unorm-stencil8", "depth16unorm"}, "trace depthFormatResolution.evidence.support")
    _require(resolution == {"status": "resolved", "acceptableFormats": ["depth32float", "depth24unorm-stencil8"], "requiredBefore": "pixel-reference-freeze", "selectionRule": "one format supported by every advancing candidate", "selectedFormat": "depth32float", "evidence": {"candidate": "sdl3-gpu-metal", "sdlVersion": "3.4.10", "driver": "metal", "query": "SDL_GPUTextureSupportsFormat", "usage": "depth-stencil-target", "support": {"depth32float": True, "depth24unorm-stencil8": False, "depth16unorm": True}}}, "depth format resolution evidence changed")
    draw = _exact(trace["drawContract"], {"clipDepthRange", "ndcYDirection", "framebufferOrigin", "frontFaceCoordinateSpace", "frontFace", "topology", "depth", "colorAttachment", "depthAttachment", "vertexLayout", "indexFormat", "textureBinding", "logicalConstantBinding"}, "trace drawContract")
    _exact(draw["depth"], {"clear", "compare", "writeEnabled"}, "trace drawContract.depth")
    _exact(draw["colorAttachment"], {"format", "load", "store"}, "trace drawContract.colorAttachment")
    _exact(draw["depthAttachment"], {"format", "load", "store"}, "trace drawContract.depthAttachment")
    _exact(draw["textureBinding"], {"stage", "textureSlot", "samplerSlot"}, "trace drawContract.textureBinding")
    _exact(draw["logicalConstantBinding"], {"stage", "slot", "byteLength"}, "trace drawContract.logicalConstantBinding")
    _require(draw == {"clipDepthRange": [0, 1], "ndcYDirection": "up", "framebufferOrigin": "top-left", "frontFaceCoordinateSpace": "framebuffer-after-viewport", "frontFace": "counter-clockwise", "topology": "triangle-list", "depth": {"clear": 1, "compare": "less", "writeEnabled": True}, "colorAttachment": {"format": "bgra8unorm-srgb", "load": "clear", "store": "store"}, "depthAttachment": {"format": "depth32float", "load": "clear", "store": "discard"}, "vertexLayout": "fixture-v1", "indexFormat": "uint16", "textureBinding": {"stage": "fragment", "textureSlot": 0, "samplerSlot": 0}, "logicalConstantBinding": {"stage": "vertex", "slot": 0, "byteLength": 64}}, "draw contract state changed")

    checkpoints = trace["checkpoints"]
    expected_ids = [item["identity"] for item in EXPECTED_CHECKPOINTS]
    _require(isinstance(checkpoints, list) and [item.get("identity") for item in checkpoints] == expected_ids, "trace checkpoint sequence changed")
    _require([item.get("atNanoseconds") for item in checkpoints] == [0, 1, 250000000, 250000001], "trace checkpoint times changed")
    by_checkpoint = {}
    for checkpoint, expected in zip(checkpoints, EXPECTED_CHECKPOINTS):
        identity = checkpoint.get("identity")
        _exact(checkpoint, {"identity", "atNanoseconds", "extent", "transform", "rasterCullMode", "geometryState", "issuedDrawEvidence", "assertions"}, f"trace checkpoint {identity}")
        _exact(checkpoint["extent"], {"pixelWidth", "pixelHeight"}, f"trace checkpoint {identity}.extent")
        _exact(checkpoint["issuedDrawEvidence"], {"indexed", "drawCount", "indexCount", "indexSha256"}, f"trace checkpoint {identity}.issuedDrawEvidence")
        transform = transforms.get(checkpoint["transform"])
        _require(transform is not None and checkpoint["extent"] == transform["extent"], "checkpoint extent contradicts transform")
        _require(checkpoint["issuedDrawEvidence"] == {"indexed": True, "drawCount": 1, "indexCount": 57, "indexSha256": geometry["indexSha256"]}, "checkpoint issued-draw evidence changed")
        _require(
            {key: checkpoint[key] for key in expected} == expected,
            f"checkpoint semantics changed: {identity}",
        )
        by_checkpoint[identity] = checkpoint
    none, back = checkpoints[:2]
    for field in ("extent", "transform", "geometryState", "issuedDrawEvidence"):
        _require(none[field] == back[field], f"cull pair differs in {field}")
    _require(none["rasterCullMode"] == "none" and back["rasterCullMode"] == "back", "cull pair does not isolate rasterCullMode")
    _require(trace["resizeTransition"] == {"fromCheckpoint": "cull-back-landscape-t1", "toCheckpoint": "cull-back-portrait-t1", "requires": ["new-presentation-extent", "new-depth-attachment", "new-resolved-transform", "completion-before-old-depth-retirement", "no-stale-old-extent-output"]}, "resize transition changed")
    _exact(trace["teardown"], {"requires"}, "trace teardown")
    _require(
        trace["teardown"] == {
            "requires": [
                "completion-before-retirement", "zero-live-logical-resources",
                "zero-live-extent-dependent-attachments",
            ]
        },
        "trace teardown semantics changed",
    )
    return checkpoints, by_checkpoint


def _validate_reference(reference, trace, fixture, geometry, transforms, checkpoints, by_checkpoint):
    _exact(reference, {"schemaVersion", "workload", "profile", "pixelOracle", "probes", "perspectiveBounds", "indexSensitivity", "assertions", "exclusions"}, "reference")
    _require(reference["schemaVersion"] == 1 and reference["workload"] == WORKLOAD and reference["profile"] == "sdl3-depth-frozen", "reference identity changed")
    oracle = _exact(reference["pixelOracle"], {"status", "selectedDepthFormat", "referenceSet"}, "reference pixelOracle")
    _require(oracle == {"status": "ready", "selectedDepthFormat": "depth32float", "referenceSet": "spikes/sdl3-gpu/reference-v1.json"}, "pixel oracle advanced without the frozen reference set")

    probes = reference["probes"]
    _require(isinstance(probes, list) and len(probes) == len(EXPECTED_ROLES), "reference probes changed")
    probe_rects = {}
    for probe in probes:
        identity = probe.get("identity")
        _exact(probe, {"identity", "normalizedMilliRect", "expectedRoles"}, f"reference probe {identity}")
        _require(identity in EXPECTED_ROLES and probe["expectedRoles"] == EXPECTED_ROLES[identity], f"reference probe expectedRole changed: {identity}")
        probe_rects[identity] = _rect(probe["normalizedMilliRect"], identity)
    _require(set(probe_rects) == set(EXPECTED_ROLES), "reference probe identities changed")
    depth_rect = probe_rects["depth-overlap-near"]
    for identity in ("far-nonoverlap-visible", "perspective-near-extent", "perspective-far-extent"):
        _require(_disjoint(depth_rect, probe_rects[identity]), f"{identity} overlaps the depth probe")
    _require(_disjoint(probe_rects["perspective-near-extent"], probe_rects["perspective-far-extent"]), "perspective probes overlap each other")

    vertices, indices = geometry["vertices"], geometry["indices"]
    for probe in probes:
        for checkpoint_identity, expected_role in probe["expectedRoles"].items():
            checkpoint = by_checkpoint[checkpoint_identity]
            matrix = transforms[checkpoint["transform"]]["resolvedFloat32ColumnMajor"]
            for point in _samples_for_rect(probe_rects[probe["identity"]]):
                hits = _raster_hits(
                    vertices, indices, matrix, point,
                    checkpoint["rasterCullMode"],
                )
                actual = _role(hits[0] if hits else None)
                _require(actual == expected_role, f"probe {probe['identity']} does not isolate expected role {expected_role}")
                intended_parts = (
                    {"cube", "far-overlap"}
                    if probe["identity"] == "depth-overlap-near"
                    else set() if expected_role == "clear"
                    else {"cube" if expected_role == "cube-near" else expected_role}
                )
                _require(
                    {hit[1] for hit in hits} == intended_parts,
                    f"probe {probe['identity']} has unintended primitive coverage",
                )

    matrix = transforms["landscape-t0"]["resolvedFloat32ColumnMajor"]
    depth_center = _samples_for_rect(depth_rect)[-1]
    depth_hits = _raster_hits(vertices, indices, matrix, depth_center, "back")
    _require({hit[1] for hit in depth_hits} >= {"cube", "far-overlap"} and depth_hits[0][1] == "cube", "depth probe does not prove a near winner over an issued far competitor")
    far_center = _samples_for_rect(probe_rects["far-nonoverlap-visible"])[-1]
    _require({hit[1] for hit in _raster_hits(vertices, indices, matrix, far_center, "back")} == {"far-overlap"}, "far-only probe has unintended primitive coverage")
    near_center = _visible_sample(vertices, indices, matrix, _samples_for_rect(probe_rects["texture-top-left"])[-1], "back")
    bottom_center = _visible_sample(vertices, indices, matrix, _samples_for_rect(probe_rects["texture-bottom-right"])[-1], "back")
    _require(near_center[3][0] < 0.5 and near_center[3][1] < 0.5 and bottom_center[3][0] > 0.5 and bottom_center[3][1] > 0.5, "texture probes contradict top-left image-edge orientation")

    perspective = _exact(reference["perspectiveBounds"], {"checkpoint", "equalObjectSize", "nearCameraZ", "farCameraZ", "nearNormalizedMilliBounds", "farNormalizedMilliBounds", "requiredInequality"}, "reference perspectiveBounds")
    _require(perspective["checkpoint"] == "cull-back-landscape-t0" and perspective["equalObjectSize"] == [0.4, 0.4] and perspective["nearCameraZ"] == 4 and perspective["farCameraZ"] == 6 and perspective["requiredInequality"] == "near-width-and-height-greater-than-far", "perspective diagnostic declaration changed")
    def bounds(part_identity):
        part = next(item for item in PARTS if item["identity"] == part_identity)
        vertex_ids = set(indices[part["firstIndex"]:part["firstIndex"] + part["indexCount"]])
        points = [_project(vertices[index], matrix) for index in vertex_ids]
        return [min(point[0] for point in points) * 1000, min(point[1] for point in points) * 1000, max(point[0] for point in points) * 1000, max(point[1] for point in points) * 1000]
    near_bounds, far_bounds = bounds("perspective-near"), bounds("perspective-far")
    for actual, frozen, identity in ((near_bounds, perspective["nearNormalizedMilliBounds"], "near"), (far_bounds, perspective["farNormalizedMilliBounds"], "far")):
        _numbers(frozen, 4, f"perspective {identity} bounds")
        _require(all(math.isclose(a, b, abs_tol=1e-9) for a, b in zip(actual, frozen)), f"perspective {identity} projected bounds changed")
    near_width, near_height = near_bounds[2] - near_bounds[0], near_bounds[3] - near_bounds[1]
    far_width, far_height = far_bounds[2] - far_bounds[0], far_bounds[3] - far_bounds[1]
    _require(near_width > far_width and near_height > far_height, "equal-size geometry does not prove perspective foreshortening")
    for ids, camera_z in (((28, 29, 30, 31), 4), ((32, 33, 34, 35), 6)):
        xs, ys = [vertices[i][0] for i in ids], [vertices[i][1] for i in ids]
        _require(math.isclose(max(xs) - min(xs), 0.4) and math.isclose(max(ys) - min(ys), 0.4) and all(vertices[i][2] + 4 == camera_z for i in ids), "perspective objects are not equal-size isolated depth diagnostics")

    sensitivity = _exact(reference["indexSensitivity"], {"indexSha256", "nonsequential", "sharedVertices", "mutations"}, "reference indexSensitivity")
    _require(sensitivity["indexSha256"] == geometry["indexSha256"] and sensitivity["nonsequential"] is True and sensitivity["sharedVertices"] is True, "index-sensitivity declaration contradicts the fixture")
    expected_mutations = [
        {"identity": "cube-texture-coverage", "indexOrdinal": 3, "replacement": 1, "targetProbe": "texture-top-left", "preservedProbe": "depth-overlap-near"},
        {"identity": "far-only-coverage", "indexOrdinal": 36, "replacement": 1, "targetProbe": "far-nonoverlap-visible", "preservedProbe": "depth-overlap-near"},
    ]
    _require(sensitivity["mutations"] == expected_mutations, "index mutations changed")
    for mutation in sensitivity["mutations"]:
        changed = list(indices)
        changed[mutation["indexOrdinal"]] = mutation["replacement"]
        target_point = _samples_for_rect(probe_rects[mutation["targetProbe"]])[-1]
        preserved_point = _samples_for_rect(probe_rects[mutation["preservedProbe"]])[-1]
        before_target = _visible_sample(vertices, indices, matrix, target_point, "back")
        after_target = _visible_sample(vertices, changed, matrix, target_point, "back")
        before_preserved = _visible_sample(vertices, indices, matrix, preserved_point, "back")
        after_preserved = _visible_sample(vertices, changed, matrix, preserved_point, "back")
        _require(not _same_sample(before_target, after_target), f"index mutation {mutation['identity']} does not alter target raster coverage")
        _require(_same_sample(before_preserved, after_preserved), f"index mutation {mutation['identity']} alters its preserved control probe")

    assertions = reference["assertions"]
    _require(isinstance(assertions, list), "reference assertions are missing")
    actual_evidence = {}
    for assertion in assertions:
        _exact(assertion, {"identity", "evidence"}, f"reference assertion {assertion.get('identity')}")
        actual_evidence[assertion["identity"]] = assertion["evidence"]
    _require(actual_evidence == EXPECTED_ASSERTION_EVIDENCE, "assertion evidence mapping changed")
    trace_assertions = {identity for checkpoint in checkpoints for identity in checkpoint["assertions"]}
    _require(trace_assertions == set(EXPECTED_ASSERTION_EVIDENCE), "trace assertions contradict the reference")
    exclusions = {"lighting", "material-system", "model-loader", "scene-graph", "camera-object", "animation-system", "frustum-culling", "occlusion-culling", "visibility-algorithms", "shadows", "instancing", "indirect-draws", "wallpaper-engine-3d-integration"}
    _require(exclusions <= set(reference["exclusions"]), "reference expands into a high-level 3D system")
    _require(trace["depthFormatResolution"]["status"] == "resolved" and trace["depthFormatResolution"]["selectedFormat"] == oracle["selectedDepthFormat"], "reference and trace depth-format states disagree")


def validate_values(fixture, trace, reference):
    geometry, transforms = _validate_fixture(fixture)
    checkpoints, by_checkpoint = _validate_trace(trace, geometry, transforms)
    _validate_reference(reference, trace, fixture, geometry, transforms, checkpoints, by_checkpoint)
    return fixture, trace, reference


def validate_directory(root):
    root = pathlib.Path(root)
    manifest = contract.load_json(root / MANIFEST)
    contract.validate_manifest(manifest)
    _require(manifest["workload"] == {"identity": WORKLOAD, "version": 1, "classification": "primary"}, "minimal-3d manifest identity changed")
    _require(manifest["criteriaVersion"] == "minimal-3d-sdl3-depth-v1", "minimal-3d criteria version changed")
    expected_files = {"fixture-v1": (FIXTURE, manifest["assets"]), "trace-v1": (TRACE, manifest["inputs"]), "reference-v1": (REFERENCE, [manifest["reference"]])}
    for identity, (filename, declarations) in expected_files.items():
        matches = [item for item in declarations if item["identity"] == identity]
        _require(len(matches) == 1, f"manifest does not bind {identity}")
        _require(_file_identity(root / filename) == (matches[0]["sha256"], matches[0]["bytes"]), f"manifest hash mismatch for {filename}")
    fixture = contract.load_json(root / FIXTURE)
    trace = contract.load_json(root / TRACE)
    reference = contract.load_json(root / REFERENCE)
    validate_values(fixture, trace, reference)
    expected_checkpoints = [{"identity": item["identity"], "invariants": item["assertions"]} for item in trace["checkpoints"]]
    _require([{"identity": item["identity"], "invariants": item["invariants"]} for item in manifest["checkpoints"]] == expected_checkpoints, "manifest checkpoints contradict the trace")
    _require([item["identity"] for item in manifest["invariants"]] == [item["identity"] for item in reference["assertions"]], "manifest invariants contradict the reference")
    return manifest, fixture, trace, reference


if __name__ == "__main__":
    workload_root = pathlib.Path(__file__).with_name("workloads") / WORKLOAD
    manifest, *_ = validate_directory(workload_root)
    print(contract.manifest_hash(manifest))
