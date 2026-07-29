#pragma once

#include <optional>

namespace FrescoScene {

inline constexpr int maximumSceneObjectOpacityDepth = 32;

struct SceneObjectOpacityNode {
    std::optional<int> parent;
    bool propagatesOpacity = false;
    float opacity = 1.0f;
};

// A passthrough composition layer is a grouping construct, so its chain opacity
// is the group's opacity and reaches its children. Hyuga 3479521040 fades its
// opening overlay by animating the `alpha` constant of an opacity effect on
// object 367 (`可调整组合层`), and the reference fades that layer's particle
// child 261 with it. 261 declares no alpha and no visibility of its own, and
// authored order draws it after 367, so it was never in the layer's framebuffer
// copy and nothing scaled it.
//
// The opacity travels as a multiplier and the geometry is untouched. The
// operator confirmed the embers are not cut by the layer's opacity mask
// (`masks/opacity_mask_f1d04d58` on effect 406), which rules out the child
// being composited into the layer's own chain.
//
// An ordinary image's effect alpha describes that image's own rendering and
// must not reach its children. A corpus survey over all 27 installed packages
// found 278 objects under an ancestor carrying an `alpha` effect constant, of
// which exactly one — Hyuga 261 — sits under a passthrough composition layer.
// Propagating from ordinary parents would darken Elaina's media widget by
// 0.3 * 0.7 and move Persona's six animated media-text children.
template<typename ParentResolver>
float sceneObjectInheritedOpacity (
    std::optional<int> parentId, ParentResolver&& resolveParent
) {
    float opacity = 1.0f;
    // Scene construction owns hierarchy validation. Runtime fails open for a
    // missing, cyclic, or overdeep chain instead of blanking valid output.
    for (
        int depth = 0;
        parentId.has_value () && depth < maximumSceneObjectOpacityDepth;
        ++depth
    ) {
        const auto parent = resolveParent (*parentId);
        if (!parent.has_value ()) {
            return opacity;
        }
        if (parent->propagatesOpacity) {
            opacity *= parent->opacity;
        }
        parentId = parent->parent;
    }
    return opacity;
}

} // namespace FrescoScene
