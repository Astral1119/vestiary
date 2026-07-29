#include "FrescoScene/SceneObjectOpacity.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cmath>
#include <map>
#include <optional>

namespace {

using FrescoScene::SceneObjectOpacityNode;
using FrescoScene::maximumSceneObjectOpacityDepth;
using FrescoScene::sceneObjectInheritedOpacity;

using Chain = std::map<int, SceneObjectOpacityNode>;

float resolve (const Chain& chain, std::optional<int> parent) {
    return sceneObjectInheritedOpacity (
        parent,
        [&chain] (int id) -> std::optional<SceneObjectOpacityNode> {
            const auto found = chain.find (id);
            return found == chain.end ()
                ? std::nullopt
                : std::optional (found->second);
        }
    );
}

bool near (float value, float expected) {
    return std::fabs (value - expected) < 1e-6f;
}

} // namespace

int main () {
    // No parent is fully opaque.
    assert (near (resolve ({}, std::nullopt), 1.0f));

    // Hyuga's shape: particle 261 under composition layer 367 under group 438.
    // Only the composition layer contributes.
    const Chain hyuga {
        { 367, { .parent = 438, .propagatesOpacity = true, .opacity = 0.25f } },
        { 438, { .parent = std::nullopt } },
    };
    assert (near (resolve (hyuga, 367), 0.25f));

    // A fully faded layer takes its children to zero with it.
    const Chain faded {
        { 367, { .parent = std::nullopt, .propagatesOpacity = true, .opacity = 0.0f } },
    };
    assert (near (resolve (faded, 367), 0.0f));

    // An ordinary image does not contribute, however low its own effect alpha.
    // Elaina's media widget sits under 140 at 0.3 and 0.7; propagating those
    // would darken it to 0.21.
    const Chain ordinary {
        { 140, { .parent = std::nullopt, .propagatesOpacity = false, .opacity = 0.21f } },
    };
    assert (near (resolve (ordinary, 140), 1.0f));

    // Nested composition layers multiply.
    const Chain nested {
        { 2, { .parent = 1, .propagatesOpacity = true, .opacity = 0.5f } },
        { 1, { .parent = std::nullopt, .propagatesOpacity = true, .opacity = 0.5f } },
    };
    assert (near (resolve (nested, 2), 0.25f));

    // A contributing layer between two ordinary ones still reaches through.
    const Chain mixed {
        { 3, { .parent = 2, .propagatesOpacity = false, .opacity = 0.1f } },
        { 2, { .parent = 1, .propagatesOpacity = true, .opacity = 0.4f } },
        { 1, { .parent = std::nullopt, .propagatesOpacity = false, .opacity = 0.1f } },
    };
    assert (near (resolve (mixed, 3), 0.4f));

    // A missing parent fails open at whatever was accumulated, rather than
    // blanking output that scene construction already accepted.
    const Chain broken {
        { 2, { .parent = 99, .propagatesOpacity = true, .opacity = 0.5f } },
    };
    assert (near (resolve (broken, 2), 0.5f));
    assert (near (resolve (broken, 99), 1.0f));

    // A cycle terminates at the depth bound rather than spinning. Two mutually
    // parented layers at 1.0 leave the result opaque.
    const Chain cyclic {
        { 1, { .parent = 2, .propagatesOpacity = true, .opacity = 1.0f } },
        { 2, { .parent = 1, .propagatesOpacity = true, .opacity = 1.0f } },
    };
    assert (near (resolve (cyclic, 1), 1.0f));

    // A deep chain stops contributing past the bound. Each of the first
    // `maximumSceneObjectOpacityDepth` layers halves; beyond that nothing is
    // read, so the result is exactly that many halvings.
    Chain deep;
    for (int id = 0; id < maximumSceneObjectOpacityDepth + 8; ++id) {
        deep[id] = {
            .parent = id + 1,
            .propagatesOpacity = true,
            .opacity = 0.5f,
        };
    }
    float expected = 1.0f;
    for (int step = 0; step < maximumSceneObjectOpacityDepth; ++step) {
        expected *= 0.5f;
    }
    assert (near (resolve (deep, 0), expected));

    return 0;
}
