#pragma once

#include "FrescoScene/SceneScriptCompatibility.h"

#include <string_view>

namespace FrescoScene {

[[nodiscard]] SceneScriptCompatibility
classifyBounded2DSceneScript (std::string_view key, SceneScriptValueKind valueKind,
                              std::string_view source);

}
