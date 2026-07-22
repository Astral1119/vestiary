#include "FrescoScene/ParticleCompatibility.h"

#include <algorithm>
#include <cmath>

namespace FrescoScene {

ParticleChildContract particleChildContract (
    std::string_view type,
    std::string_view path,
    int maximumCount
) {
    ParticleChildContract result {
        .path = std::string (path),
        .maximumCount = maximumCount,
    };

    if (type.empty () || type == "static") {
        result.type = ParticleChildType::staticSystem;
    } else if (type == "eventfollow") {
        result.type = ParticleChildType::eventFollow;
    } else if (type == "eventspawn") {
        result.type = ParticleChildType::eventSpawn;
    } else {
        result.diagnostic = "unsupported particle child type: " + std::string (type);
        return result;
    }

    if (path.empty ()) {
        result.diagnostic = "particle child path is empty";
        return result;
    }
    if (maximumCount <= 0) {
        result.diagnostic = "particle child maximum count must be positive";
        return result;
    }

    result.renderable = true;
    return result;
}

ParticleAudioResult particleAudioFactor (
    const WallpaperEngine::Audio::Drivers::Recorders::PlaybackRecorder& recorder,
    const ParticleAudioConfiguration& configuration
) {
    if (configuration.mode == 0) {
        return {};
    }
    if (configuration.mode != 3) {
        return {
            .factor = 0.0F,
            .supported = false,
            .diagnostic = "unsupported particle audio processing mode: "
                + std::to_string (configuration.mode),
        };
    }
    if (!std::isfinite (configuration.lowerBound)
        || !std::isfinite (configuration.upperBound)
        || configuration.lowerBound >= configuration.upperBound) {
        return {
            .factor = 0.0F,
            .supported = false,
            .diagnostic = "invalid particle audio processing bounds",
        };
    }
    if (configuration.exponent <= 0) {
        return {
            .factor = 0.0F,
            .supported = false,
            .diagnostic = "particle audio processing exponent must be positive",
        };
    }
    if (configuration.frequencyStart < 0
        || configuration.frequencyEnd > 15
        || configuration.frequencyStart > configuration.frequencyEnd) {
        return {
            .factor = 0.0F,
            .supported = false,
            .diagnostic = "particle audio processing frequency range must be within 0...15",
        };
    }

    // Wallpaper Engine mode 3 is Center: the arithmetic mean of both channels.
    float total = 0.0F;
    std::size_t samples = 0;
    for (int index = configuration.frequencyStart;
         index <= configuration.frequencyEnd; ++index) {
        const float left = std::isfinite (recorder.audio16Left[index])
            ? recorder.audio16Left[index]
            : 0.0F;
        const float right = std::isfinite (recorder.audio16Right[index])
            ? recorder.audio16Right[index]
            : 0.0F;
        total += (left + right) * 0.5F;
        ++samples;
    }

    const float level = samples == 0 ? 0.0F : total / static_cast<float> (samples);
    const float normalized = std::clamp (
        (level - configuration.lowerBound)
            / (configuration.upperBound - configuration.lowerBound),
        0.0F,
        1.0F
    );
    return {
        .level = level,
        .factor = std::pow (normalized, static_cast<float> (configuration.exponent)),
    };
}

}
