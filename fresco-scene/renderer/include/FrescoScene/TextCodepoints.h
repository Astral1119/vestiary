#pragma once

#include <string_view>
#include <vector>

namespace FrescoScene {

inline constexpr char32_t kReplacementCodepoint = 0xFFFD;

// Decode UTF-8 into codepoints. Wallpaper text arrives as UTF-8, and iterating
// it as bytes rasterizes each byte as a separate Latin-1 character: GBC Subaru
// 3448290956 authors "功能提示：视线跟随、音频感应、自定义布局" and rendered it
// as mojibake.
//
// A malformed sequence yields one replacement codepoint per offending byte and
// decoding continues, so broken input still rasterizes rather than truncating
// the string. Overlong encodings, surrogates, and values above U+10FFFF are all
// malformed.
[[nodiscard]] std::vector<char32_t> decodeUtf8 (std::string_view text);

}
