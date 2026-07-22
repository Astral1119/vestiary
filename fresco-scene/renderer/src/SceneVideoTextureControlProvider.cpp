#include "FrescoScene/SceneVideoTextureControlProvider.h"

#include <map>
#include <mutex>
#include <unordered_map>

namespace FrescoScene {
namespace {

struct SceneBinding {
    VideoTextureControlRegistry* registry;
    std::map<int, VideoTextureObjectToken> objects;
};

std::unordered_map<VideoTextureSceneToken, SceneBinding> scenes;
std::mutex scenesMutex;

}

void registerSceneVideoTextureControl (
    VideoTextureSceneToken scene,
    VideoTextureControlRegistry& registry
) {
    const std::lock_guard lock (scenesMutex);
    if (scene == nullptr) {
        return;
    }
    scenes.insert_or_assign (scene, SceneBinding { .registry = &registry });
}

bool registerSceneVideoTextureObject (
    VideoTextureSceneToken scene,
    int objectId,
    VideoTextureObjectToken object,
    std::string& diagnostic
) {
    const std::lock_guard lock (scenesMutex);
    diagnostic.clear ();
    const auto binding = scenes.find (scene);
    if (scene == nullptr || binding == scenes.end ()) {
        diagnostic = "getVideoTexture() scene is not registered";
        return false;
    }
    if (object == nullptr) {
        diagnostic = "getVideoTexture() layer object is null";
        return false;
    }
    binding->second.objects.insert_or_assign (objectId, object);
    return true;
}

void unregisterSceneVideoTextureObject (
    VideoTextureSceneToken scene,
    int objectId
) {
    const std::lock_guard lock (scenesMutex);
    const auto binding = scenes.find (scene);
    if (binding != scenes.end ()) {
        binding->second.objects.erase (objectId);
    }
}

void clearSceneVideoTextureControl (VideoTextureSceneToken scene) {
    const std::lock_guard lock (scenesMutex);
    scenes.erase (scene);
}

bool setSceneVideoTexturePaused (
    VideoTextureSceneToken scene,
    int objectId,
    bool paused,
    std::string& diagnostic
) {
    const std::lock_guard lock (scenesMutex);
    diagnostic.clear ();
    const auto binding = scenes.find (scene);
    if (scene == nullptr || binding == scenes.end ()) {
        diagnostic = "getVideoTexture() scene is not registered";
        return false;
    }
    const auto object = binding->second.objects.find (objectId);
    if (object == binding->second.objects.end ()) {
        diagnostic = "getVideoTexture() layer object "
            + std::to_string (objectId) + " is not registered";
        return false;
    }
    const auto result = binding->second.registry->control (
        object->second,
        paused ? VideoTextureMethod::pause : VideoTextureMethod::play
    );
    if (!result) {
        diagnostic = videoTextureControlDiagnostic (result.error);
        return false;
    }
    return true;
}

std::optional<VideoTextureControlMetrics> sceneVideoTextureControlMetrics (
    VideoTextureSceneToken scene
) {
    const std::lock_guard lock (scenesMutex);
    const auto binding = scenes.find (scene);
    if (scene == nullptr || binding == scenes.end ()) {
        return std::nullopt;
    }
    return binding->second.registry->metrics ();
}

}
