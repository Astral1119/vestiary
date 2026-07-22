#pragma once

#include <cstdint>

namespace FrescoScene {

enum class FrameRenderResult : std::uint8_t {
    presented,
    suppressedBeforePresentation,
    terminallySuppressedBeforePresentation,
};

}
