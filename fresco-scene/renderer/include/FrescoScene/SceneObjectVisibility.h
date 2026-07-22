#pragma once

#include <optional>

namespace FrescoScene {

inline constexpr int maximumSceneObjectVisibilityDepth = 32;

struct SceneObjectVisibilityNode {
    std::optional<int> parent;
    bool visible = true;
    bool propagatesVisibility = true;
};

constexpr bool sceneObjectTypePropagatesVisibility (
    bool isParticle, bool isText, bool isSound
) {
    return !isParticle && !isText && !isSound;
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
