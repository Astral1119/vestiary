#pragma once

#include <string>
#include <string_view>

namespace FrescoScene {

struct TextWidthLimitRequest {
    bool limitWidth = false;
    bool limitRows = false;
    bool useEllipsis = false;
    int maxRows = 0;
    int fullWidthPixels = 0;
    int maxWidthPixels = 0;
    std::string_view alignment;
};

struct TextWidthLimitResult {
    bool supported = false;
    int sourceOffsetPixels = 0;
    int widthPixels = 0;
    float quadLeft = 0.0f;
    float quadRight = 0.0f;
    std::string diagnostic;
};

[[nodiscard]] TextWidthLimitResult computeTextWidthLimit (
    const TextWidthLimitRequest& request
);
[[nodiscard]] std::string singleTextRow (std::string_view text);

}
