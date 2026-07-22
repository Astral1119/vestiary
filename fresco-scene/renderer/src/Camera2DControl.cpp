#include "FrescoScene/Camera2DControl.h"
#include "FrescoScene/SceneZoomControl.h"

#include "WallpaperEngine/Data/Model/DynamicValue.h"
#include "WallpaperEngine/Render/Wallpapers/CScene.h"

#include <glm/gtc/matrix_transform.hpp>

#include <cmath>
#include <cstdlib>
#include <map>
#include <mutex>

using WallpaperEngine::Data::Model::DynamicValue;

namespace FrescoScene {
namespace {

std::mutex registryMutex;
std::map<DynamicValue*, Camera2DControlDefinition> registry;

struct ActiveCamera2DControl {
    glm::vec2 center = {};
    float zoom = 1.0f;
};

std::map<const WallpaperEngine::Render::Wallpapers::CScene*, ActiveCamera2DControl>
    activeControls;

}

void registerCamera2DControl (
    DynamicValue& origin, Camera2DControlDefinition definition
) {
    if (std::getenv ("FRESCO_SCENE_2D_CAMERA_DISABLED") != nullptr) {
        return;
    }
    const std::lock_guard lock (registryMutex);
    registry.insert_or_assign (&origin, std::move (definition));
}

std::optional<Camera2DControlDefinition> takeCamera2DControl (
    DynamicValue& origin
) {
    const std::lock_guard lock (registryMutex);
    const auto found = registry.find (&origin);
    if (found == registry.end ()) {
        return std::nullopt;
    }
    auto result = std::move (found->second);
    registry.erase (found);
    return result;
}

void clearPendingCamera2DControls () {
    const std::lock_guard lock (registryMutex);
    registry.clear ();
}

bool setCamera2DControl (
    WallpaperEngine::Render::Wallpapers::CScene& scene,
    const glm::vec2& center,
    float zoom
) {
    if (!std::isfinite (center.x) || !std::isfinite (center.y)
        || !std::isfinite (zoom) || zoom <= 0.0f) {
        return false;
    }
    const std::lock_guard lock (registryMutex);
    const glm::vec2 canonicalCenter {
        static_cast<float> (scene.getWidth ()) * 0.5f,
        static_cast<float> (scene.getHeight ()) * 0.5f,
    };
    const ActiveCamera2DControl next {
        .center = canonicalCenter + center,
        .zoom = zoom,
    };
    const auto current = activeControls.find (&scene);
    const bool changed = current == activeControls.end ()
        || current->second.center != next.center
        || current->second.zoom != next.zoom;
    activeControls.insert_or_assign (&scene, next);
    return changed;
}

glm::mat4 applyCamera2DControl (
    const WallpaperEngine::Render::Wallpapers::CScene& scene,
    const glm::mat4& projection
) {
    const std::lock_guard lock (registryMutex);
    const auto control = activeControls.find (&scene);
    if (control == activeControls.end ()) {
        return applySceneZoom (scene, projection);
    }
    const glm::vec2 canonicalCenter {
        static_cast<float> (scene.getWidth ()) * 0.5f,
        static_cast<float> (scene.getHeight ()) * 0.5f,
    };
    const glm::vec2 delta = control->second.center - canonicalCenter;
    if (delta == glm::vec2 (0.0f) && control->second.zoom == 1.0f) {
        return applySceneZoom (scene, projection);
    }
    return applySceneZoom (scene, projection
        * glm::scale (
            glm::mat4 (1.0f),
            glm::vec3 (control->second.zoom, control->second.zoom, 1.0f)
        )
        * glm::translate (
            glm::mat4 (1.0f), glm::vec3 (-delta.x, -delta.y, 0.0f)
        ));
}

void clearCamera2DControl (
    const WallpaperEngine::Render::Wallpapers::CScene& scene
) {
    const std::lock_guard lock (registryMutex);
    activeControls.erase (&scene);
}

Camera2DControlEvidence camera2DControlEvidence (
    const WallpaperEngine::Render::Wallpapers::CScene& scene
) {
    const std::lock_guard lock (registryMutex);
    const auto control = activeControls.find (&scene);
    if (control == activeControls.end ()) {
        return {};
    }
    return {
        .active = true,
        .center = control->second.center,
        .zoom = control->second.zoom,
    };
}

}
