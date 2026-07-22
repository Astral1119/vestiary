#pragma once

#include "WallpaperEngine/Audio/AudioContext.h"

#include <cstddef>
#include <string>
#include <string_view>

namespace FrescoScene {

enum class ParticleChildType {
    staticSystem,
    eventFollow,
    eventSpawn,
    unsupported,
};

struct ParticleChildContract {
    ParticleChildType type = ParticleChildType::unsupported;
    std::string path;
    int maximumCount = 0;
    bool renderable = false;
    std::string diagnostic;
};

[[nodiscard]] ParticleChildContract particleChildContract (
    std::string_view type,
    std::string_view path,
    int maximumCount
);

struct ParticleAudioConfiguration {
    int mode = 0;
    float lowerBound = 0.0F;
    float upperBound = 1.0F;
    int exponent = 1;
    int frequencyStart = 0;
    int frequencyEnd = 15;
};

struct ParticleAudioResult {
    float level = 0.0F;
    float factor = 1.0F;
    bool supported = true;
    std::string diagnostic;
};

[[nodiscard]] ParticleAudioResult particleAudioFactor (
    const WallpaperEngine::Audio::Drivers::Recorders::PlaybackRecorder& recorder,
    const ParticleAudioConfiguration& configuration
);

}
