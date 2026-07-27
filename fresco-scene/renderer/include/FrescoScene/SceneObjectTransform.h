#pragma once

#include <array>
#include <cmath>
#include <optional>

#include <glm/vec2.hpp>
#include <glm/vec3.hpp>

namespace FrescoScene {

inline constexpr int maximumSceneObjectTransformDepth = 32;

struct SceneObjectTransform2D {
    glm::vec3 origin = { 0.0f, 0.0f, 0.0f };
    glm::vec3 scale = { 1.0f, 1.0f, 1.0f };
    float angle = 0.0f;
};

struct SceneObjectTransformNode {
    std::optional<int> parent;
    SceneObjectTransform2D local;
};

inline SceneObjectTransform2D composeSceneObjectTransform (
    const SceneObjectTransform2D& parent,
    const SceneObjectTransform2D& local
) {
    const float cosine = std::cos (parent.angle);
    const float sine = std::sin (parent.angle);
    // Scene origins run bottom-up, so a child's local Y adds to its parent's
    // rather than subtracting from it. Negating it here placed text and
    // particle children on opposite sides of their parent, because CText mapped
    // the resolved origin as `y - h/2` while CParticle used `h/2 - y`. The two
    // errors cancel whenever the root ancestor sits at the scene centre, which
    // is common enough to have hidden this.
    const glm::vec2 scaled {
        local.origin.x * parent.scale.x,
        local.origin.y * parent.scale.y,
    };
    const glm::vec2 rotated {
        scaled.x * cosine - scaled.y * sine,
        scaled.x * sine + scaled.y * cosine,
    };
    return {
        .origin = {
            parent.origin.x + rotated.x,
            parent.origin.y + rotated.y,
            parent.origin.z + local.origin.z * parent.scale.z,
        },
        .scale = local.scale * parent.scale,
        .angle = local.angle + parent.angle,
    };
}

template<typename ParentResolver>
SceneObjectTransform2D resolveSceneObjectTransform (
    const SceneObjectTransformNode& object,
    ParentResolver&& resolveParent
) {
    std::array<SceneObjectTransform2D, maximumSceneObjectTransformDepth + 1>
        chain {};
    int count = 1;
    chain[0] = object.local;
    std::optional<int> parent = object.parent;

    while (parent.has_value () && count <= maximumSceneObjectTransformDepth) {
        const auto node = resolveParent (*parent);
        if (!node.has_value ()) {
            break;
        }
        chain[count++] = node->local;
        parent = node->parent;
    }

    SceneObjectTransform2D resolved = chain[count - 1];
    for (int index = count - 2; index >= 0; --index) {
        resolved = composeSceneObjectTransform (resolved, chain[index]);
    }
    return resolved;
}

} // namespace FrescoScene
