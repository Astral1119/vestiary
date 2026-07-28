#include "FrescoScene/SceneObjectVisibility.h"

#include <cassert>
#include <map>

namespace {

using FrescoScene::SceneObjectVisibilityNode;

void testAuthoredTypePropagationPolicy () {
    const auto propagates = FrescoScene::sceneObjectTypePropagatesVisibility;
    assert (propagates (false, false, false)); // Image and generic group.
    assert (!propagates (true, false, false)); // Particle hierarchy.
    assert (!propagates (false, false, true)); // Sound hierarchy.

    // Text gates its children, against Wallpaper Engine. Persona 3151551777's
    // middle date/time cluster hangs off text object 476, authored off under
    // the default `datetime`, and the reference draws none of it.
    assert (propagates (false, true, false));
}

bool visible (
    const SceneObjectVisibilityNode& object,
    const std::map<int, SceneObjectVisibilityNode>& objects
) {
    return FrescoScene::sceneObjectVisibleWithAncestors (
        object.parent,
        [&objects] (int id) -> std::optional<SceneObjectVisibilityNode> {
            const auto object = objects.find (id);
            return object == objects.end ()
                ? std::nullopt
                : std::optional (object->second);
        }
    );
}

void testAncestorVisibility () {
    const std::map<int, SceneObjectVisibilityNode> objects {
        { 1, { .parent = std::nullopt, .visible = true } },
        { 2, { .parent = 1, .visible = true } },
        { 3, { .parent = 2, .visible = true } },
    };
    assert (visible (objects.at (3), objects));

    auto hiddenParent = objects;
    hiddenParent.at (2).visible = false;
    assert (!visible (hiddenParent.at (3), hiddenParent));

}

void testDynamicAncestorVisibility () {
    std::map<int, SceneObjectVisibilityNode> objects {
        { 1, { .parent = std::nullopt, .visible = false } },
        { 2, { .parent = 1, .visible = true } },
    };
    assert (!visible (objects.at (2), objects));
    objects.at (1).visible = true;
    assert (visible (objects.at (2), objects));
}

void testParticleParentDoesNotGateAuthoredChild () {
    std::map<int, SceneObjectVisibilityNode> objects {
        { 1, {
            .parent = std::nullopt,
            .visible = false,
            .propagatesVisibility = false,
        } },
        { 2, { .parent = 1, .visible = true } },
    };
    assert (visible (objects.at (2), objects));
    objects.at (1).visible = true;
    assert (visible (objects.at (2), objects));
}

void testInvalidAndOverdeepHierarchyFailsOpen () {
    const std::map<int, SceneObjectVisibilityNode> missingParent {
        { 1, { .parent = 99, .visible = true } },
    };
    assert (visible (missingParent.at (1), missingParent));

    const std::map<int, SceneObjectVisibilityNode> cycle {
        { 1, { .parent = 2, .visible = true } },
        { 2, { .parent = 1, .visible = true } },
    };
    assert (visible (cycle.at (1), cycle));

    std::map<int, SceneObjectVisibilityNode> overdeep;
    for (int id = 1; id <= 34; ++id) {
        overdeep.emplace (id, SceneObjectVisibilityNode {
            .parent = id == 1 ? std::nullopt : std::optional (id - 1),
            .visible = id != 1,
        });
    }
    assert (visible (overdeep.at (34), overdeep));
    overdeep.at (2).visible = false;
    assert (!visible (overdeep.at (34), overdeep));
}

} // namespace

int main () {
    testAuthoredTypePropagationPolicy ();
    testAncestorVisibility ();
    testDynamicAncestorVisibility ();
    testParticleParentDoesNotGateAuthoredChild ();
    testInvalidAndOverdeepHierarchyFailsOpen ();
}
