#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
workshop=${FRESCO_WORKSHOP_ROOT:-"$HOME/Library/Application Support/Steam/steamapps/workshop/content/431960"}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fresco-puppet.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

python3 - "$workshop" "$scratch" <<'PY'
import pathlib
import struct
import sys
import json

workshop = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
models = {
    "3479521040": ["models/人物_puppet.mdl", "models/气球_puppet.mdl"],
    "3448290956": [
        "models/左眼白_puppet.mdl",
        "models/脸_puppet.mdl",
        "models/左眼皮_puppet.mdl",
        "models/右眼皮_puppet.mdl",
        "models/呆毛_puppet.mdl",
    ],
}

for workshop_id, wanted in models.items():
    package_path = workshop / workshop_id / "scene.pkg"
    if not package_path.is_file():
        raise SystemExit(f"missing pinned Workshop package {workshop_id}")
    package = package_path.read_bytes()
    expected_hashes = {
        "3479521040": "c8e35f0ad9b49f882eda411fb0feada0fb1059fa7bb058db79271cae794cf147",
        "3448290956": "4bac6871f95380c374653c44a903538cfa841a8d17abe310a092543dd9ac6ac1",
    }
    import hashlib
    if hashlib.sha256(package).hexdigest() != expected_hashes[workshop_id]:
        raise SystemExit(f"pinned Workshop package changed for {workshop_id}")
    offset = 0
    header_size, = struct.unpack_from("<I", package, offset)
    offset += 4
    header = package[offset:offset + header_size]
    offset += header_size
    if header != b"PKGV0022":
        raise SystemExit(f"unexpected package version for {workshop_id}")
    entry_count, = struct.unpack_from("<I", package, offset)
    offset += 4
    entries = {}
    for _ in range(entry_count):
        name_size, = struct.unpack_from("<I", package, offset)
        offset += 4
        name = package[offset:offset + name_size].decode()
        offset += name_size
        entry_offset, entry_size = struct.unpack_from("<II", package, offset)
        offset += 8
        entries[name] = (entry_offset, entry_size)
    base = offset
    scene_offset, scene_size = entries["scene.json"]
    scene = json.loads(package[base + scene_offset:base + scene_offset + scene_size])
    if workshop_id == "3448290956":
        objects = {item["id"]: item for item in scene["objects"] if "id" in item}
        ahoge = next(item for item in objects.values() if item.get("image") == "models/呆毛.json")
        if ahoge.get("animationlayers"):
            raise SystemExit("Subaru ahoge unexpectedly gained authored model animation")
        ancestry = []
        parent = ahoge.get("parent")
        while parent is not None:
            ancestry.append(parent)
            parent = objects[parent].get("parent")
        if ancestry != [137, 142, 377, 179]:
            raise SystemExit(f"Subaru ahoge parent chain changed: {ancestry}")
        head = objects[142]
        origin_y = [point["value"] for point in head["origin"]["animation"]["c1"]]
        scale_x = [point["value"] for point in head["scale"]["animation"]["c0"]]
        if max(origin_y) - min(origin_y) < 1000 or max(scale_x) - min(scale_x) < 0.19:
            raise SystemExit("Subaru ahoge ancestors lost authored driving motion")
    for index, name in enumerate(wanted):
        if name not in entries:
            raise SystemExit(f"missing {name} in {workshop_id}")
        entry_offset, entry_size = entries[name]
        target = output / f"{workshop_id}-{index}.mdl"
        target.write_bytes(package[base + entry_offset:base + entry_offset + entry_size])
PY

clang++ -std=c++20 -Wall -Wextra -Werror \
    -I "$root/fresco-scene/renderer/include" \
    "$root/fresco-scene/renderer/src/PuppetModel.cpp" \
    "$root/fresco-scene/renderer/src/PuppetRuntimeMesh.cpp" \
    "$root/fresco-scene/renderer/src/PuppetSecondaryMotion.cpp" \
    "$root/fresco-scene/renderer/tests/puppet_model_test.cpp" \
    -o "$scratch/puppet-model-test"

clang++ -std=c++20 -Wall -Wextra -Werror \
    -I "$root/fresco-scene/renderer/include" \
    "$root/fresco-scene/renderer/src/PuppetLayerSemantics.cpp" \
    "$root/fresco-scene/renderer/tests/puppet_layer_semantics_test.cpp" \
    -o "$scratch/puppet-layer-semantics-test"

"$scratch/puppet-layer-semantics-test"

"$scratch/puppet-model-test" \
    "$scratch/3479521040-0.mdl" \
    "$scratch/3479521040-1.mdl" \
    "$scratch/3448290956-0.mdl" \
    "$scratch/3448290956-1.mdl" \
    "$scratch/3448290956-2.mdl" \
    "$scratch/3448290956-3.mdl" \
    "$scratch/3448290956-4.mdl"
