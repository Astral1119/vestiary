#pragma once

#include <string>
#include <string_view>

namespace FrescoScene {

enum class SceneScriptValueKind {
    null,
    vector2,
    vector3,
    vector4,
    floatingPoint,
    integer,
    boolean,
    string,
};

struct SceneScriptCompatibility {
    bool supported = false;
    std::string profile;
    std::string reason;
};

[[nodiscard]] bool isExactAudioVectorTransformSource (
    std::string_view source
);

[[nodiscard]] bool isTextLayerOwnedPropertyScript (
    std::string_view key,
    SceneScriptValueKind valueKind,
    bool objectIsText,
    int objectId
);

[[nodiscard]] SceneScriptCompatibility classifyScenePropertyScript (
    std::string_view key,
    SceneScriptValueKind valueKind,
    std::string_view source
);

[[nodiscard]] SceneScriptCompatibility classifySceneTextScript (
    std::string_view source
);

}
