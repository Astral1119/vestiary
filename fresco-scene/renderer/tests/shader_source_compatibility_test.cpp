// Every shader in a scene passes through this, so the cases that matter most
// are the ones where it must do nothing. A false rewrite would corrupt a shader
// that compiles today.

#include "FrescoScene/ShaderSourceCompatibility.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <string>

using FrescoScene::ShaderSourceRepair;
using FrescoScene::repairShaderSource;

namespace {

int countOf(const FrescoScene::ShaderSourceCompatibility &result,
            ShaderSourceRepair::Kind kind) {
  int total = 0;
  for (const auto &repair : result.repairs) {
    if (repair.kind == kind) {
      ++total;
    }
  }
  return total;
}

void unchanged(const std::string &source) {
  const auto result = repairShaderSource(source);
  assert(result.source == source);
  assert(result.repairs.empty());
}

} // namespace

int main() {
  // --- leaves correct shaders alone ---------------------------------------

  unchanged("void main() { gl_Position = vec4(0.0); }\n");
  unchanged("#if MASK\nuniform vec4 g_Texture1Resolution;\n#endif\n");
  unchanged("#ifdef A\n#else\n#endif\n#ifndef B\n#endif\n");
  // Same widths need no truncation.
  unchanged("uniform vec2 a;\nuniform vec2 b;\nvoid main() { vec2 c = a * b; }\n");
  // Scalar against a vector is legal GLSL broadcast, not a truncation.
  unchanged("uniform vec4 a;\nuniform float s;\nvoid main() { vec4 c = a * s; }\n");
  // Already swizzled.
  unchanged("uniform vec4 a;\nuniform vec2 b;\nvoid main() { vec2 c = a.xy * b; }\n");
  // A matrix operand is not a declared vector, so mul-style code is untouched.
  unchanged("uniform mat4 m;\nuniform vec4 v;\nvoid main() { vec4 c = m * v; }\n");
  // Member access on the right must not be read as a bare operand.
  unchanged("uniform vec4 a;\nuniform vec2 b;\nvoid main() { vec2 c = b * a.xy; }\n");

  // A directive inside a comment is not a directive.
  unchanged("// #endif\nvoid main() {}\n");
  unchanged("/* #endif\n#endif */\nvoid main() {}\n");

  // --- unmatched #endif ---------------------------------------------------

  {
    // The shape GBC Subaru's iris_movement__ shader has: a well-formed block
    // followed by a stray #endif.
    const auto result = repairShaderSource(
        "#if FOLLOWCURSOR\n  vec2 da;\n#endif\n\n#endif\n\nvoid main() {}\n");
    assert(countOf(result, ShaderSourceRepair::Kind::UnmatchedEndif) == 1);
    assert(result.source.find("#if FOLLOWCURSOR") != std::string::npos);
    assert(result.source ==
           "#if FOLLOWCURSOR\n  vec2 da;\n#endif\n\n\nvoid main() {}\n");
    assert(result.repairs.front().line == 5);
  }
  {
    // Indented and spaced forms are still directives.
    const auto result = repairShaderSource("  #  endif\nvoid main() {}\n");
    assert(countOf(result, ShaderSourceRepair::Kind::UnmatchedEndif) == 1);
    assert(result.source == "void main() {}\n");
  }
  {
    // An unclosed #if is left alone. Dropping something would not fix it, and
    // the error glslang gives for it is accurate.
    const auto result = repairShaderSource("#if A\nvoid main() {}\n");
    assert(result.repairs.empty());
  }

  // --- HLSL implicit truncation -------------------------------------------

  {
    // The GBC line, with the operand declared as a local.
    const auto result = repairShaderSource(
        "uniform vec2 g_CursorScale;\n"
        "void main() {\n"
        "  vec4 transformedCursorPosition = mul(v, m);\n"
        "  vec2 da = transformedCursorPosition * g_CursorScale;\n"
        "}\n");
    assert(countOf(result, ShaderSourceRepair::Kind::VectorTruncation) == 1);
    assert(result.source.find("transformedCursorPosition.xy * g_CursorScale") !=
           std::string::npos);
    // The declaration itself must not pick up a swizzle.
    assert(result.source.find("vec4 transformedCursorPosition = mul") !=
           std::string::npos);
  }
  {
    // Truncates toward the narrower operand whichever side it is on.
    const auto result = repairShaderSource(
        "uniform vec2 b;\nuniform vec4 a;\nvoid main() { vec2 c = b * a; }\n");
    assert(result.source.find("b * a.xy") != std::string::npos);
  }
  {
    // vec4 against vec3 narrows to three components, not two.
    const auto result = repairShaderSource(
        "uniform vec3 b;\nuniform vec4 a;\nvoid main() { vec3 c = a * b; }\n");
    assert(result.source.find("a.xyz * b") != std::string::npos);
  }
  {
    // A chain settles rather than stopping after the first rewrite.
    const auto result = repairShaderSource(
        "uniform vec4 a;\nuniform vec2 b;\nuniform vec2 c;\n"
        "void main() { vec2 d = a * b * c; }\n");
    assert(result.source.find("a.xy * b * c") != std::string::npos);
  }
  {
    // Multiple declarators on one line each register their width.
    const auto result = repairShaderSource(
        "void main() { vec4 a, b; vec2 s; vec2 r = b * s; }\n");
    assert(result.source.find("b.xy * s") != std::string::npos);
  }
  {
    // A name declared at two widths is ambiguous, so it is left alone.
    const auto result = repairShaderSource(
        "void f() { vec4 a; }\nvoid g() { vec2 a; vec2 b; vec2 c = a * b; }\n");
    assert(countOf(result, ShaderSourceRepair::Kind::VectorTruncation) == 0);
  }
  {
    // Hyuga's lens_flare_sun: a local scalar shadows a file-scope vector of the
    // same name. Tracking only the vector declaration appends `.xy` to a float
    // and breaks a shader that compiled before.
    const auto result = repairShaderSource(
        "varying vec4 timer;\n"
        "uniform vec2 rotation;\n"
        "void main() {\n"
        "  float timer = sin(g_Time);\n"
        "  vec2 v = rotation + timer;\n"
        "}\n");
    assert(countOf(result, ShaderSourceRepair::Kind::VectorTruncation) == 0);
    assert(result.source.find("timer.xy") == std::string::npos);
  }
  {
    // A scalar is not a truncation in either operand position.
    unchanged("uniform float s;\nuniform vec4 a;\nvoid main() { vec4 c = s * a; }\n");
  }
  {
    // A parameter list is separate declarations. Reading `float` as a
    // declarator name here made the scan run past the closing paren and through
    // the function body, so every declaration behind it went unseen — which is
    // how the shadowed `timer` above escaped the conflict rule.
    const auto result = repairShaderSource(
        "varying vec4 timer;\n"
        "uniform vec2 rotation;\n"
        "vec3 cc(vec3 color, float factor, float factor2) { return color; }\n"
        "void main() {\n"
        "  float timer = 1.0;\n"
        "  vec2 v = rotation + timer;\n"
        "}\n");
    assert(result.repairs.empty());
    assert(result.source.find("timer.xy") == std::string::npos);
  }
  {
    // A matrix must never take a swizzle.
    unchanged("uniform mat4 m;\nuniform vec2 b;\nvoid main() { vec2 c = m * b; }\n");
  }
  {
    // Compound assignment is not a binary arithmetic operator here.
    unchanged("uniform vec4 a;\nuniform vec2 b;\nvoid main() { b *= 2.0; }\n");
  }

  // --- one-sided rope trail extrusion -------------------------------------

  {
    // The authored line from genericropeparticle.vert's no-geometry-shader
    // fallback. The ribbon must extrude to both sides of the particle path,
    // as the geometry-shader path WE runs does.
    const auto result = repairShaderSource(
        "void main() {\n"
        "\tvec3 position = mix(startPosition, endPosition, uvs.y);\n"
        "\tvec3 right = mix(trailRightStart, trailRightEnd, uvs.y);\n"
        "\tposition += right * uvs.x * 2.0 - 1.0;\n"
        "}\n");
    assert(countOf(result, ShaderSourceRepair::Kind::RopeTrailExtrusion) == 1);
    assert(result.source.find("position += right * (uvs.x * 2.0 - 1.0);") !=
           std::string::npos);
    assert(result.source.find("right * uvs.x * 2.0 - 1.0") == std::string::npos);
    assert(result.repairs.front().line == 4);
  }
  {
    // The centred form needs nothing.
    unchanged("void main() { position += right * (uvs.x * 2.0 - 1.0); }\n");
  }
  {
    // The authored line in a comment is not code.
    unchanged("// position += right * uvs.x * 2.0 - 1.0;\nvoid main() {}\n");
  }

  // --- both at once -------------------------------------------------------

  {
    const auto result = repairShaderSource(
        "uniform vec2 s;\n"
        "#if A\n"
        "void main() { vec4 p = q; vec2 d = p * s; }\n"
        "#endif\n"
        "#endif\n");
    assert(countOf(result, ShaderSourceRepair::Kind::UnmatchedEndif) == 1);
    assert(countOf(result, ShaderSourceRepair::Kind::VectorTruncation) == 1);
    assert(result.source.find("p.xy * s") != std::string::npos);
    assert(result.source.find("#endif\n#endif") == std::string::npos);
  }

  return 0;
}
