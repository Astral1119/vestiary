#include "FrescoScene/SceneSoundCompatibility.h"

bool FrescoScene::forceStartSilent (
    std::size_t layerIndex,
    const std::vector<std::string>& layerNames,
    const std::vector<SoundControllerCapability>& controllers
) {
    const auto ownership = soundLayerOwnership (layerNames, controllers);
    return layerIndex < ownership.size () && ownership[layerIndex].startPaused;
}
