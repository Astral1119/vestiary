#include "FrescoScene/AudioLifecycleClassifier.h"

#include <cstdlib>

namespace {

void require (bool condition) {
    if (!condition) {
        std::abort ();
    }
}

}

int main () {
    const FrescoScene::AudioLifecycleClassifierEvidence exact {
        .objects = 1,
        .supportedConsumerObjects = 1,
        .objectTypeKinds = 1,
        .scriptValues = 1,
        .genericPropertyScripts = 1,
        .continuousGenericPropertyScripts = 1,
        .audioVectorScripts = 1,
        .exactTrackedAudioVectorScripts = 1,
    };
    require (FrescoScene::qualifiesTrackedAudioLifecycle (exact));
    auto unknown = exact;
    unknown.deferredScriptValues = 1;
    require (!FrescoScene::qualifiesTrackedAudioLifecycle (unknown));
    auto mixed = exact;
    mixed.genericPropertyScripts = 2;
    mixed.continuousGenericPropertyScripts = 2;
    require (!FrescoScene::qualifiesTrackedAudioLifecycle (mixed));
    auto automatic = exact;
    automatic.automaticDynamicValueAnimations = 1;
    require (!FrescoScene::qualifiesTrackedAudioLifecycle (automatic));
    auto unsupportedConsumer = exact;
    unsupportedConsumer.supportedConsumerObjects = 0;
    require (!FrescoScene::qualifiesTrackedAudioLifecycle (
        unsupportedConsumer
    ));
    auto genericAudio = exact;
    genericAudio.exactTrackedAudioVectorScripts = 0;
    require (!FrescoScene::qualifiesTrackedAudioLifecycle (genericAudio));
}
