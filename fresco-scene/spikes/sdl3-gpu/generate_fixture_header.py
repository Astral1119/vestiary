#!/usr/bin/env python3

import json
import pathlib
import sys


if len(sys.argv) != 3:
    raise SystemExit("usage: generate_fixture_header.py FIXTURE OUTPUT")

fixture = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
geometry = fixture["geometry"]
transforms = {item["identity"]: item for item in fixture["transforms"]}


def floats(values):
    rendered = []
    for value in values:
        text = f"{float(value):.17g}"
        if "." not in text and "e" not in text:
            text += ".0"
        rendered.append(f"{text}f")
    return ", ".join(rendered)


lines = [
    "#pragma once",
    "#include <array>",
    "#include <cstdint>",
    "namespace fresco::sdl3_spike {",
    "struct Vertex { float x, y, z, u, v; };",
    f"inline constexpr std::array<Vertex, {len(geometry['vertices'])}> kVertices = {{{{",
]
lines.extend(f"    Vertex{{{floats(vertex)}}}," for vertex in geometry["vertices"])
lines.extend([
    "}};",
    f"inline constexpr std::array<std::uint16_t, {len(geometry['indices'])}> kIndices = {{{{{', '.join(str(value) for value in geometry['indices'])}}}}};",
    f"inline constexpr std::array<std::uint8_t, 16> kTexture = {{{{{', '.join(str(value) for value in bytes.fromhex(fixture['texture']['rgbaBytesHex']))}}}}};",
])
for identity in ("landscape-t0", "landscape-t1", "portrait-t1"):
    symbol = "k" + "".join(part.title() for part in identity.split("-"))
    lines.append(f"inline constexpr std::array<float, 16> {symbol} = {{{{{floats(transforms[identity]['resolvedFloat32ColumnMajor'])}}}}};")
lines.extend([
    "static_assert(sizeof(Vertex) == 20);",
    "}  // namespace fresco::sdl3_spike",
    "",
])
output = pathlib.Path(sys.argv[2])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text("\n".join(lines), encoding="utf-8")
