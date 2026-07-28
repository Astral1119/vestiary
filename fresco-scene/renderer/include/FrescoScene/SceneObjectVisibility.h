#pragma once

#include <optional>

namespace FrescoScene {

inline constexpr int maximumSceneObjectVisibilityDepth = 32;

struct SceneObjectVisibilityNode {
    std::optional<int> parent;
    bool visible = true;
    bool propagatesVisibility = true;
};

// A text parent gates its children, measured against Wallpaper Engine. Persona
// 3151551777 roots its middle date/time cluster at text object 476
// `Clock-SHADOW`, authored off under the default `datetime` combo, and the
// reference draws none of its five children. Fresco drew all five, because text
// was excluded here and the children author no visibility of their own.
//
// Particle and Sound parents are not covered by that observation and keep the
// original policy until a reference measurement rules on them.
constexpr bool sceneObjectTypePropagatesVisibility (
    bool isParticle, [[maybe_unused]] bool isText, bool isSound
) {
    return !isParticle && !isSound;
}

template<typename ParentResolver>
bool sceneObjectVisibleWithAncestors (
    std::optional<int> parentId, ParentResolver&& resolveParent
) {
    // Scene construction owns hierarchy validation. Runtime culling fails open
    // for a missing, cyclic, or overdeep chain instead of hiding valid output.
    for (
        int depth = 0;
        parentId.has_value () && depth < maximumSceneObjectVisibilityDepth;
        ++depth
    ) {
        const auto parent = resolveParent (*parentId);
        if (!parent.has_value ()) {
            return true;
        }
        if (parent->propagatesVisibility && !parent->visible) {
            return false;
        }
        parentId = parent->parent;
    }
    return true;
}

} // namespace FrescoScene
