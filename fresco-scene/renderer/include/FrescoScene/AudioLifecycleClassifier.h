#pragma once

#include <cstddef>

namespace FrescoScene {

struct AudioLifecycleClassifierEvidence {
    std::size_t objects = 0;
    std::size_t supportedConsumerObjects = 0;
    std::size_t objectTypeKinds = 0;
    std::size_t effects = 0;
    std::size_t shaderFiles = 0;
    std::size_t puppetModels = 0;
    std::size_t audioFiles = 0;
    std::size_t scriptValues = 0;
    std::size_t genericPropertyScripts = 0;
    std::size_t continuousGenericPropertyScripts = 0;
    std::size_t audioVectorScripts = 0;
    std::size_t exactTrackedAudioVectorScripts = 0;
    std::size_t deferredScriptValues = 0;
    std::size_t automaticDynamicValueAnimations = 0;
};

[[nodiscard]] constexpr bool qualifiesTrackedAudioLifecycle (
    const AudioLifecycleClassifierEvidence& evidence
) noexcept {
    return evidence.objects == 1
        && evidence.supportedConsumerObjects == evidence.objects
        && evidence.objectTypeKinds == 1
        && evidence.effects == 0
        && evidence.shaderFiles == 0
        && evidence.puppetModels == 0
        && evidence.audioFiles == 0
        && evidence.scriptValues == 1
        && evidence.genericPropertyScripts == 1
        && evidence.continuousGenericPropertyScripts == 1
        && evidence.audioVectorScripts == 1
        && evidence.exactTrackedAudioVectorScripts == 1
        && evidence.deferredScriptValues == 0
        && evidence.automaticDynamicValueAnimations == 0;
}

}
