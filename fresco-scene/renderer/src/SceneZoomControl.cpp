#include "FrescoScene/SceneZoomControl.h"

#include "WallpaperEngine/Data/Model/DynamicValue.h"
#include "WallpaperEngine/Render/Wallpapers/CScene.h"

#include <cmath>
#include <map>
#include <mutex>

#include <glm/gtc/matrix_transform.hpp>

namespace FrescoScene {
namespace {

std::mutex zoomMutex;
WallpaperEngine::Data::Model::UserSettingUniquePtr pendingZoom;
std::map<const WallpaperEngine::Render::Wallpapers::CScene*, float> activeZoom;

}

void registerPendingSceneZoom (
    WallpaperEngine::Data::Model::UserSettingUniquePtr zoom
) {
    const std::lock_guard lock (zoomMutex);
    pendingZoom = std::move (zoom);
}

WallpaperEngine::Data::Model::DynamicValue* pendingSceneZoom () {
    const std::lock_guard lock (zoomMutex);
    return pendingZoom == nullptr ? nullptr : pendingZoom->value.get ();
}

void clearPendingSceneZoom () {
    const std::lock_guard lock (zoomMutex);
    pendingZoom.reset ();
}

bool setSceneZoom (
    WallpaperEngine::Render::Wallpapers::CScene& scene, float zoom
) {
    if (!std::isfinite (zoom) || zoom <= 0.0f) {
        return false;
    }
    const std::lock_guard lock (zoomMutex);
    const auto current = activeZoom.find (&scene);
    const bool changed = current == activeZoom.end () || current->second != zoom;
    activeZoom.insert_or_assign (&scene, zoom);
    return changed;
}

glm::mat4 applySceneZoom (
    const WallpaperEngine::Render::Wallpapers::CScene& scene,
    const glm::mat4& projection
) {
    const std::lock_guard lock (zoomMutex);
    const auto current = activeZoom.find (&scene);
    if (current == activeZoom.end () || current->second == 1.0f) {
        return projection;
    }
    return projection * glm::scale (
        glm::mat4 (1.0f), glm::vec3 (current->second, current->second, 1.0f)
    );
}

void clearSceneZoom (
    const WallpaperEngine::Render::Wallpapers::CScene& scene
) {
    const std::lock_guard lock (zoomMutex);
    activeZoom.erase (&scene);
}

SceneZoomEvidence sceneZoomEvidence (
    const WallpaperEngine::Render::Wallpapers::CScene& scene
) {
    const std::lock_guard lock (zoomMutex);
    const auto current = activeZoom.find (&scene);
    return current == activeZoom.end ()
        ? SceneZoomEvidence {}
        : SceneZoomEvidence { .active = true, .zoom = current->second };
}

}
