#include "FrescoScene/TextWidthLimit.h"

#include <algorithm>

namespace FrescoScene {

TextWidthLimitResult computeTextWidthLimit (
    const TextWidthLimitRequest& request
) {
    if (!request.limitWidth) {
        return {.diagnostic = "text width limiting is not enabled"};
    }
    if (!request.limitRows || request.maxRows != 1) {
        return {.diagnostic = "text width limiting only supports one limited row"};
    }
    if (request.useEllipsis) {
        return {.diagnostic = "text width limiting does not support ellipsis"};
    }
    if (request.alignment != "left" && request.alignment != "right") {
        return {
            .diagnostic = "text width limiting only supports left or right alignment",
        };
    }
    if (request.fullWidthPixels < 0 || request.maxWidthPixels < 0) {
        return {.diagnostic = "text width limiting requires finite non-negative widths"};
    }

    const int width = std::min (
        request.fullWidthPixels, request.maxWidthPixels
    );
    if (request.alignment == "right") {
        return {
            .supported = true,
            .sourceOffsetPixels = request.fullWidthPixels - width,
            .widthPixels = width,
            .quadLeft = -static_cast<float> (width),
            .quadRight = 0.0f,
        };
    }
    return {
        .supported = true,
        .sourceOffsetPixels = 0,
        .widthPixels = width,
        .quadLeft = 0.0f,
        .quadRight = static_cast<float> (width),
    };
}

std::string singleTextRow (std::string_view text) {
    return std::string (text.substr (0, text.find_first_of ("\r\n")));
}

}
