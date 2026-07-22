#!/usr/bin/env python3

import pathlib
import sys


source = pathlib.Path(sys.argv[1]).read_text()

mapper_start = source.index("const auto visibilityNode")
mapper_end = source.index("const auto objectVisibleWithParents", mapper_start)
mapper = source[mapper_start:mapper_end]
assert "model.groupVisible" in mapper, mapper
assert "image->visible" not in mapper, mapper
assert "sceneObjectTypePropagatesVisibility" in mapper, mapper
for model_type in ("Particle", "Text", "Sound"):
    assert f"model.is<{model_type}> ()" in mapper, mapper

texture_marker = "Fresco: hidden-ancestor dynamic texture update gate."
render_marker = "Fresco: hidden-ancestor particle render gate."
assert source.count(texture_marker) == 1, source.count(texture_marker)
assert source.count(render_marker) == 1, source.count(render_marker)
assert "cur->is<Objects::CParticle> ()" in source, source

print("scene visibility generated-source contract passed")
