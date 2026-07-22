#include "FrescoScene/SceneObjectTransform.h"

#include <cassert>
#include <cmath>
#include <map>

namespace {

using FrescoScene::SceneObjectTransform2D;
using FrescoScene::SceneObjectTransformNode;

constexpr float halfPi = 1.57079632679489661923f;

bool near (float left, float right) {
    return std::abs (left - right) < 0.0001f;
}

void testCompositionOrder () {
    const SceneObjectTransform2D parent {
        .origin = { 100.0f, 200.0f, 3.0f },
        .scale = { 2.0f, 3.0f, 4.0f },
        .angle = halfPi,
    };
    const SceneObjectTransform2D local {
        .origin = { 10.0f, 5.0f, 2.0f },
        .scale = { 0.5f, 2.0f, 0.25f },
        .angle = -0.25f,
    };
    const auto result = FrescoScene::composeSceneObjectTransform (parent, local);
    assert (near (result.origin.x, 115.0f));
    assert (near (result.origin.y, 220.0f));
    assert (near (result.origin.z, 11.0f));
    assert (near (result.scale.x, 1.0f));
    assert (near (result.scale.y, 6.0f));
    assert (near (result.scale.z, 1.0f));
    assert (near (result.angle, halfPi - 0.25f));
}

void testBoundedAncestorResolution () {
    const std::map<int, SceneObjectTransformNode> objects {
        { 1, {
            .parent = std::nullopt,
            .local = { .origin = { 100.0f, 0.0f, 0.0f } },
        } },
        { 2, {
            .parent = 1,
            .local = {
                .origin = { 10.0f, 0.0f, 0.0f },
                .scale = { 2.0f, 2.0f, 1.0f },
            },
        } },
        { 3, {
            .parent = 2,
            .local = { .origin = { 5.0f, 0.0f, 0.0f } },
        } },
    };
    const auto resolved = FrescoScene::resolveSceneObjectTransform (
        objects.at (3),
        [&objects] (int id) -> std::optional<SceneObjectTransformNode> {
            const auto value = objects.find (id);
            return value == objects.end ()
                ? std::nullopt
                : std::optional (value->second);
        }
    );
    assert (near (resolved.origin.x, 120.0f));
    assert (near (resolved.scale.x, 2.0f));
}

void testMissingParentFailsOpenAtLastResolvedNode () {
    const SceneObjectTransformNode object {
        .parent = 99,
        .local = { .origin = { 7.0f, 8.0f, 9.0f } },
    };
    const auto resolved = FrescoScene::resolveSceneObjectTransform (
        object,
        [] (int) -> std::optional<SceneObjectTransformNode> {
            return std::nullopt;
        }
    );
    assert (near (resolved.origin.x, 7.0f));
    assert (near (resolved.origin.y, 8.0f));
    assert (near (resolved.origin.z, 9.0f));
}

} // namespace

int main () {
    testCompositionOrder ();
    testBoundedAncestorResolution ();
    testMissingParentFailsOpenAtLastResolvedNode ();
}
