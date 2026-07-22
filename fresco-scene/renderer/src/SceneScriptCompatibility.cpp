#include "FrescoScene/SceneScriptCompatibility.h"
#include "FrescoScene/SceneScript2DCapability.h"
#include "FrescoScene/SceneEventCompatibility.h"

#include <algorithm>
#include <array>
#include <cctype>

namespace FrescoScene {
namespace {

bool contains (std::string_view source, std::string_view token) {
    return source.find (token) != std::string_view::npos;
}

std::size_t countOccurrences (std::string_view source, std::string_view token) {
    std::size_t count = 0;
    std::size_t position = 0;
    while ((position = source.find (token, position)) != std::string_view::npos) {
        ++count;
        position += token.size ();
    }
    return count;
}

bool hasOnlyMediaPropertyFields (std::string_view source) {
    constexpr std::array fields = {
        std::string_view ("title"),
        std::string_view ("artist"),
        std::string_view ("albumTitle"),
    };
    std::size_t position = 0;
    while ((position = source.find ("event.", position)) != std::string_view::npos) {
        const std::size_t start = position + 6;
        std::size_t end = start;
        while (end < source.size ()
               && (std::isalnum (static_cast<unsigned char> (source[end]))
                   || source[end] == '_')) {
            ++end;
        }
        const std::string_view field = source.substr (start, end - start);
        if (std::find (fields.begin (), fields.end (), field) == fields.end ()) {
            return false;
        }
        position = end;
    }
    return true;
}

bool isSharedStateValueKind (SceneScriptValueKind kind) {
    return kind == SceneScriptValueKind::boolean
        || kind == SceneScriptValueKind::floatingPoint
        || kind == SceneScriptValueKind::integer
        || kind == SceneScriptValueKind::vector3;
}

bool usesSupportedSharedState (std::string_view source) {
    constexpr std::array fields = {
        std::string_view ("shared.night"),
        std::string_view ("shared.shownight"),
        std::string_view ("shared.sunset"),
        std::string_view ("shared.showsunset"),
    };
    return std::ranges::any_of (fields, [&source] (const auto field) {
        return contains (source, field);
    });
}

bool hasOnlySupportedSharedState (std::string_view source) {
    constexpr std::array fields = {
        std::string_view ("miClockPos"),
        std::string_view ("miCursorIn"),
        std::string_view ("miDragable"),
        std::string_view ("miInitTextBgColorAlpha"),
        std::string_view ("miMaxCLickTime"),
        std::string_view ("miPrimaryColor"),
        std::string_view ("miSettingsOpen"),
        std::string_view ("miSettingsOpenSpeed"),
        std::string_view ("miSettingsVisible"),
        std::string_view ("miShowClock"),
        std::string_view ("miTextBgColor"),
        std::string_view ("miTextBgColorFadeSpeed"),
        std::string_view ("miTextColor"),
        std::string_view ("miTextContainerScale"),
        std::string_view ("miTextPos"),
        std::string_view ("miTextVisible"),
        std::string_view ("miTextVisibleTriggerValue"),
        std::string_view ("night"),
        std::string_view ("shownight"),
        std::string_view ("sunset"),
        std::string_view ("showsunset"),
    };
    std::size_t position = 0;
    while ((position = source.find ("shared.", position)) != std::string_view::npos) {
        const std::size_t start = position + std::string_view ("shared.").size ();
        std::size_t end = start;
        while (end < source.size ()
               && (std::isalnum (static_cast<unsigned char> (source[end]))
                   || source[end] == '_')) {
            ++end;
        }
        if (std::find (fields.begin (), fields.end (), source.substr (start, end - start))
            == fields.end ()) {
            return false;
        }
        position = end;
    }
    return true;
}

bool hasSceneEventCallback (std::string_view source) {
    constexpr std::array callbacks = {
        std::string_view ("mediaPlaybackChanged"),
        std::string_view ("mediaTimelineChanged"),
        std::string_view ("mediaThumbnailChanged"),
        std::string_view ("cursorClick"),
        std::string_view ("cursorDown"),
        std::string_view ("cursorMove"),
        std::string_view ("cursorUp"),
        std::string_view ("cursorEnter"),
        std::string_view ("cursorLeave"),
    };
    return std::ranges::any_of (callbacks, [&source] (const auto callback) {
        return contains (source, callback);
    });
}

std::string compactASCIIWhitespace (std::string_view source) {
    std::string result;
    result.reserve (source.size ());
    for (const char value : source) {
        if (!std::isspace (static_cast<unsigned char> (value))) {
            result.push_back (value);
        }
    }
    return result;
}

}

bool isExactAudioVectorTransformSource (std::string_view source) {
    constexpr std::string_view exact =
        "exportvarscriptProperties=createScriptProperties()"
        ".addSlider({name:'frequency',value:0,min:0,max:15,integer:true})"
        ".addSlider({name:'smoothing',value:60,min:0,max:60})"
        ".addSlider({name:'minvalue',value:0,min:0,max:1})"
        ".addSlider({name:'maxvalue',value:1,min:0,max:1}).finish();"
        "constaudioBuffer=engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);"
        "letinitialValue;"
        "exportfunctioninit(value){initialValue=value;returnvalue;}"
        "exportfunctionupdate(value){"
        "constsmoothValue=audioBuffer.average[scriptProperties.frequency];"
        "returninitialValue.multiply(smoothValue*"
        "(scriptProperties.maxvalue-scriptProperties.minvalue)+"
        "scriptProperties.minvalue);}";
    return compactASCIIWhitespace (source) == exact;
}

bool isTextLayerOwnedPropertyScript (
    std::string_view key,
    SceneScriptValueKind valueKind,
    bool objectIsText,
    int objectId
) {
    return objectIsText
        && valueKind == SceneScriptValueKind::string
        && key == "text_" + std::to_string (objectId);
}

SceneScriptCompatibility classifyScenePropertyScript (
    std::string_view key,
    SceneScriptValueKind valueKind,
    std::string_view source
) {
    const auto eventProfile = classifySceneEventProperty (key, valueKind, source);
    switch (eventProfile) {
        case SceneEventProfile::playbackVisibility:
            return { .supported = true, .profile = "generic-media-playback-visibility-v1" };
        case SceneEventProfile::thumbnailPrimaryColor:
            return { .supported = true, .profile = "generic-media-thumbnail-primary-color-v1" };
        case SceneEventProfile::scriptPropertiesOrigin3:
            return { .supported = true, .profile = "generic-script-properties-vec3-v1" };
        case SceneEventProfile::inertCommented:
            return { .supported = true, .profile = "generic-inert-comment-v1" };
        case SceneEventProfile::inertTypeMismatch:
            return { .supported = true, .profile = "generic-inert-type-mismatch-v1" };
        case SceneEventProfile::booleanSceneCameraZoom:
        case SceneEventProfile::none:
            break;
    }
    const bool boundedSharedLayerGraph
        = contains (source, "shared.")
        && hasOnlySupportedSharedState (source)
        && (contains (source, "export function update")
            || contains (source, "export function init"));
    if (contains (source, "shared.") && !hasOnlySupportedSharedState (source)) {
        return {
            .supported = false,
            .reason = "the script requests an unsupported shared-state field",
        };
    }

    const bool audioVectorTransform
        = key.starts_with ("scale_")
        && valueKind == SceneScriptValueKind::vector3
        && (contains (source, "engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16)")
            || contains (source, "engine.registerAudioBuffers(16)"))
        && contains (source, "initialValue")
        && (contains (source, "audioBuffer.average[0]")
            || (contains (source, "audioBuffer.average[scriptProperties.frequency]")
                && contains (source, "smoothValue")))
        && contains (source, "export function init")
        && contains (source, "export function update")
        && !contains (source, "thisLayer")
        && !contains (source, "thisObject")
        && !contains (source, "thisScene")
        && !contains (source, "input.")
        && !contains (source, "shared.")
        && !contains (source, "media")
        && !contains (source, "cursor");
    if (audioVectorTransform) {
        return {
            .supported = true,
            .profile = isExactAudioVectorTransformSource (source)
                ? "exact-tracked-audio-vector-transform-v1"
                : "generic-audio-vector-transform-v1",
        };
    }

    const bool audioPlaybackLayout
        = valueKind == SceneScriptValueKind::vector3
        && (contains (source, "engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16)")
            || contains (source, "engine.registerAudioBuffers(16)"))
        && contains (source, "audioBuffer.average")
        && contains (source, "mediaPlaybackChanged")
        && contains (source, "import * as WEMath from 'WEMath';")
        && contains (source, "createScriptProperties")
        && contains (source, "export function init")
        && contains (source, "export function update")
        && !contains (source, "getVideoTexture")
        && !contains (source, "thisScene.setCamera")
        && !contains (source, "engine.setCamera");
    if (audioPlaybackLayout) {
        return {
            .supported = true,
            .profile = "generic-media-playback-layout-v1",
        };
    }

    const auto exactPlayback2D = classifyBounded2DSceneScript (
        key, valueKind, source
    );
    if (exactPlayback2D.supported
        && (contains (source, "export function update")
            || (key.starts_with ("visible_")
                && valueKind == SceneScriptValueKind::boolean
                && contains (
                    source,
                    "thisLayer.visible = event.state !== "
                    "MediaPlaybackEvent.PLAYBACK_STOPPED;"
                )
                && countOccurrences (source, "thisLayer") == 1
                && !contains (source, "export function init")
                && !contains (source, "cursor")))
        && (exactPlayback2D.profile == "generic-media-playback-layout-v1"
            || exactPlayback2D.profile
                == "generic-media-playback-timeline-v1")) {
        return exactPlayback2D;
    }
    if (hasDistinctiveSceneEventKernel (source)) {
        return {
            .supported = false,
            .reason = "distinctive SceneEvent kernel failed exact classification",
        };
    }

    const bool videoLayerControl
        = valueKind == SceneScriptValueKind::boolean
        && contains (source, "displayVideo")
        && contains (source, "thisScene.getLayer")
        && contains (source, "getVideoTexture().play()")
        && contains (source, "getVideoTexture().pause()")
        && contains (source, "export function applyUserProperties")
        && contains (source, "export function init")
        && contains (source, "export function update")
        && !contains (source, "getVideoTexture().seek")
        && !contains (source, "thisScene.setCamera")
        && !contains (source, "engine.setCamera");
    if (videoLayerControl) {
        return {
            .supported = true,
            .profile = "generic-video-layer-control-v1",
        };
    }

    const std::string_view textureFrameCall
        = "thisLayer.getTextureAnimation().setFrame";
    if (key.starts_with ("visible_")
        && valueKind == SceneScriptValueKind::boolean
        && contains (source, "export function update")
        && contains (source, "new Date()")
        && contains (source, ".getHours()")
        && contains (source, textureFrameCall)
        && !contains (source, "import ")
        && !contains (source, "thisObject")
        && !contains (source, "thisScene")
        && !contains (source, "engine.")
        && !contains (source, "input.")
        && !contains (source, "shared.")
        && !contains (source, "userProperties")
        && !contains (source, "cursor")
        && !contains (source, "media")
        && source.find ("thisLayer", source.find ("thisLayer") + 1)
            == std::string_view::npos) {
        return {
            .supported = true,
            .profile = "generic-clock-texture-frame-v1",
        };
    }
    if (contains (source, "new Date()")
        && contains (source, ".getHours()")
        && contains (source, textureFrameCall)) {
        return {
            .reason = "the clock texture-frame kernel failed exact classification",
        };
    }
    const bool cursorTextureSelector
        = key.starts_with ("scale_")
        && valueKind == SceneScriptValueKind::vector3
        && contains (source, "let animation, parent;")
        && contains (source, "export function init()")
        && contains (source, "animation = thisLayer.getTextureAnimation();")
        && contains (source, "animation.stop();")
        && contains (source, "parent = thisLayer.getParent();")
        && contains (source, "export function cursorClick(event)")
        && contains (source, "if (parent.visible)")
        && contains (source, "localStorage.set(")
        && countOccurrences (source, "thisLayer.getTextureAnimation()") == 1
        && countOccurrences (source, "thisLayer.") == 2
        && countOccurrences (source, "animation.stop()") == 1
        && countOccurrences (source, "animation.setFrame(") == 2
        && countOccurrences (source, "export function") == 2
        && hasOnlySupportedSharedState (source)
        && !contains (source, "export function update")
        && !contains (source, "import ")
        && !contains (source, "thisObject")
        && !contains (source, "thisScene")
        && !contains (source, "engine.")
        && !contains (source, "input.")
        && !contains (source, "media")
        && !contains (source, "fetch(")
        && !contains (source, "eval(")
        && !contains (source, "animation.play(")
        && !contains (source, "animation.pause(")
        && !contains (source, "animation.restart(")
        && !contains (source, "animation.setRate(");
    if (cursorTextureSelector) {
        return {
            .supported = true,
            .profile = "generic-cursor-texture-selector-v1",
        };
    }
    if (contains (source, "getTextureAnimation()")) {
        return {
            .reason = "the script requests unsupported texture-animation behavior",
        };
    }

    const bool timeSharedStateWriter
        = (valueKind == SceneScriptValueKind::integer
           || valueKind == SceneScriptValueKind::floatingPoint)
        && contains (source, "export function update")
        && !contains (source, "//export function update")
        && contains (source, "import * as WEMath from 'WEMath';")
        && contains (source, "engine.userProperties.timeofday")
        && contains (source, "engine.timeOfDay")
        && usesSupportedSharedState (source)
        && contains (source, "shared.")
        && !contains (source, "thisLayer")
        && !contains (source, "thisObject")
        && !contains (source, "thisScene")
        && !contains (source, "input.")
        && !contains (source, "cursor")
        && !contains (source, "media");
    if (timeSharedStateWriter) {
        return {
            .supported = true,
            .profile = "generic-time-shared-state-v1",
        };
    }

    const bool sharedStateReader
        = isSharedStateValueKind (valueKind)
        && contains (source, "export function update")
        && usesSupportedSharedState (source)
        && !contains (source, "shared.night =")
        && !contains (source, "shared.shownight =")
        && !contains (source, "shared.sunset =")
        && !contains (source, "shared.showsunset =")
        && !contains (source, "import ")
        && !contains (source, "engine.")
        && !contains (source, "thisLayer")
        && !contains (source, "thisObject")
        && !contains (source, "thisScene")
        && !contains (source, "input.")
        && !contains (source, "cursor")
        && !contains (source, "media")
        && !(valueKind == SceneScriptValueKind::floatingPoint
             && contains (source, "new Vec3"));
    if (sharedStateReader) {
        return {
            .supported = true,
            .profile = "generic-shared-state-value-v1",
        };
    }

    if (contains (source, "shared.") && !hasSceneEventCallback (source)
        && !boundedSharedLayerGraph) {
        return {
            .reason = "the script requests unsupported shared-state behavior",
        };
    }

    const bool userPropertyScalar
        = (valueKind == SceneScriptValueKind::boolean
           || valueKind == SceneScriptValueKind::floatingPoint
           || valueKind == SceneScriptValueKind::integer)
        && contains (source, "export function update")
        && contains (source, "engine.userProperties.character")
        && !contains (source, "import ")
        && !contains (source, "shared.")
        && !contains (source, "thisLayer")
        && !contains (source, "thisObject")
        && !contains (source, "thisScene")
        && !contains (source, "input.")
        && !contains (source, "cursor")
        && !contains (source, "media");
    if (userPropertyScalar) {
        return {
            .supported = true,
            .profile = "generic-user-property-scalar-v1",
        };
    }

    const bool timePropertyScalar
        = (valueKind == SceneScriptValueKind::floatingPoint
           || valueKind == SceneScriptValueKind::integer)
        && contains (source, "export function update")
        && contains (source, "import * as WEMath from 'WEMath';")
        && contains (source, "engine.userProperties.timeofday")
        && contains (source, "engine.timeOfDay")
        && !contains (source, "shared.")
        && !contains (source, "thisLayer")
        && !contains (source, "thisObject")
        && !contains (source, "thisScene")
        && !contains (source, "input.")
        && !contains (source, "cursor")
        && !contains (source, "media");
    if (timePropertyScalar) {
        return {
            .supported = true,
            .profile = "generic-time-user-property-scalar-v1",
        };
    }

    const bool boundedLayerDrag
        = key.starts_with ("visible_")
        && valueKind == SceneScriptValueKind::boolean
        && contains (source, "export function cursorDown")
        && contains (source, "export function cursorMove")
        && contains (source, "export function cursorUp")
        && contains (source, "export function update")
        && contains (source, "event.worldPosition")
        && contains (source, "thisLayer.origin")
        && contains (source, "thisLayer.scale")
        && contains (source, "thisLayer.size")
        && contains (source, "engine.canvasSize")
        && !contains (source, "import ")
        && !contains (source, "thisObject")
        && !contains (source, "thisScene")
        && !contains (source, "input.")
        && !contains (source, "shared.")
        && !contains (source, "cursorClick")
        && !contains (source, "media");
    if (boundedLayerDrag) {
        return {
            .supported = true,
            .profile = "generic-bounded-layer-drag-v1",
        };
    }

    const bool cursorAngle
        = key.starts_with ("angles_")
        && valueKind == SceneScriptValueKind::vector3
        && contains (source, "createScriptProperties")
        && contains (source, "export function update")
        && contains (source, "input.cursorWorldPosition")
        && !contains (source, "export function init")
        && !contains (source, "thisLayer")
        && !contains (source, "thisScene")
        && !contains (source, "import ")
        && !contains (source, "cursorClick")
        && !contains (source, "media");
    if (cursorAngle) {
        return { .supported = true, .profile = "generic-cursor-angle-v1" };
    }

    const bool cursorScale
        = key.starts_with ("scale_")
        && valueKind == SceneScriptValueKind::vector3
        && contains (source, "createScriptProperties")
        && contains (source, "export function init")
        && contains (source, "export function update")
        && contains (source, "input.cursorWorldPosition")
        && contains (source, "thisLayer.origin")
        && !contains (source, "thisScene")
        && !contains (source, "import ")
        && !contains (source, "cursorClick")
        && !contains (source, "media");
    if (cursorScale) {
        return { .supported = true, .profile = "generic-cursor-scale-v1" };
    }

    const bool cursorParentOrigin
        = key.starts_with ("origin_")
        && valueKind == SceneScriptValueKind::vector3
        && contains (source, "createScriptProperties")
        && contains (source, "export function init")
        && contains (source, "export function update")
        && contains (source, "input.cursorWorldPosition")
        && contains (source, "thisScene.getLayer")
        && !contains (source, "thisScene.setCamera")
        && !contains (source, "thisLayer")
        && !contains (source, "import ")
        && !contains (source, "cursorClick")
        && !contains (source, "media");
    if (cursorParentOrigin) {
        return { .supported = true, .profile = "generic-cursor-parent-origin-v1" };
    }

    const bool mediaThumbnailAnimationPlay
        = (valueKind == SceneScriptValueKind::floatingPoint
            || valueKind == SceneScriptValueKind::integer
            || valueKind == SceneScriptValueKind::vector2)
        && contains (source, "export function mediaThumbnailChanged")
        && contains (source, "thisObject.getAnimation().play();")
        && !contains (source, "export function update")
        && !contains (source, "export function init")
        && !contains (source, "thisLayer")
        && !contains (source, "thisScene")
        && !contains (source, "input.")
        && !contains (source, "shared.")
        && !contains (source, "mediaPlaybackChanged")
        && !contains (source, "mediaPropertiesChanged")
        && !contains (source, "mediaTimelineChanged")
        && !contains (source, "cursor");
    if (mediaThumbnailAnimationPlay) {
        return {
            .supported = true,
            .profile = "generic-media-thumbnail-animation-play-v1",
        };
    }

    const bool mediaPlaybackAnimationPlay
        = key.starts_with ("alpha_")
        && valueKind == SceneScriptValueKind::floatingPoint
        && contains (source, "export function mediaPlaybackChanged(event)")
        && (contains (source, "event.state == 1")
            || contains (source, "event.state == 2"))
        && contains (source, "!shared.miSettingsVisible")
        && contains (source, "thisObject.getAnimation().play();")
        && countOccurrences (source, "export function") == 1
        && countOccurrences (source, "event.state") == 1
        && countOccurrences (source, "thisObject") == 1
        && countOccurrences (source, "shared.") == 1
        && hasOnlySupportedSharedState (source)
        && !contains (source, "export function update")
        && !contains (source, "export function init")
        && !contains (source, "thisLayer")
        && !contains (source, "thisScene")
        && !contains (source, "input.")
        && !contains (source, "mediaThumbnailChanged")
        && !contains (source, "mediaPropertiesChanged")
        && !contains (source, "mediaTimelineChanged")
        && !contains (source, "cursor")
        && !contains (source, "fetch(")
        && !contains (source, "eval(");
    if (mediaPlaybackAnimationPlay) {
        return {
            .supported = true,
            .profile = "generic-media-playback-animation-play-v1",
        };
    }

    const bool namedAnimationDoubleClick
        = key.starts_with ("visible_")
        && valueKind == SceneScriptValueKind::boolean
        && contains (source, "createScriptProperties")
        && contains (source, ".addCheckbox(")
        && contains (source, "export function init")
        && contains (source, "export function cursorClick")
        && contains (source, "Date.now()")
        && contains (source, "doubleClickThreshold = 500")
        && contains (source, "< doubleClickThreshold")
        && contains (source, "thisScene.getLayer(")
        && contains (source, ".getAnimation(")
        && contains (source, ".play()")
        && !contains (source, "cursorDown")
        && !contains (source, "cursorMove")
        && !contains (source, "cursorUp")
        && !contains (source, "input.")
        && !contains (source, "shared.")
        && !contains (source, "mediaPlaybackChanged")
        && !contains (source, "mediaPropertiesChanged")
        && !contains (source, "mediaThumbnailChanged")
        && !contains (source, "mediaTimelineChanged");
    if (namedAnimationDoubleClick) {
        return {
            .supported = true,
            .profile = "generic-named-animation-double-click-v1",
        };
    }

    const bool scriptPropertyAngleZ
        = key.starts_with ("angles_")
        && valueKind == SceneScriptValueKind::vector3
        && contains (source, "createScriptProperties")
        && contains (source, ".addCheckbox(")
        && contains (source, ".addSlider(")
        && contains (source, "export function update")
        && contains (source, "value.z =")
        && contains (source, "scriptProperties.")
        && contains (source, "export function init")
        && contains (source, "thisLayer.origin")
        && !contains (source, "thisScene")
        && !contains (source, "thisObject")
        && !contains (source, "input.")
        && !contains (source, "shared.")
        && !contains (source, "import ")
        && !contains (source, "cursor")
        && !contains (source, "media");
    if (scriptPropertyAngleZ) {
        return {
            .supported = true,
            .profile = "generic-script-properties-angle-z-v1",
        };
    }
    if (contains (source, "createScriptProperties")
        && contains (source, "value.z =")
        && contains (source, "thisLayer.origin")) {
        return {
            .reason = "the script-properties angle kernel targets an unsupported property",
        };
    }
    if (contains (source, "input.cursorWorldPosition")
        && !(key.starts_with ("origin_")
             && valueKind == SceneScriptValueKind::vector3
             && contains (source, "value.x = input.cursorWorldPosition.x")
             && contains (source, "value.y = input.cursorWorldPosition.y"))) {
        return {
            .reason = "the cursor-position kernel failed exact classification",
        };
    }
    if (hasSceneEventCallback (source)
        && !contains (source, "export function update")
        && !contains (source, "export function init")) {
        return {
            .reason = "the event callback has no supported value lifecycle",
        };
    }

    const auto bounded2D = classifyBounded2DSceneScript (
        key, valueKind, source
    );
    if (bounded2D.supported || !bounded2D.reason.empty ()) {
        return bounded2D;
    }

    constexpr std::array unsupportedTokens = {
        std::string_view ("import "),
        std::string_view ("thisLayer"),
        std::string_view ("thisObject"),
        std::string_view ("thisScene"),
        std::string_view ("input."),
        std::string_view ("shared."),
        std::string_view ("registerAudioBuffers"),
        std::string_view ("userProperties"),
        std::string_view ("mediaPlaybackChanged"),
        std::string_view ("mediaPropertiesChanged"),
        std::string_view ("mediaThumbnailChanged"),
        std::string_view ("mediaTimelineChanged"),
        std::string_view ("cursorClick"),
        std::string_view ("cursorDown"),
        std::string_view ("cursorUp"),
        std::string_view ("cursorMove"),
        std::string_view ("cursorEnter"),
        std::string_view ("cursorLeave"),
    };
    for (const auto token : unsupportedTokens) {
        if (contains (source, token)) {
            return { .reason = "the script requests a deferred SceneScript API" };
        }
    }

    if (contains (source, "export function init")
        || contains (source, "export function destroy")
        || contains (source, "export function applyUserProperties")) {
        return { .reason = "generic property profiles only support update" };
    }

    if (key.starts_with ("origin_")
        && valueKind == SceneScriptValueKind::vector3
        && contains (source, "createScriptProperties")
        && contains (source, "engine.canvasSize")
        && contains (source, "export function update")) {
        return {
            .supported = true,
            .profile = "generic-canvas-origin-v1",
        };
    }

    if (key.starts_with ("effect_")
        && valueKind == SceneScriptValueKind::vector2
        && contains (source, "createScriptProperties")
        && contains (source, "export function update")
        && contains (source, "value.x = scriptProperties.")
        && contains (source, "value.y = scriptProperties.")) {
        return {
            .supported = true,
            .profile = "generic-script-properties-vec2-v1",
        };
    }

    return { .reason = "the script is outside the supported property profiles" };
}

SceneScriptCompatibility classifySceneTextScript (std::string_view source) {
    if (!contains (source, "export function update")
        || !contains (source, "export function mediaPropertiesChanged")) {
        return { .reason = "the script has no media-properties text lifecycle" };
    }
    constexpr std::array unsupportedTokens = {
        std::string_view ("mediaPlaybackChanged"),
        std::string_view ("mediaThumbnailChanged"),
        std::string_view ("mediaTimelineChanged"),
        std::string_view ("thisLayer"),
        std::string_view ("thisObject"),
        std::string_view ("thisScene"),
        std::string_view ("engine."),
        std::string_view ("input."),
        std::string_view ("shared."),
        std::string_view ("cursorClick"),
        std::string_view ("cursorDown"),
        std::string_view ("cursorUp"),
        std::string_view ("cursorMove"),
        std::string_view ("import "),
        std::string_view ("fetch("),
        std::string_view ("eval("),
    };
    for (const auto token : unsupportedTokens) {
        if (contains (source, token)) {
            return { .reason = "the text script requests a deferred SceneScript API" };
        }
    }
    if ((!contains (source, "event.title")
        && !contains (source, "event.artist")
        && !contains (source, "event.albumTitle"))
        || !hasOnlyMediaPropertyFields (source)) {
        return { .reason = "the media-properties handler requests unsupported fields" };
    }
    return {
        .supported = true,
        .profile = "generic-media-properties-text-v1",
    };
}

}
