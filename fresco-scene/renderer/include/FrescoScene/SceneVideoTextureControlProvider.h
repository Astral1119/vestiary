#pragma once

#include "FrescoScene/VideoTextureControl.h"

#include <optional>
#include <string>

namespace FrescoScene {

using VideoTextureSceneToken = const void*;

void registerSceneVideoTextureControl (
    VideoTextureSceneToken scene,
    VideoTextureControlRegistry& registry
);
[[nodiscard]] bool registerSceneVideoTextureObject (
    VideoTextureSceneToken scene,
    int objectId,
    VideoTextureObjectToken object,
    std::string& diagnostic
);
void unregisterSceneVideoTextureObject (
    VideoTextureSceneToken scene,
    int objectId
);
void clearSceneVideoTextureControl (VideoTextureSceneToken scene);

[[nodiscard]] bool setSceneVideoTexturePaused (
    VideoTextureSceneToken scene,
    int objectId,
    bool paused,
    std::string& diagnostic
);
[[nodiscard]] std::optional<VideoTextureControlMetrics>
sceneVideoTextureControlMetrics (VideoTextureSceneToken scene);

}
