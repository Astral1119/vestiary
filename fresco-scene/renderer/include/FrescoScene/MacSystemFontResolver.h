#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace FrescoScene {

struct MacSystemFontResolution {
    std::string requestedFamily;
    std::string resolvedFamily;
    std::string path;
    bool substituted = false;
    bool fixedPitch = false;
};

[[nodiscard]] std::optional<MacSystemFontResolution> resolveMacSystemFont (
    std::string_view wallpaperFont
);

// Path of a font carrying a glyph for `codepoint`, taken from Core Text's
// cascade. An embedded wallpaper font may legitimately lack the characters its
// own scripted text produces — Persona and Arknights both embed an Anurati face
// covering 37 codepoints, uppercase and punctuation only, and drive it with a
// date script that emits digits — and FreeType renders those as .notdef boxes.
// Returns nullopt when no installed font covers the codepoint.
[[nodiscard]] std::optional<std::string> resolveMacFallbackFontPath (
    char32_t codepoint
);

}
