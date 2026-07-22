#pragma once

#include "FrescoScene/SceneScriptCompatibility.h"

#include <array>
#include <optional>
#include <string>
#include <string_view>

namespace FrescoScene {

enum class SceneEventProfile {
    none,
    playbackVisibility,
    thumbnailPrimaryColor,
    scriptPropertiesOrigin3,
    booleanSceneCameraZoom,
    inertCommented,
    inertTypeMismatch,
};

struct SceneCameraZoomCapability {
    std::string propertyKey;
    float enabledZoom = 1.0F;
    float disabledZoom = 1.0F;
};

[[nodiscard]] SceneEventProfile classifySceneEventProperty (
    std::string_view key,
    SceneScriptValueKind kind,
    std::string_view source
);

[[nodiscard]] SceneEventProfile classifySceneCameraZoom (
    SceneScriptValueKind kind,
    std::string_view source
);

[[nodiscard]] std::optional<SceneCameraZoomCapability>
parseSceneCameraZoomCapability (
    SceneScriptValueKind kind,
    std::string_view source
);

[[nodiscard]] bool hasDistinctiveSceneEventKernel (std::string_view source);
[[nodiscard]] bool hasDistinctiveSceneCameraZoomKernel (
    std::string_view source
);

[[nodiscard]] bool mediaPlaybackVisible (int playbackState);
[[nodiscard]] std::optional<std::array<float, 3>> parseThumbnailPrimaryColor (
    std::string_view color
);

class PrimaryColorTransition {
public:
    void setTarget (std::array<float, 3> color);
    [[nodiscard]] std::array<float, 3> advance (float deltaSeconds);
    [[nodiscard]] bool active () const;

private:
    static constexpr float durationSeconds = 1.0f;
    std::array<float, 3> m_previous {};
    std::array<float, 3> m_current {};
    float m_elapsed = durationSeconds;
};

}
