#include "FrescoScene/SceneScriptCompatibility.h"
#include "FrescoScene/SceneEventCompatibility.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <string>

using FrescoScene::SceneScriptValueKind;
using FrescoScene::classifyScenePropertyScript;
using FrescoScene::classifySceneTextScript;
using FrescoScene::isExactAudioVectorTransformSource;
using FrescoScene::isTextLayerOwnedPropertyScript;

int main () {
    assert (isTextLayerOwnedPropertyScript (
        "text_42", SceneScriptValueKind::string, true, 42
    ));
    assert (!isTextLayerOwnedPropertyScript (
        "effect_42_1", SceneScriptValueKind::string, true, 42
    ));
    assert (!isTextLayerOwnedPropertyScript (
        "text_42", SceneScriptValueKind::string, false, 42
    ));
    assert (!isTextLayerOwnedPropertyScript (
        "text_42", SceneScriptValueKind::floatingPoint, true, 42
    ));
    assert (!classifyScenePropertyScript (
        "effect_42_1", SceneScriptValueKind::string,
        "export function update(value) { return value; }"
    ).supported);
    constexpr auto exactAudio = R"(
export var scriptProperties = createScriptProperties()
  .addSlider({name:'frequency',value:0,min:0,max:15,integer:true})
  .addSlider({name:'smoothing',value:60,min:0,max:60})
  .addSlider({name:'minvalue',value:0,min:0,max:1})
  .addSlider({name:'maxvalue',value:1,min:0,max:1}).finish();
const audioBuffer = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
let initialValue;
export function init(value) { initialValue = value; return value; }
export function update(value) {
  const smoothValue = audioBuffer.average[scriptProperties.frequency];
  return initialValue.multiply(smoothValue *
    (scriptProperties.maxvalue - scriptProperties.minvalue) +
    scriptProperties.minvalue);
}
)";
    assert (isExactAudioVectorTransformSource (exactAudio));
    const auto acceptedAudio = classifyScenePropertyScript (
        "scale_126", SceneScriptValueKind::vector3, exactAudio
    );
    assert (acceptedAudio.supported);
    assert (acceptedAudio.profile
        == "exact-tracked-audio-vector-transform-v1");
    for (const auto suffix : {
             " engine.setTimeout(function() {}, 1);",
             " const now = new Date();",
         }) {
        const std::string nearMatch = std::string (exactAudio) + suffix;
        assert (!isExactAudioVectorTransformSource (nearMatch));
        const auto genericAudio = classifyScenePropertyScript (
            "scale_126", SceneScriptValueKind::vector3, nearMatch
        );
        assert (genericAudio.supported);
        assert (genericAudio.profile == "generic-audio-vector-transform-v1");
    }
    assert (!classifyScenePropertyScript (
        "scale_126", SceneScriptValueKind::vector3,
        std::string (exactAudio) + " shared.extra = true;"
    ).supported);

    const auto timerOnly = classifyScenePropertyScript (
        "visible_1", SceneScriptValueKind::boolean,
        "export function init(value) { engine.setTimeout(function() {}, 50); return value; }"
    );
    assert (timerOnly.supported);
    assert (timerOnly.profile == "generic-2d-layer-graph-v1");
    assert (!classifyScenePropertyScript (
        "visible_1", SceneScriptValueKind::boolean,
        "export function init(value) { engine.setTimeout(function() { fetch('x'); }, 50); return value; }"
    ).supported);

    constexpr auto canvasOrigin = R"(
export var scriptProperties = createScriptProperties()
  .addSlider({ name: 'x', value: 0.5 })
  .addSlider({ name: 'y', value: 0.5 })
  .finish();
export function update(value) {
  value.x = scriptProperties.x * engine.canvasSize.x;
  value.y = scriptProperties.y * engine.canvasSize.y;
  return value;
}
)";
    const auto accepted = classifyScenePropertyScript (
        "origin_179", SceneScriptValueKind::vector3, canvasOrigin
    );
    assert (accepted.supported);
    assert (accepted.profile == "generic-canvas-origin-v1");

    assert (!classifyScenePropertyScript (
        "scale_179", SceneScriptValueKind::vector3, canvasOrigin
    ).supported);

    constexpr auto bounds = R"(
export var scriptProperties = createScriptProperties()
  .addSlider({ name: 'posX', value: 0 })
  .addSlider({ name: 'posY', value: 0.8 })
  .finish();
export function update(value) {
  value.x = scriptProperties.posX;
  value.y = scriptProperties.posY;
  return value;
}
)";
    const auto acceptedBounds = classifyScenePropertyScript (
        "effect_568_1", SceneScriptValueKind::vector2, bounds
    );
    assert (acceptedBounds.supported);
    assert (acceptedBounds.profile == "generic-script-properties-vec2-v1");
    assert (!classifyScenePropertyScript (
        "instance_count_568", SceneScriptValueKind::vector2, bounds
    ).supported);
    assert (!classifyScenePropertyScript (
        "effect_568_1", SceneScriptValueKind::vector3, bounds
    ).supported);
    assert (!classifyScenePropertyScript (
        "effect_568_1", SceneScriptValueKind::vector2,
        "export function update(value) { return shared.bounds; }"
    ).supported);

    constexpr auto nightWriter = R"(
import * as WEMath from 'WEMath';
export function update(value) {
  if (engine.userProperties.timeofday == 2) value = 1;
  else value = WEMath.smoothStep(0.8, 0.9, engine.timeOfDay);
  shared.night = value;
  shared.shownight = value > 0;
  return value;
}
)";
    const auto acceptedNightWriter = classifyScenePropertyScript (
        "effect_1_1", SceneScriptValueKind::integer, nightWriter
    );
    assert (acceptedNightWriter.supported);
    assert (acceptedNightWriter.profile == "generic-time-shared-state-v1");
    const auto acceptedNightReader = classifyScenePropertyScript (
        "effect_visible_1_1", SceneScriptValueKind::boolean,
        "export function update(value) { value = shared.shownight; return value; }"
    );
    assert (acceptedNightReader.supported);
    assert (acceptedNightReader.profile == "generic-shared-state-value-v1");
    assert (!classifyScenePropertyScript (
        "effect_1_1", SceneScriptValueKind::integer,
        "export function update(value) { shared.night = input.cursorWorldPosition.x; return value; }"
    ).supported);
    assert (!classifyScenePropertyScript (
        "effect_visible_1_1", SceneScriptValueKind::boolean,
        "export function update(value) { return shared.unprovenState; }"
    ).supported);
    const auto acceptedElainaShared = classifyScenePropertyScript (
        "visible_15", SceneScriptValueKind::boolean,
        "export function init() { shared.miTextVisible = true; "
        "parent = thisLayer.getParent(); } export function update(value) { "
        "return shared.miTextVisible && parent.visible; }"
    );
    assert (acceptedElainaShared.supported);
    assert (acceptedElainaShared.profile == "generic-2d-layer-graph-v1");
    assert (!classifyScenePropertyScript (
        "visible_15", SceneScriptValueKind::boolean,
        "export function init() { shared.unmodeledState = true; "
        "parent = thisLayer.getParent(); } export function update(value) { "
        "return shared.unmodeledState && parent.visible; }"
    ).supported);
    assert (!classifyScenePropertyScript (
        "visible_15", SceneScriptValueKind::boolean,
        "export function cursorClick(event) { shared.unmodeledState = true; }"
    ).supported);
    constexpr auto sharedColorReader = R"(
'use strict';
export function update(value) {
    if (shared.shownight > 0) value = new Vec3(0.667, 0, 0.584);
    else value = new Vec3(1, 0.8745, 0.9843);
    return value;
}
)";
    const auto acceptedSharedColor = classifyScenePropertyScript (
        "instance_colorn_1180", SceneScriptValueKind::vector3, sharedColorReader
    );
    assert (acceptedSharedColor.supported);
    assert (acceptedSharedColor.profile == "generic-shared-state-value-v1");
    assert (!classifyScenePropertyScript (
        "instance_colorn_1180", SceneScriptValueKind::vector3,
        std::string (sharedColorReader) + "\nshared.unmodeledState = true;\n"
    ).supported);
    const auto acceptedCharacter = classifyScenePropertyScript (
        "visible_49", SceneScriptValueKind::boolean,
        "export function update(value) { value = engine.userProperties.character == 3; return value; }"
    );
    assert (acceptedCharacter.supported);
    assert (acceptedCharacter.profile == "generic-user-property-scalar-v1");
    const auto acceptedTimeScalar = classifyScenePropertyScript (
        "instance_count_13", SceneScriptValueKind::floatingPoint,
        "import * as WEMath from 'WEMath'; export function update(value) { if (engine.userProperties.timeofday == 0) value = 1; else value = WEMath.smoothStep(0.2, 0.3, engine.timeOfDay); return value; }"
    );
    assert (acceptedTimeScalar.supported);
    assert (acceptedTimeScalar.profile == "generic-time-user-property-scalar-v1");
    assert (!classifyScenePropertyScript (
        "visible_49", SceneScriptValueKind::boolean,
        "export function update(value) { thisLayer.visible = engine.userProperties.character == 3; return value; }"
    ).supported);
    constexpr auto boundedDrag = R"(
export function cursorDown(event) { drag = thisLayer.origin.subtract(event.worldPosition); }
export function cursorMove(event) { thisLayer.origin = event.worldPosition.add(drag); let s = thisLayer.scale; let z = thisLayer.size; let c = engine.canvasSize; }
export function cursorUp(event) { bouncing = true; }
export function update(value) { return value; }
)";
    const auto acceptedDrag = classifyScenePropertyScript (
        "visible_303", SceneScriptValueKind::boolean, boundedDrag
    );
    assert (acceptedDrag.supported);
    assert (acceptedDrag.profile == "generic-bounded-layer-drag-v1");
    assert (!classifyScenePropertyScript (
        "visible_303", SceneScriptValueKind::boolean,
        "export function cursorDown(event) {} export function cursorMove(event) { thisScene.setCameraTransforms(event.worldPosition); } export function cursorUp(event) {} export function update(value) { return value; }"
    ).supported);
    constexpr auto dormantCursorReset = R"(
export var scriptProperties = createScriptProperties()
  .addCheckbox({ name: 'isMovable', value: false }).finish();
const storageName = "storedPosRoundMIC";
let isDragging = false, dragOffset, timer;
export function resetPosition() {
  localStorage.remove(storageName);
  thisLayer.origin = thisLayer.originalOrigin;
}
export function cursorDown(event) {
  if (!scriptProperties.isMovable || !shared.miDragable) return;
  timer = Date.now(); isDragging = true;
  dragOffset = thisLayer.origin.subtract(event.worldPosition);
}
export function cursorMove(event) {
  if (!isDragging || !scriptProperties.isMovable || !shared.miDragable) return;
  thisLayer.origin = event.worldPosition.add(dragOffset);
}
export function cursorUp(event) {
  isDragging = false;
  if (scriptProperties.isMovable && shared.miDragable)
    localStorage.set(storageName, thisLayer.origin);
}
export function init() {
  shared.miDragable = localStorage.get("miDragable") ?? scriptProperties.isMovable;
  const storedPos = localStorage.get(storageName);
  if (shared.miDragable && storedPos) thisLayer.origin = storedPos;
  return thisLayer.origin;
}
)";
    const auto acceptedDormantCursorReset = classifyScenePropertyScript (
        "visible_96", SceneScriptValueKind::boolean, dormantCursorReset
    );
    assert (acceptedDormantCursorReset.supported);
    assert (
        acceptedDormantCursorReset.profile
        == "generic-cursor-storage-side-effect-init-v1"
    );
    assert (!classifyScenePropertyScript (
        "visible_96", SceneScriptValueKind::boolean,
        std::string (dormantCursorReset)
            + "\nexport function update(value) { localStorage.remove('active'); return value; }"
    ).supported);
    const auto acceptedCursorAngle = classifyScenePropertyScript (
        "angles_3", SceneScriptValueKind::vector3,
        "export var scriptProperties = createScriptProperties().addSlider({name:'factor',value:1}).finish(); export function update(value) { value.z = input.cursorWorldPosition.x * scriptProperties.factor; return value; }"
    );
    assert (acceptedCursorAngle.supported);
    assert (acceptedCursorAngle.profile == "generic-cursor-angle-v1");
    const auto acceptedCursorScale = classifyScenePropertyScript (
        "scale_12", SceneScriptValueKind::vector3,
        "export var scriptProperties = createScriptProperties().addSlider({name:'ratio',value:1}).finish(); export function init(value) { return value; } export function update(value) { value.y = input.cursorWorldPosition.subtract(thisLayer.origin).length() * scriptProperties.ratio; return value; }"
    );
    assert (acceptedCursorScale.supported);
    assert (acceptedCursorScale.profile == "generic-cursor-scale-v1");
    const auto acceptedCursorParent = classifyScenePropertyScript (
        "origin_8", SceneScriptValueKind::vector3,
        "export var scriptProperties = createScriptProperties().addText({name:'parentName',value:'parent'}).finish(); var parent; export function init(value) { parent = thisScene.getLayer(scriptProperties.parentName); return value; } export function update(value) { return parent.origin.add(input.cursorWorldPosition.subtract(value)); }"
    );
    assert (acceptedCursorParent.supported);
    assert (acceptedCursorParent.profile == "generic-cursor-parent-origin-v1");
    constexpr auto propertyAngleZ = R"(
export var scriptProperties = createScriptProperties()
  .addCheckbox({ name: 'active', value: true })
  .addSlider({ name: 'zRotation', value: 0 })
  .finish();
export function update(value) {
  if (scriptProperties.active) value.z = scriptProperties.zRotation;
  return value;
}
export function init() { oldOrigin = thisLayer.origin; }
)";
    const auto acceptedPropertyAngleZ = classifyScenePropertyScript (
        "angles_137", SceneScriptValueKind::vector3, propertyAngleZ
    );
    assert (acceptedPropertyAngleZ.supported);
    assert (
        acceptedPropertyAngleZ.profile
        == "generic-script-properties-angle-z-v1"
    );
    assert (!classifyScenePropertyScript (
        "origin_137", SceneScriptValueKind::vector3, propertyAngleZ
    ).supported);
    assert (!classifyScenePropertyScript (
        "angles_137", SceneScriptValueKind::vector3,
        std::string (propertyAngleZ) + " export function cursorMove() {}"
    ).supported);
    assert (!classifyScenePropertyScript (
        "origin_8", SceneScriptValueKind::vector3,
        "export function update(value) { thisScene.setCameraTransforms(input.cursorWorldPosition); return value; }"
    ).supported);
    constexpr auto clockFrame = R"(
export function update(value) {
  var current = new Date();
  var nowTime = current.getHours();
  thisLayer.getTextureAnimation().setFrame(nowTime >= 12 ? 1 : 0);
  return value;
}
)";
    const auto acceptedClockFrame = classifyScenePropertyScript (
        "visible_25", SceneScriptValueKind::boolean, clockFrame
    );
    assert (acceptedClockFrame.supported);
    assert (acceptedClockFrame.profile == "generic-clock-texture-frame-v1");
    assert (!classifyScenePropertyScript (
        "visible_25", SceneScriptValueKind::boolean,
        "export function update(value) { var d = new Date(); var h = d.getHours(); thisLayer.getTextureAnimation().setFrame(0); thisLayer.visible = value; return value; }"
    ).supported);
    constexpr auto textureSelector = R"(
let animation, parent;
export function init() {
    animation = thisLayer.getTextureAnimation();
    animation.stop();
    parent = thisLayer.getParent();
    animation.setFrame(shared.miDragable * 1);
}
export function cursorClick(event) {
    if (parent.visible) {
        shared.miDragable = !shared.miDragable;
        localStorage.set("miDragable", shared.miDragable);
        animation.setFrame(shared.miDragable * 1);
    }
}
)";
    const auto acceptedTextureSelector = classifyScenePropertyScript (
        "scale_21", SceneScriptValueKind::vector3, textureSelector
    );
    assert (acceptedTextureSelector.supported);
    assert (
        acceptedTextureSelector.profile
        == "generic-cursor-texture-selector-v1"
    );
    assert (!classifyScenePropertyScript (
        "scale_21", SceneScriptValueKind::vector3,
        std::string (textureSelector) + "\nanimation.play();\n"
    ).supported);
    assert (!classifyScenePropertyScript (
        "visible_25", SceneScriptValueKind::boolean,
        "export function update(value) { thisLayer.getTextureAnimation().setRate(2); return value; }"
    ).supported);
    assert (!classifyScenePropertyScript (
        "visible_25", SceneScriptValueKind::boolean,
        "export function update(value) { var d = new Date(); var h = d.getHours(); thisLayer.getTextureAnimation().setFrame(input.cursorWorldPosition.x); return value; }"
    ).supported);
    assert (!classifyScenePropertyScript (
        "origin_179", SceneScriptValueKind::floatingPoint, canvasOrigin
    ).supported);
    assert (!classifyScenePropertyScript (
        "origin_8", SceneScriptValueKind::vector3,
        "export function update(value) { return input.cursorWorldPosition; }"
    ).supported);
    assert (!classifyScenePropertyScript (
        "origin_8", SceneScriptValueKind::vector3,
        "export function update(value) { return shared.position; }"
    ).supported);
    assert (!classifyScenePropertyScript (
        "origin_8", SceneScriptValueKind::vector3,
        "export function mediaPlaybackChanged(event) { thisLayer.visible = true; }"
    ).supported);
    assert (!classifyScenePropertyScript (
        "origin_8", SceneScriptValueKind::vector3,
        "export function cursorMove(event) { thisLayer.origin = event.position; }"
    ).supported);

    const auto mediaThumbnailAnimation = classifyScenePropertyScript (
        "alpha_8", SceneScriptValueKind::floatingPoint, R"(
export function mediaThumbnailChanged(event) {
    thisObject.getAnimation().play();
}
)"
    );
    assert (mediaThumbnailAnimation.supported);
    assert (
        mediaThumbnailAnimation.profile
        == "generic-media-thumbnail-animation-play-v1"
    );
    assert (classifyScenePropertyScript (
        "origin_8", SceneScriptValueKind::vector2, R"(
export function mediaThumbnailChanged(event) {
    thisObject.getAnimation().play();
}
)"
    ).supported);
    assert (classifyScenePropertyScript (
        "alpha_8", SceneScriptValueKind::integer, R"(
export function mediaThumbnailChanged(event) {
    thisObject.getAnimation().play();
}
)"
    ).supported);
    assert (!classifyScenePropertyScript (
        "alpha_8", SceneScriptValueKind::floatingPoint, R"(
export function mediaThumbnailChanged(event) {
    thisObject.getAnimation().restart();
}
)"
    ).supported);

    const auto playbackAnimation = classifyScenePropertyScript (
        "alpha_26", SceneScriptValueKind::floatingPoint, R"(
export function mediaPlaybackChanged(event) {
    if (event.state == 1 && !shared.miSettingsVisible)
        thisObject.getAnimation().play();
}
)"
    );
    assert (playbackAnimation.supported);
    assert (
        playbackAnimation.profile
        == "generic-media-playback-animation-play-v1"
    );
    assert (!classifyScenePropertyScript (
        "alpha_26", SceneScriptValueKind::floatingPoint, R"(
export function mediaPlaybackChanged(event) {
    if (event.state == 1 && !shared.miSettingsVisible)
        thisObject.getAnimation().restart();
}
)"
    ).supported);

    const auto stoppedLayout = classifyScenePropertyScript (
        "visible_132", SceneScriptValueKind::boolean, R"(
export function init(value) { return value; }
export function update(value) { return value; }
export function mediaPlaybackChanged(event) {
    return event.state !== MediaPlaybackEvent.PLAYBACK_STOPPED;
}
)"
    );
    assert (stoppedLayout.supported);
    assert (stoppedLayout.profile == "generic-media-playback-layout-v1");

    constexpr auto primaryColorTransition = R"(
const DURATION = 1;
let oldColor = new Vec3(0, 0, 0);
let newColor = new Vec3(0, 0, 0);
let timer = DURATION;
export function update() {
    timer += engine.frametime;
    return oldColor;
}
export function mediaThumbnailChanged(event) {
    oldColor = newColor;
    newColor = event.primaryColor;
}
)";
    for (const auto kind : {
            SceneScriptValueKind::vector3,
            SceneScriptValueKind::vector4,
        }) {
        const auto primaryColor = classifyScenePropertyScript (
            "color_282", kind, primaryColorTransition
        );
        assert (primaryColor.supported);
        assert (
            primaryColor.profile
            == "generic-media-thumbnail-primary-color-v1"
        );
    }
    assert (!classifyScenePropertyScript (
        "color_282", SceneScriptValueKind::vector2, primaryColorTransition
    ).supported);
    assert (!classifyScenePropertyScript (
        "color_282", SceneScriptValueKind::vector3,
        std::string (primaryColorTransition)
            + "\nconst unmodeled = input.cursorWorldPosition;\n"
    ).supported);
    const auto parsedPrimaryColor
        = FrescoScene::parseThumbnailPrimaryColor ("#112233");
    assert (parsedPrimaryColor.has_value ());
    assert ((*parsedPrimaryColor)[0] == 17.0f / 255.0f);
    assert ((*parsedPrimaryColor)[1] == 34.0f / 255.0f);
    assert ((*parsedPrimaryColor)[2] == 51.0f / 255.0f);
    assert (!FrescoScene::parseThumbnailPrimaryColor ("112233").has_value ());
    assert (!FrescoScene::parseThumbnailPrimaryColor ("#12zz33").has_value ());
    assert (!classifyScenePropertyScript (
        "alpha_8", SceneScriptValueKind::floatingPoint, R"(
export function mediaThumbnailChanged(event) {
    thisObject.getAnimation().play();
    thisScene.getLayer("other");
}
)"
    ).supported);

    const auto namedDoubleClick = classifyScenePropertyScript (
        "visible_134", SceneScriptValueKind::boolean, R"(
export var scriptProperties = createScriptProperties()
    .addCheckbox({ name: 'enabled', value: true }).finish();
let lastClickTime = 0;
const doubleClickThreshold = 500;
export function init() {
    thisScene.getLayer("eye").getAnimation("poke");
}
export function cursorClick() {
    const currentTime = Date.now();
    if (currentTime - lastClickTime < doubleClickThreshold) animation.play();
}
)"
    );
    assert (namedDoubleClick.supported);
    assert (
        namedDoubleClick.profile
        == "generic-named-animation-double-click-v1"
    );

    const auto mediaTitle = classifySceneTextScript (R"(
var mediaData = "";
export function update(value) { return mediaData; }
export function mediaPropertiesChanged(event) { mediaData = event.title; }
)");
    assert (mediaTitle.supported);
    assert (mediaTitle.profile == "generic-media-properties-text-v1");
    assert (classifySceneTextScript (R"(
var mediaData = "";
export function update(value) { return mediaData; }
export function mediaPropertiesChanged(event) { mediaData = event.artist; }
)").supported);
    assert (classifySceneTextScript (R"(
var mediaData = "";
export function update(value) { return mediaData; }
export function mediaPropertiesChanged(event) { mediaData = event.albumTitle; }
)").supported);
    assert (!classifySceneTextScript (
        "export function mediaPlaybackChanged(event) { thisLayer.visible = true; }"
    ).supported);
    assert (!classifySceneTextScript (R"(
export function update(value) { return value; }
export function mediaPropertiesChanged(event) { shared.title = event.title; }
)").supported);
    assert (!classifySceneTextScript (R"(
export function update(value) { return value; }
export function mediaPropertiesChanged(event) { return event.title + event.genre; }
)").supported);
    assert (!classifySceneTextScript (R"(
import * as Network from 'Network';
export function update(value) { return value; }
export function mediaPropertiesChanged(event) { return event.title; }
)").supported);
    assert (!classifySceneTextScript (R"(
export function update(value) { fetch(event.title); return value; }
export function mediaPropertiesChanged(event) { return event.title; }
)").supported);
}
