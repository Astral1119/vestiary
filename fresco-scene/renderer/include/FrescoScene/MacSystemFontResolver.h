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

}
