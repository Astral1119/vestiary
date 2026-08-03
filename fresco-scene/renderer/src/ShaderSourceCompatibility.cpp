#include "FrescoScene/ShaderSourceCompatibility.h"

#include <algorithm>
#include <cctype>
#include <map>
#include <string_view>

namespace FrescoScene {
namespace {

// Both repairs must ignore anything inside a comment. A `#endif` in a commented
// block is not a directive, and an operator there is not code. The mask is
// computed once and both passes read it, so neither has to re-derive comment
// state and risk disagreeing with the other.
std::vector<bool> codeMask(const std::string &source) {
  std::vector<bool> code(source.size(), true);
  bool inLine = false;
  bool inBlock = false;
  for (std::size_t index = 0; index < source.size(); ++index) {
    const char current = source[index];
    const char next = index + 1 < source.size() ? source[index + 1] : '\0';
    if (inLine) {
      code[index] = false;
      if (current == '\n') {
        inLine = false;
        code[index] = true;
      }
      continue;
    }
    if (inBlock) {
      code[index] = false;
      if (current == '*' && next == '/') {
        code[index + 1] = false;
        ++index;
        inBlock = false;
      }
      continue;
    }
    if (current == '/' && next == '/') {
      inLine = true;
      code[index] = false;
      continue;
    }
    if (current == '/' && next == '*') {
      inBlock = true;
      code[index] = false;
      code[index + 1] = false;
      ++index;
      continue;
    }
  }
  return code;
}

bool identifierChar(char value) {
  return std::isalnum(static_cast<unsigned char>(value)) != 0 || value == '_';
}

std::size_t lineOf(const std::string &source, std::size_t offset) {
  return static_cast<std::size_t>(
             std::count(source.begin(), source.begin() + static_cast<long>(offset), '\n')) +
         1;
}

// --- unmatched #endif -----------------------------------------------------

// Line-oriented rather than token-oriented, because a preprocessor directive
// occupies its whole line. Only the depth-zero `#endif` is dropped; a shader
// whose directives balance comes back untouched.
ShaderSourceCompatibility dropUnmatchedEndif(const std::string &source) {
  ShaderSourceCompatibility result;
  const auto code = codeMask(source);
  std::string output;
  output.reserve(source.size());
  std::size_t depth = 0;
  std::size_t position = 0;
  while (position <= source.size()) {
    const std::size_t end = source.find('\n', position);
    const std::size_t stop = end == std::string::npos ? source.size() : end;

    std::size_t cursor = position;
    while (cursor < stop && code[cursor] &&
           std::isspace(static_cast<unsigned char>(source[cursor])) != 0) {
      ++cursor;
    }
    bool dropped = false;
    if (cursor < stop && code[cursor] && source[cursor] == '#') {
      std::size_t word = cursor + 1;
      while (word < stop && code[word] &&
             std::isspace(static_cast<unsigned char>(source[word])) != 0) {
        ++word;
      }
      std::size_t wordEnd = word;
      while (wordEnd < stop && code[wordEnd] && identifierChar(source[wordEnd])) {
        ++wordEnd;
      }
      const std::string_view directive(source.data() + word, wordEnd - word);
      if (directive == "if" || directive == "ifdef" || directive == "ifndef") {
        ++depth;
      } else if (directive == "endif") {
        if (depth == 0) {
          result.repairs.push_back(
              {.kind = ShaderSourceRepair::Kind::UnmatchedEndif,
               .line = lineOf(source, cursor),
               .detail = "#endif with no open #if"});
          dropped = true;
        } else {
          --depth;
        }
      }
    }

    if (!dropped) {
      output.append(source, position, stop - position);
      if (end != std::string::npos) {
        output.push_back('\n');
      }
    }
    if (end == std::string::npos) {
      break;
    }
    position = end + 1;
  }
  result.source = std::move(output);
  return result;
}

// --- HLSL implicit vector truncation --------------------------------------

// A width of 1 is a scalar and kUnusable is anything a swizzle must never be
// appended to. Both are tracked rather than ignored, because the rule that
// matters is the conflict rule: a name declared at two different types is
// ambiguous and must be left alone. lens_flare_sun declares `varying vec4
// timer` at file scope and a local `float timer` that shadows it, and tracking
// only the vector declaration would append `.xy` to a float.
constexpr int kUnusable = -1;

int widthOfTypeKeyword(std::string_view keyword) {
  if (keyword == "float" || keyword == "int" || keyword == "uint" ||
      keyword == "bool" || keyword == "double") {
    return 1;
  }
  if (keyword == "vec2" || keyword == "ivec2" || keyword == "bvec2" ||
      keyword == "uvec2" || keyword == "dvec2") {
    return 2;
  }
  if (keyword == "vec3" || keyword == "ivec3" || keyword == "bvec3" ||
      keyword == "uvec3" || keyword == "dvec3") {
    return 3;
  }
  if (keyword == "vec4" || keyword == "ivec4" || keyword == "bvec4" ||
      keyword == "uvec4" || keyword == "dvec4") {
    return 4;
  }
  if (keyword.starts_with("mat") || keyword.starts_with("sampler") ||
      keyword.starts_with("image") || keyword == "void") {
    return kUnusable;
  }
  return 0; // not a type keyword
}

// Declared widths for named values. A name declared twice at different types is
// dropped rather than guessed at, so an ambiguous shader is left alone instead
// of being rewritten wrongly.
std::map<std::string, int> declaredWidths(const std::string &source,
                                          const std::vector<bool> &code) {
  std::map<std::string, int> widths;
  std::vector<std::string> conflicted;
  std::size_t index = 0;
  while (index < source.size()) {
    if (!code[index] || !identifierChar(source[index]) ||
        (index > 0 && identifierChar(source[index - 1]))) {
      ++index;
      continue;
    }
    std::size_t keywordEnd = index;
    while (keywordEnd < source.size() && identifierChar(source[keywordEnd])) {
      ++keywordEnd;
    }
    const int width =
        widthOfTypeKeyword(std::string_view(source.data() + index, keywordEnd - index));
    if (width == 0) {
      index = keywordEnd;
      continue;
    }
    std::size_t cursor = keywordEnd;
    // One or more declarators, so `vec2 a, b;` registers both.
    bool first = true;
    while (cursor < source.size()) {
      while (cursor < source.size() &&
             std::isspace(static_cast<unsigned char>(source[cursor])) != 0) {
        ++cursor;
      }
      if (cursor >= source.size() || !identifierChar(source[cursor]) ||
          std::isdigit(static_cast<unsigned char>(source[cursor])) != 0) {
        break;
      }
      const std::size_t nameStart = cursor;
      while (cursor < source.size() && identifierChar(source[cursor])) {
        ++cursor;
      }
      const std::string name = source.substr(nameStart, cursor - nameStart);
      // A parameter list is a run of separate declarations, not a run of
      // declarators, so a type keyword here ends this one and the outer scan
      // picks it up. Reading it as a name is what let `vec3 cc(vec3 color,
      // float factor, float factor2)` register `float` as a variable.
      if (widthOfTypeKeyword(name) != 0) {
        break;
      }
      while (cursor < source.size() &&
             std::isspace(static_cast<unsigned char>(source[cursor])) != 0) {
        ++cursor;
      }
      // A `(` here is a function signature or a constructor call such as
      // `vec2(x, y)`, not a declaration, so nothing is registered for it.
      if (cursor < source.size() && source[cursor] == '(' && first) {
        break;
      }
      const auto existing = widths.find(name);
      if (existing != widths.end() && existing->second != width) {
        conflicted.push_back(name);
      } else {
        widths.emplace(name, width);
      }
      first = false;
      // Skip an initializer so `vec4 a = f(x), b;` still reaches `b`. Stopping
      // when the nesting would go negative keeps a closing `)` from running the
      // scan on through the function body behind it and hiding every
      // declaration in there.
      int nesting = 0;
      bool closed = false;
      while (cursor < source.size()) {
        const char current = source[cursor];
        if (current == '(' || current == '[') {
          ++nesting;
        } else if (current == ')' || current == ']') {
          if (nesting == 0) {
            closed = true;
            break;
          }
          --nesting;
        } else if (nesting == 0 && (current == ',' || current == ';')) {
          break;
        }
        ++cursor;
      }
      // Only a comma continues the declarator run.
      if (closed || cursor >= source.size() || source[cursor] != ',') {
        break;
      }
      ++cursor;
    }
    index = cursor > index ? cursor : index + 1;
  }
  for (const auto &name : conflicted) {
    widths.erase(name);
  }
  return widths;
}

const char *swizzleFor(int width) {
  switch (width) {
  case 2:
    return ".xy";
  case 3:
    return ".xyz";
  default:
    return "";
  }
}

// Finds one `A op B` where A and B are declared vectors of different widths and
// rewrites the wider with a swizzle. Returns false when there is nothing left
// to do; the caller loops so that chains such as `a * b * c` settle.
bool truncateOnce(std::string &source, ShaderSourceCompatibility &result) {
  const auto code = codeMask(source);
  const auto widths = declaredWidths(source, code);
  if (widths.empty()) {
    return false;
  }

  auto readIdentifier = [&](std::size_t start, std::size_t &nameStart,
                            std::size_t &nameEnd) -> bool {
    std::size_t cursor = start;
    while (cursor < source.size() && code[cursor] &&
           std::isspace(static_cast<unsigned char>(source[cursor])) != 0) {
      ++cursor;
    }
    if (cursor >= source.size() || !code[cursor] || !identifierChar(source[cursor]) ||
        std::isdigit(static_cast<unsigned char>(source[cursor])) != 0) {
      return false;
    }
    nameStart = cursor;
    while (cursor < source.size() && identifierChar(source[cursor])) {
      ++cursor;
    }
    nameEnd = cursor;
    return true;
  };

  // A usable operand is a bare declared vector: not a member access, not
  // already swizzled, and not a function call.
  auto operandWidth = [&](std::size_t nameStart, std::size_t nameEnd,
                          int &width) -> bool {
    std::size_t back = nameStart;
    while (back > 0 && std::isspace(static_cast<unsigned char>(source[back - 1])) != 0) {
      --back;
    }
    if (back > 0 && source[back - 1] == '.') {
      return false;
    }
    std::size_t ahead = nameEnd;
    while (ahead < source.size() &&
           std::isspace(static_cast<unsigned char>(source[ahead])) != 0) {
      ++ahead;
    }
    if (ahead < source.size() && (source[ahead] == '.' || source[ahead] == '(' ||
                                  source[ahead] == '[')) {
      return false;
    }
    const auto found = widths.find(source.substr(nameStart, nameEnd - nameStart));
    // Only genuine vectors. A scalar against a vector is legal GLSL broadcast
    // rather than a truncation, and a matrix or sampler must never take a
    // swizzle.
    if (found == widths.end() || found->second < 2) {
      return false;
    }
    width = found->second;
    return true;
  };

  std::size_t index = 0;
  while (index < source.size()) {
    if (!code[index] || !identifierChar(source[index])) {
      ++index;
      continue;
    }
    if (index > 0 && identifierChar(source[index - 1])) {
      ++index;
      continue;
    }
    std::size_t leftStart = 0;
    std::size_t leftEnd = 0;
    if (!readIdentifier(index, leftStart, leftEnd)) {
      ++index;
      continue;
    }
    int leftWidth = 0;
    if (!operandWidth(leftStart, leftEnd, leftWidth)) {
      index = leftEnd;
      continue;
    }
    std::size_t cursor = leftEnd;
    while (cursor < source.size() &&
           std::isspace(static_cast<unsigned char>(source[cursor])) != 0) {
      ++cursor;
    }
    // Only the arithmetic operators. Comparison and assignment have their own
    // rules and are not what HLSL truncates.
    if (cursor >= source.size() || !code[cursor] ||
        (source[cursor] != '*' && source[cursor] != '/' && source[cursor] != '+' &&
         source[cursor] != '-')) {
      index = leftEnd;
      continue;
    }
    const char op = source[cursor];
    if (cursor + 1 < source.size() &&
        (source[cursor + 1] == '=' || source[cursor + 1] == op)) {
      index = leftEnd;
      continue;
    }
    std::size_t rightStart = 0;
    std::size_t rightEnd = 0;
    if (!readIdentifier(cursor + 1, rightStart, rightEnd)) {
      index = leftEnd;
      continue;
    }
    int rightWidth = 0;
    if (!operandWidth(rightStart, rightEnd, rightWidth)) {
      index = leftEnd;
      continue;
    }
    if (leftWidth == rightWidth) {
      index = leftEnd;
      continue;
    }

    const bool leftIsWider = leftWidth > rightWidth;
    const int narrow = leftIsWider ? rightWidth : leftWidth;
    const std::size_t insertAt = leftIsWider ? leftEnd : rightEnd;
    const std::string wide =
        source.substr(leftIsWider ? leftStart : rightStart,
                      (leftIsWider ? leftEnd - leftStart : rightEnd - rightStart));
    result.repairs.push_back(
        {.kind = ShaderSourceRepair::Kind::VectorTruncation,
         .line = lineOf(source, insertAt),
         .detail = wide + " truncated to vec" + std::to_string(narrow) +
                   " for '" + op + "'"});
    source.insert(insertAt, swizzleFor(narrow));
    return true;
  }
  return false;
}

// --- one-sided rope trail extrusion ---------------------------------------

// The line as WE ships it, and the same line with the parentheses the
// geometry-shader path implies. The cursor's trail ribbon is extruded from the
// particle path by `right`, a vector `cross()` derives from the direction of
// travel, so the unparenthesised form lays the ribbon wholly on one side of
// the path and swaps sides whenever the travel reverses. Matched as the exact
// authored bytes: this is a repair for one known line in one stock asset, not
// a grammar, and a source without it must come back untouched.
constexpr std::string_view kOneSidedExtrusion =
    "position += right * uvs.x * 2.0 - 1.0;";
constexpr std::string_view kCenteredExtrusion =
    "position += right * (uvs.x * 2.0 - 1.0);";

bool centerRopeTrailOnce(std::string &source, ShaderSourceCompatibility &result) {
  const auto code = codeMask(source);
  std::size_t position = source.find(kOneSidedExtrusion);
  while (position != std::string::npos && !code[position]) {
    position = source.find(kOneSidedExtrusion, position + 1);
  }
  if (position == std::string::npos) {
    return false;
  }
  result.repairs.push_back({.kind = ShaderSourceRepair::Kind::RopeTrailExtrusion,
                            .line = lineOf(source, position),
                            .detail = "rope trail extrusion recentred on the "
                                      "particle path"});
  source.replace(position, kOneSidedExtrusion.size(), kCenteredExtrusion);
  return true;
}

} // namespace

ShaderSourceCompatibility repairShaderSource(const std::string &source) {
  ShaderSourceCompatibility result = dropUnmatchedEndif(source);
  // Bounded so a rule that somehow fails to converge cannot hang a load. Each
  // pass inserts one swizzle, and no shader in the corpus needs more than a
  // handful.
  constexpr int kMaximumTruncations = 64;
  for (int pass = 0; pass < kMaximumTruncations; ++pass) {
    if (!truncateOnce(result.source, result)) {
      break;
    }
  }
  for (int pass = 0; pass < kMaximumTruncations; ++pass) {
    if (!centerRopeTrailOnce(result.source, result)) {
      break;
    }
  }
  return result;
}

} // namespace FrescoScene
