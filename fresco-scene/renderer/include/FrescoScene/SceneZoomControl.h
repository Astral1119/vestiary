#pragma once

#include "WallpaperEngine/Data/Model/UserSetting.h"

#include <glm/mat4x4.hpp>

namespace WallpaperEngine::Data::Model {
class DynamicValue;
}

namespace WallpaperEngine::Render::Wallpapers {
class CScene;
}

namespace FrescoScene {

struct SceneZoomEvidence {
    bool active = false;
    float zoom = 1.0f;
};

void registerPendingSceneZoom (
    WallpaperEngine::Data::Model::UserSettingUniquePtr zoom
);

WallpaperEngine::Data::Model::DynamicValue* pendingSceneZoom ();
void clearPendingSceneZoom ();

bool setSceneZoom (
    WallpaperEngine::Render::Wallpapers::CScene& scene,
    float zoom
);

glm::mat4 applySceneZoom (
    const WallpaperEngine::Render::Wallpapers::CScene& scene,
    const glm::mat4& projection
);

void clearSceneZoom (
    const WallpaperEngine::Render::Wallpapers::CScene& scene
);

SceneZoomEvidence sceneZoomEvidence (
    const WallpaperEngine::Render::Wallpapers::CScene& scene
);

}
