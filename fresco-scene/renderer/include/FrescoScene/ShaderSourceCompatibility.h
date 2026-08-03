#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace FrescoScene {

// Workshop shaders are authored against Wallpaper Engine's own compiler and
// runtime. Two repairs cover leniencies WE's compiler grants that glslang
// rejects outright — a shader that trips either one fails to build and its
// object is dropped, and when that object is a composition layer the whole
// subtree beneath it goes with it. The third covers a defect in a stock
// shader's fallback path that WE ships but never executes.
struct ShaderSourceRepair {
  enum class Kind {
    // A `#endif` with no open `#if`. WE's preprocessor ignores it.
    UnmatchedEndif,
    // A binary operation between vectors of different widths. HLSL truncates
    // the wider operand to the narrower one and warns; glslang errors.
    VectorTruncation,
    // genericropeparticle.vert's no-geometry-shader fallback extrudes the
    // trail ribbon as `right * uvs.x * 2.0 - 1.0`, which precedence binds as
    // `(right * uvs.x * 2.0) - 1.0`: the whole ribbon on one side of the
    // particle path, on whichever side the direction of travel puts it. The
    // geometry path WE actually runs emits `position ± right`, centred.
    RopeTrailExtrusion,
  };

  Kind kind;
  std::size_t line = 0; // 1-indexed, against the source as supplied
  std::string detail;
};

struct ShaderSourceCompatibility {
  std::string source;
  std::vector<ShaderSourceRepair> repairs;
};

// Returns the source with WE's leniencies applied, and a record of what was
// repaired. A shader needing nothing comes back byte-identical with no repairs,
// so this is safe to run over every shader rather than a known-bad list.
[[nodiscard]] ShaderSourceCompatibility
repairShaderSource(const std::string &source);

} // namespace FrescoScene
