#include "FrescoScene/MediaLifecycleClassifier.h"

#include <cstdlib>

using FrescoScene::MediaLifecycleClassificationEvidence;
using FrescoScene::qualifiesForTrackedMediaLifecycle;

namespace {

void require (bool condition) {
    if (!condition) {
        std::abort ();
    }
}

}

int main () {
    const MediaLifecycleClassificationEvidence exact {
        .objects = 1,
        .imageObjects = 1,
        .objectTypeKinds = 1,
        .players = 1,
        .referencedPlayers = 1,
    };
    require (qualifiesForTrackedMediaLifecycle (exact));

    auto multiObject = exact;
    multiObject.objects = 2;
    multiObject.imageObjects = 2;
    multiObject.players = 2;
    multiObject.referencedPlayers = 2;
    require (!qualifiesForTrackedMediaLifecycle (multiObject));

    auto secondPlayer = exact;
    secondPlayer.players = 2;
    secondPlayer.referencedPlayers = 2;
    require (!qualifiesForTrackedMediaLifecycle (secondPlayer));

    auto mixed = exact;
    mixed.objectTypeKinds = 2;
    require (!qualifiesForTrackedMediaLifecycle (mixed));

    auto animated = exact;
    animated.automaticDynamicValueAnimations = 1;
    require (!qualifiesForTrackedMediaLifecycle (animated));
}
