#pragma once

#include <cstddef>

namespace FrescoScene {

struct MediaLifecycleClassificationEvidence {
    std::size_t objects = 0;
    std::size_t imageObjects = 0;
    std::size_t objectTypeKinds = 0;
    std::size_t effects = 0;
    std::size_t shaderFiles = 0;
    std::size_t puppetModels = 0;
    std::size_t audioFiles = 0;
    std::size_t scriptValues = 0;
    std::size_t players = 0;
    std::size_t referencedPlayers = 0;
    std::size_t fallbackPlayers = 0;
    std::size_t automaticDynamicValueAnimations = 0;
};

[[nodiscard]] inline bool qualifiesForTrackedMediaLifecycle (
    const MediaLifecycleClassificationEvidence& evidence
) {
    return evidence.objects == 1
        && evidence.imageObjects == 1
        && evidence.objectTypeKinds == 1
        && evidence.effects == 0
        && evidence.shaderFiles == 0
        && evidence.puppetModels == 0
        && evidence.audioFiles == 0
        && evidence.scriptValues == 0
        && evidence.players == 1
        && evidence.referencedPlayers == 1
        && evidence.fallbackPlayers == 0
        && evidence.automaticDynamicValueAnimations == 0;
}

}
