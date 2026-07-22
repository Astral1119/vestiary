#include "FrescoScene/SceneSoundCompatibility.h"

#include <cstdlib>
#include <string>
#include <vector>

namespace {

void require (bool condition) {
    if (!condition) {
        std::abort ();
    }
}

}

int main () {
    const FrescoScene::SoundControllerCapability renamedAndReidentifiedController {
        .kind = FrescoScene::SoundControllerCapabilityKind::cursorSingleShot,
        .referencedLayers = {"renamed voice layer"},
    };
    const std::vector controllers {renamedAndReidentifiedController};
    require (FrescoScene::forceStartSilent (
        0, {"renamed voice layer", "ambient"}, controllers
    ));
    require (!FrescoScene::forceStartSilent (
        1, {"renamed voice layer", "ambient"}, controllers
    ));

    require (!FrescoScene::forceStartSilent (
        0, {"renamed voice layer", "renamed voice layer"}, controllers
    ));
    require (!FrescoScene::forceStartSilent (
        1, {"renamed voice layer", "renamed voice layer"}, controllers
    ));

    require (!FrescoScene::forceStartSilent (0, {"ambient"}, controllers));

    auto duplicateControllers = controllers;
    duplicateControllers.push_back (renamedAndReidentifiedController);
    require (FrescoScene::forceStartSilent (
        0, {"renamed voice layer"}, duplicateControllers
    ));
}
