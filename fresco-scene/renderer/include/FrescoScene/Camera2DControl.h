#pragma once

#include "WallpaperEngine/Data/Model/UserSetting.h"

#include <glm/mat4x4.hpp>
#include <glm/vec2.hpp>

#include <optional>
#include <string>

namespace WallpaperEngine::Data::Model {
class DynamicValue;
}
namespace WallpaperEngine::Render::Wallpapers {
class CScene;
}

namespace FrescoScene {

struct Camera2DControlDefinition {
    int objectId = 0;
    std::string path;
    WallpaperEngine::Data::Model::UserSettingUniquePtr zoom;
};

struct Camera2DControlEvidence {
    bool active = false;
    glm::vec2 center = {};
    float zoom = 1.0f;
};

void registerCamera2DControl (
    WallpaperEngine::Data::Model::DynamicValue& origin,
    Camera2DControlDefinition definition
);

std::optional<Camera2DControlDefinition> takeCamera2DControl (
    WallpaperEngine::Data::Model::DynamicValue& origin
);

void clearPendingCamera2DControls ();

bool setCamera2DControl (
    WallpaperEngine::Render::Wallpapers::CScene& scene,
    const glm::vec2& center,
    float zoom
);

glm::mat4 applyCamera2DControl (
    const WallpaperEngine::Render::Wallpapers::CScene& scene,
    const glm::mat4& projection
);

void clearCamera2DControl (
    const WallpaperEngine::Render::Wallpapers::CScene& scene
);

Camera2DControlEvidence camera2DControlEvidence (
    const WallpaperEngine::Render::Wallpapers::CScene& scene
);

}
