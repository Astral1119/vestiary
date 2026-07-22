#pragma once

#include <string_view>

#include "FrescoScene/SceneSoundSemanticCapability.h"

namespace FrescoScene {

inline bool supportsMonoAudioAverageTransform (std::string_view source) {
    const auto capability = parseMonoAudioAverageTransformCapability (source);
    return capability.has_value ()
        && capability->resolution == 16
        && capability->bin == 0;
}

}
