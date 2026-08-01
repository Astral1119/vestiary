#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace FrescoScene {

// Workshop shaders are authored against Wallpaper Engine's own compiler, which
// accepts two things glslang rejects outright. A shader that trips either one
// fails to build and its object is dropped, and when that object is a
// composition layer the whole subtree beneath it goes with it.
struct ShaderSourceRepair {
  enum class Kind {
    // A `#endif` with no open `#if`. WE's preprocessor ignores it.
    UnmatchedEndif,
    // A binary operation between vectors of different widths. HLSL truncates
    // the wider operand to the narrower one and warns; glslang errors.
    VectorTruncation,
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
