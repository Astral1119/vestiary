#pragma once

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

namespace FrescoScene {

struct LocalAnimationLayerPlayClickCapability {
    std::string targetName;
};

struct LocalAnimationLayerTopology {
    bool imageObject = false;
    std::size_t serializedAnimationLayerCount = 0;
    std::size_t effectCount = 0;
    bool modelPresent = false;
    bool modelAutosize = false;
    bool puppetModel = false;
    std::size_t materialPassCount = 0;
    std::string materialShader;
    std::size_t textureImageCount = 0;
    bool textureAnimated = false;
    bool requestedNamedAnimationPresent = false;
};

[[nodiscard]] std::optional<LocalAnimationLayerPlayClickCapability>
parseLocalAnimationLayerPlayClickCapability (std::string_view source);

[[nodiscard]] bool isTopologyProvenInert (
    const LocalAnimationLayerPlayClickCapability& capability,
    const LocalAnimationLayerTopology& topology
);

}
