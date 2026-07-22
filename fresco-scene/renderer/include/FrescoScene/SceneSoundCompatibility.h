#pragma once

#include "FrescoScene/SceneSoundSemanticCapability.h"

#include <cstddef>
#include <string>
#include <vector>

namespace FrescoScene {

[[nodiscard]] bool forceStartSilent (
    std::size_t layerIndex,
    const std::vector<std::string>& layerNames,
    const std::vector<SoundControllerCapability>& controllers
);

}
