#pragma once

#include <cstdint>
#include <optional>

namespace FrescoScene {

[[nodiscard]] bool setScriptedTextureAnimationFrame (
    const void* scene, int objectId, uint32_t frame
);
[[nodiscard]] std::optional<uint32_t> scriptedTextureAnimationFrame (
    const void* scene, int objectId
);
void clearScriptedTextureAnimationFrame (const void* scene, int objectId);
void clearScriptedTextureAnimationFrames (const void* scene);

}
