#include "FrescoScene/SceneScriptCompatibility.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <string_view>

using FrescoScene::classifyScenePropertyScript;
using FrescoScene::SceneScriptValueKind;

namespace {

void accepts (std::string_view key, SceneScriptValueKind kind, std::string_view source,
              std::string_view profile) {
    const auto result = classifyScenePropertyScript (key, kind, source);
    assert (result.supported);
    assert (result.profile == profile);
}

void rejects (std::string_view key, SceneScriptValueKind kind,
              std::string_view source) {
    const auto result = classifyScenePropertyScript (key, kind, source);
    assert (!result.supported);
    assert (!result.reason.empty ());
}

} // namespace

int main () {
    accepts ("color_9", SceneScriptValueKind::vector3,
             "export function update(value) { return value.mix(next, "
             "engine.frametime); }"
             "export function mediaThumbnailChanged(event) { next = "
             "event.primaryColor; }",
             "generic-media-thumbnail-color-v1");
    accepts ("scale_9", SceneScriptValueKind::vector3,
             "import * as WEMath from 'WEMath';"
             "export function update(value) { return new Vec3(WEMath.mix(value.x, "
             "1, 0.5)); }"
             "export function mediaPlaybackChanged(event) { state = event.state; }"
             "export function cursorEnter(event) { shared.miCursorIn = true; }"
             "export function cursorLeave(event) { shared.miCursorIn = false; }",
             "generic-media-playback-layout-v1");
    accepts ("scale_155", SceneScriptValueKind::vector3,
             "export function init(value) { initial = value; }"
             "export function update(value) { return value; }"
             "export function mediaTimelineChanged(event) { ratio = event.position / "
             "event.duration; }"
             "export function mediaPlaybackChanged(event) { state = event.state; }",
             "generic-media-playback-timeline-v1");
    accepts ("visible_202", SceneScriptValueKind::boolean,
             "export function init() { shared.miSettingsOpen = localStorage.get('open'); }"
             "export function cursorEnter() { thisLayer.visible = true; }"
             "export function cursorLeave() { thisLayer.visible = false; }"
             "export function cursorDown() { started = Date.now(); }"
             "export function cursorUp() { localStorage.set('open', shared.miSettingsOpen); }",
             "generic-cursor-storage-control-v1");
    accepts ("origin_398", SceneScriptValueKind::vector3,
             "export function update(value) { value.x = input.cursorWorldPosition.x; "
             "value.y = input.cursorWorldPosition.y; return value; }",
             "generic-cursor-follow-v1");
    accepts ("visible_15", SceneScriptValueKind::boolean,
             "export function init() { parent = thisLayer.getParent(); "
             "shared.miTextVisible = true; }"
             "export function update(value) { return shared.miTextVisible && "
             "parent.visible; }",
             "generic-2d-layer-graph-v1");
    accepts ("maxwidth_160", SceneScriptValueKind::floatingPoint,
             "export function init(value) { mediaRoot = "
             "thisScene.getLayer('Media Info (ROUND)'); return value; }"
             "export function update(value) { return "
             "engine.canvasSize.x + mediaRoot.origin.x + thisLayer.scale.x; }",
             "generic-2d-layer-graph-v1");
    accepts ("visible_130", SceneScriptValueKind::boolean,
             "thisLayer = scene.getLayer('myLayer');"
             "scene.on('update', function() { thisLayer.visible = "
             "!scene.timeVarying; });",
             "generic-legacy-scene-update-v1");

    rejects ("visible_1", SceneScriptValueKind::boolean,
             "export function update(value) { thisScene.setCamera('other'); "
             "return value; }");
    rejects ("visible_1", SceneScriptValueKind::boolean,
             "import * as Filesystem from 'filesystem'; export function "
             "update(value) { return value; }");
    rejects ("visible_1", SceneScriptValueKind::boolean,
             "export function update(value) { thisLayer.depth = 1; return value; }");
    rejects ("visible_1", SceneScriptValueKind::boolean,
             "export function update(value) { "
             "thisLayer.getVideoTexture().seek(12); return value; }");
    rejects ("color_1", SceneScriptValueKind::vector3,
             "export function update(value) { return value; }"
             "export function mediaThumbnailChanged(event) { return event.bitmap; }");
    rejects ("visible_1", SceneScriptValueKind::boolean,
             "export function update(value) { fetch('https://example.test'); "
             "return value; }");
}
