#include "FrescoScene/SceneEventCompatibility.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <string>
#include <string_view>

namespace {

using FrescoScene::SceneEventProfile;
using FrescoScene::SceneScriptValueKind;

constexpr std::string_view extraImport
    = "\nimport * as WEMath from 'WEMath';\n";
constexpr std::string_view extraInput
    = "\nconst unmodeledInput = input.cursorWorldPosition;\n";
constexpr std::string_view extraShared
    = "\nshared.unmodeledState = true;\n";
constexpr std::string_view extraCursorHook
    = "\nexport function cursorClick(event) { shared.clicked = event.position; }\n";
constexpr std::string_view extraMediaCallback
    = "\nexport function mediaTimelineChanged(event) { shared.timeline = event.position; }\n";
constexpr std::string_view extraSceneOperation
    = "\nthisScene.getLayer('unmodeled-layer').visible = false;\n";

constexpr std::string_view extras[] = {
    extraImport,
    extraInput,
    extraShared,
    extraCursorHook,
    extraMediaCallback,
    extraSceneOperation,
};

void requireRejectedPropertySupersets (
    std::string_view key,
    SceneScriptValueKind kind,
    std::string_view acceptedSource
) {
    for (const auto extra : extras) {
        const std::string superset = std::string (acceptedSource) + std::string (extra);
        assert (
            FrescoScene::classifySceneEventProperty (key, kind, superset)
            == SceneEventProfile::none
        );
    }
}

void requireRejectedCameraSupersets (
    SceneScriptValueKind kind,
    std::string_view acceptedSource
) {
    for (const auto extra : extras) {
        const std::string superset = std::string (acceptedSource) + std::string (extra);
        assert (
            FrescoScene::classifySceneCameraZoom (kind, superset)
            == SceneEventProfile::none
        );
    }
}

}

int main () {
    constexpr auto playbackVisibility = R"JS(
export function mediaPlaybackChanged(event) {
    thisLayer.visible = event.state !== MediaPlaybackEvent.PLAYBACK_STOPPED;
}
)JS";
    assert (
        FrescoScene::classifySceneEventProperty (
            "visible_1", SceneScriptValueKind::boolean, playbackVisibility
        ) == SceneEventProfile::playbackVisibility
    );
    requireRejectedPropertySupersets (
        "visible_1", SceneScriptValueKind::boolean, playbackVisibility
    );

    constexpr auto thumbnailColor = R"JS(
const DURATION = 1;
let oldColor = new Vec3(0);
let newColor = new Vec3(0);
let timer = DURATION;
export function update() {
    timer += engine.frametime;
    return oldColor;
}
export function mediaThumbnailChanged(event) {
    oldColor = newColor;
    newColor = event.primaryColor;
}
)JS";
    assert (
        FrescoScene::classifySceneEventProperty (
            "color_1", SceneScriptValueKind::vector3, thumbnailColor
        ) == SceneEventProfile::thumbnailPrimaryColor
    );
    requireRejectedPropertySupersets (
        "color_1", SceneScriptValueKind::vector3, thumbnailColor
    );

    constexpr auto origin3 = R"JS(
export var scriptProperties = createScriptProperties()
    .addSlider({ name: 'posX', value: 0 })
    .addSlider({ name: 'posY', value: 0 })
    .addSlider({ name: 'posZ', value: 0 })
    .finish();
export function update(value) {
    value.x = scriptProperties.posX;
    value.y = scriptProperties.posY;
    value.z = scriptProperties.posZ;
    return value;
}
)JS";
    assert (
        FrescoScene::classifySceneEventProperty (
            "origin_1", SceneScriptValueKind::vector3, origin3
        ) == SceneEventProfile::scriptPropertiesOrigin3
    );
    requireRejectedPropertySupersets (
        "origin_1", SceneScriptValueKind::vector3, origin3
    );

    constexpr auto commentedInert = R"JS(//'use strict';
//export function update(value) {
//    return value;
//}
)JS";
    assert (
        FrescoScene::classifySceneEventProperty (
            "visible_1", SceneScriptValueKind::boolean, commentedInert
        ) == SceneEventProfile::inertCommented
    );
    requireRejectedPropertySupersets (
        "visible_1", SceneScriptValueKind::boolean, commentedInert
    );

    constexpr auto typeMismatchInert = R"JS(
export function update(value) {
    if (shared.shownight) value = new Vec3(1);
    return value;
}
)JS";
    assert (
        FrescoScene::classifySceneEventProperty (
            "alpha_1", SceneScriptValueKind::floatingPoint, typeMismatchInert
        ) == SceneEventProfile::inertTypeMismatch
    );
    requireRejectedPropertySupersets (
        "alpha_1", SceneScriptValueKind::floatingPoint, typeMismatchInert
    );

    constexpr auto cameraZoom = R"JS(
export function applyUserProperties(changedUserProperties) {
    if (changedUserProperties.cinematicPulse !== undefined) {
        const cameraTransforms = thisScene.getCameraTransforms();
        cameraTransforms.zoom = changedUserProperties.cinematicPulse ? 1.125 : 0.875;
        thisScene.setCameraTransforms(cameraTransforms);
    }
}
)JS";
    const auto capability = FrescoScene::parseSceneCameraZoomCapability (
        SceneScriptValueKind::floatingPoint, cameraZoom
    );
    assert (capability.has_value ());
    assert (capability->propertyKey == "cinematicPulse");
    assert (capability->enabledZoom == 1.125f);
    assert (capability->disabledZoom == 0.875f);
    assert (
        FrescoScene::classifySceneCameraZoom (
            SceneScriptValueKind::floatingPoint, cameraZoom
        ) == SceneEventProfile::booleanSceneCameraZoom
    );
    requireRejectedCameraSupersets (
        SceneScriptValueKind::floatingPoint, cameraZoom
    );

    constexpr auto personaCameraZoom = R"JS('use strict';
export function applyUserProperties(changedUserProperties) {
    if (changedUserProperties.trainshake != undefined) {
        let cameraTransforms = thisScene.getCameraTransforms();
        cameraTransforms.zoom = changedUserProperties.trainshake ? 1.01 : 1.0;
        thisScene.setCameraTransforms(cameraTransforms);
    }
}
)JS";
    const auto personaCapability = FrescoScene::parseSceneCameraZoomCapability (
        SceneScriptValueKind::floatingPoint, personaCameraZoom
    );
    assert (personaCapability.has_value ());
    assert (personaCapability->propertyKey == "trainshake");
    assert (personaCapability->enabledZoom == 1.01f);
    assert (personaCapability->disabledZoom == 1.0f);
}
