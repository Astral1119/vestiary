#include "FrescoScene/SceneAnimationLayerSemanticCapability.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <string>

namespace {

void require (bool condition) {
    assert (condition);
}

FrescoScene::LocalAnimationLayerTopology staticImageTopology () {
    return {
        .imageObject = true,
        .serializedAnimationLayerCount = 0,
        .effectCount = 0,
        .modelPresent = true,
        .modelAutosize = true,
        .puppetModel = false,
        .materialPassCount = 1,
        .materialShader = "genericimage4",
        .textureImageCount = 1,
        .textureAnimated = false,
        .requestedNamedAnimationPresent = false,
    };
}

}

int main () {
    constexpr auto elaina = R"JS(
'use strict';

/**
 * @param {CursorEvent} event
 */
export function cursorClick(event) {
    thisLayer.getAnimationLayer("dianji").play();
}
)JS";
    const auto capability
        = FrescoScene::parseLocalAnimationLayerPlayClickCapability (elaina);
    require (capability.has_value ());
    require (capability->targetName == "dianji");
    require (FrescoScene::isTopologyProvenInert (
        *capability, staticImageTopology ()
    ));

    const auto equivalent = FrescoScene::parseLocalAnimationLayerPlayClickCapability (
        R"JS("use strict"; export function cursorClick(pointer) {
            /* stale local target */
            thisLayer.getAnimationLayer('other-name').play();
        };)JS"
    );
    require (equivalent.has_value ());
    require (equivalent->targetName == "other-name");
    require (FrescoScene::isTopologyProvenInert (
        *equivalent, staticImageTopology ()
    ));

    constexpr std::string_view rejected[] = {
        "export function cursorClick(event) { thisLayer.getAnimationLayer(name).play(); }",
        "export function cursorClick(event) { thisLayer.getAnimationLayer('').play(); }",
        "export function cursorClick(event) { thisLayer.getAnimationLayer('a\\'b').play(); }",
        "export function cursorClick(event) { thisLayer.getAnimationLayer('dianji').pause(); }",
        "export function cursorClick(event) { thisScene.getLayer('x').getAnimationLayer('dianji').play(); }",
        "export function cursorClick(event) { thisLayer.getAnimationLayer('dianji').play(); other(); }",
        "export function cursorClick(event) { if (enabled) thisLayer.getAnimationLayer('dianji').play(); }",
        "export function cursorClick(event) { thisLayer.getAnimationLayer('dianji').play(); } export function update(value) { return value; }",
        "export function cursorDown(event) { thisLayer.getAnimationLayer('dianji').play(); }",
        "export function cursorClick(event) { thisLayer['getAnimationLayer']('dianji').play(); }",
        "export function cursorClick(event) { thisLayer.getAnimationLayer('dianji').play(); } fetch('x');",
        "export function cursorClick(event) { thisLayer.getAnimationLayer('dianji').play(); } /*",
    };
    for (const auto source : rejected) {
        require (!FrescoScene::parseLocalAnimationLayerPlayClickCapability (source)
                      .has_value ());
    }

    const auto rejectTopology = [&capability] (
        FrescoScene::LocalAnimationLayerTopology topology
    ) {
        require (!FrescoScene::isTopologyProvenInert (*capability, topology));
    };
    auto topology = staticImageTopology ();
    topology.imageObject = false;
    rejectTopology (topology);
    topology = staticImageTopology ();
    topology.serializedAnimationLayerCount = 1;
    rejectTopology (topology);
    topology = staticImageTopology ();
    topology.effectCount = 1;
    rejectTopology (topology);
    topology = staticImageTopology ();
    topology.modelPresent = false;
    rejectTopology (topology);
    topology = staticImageTopology ();
    topology.modelAutosize = false;
    rejectTopology (topology);
    topology = staticImageTopology ();
    topology.puppetModel = true;
    rejectTopology (topology);
    topology = staticImageTopology ();
    topology.materialPassCount = 2;
    rejectTopology (topology);
    topology = staticImageTopology ();
    topology.materialShader = "puppet";
    rejectTopology (topology);
    topology = staticImageTopology ();
    topology.textureImageCount = 2;
    rejectTopology (topology);
    topology = staticImageTopology ();
    topology.textureAnimated = true;
    rejectTopology (topology);
    topology = staticImageTopology ();
    topology.requestedNamedAnimationPresent = true;
    rejectTopology (topology);
}
