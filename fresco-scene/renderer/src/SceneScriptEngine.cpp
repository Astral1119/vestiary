/*
 * Fresco narrow SceneScript runtime
 *
 * Copyright (C) 2026 astral (github.com/Astral1119)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License, version 3.
 */

#include "WallpaperEngine/Scripting/ScriptEngine.h"

#include "FrescoScene/AudioFloatScript.h"
#include "FrescoScene/Camera2DControl.h"
#include "FrescoScene/DynamicValueAnimation.h"
#include "FrescoScene/GLPlayerVideoTextureControl.h"
#include "FrescoScene/SceneAnimationLayerSemanticCapability.h"
#include "FrescoScene/SceneAudioVector.h"
#include "FrescoScene/SceneEventCompatibility.h"
#include "FrescoScene/SceneScriptLayerGraph.h"
#include "FrescoScene/SceneScriptCompatibility.h"
#include "FrescoScene/SceneScriptStorage.h"
#include "FrescoScene/SceneScriptQuickJS.h"
#include "FrescoScene/SceneSoundSemanticCapability.h"
#include "FrescoScene/SceneVideoTextureControlProvider.h"
#include "FrescoScene/SceneZoomControl.h"
#include "FrescoScene/SharedScriptDependency.h"
#include "FrescoScene/TextureAnimationScript.h"
#include "FrescoScene/VideoTextureControl.h"
#include "SoundScriptBridge.h"
#include "RuntimeMediaSource.h"

#include "WallpaperEngine/Data/Model/DynamicValue.h"
#include "WallpaperEngine/Data/Model/Object.h"
#include "WallpaperEngine/Data/Model/Property.h"
#include "WallpaperEngine/Data/Model/UserSetting.h"
#include "WallpaperEngine/Logging/Log.h"
#include "WallpaperEngine/Render/CTexture.h"
#include "WallpaperEngine/Render/TextureProvider.h"
#include "WallpaperEngine/Render/Objects/CRenderable.h"
#include "WallpaperEngine/Scripting/ScriptableObject.h"
#include "WallpaperEngine/Render/Wallpapers/CScene.h"

#include <quickjs.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <type_traits>
#include <utility>

using namespace WallpaperEngine::Data::Model;
using namespace WallpaperEngine::Scripting;

namespace {

/*
 * The wall clock a scene text script sees.
 *
 * Wallpapers read the clock through `new Date()`, so an unpinned one makes
 * every render of a scene with a clock in it differ from the last. `pinned` is
 * set when any of the three environment overrides is present; the whole reading
 * is then frozen at construction, because a `Date` whose hour is pinned and
 * whose minute still runs is not a time anyone can reason about.
 */
struct ScriptClock {
    int hour = 0;
    int minute = 0;
    int second = 0;
    bool pinned = false;
    long long epochMilliseconds = 0;
};

std::optional<int> clockOverride (const char* variable, int limit) {
    const char* injected = std::getenv (variable);
    if (injected == nullptr) {
        return std::nullopt;
    }
    char* end = nullptr;
    const long value = std::strtol (injected, &end, 10);
    if (end == injected || *end != '\0' || value < 0 || value > limit) {
        return std::nullopt;
    }
    return static_cast<int> (value);
}

ScriptClock scriptClock () {
    const std::time_t now = std::time (nullptr);
    std::tm local = {};
    localtime_r (&now, &local);

    const auto hour = clockOverride ("FRESCO_SCENE_SCRIPT_CLOCK_HOUR", 23);
    const auto minute = clockOverride ("FRESCO_SCENE_SCRIPT_CLOCK_MINUTE", 59);
    const auto second = clockOverride ("FRESCO_SCENE_SCRIPT_CLOCK_SECOND", 59);

    local.tm_hour = hour.value_or (local.tm_hour);
    local.tm_min = minute.value_or (local.tm_min);
    local.tm_sec = second.value_or (local.tm_sec);
    local.tm_isdst = -1;

    // mktime normalizes, so a pinned reading that a DST jump makes impossible
    // comes back as the hour the zone actually has rather than as a rejection.
    const std::time_t pinned = std::mktime (&local);
    return ScriptClock {
        .hour = local.tm_hour,
        .minute = local.tm_min,
        .second = local.tm_sec,
        .pinned = hour.has_value () || minute.has_value () || second.has_value (),
        .epochMilliseconds = static_cast<long long> (pinned) * 1000,
    };
}

/*
 * A `Date` shim for the scene text-script scope, or nothing when the clock runs
 * free.
 *
 * It subclasses the real Date at a fixed instant rather than stubbing the three
 * getters a clock wallpaper happens to call, because the date scripts in the
 * same corpus read getDay and getMonth off the same object and those have to
 * agree with the time beside them. The native Date comes off `globalThis`: the
 * `class Date` below is a lexical binding in the scope this string lands in, so
 * reading the bare name here would land in its dead zone and fail every text
 * script in the scene.
 */
std::string pinnedDateShim (const ScriptClock& clock) {
    if (!clock.pinned) {
        return "";
    }
    const std::string instant = std::to_string (clock.epochMilliseconds);
    return "  const __frescoNativeDate = globalThis.Date;\n"
           "  class Date extends __frescoNativeDate {\n"
           "    constructor(...values) { if (values.length === 0) super("
           + instant + "); else super(...values); }\n"
           "    static now() { return " + instant + "; }\n"
           "  }\n";
}

bool usesSceneLayerGraph (std::string_view profile) {
    constexpr std::array profiles = {
        std::string_view ("generic-media-thumbnail-color-v1"),
        std::string_view ("generic-media-playback-timeline-v1"),
        std::string_view ("generic-media-playback-layout-v1"),
        std::string_view ("generic-media-playback-animation-play-v1"),
        std::string_view ("generic-cursor-texture-selector-v1"),
        std::string_view ("generic-cursor-storage-control-v1"),
        std::string_view ("generic-cursor-storage-side-effect-init-v1"),
        std::string_view ("generic-cursor-follow-v1"),
        std::string_view ("generic-legacy-scene-update-v1"),
        std::string_view ("generic-2d-layer-graph-v1"),
        std::string_view ("generic-video-layer-control-v1"),
    };
    return std::ranges::find (profiles, profile) != profiles.end ();
}

void removeAll (std::string& value, const std::string& token) {
    std::size_t position = 0;
    while ((position = value.find (token, position)) != std::string::npos) {
        value.erase (position, token.size ());
    }
}

std::string scriptBody (std::string source) {
    removeAll (source, "'use strict';");
    removeAll (source, "\"use strict\";");
    removeAll (source, "export ");
    return source;
}

std::string genericPropertyScriptBody (
    std::string source, std::string_view profile
) {
    if (profile == "generic-time-shared-state-v1"
        || profile == "generic-time-user-property-scalar-v1"
        || usesSceneLayerGraph (profile)) {
        removeAll (source, "import * as WEMath from 'WEMath';");
    }
    return scriptBody (std::move (source));
}

std::optional<std::string> sharedReaderField (std::string_view source) {
    constexpr std::array fields = {
        std::string_view ("night"),
        std::string_view ("shownight"),
        std::string_view ("sunset"),
        std::string_view ("showsunset"),
    };
    std::optional<std::string> result;
    for (const auto field : fields) {
        if (source.find (std::string ("shared.") + std::string (field))
            == std::string_view::npos) {
            continue;
        }
        if (result.has_value ()) {
            return std::nullopt;
        }
        result = field;
    }
    return result;
}

const FrescoScene::SharedScriptSchema& sharedScriptSchema () {
    static const FrescoScene::SharedScriptSchema schema {
        {"night", FrescoScene::SharedScriptValueKind::number},
        {"shownight", FrescoScene::SharedScriptValueKind::boolean},
        {"sunset", FrescoScene::SharedScriptValueKind::number},
        {"showsunset", FrescoScene::SharedScriptValueKind::boolean},
    };
    return schema;
}

std::string sceneLayerGraphPrelude (
    int objectId,
    int canvasWidth,
    int canvasHeight,
    int clockHour
) {
    std::string result = FrescoScene::SceneScriptLayerGraph::wrapperPrelude (
        objectId, canvasWidth, canvasHeight, clockHour
    );
    constexpr std::string_view marker = "  const engine = {";
    const auto position = result.find (marker);
    if (position == std::string::npos) {
        throw std::runtime_error ("SceneScript layer graph engine seam is missing");
    }
    result.replace (
        position,
        marker.size (),
        "  const engine = { AUDIO_RESOLUTION_16: 16, "
        "registerAudioBuffers(resolution) { if (resolution !== 16) "
        "throw new RangeError('unsupported audio resolution'); return { "
        "get average() { return globalThis.__frescoAudioAverage16.slice(); } }; },"
    );
    return result;
}

void logException (JSContext* context, const char* operation) {
    JSValue exception = JS_GetException (context);
    const char* message = JS_ToCString (context, exception);
    sLog.error (
        "SceneScript ", operation, " failed: ",
        message == nullptr ? "unknown JavaScript exception" : message
    );
    if (message != nullptr) {
        JS_FreeCString (context, message);
    }
    JS_FreeValue (context, exception);
}

JSValue dynamicValueToJS (JSContext* context, const DynamicValue& value) {
    switch (value.getType ()) {
        case DynamicValue::String:
            return JS_NewString (context, value.getString ().c_str ());
        case DynamicValue::Float:
            return JS_NewFloat64 (context, value.getFloat ());
        case DynamicValue::Int:
            return JS_NewInt32 (context, value.getInt ());
        case DynamicValue::Boolean:
            return JS_NewBool (context, value.getBool ());
        case DynamicValue::Vec2:
        case DynamicValue::Vec3:
        case DynamicValue::Vec4: {
            const glm::vec4 vector = value.getVec4 ();
            JSValue result = JS_NewObject (context);
            JS_SetPropertyStr (context, result, "x", JS_NewFloat64 (context, vector.x));
            JS_SetPropertyStr (context, result, "y", JS_NewFloat64 (context, vector.y));
            if (value.getType () != DynamicValue::Vec2) {
                JS_SetPropertyStr (context, result, "z", JS_NewFloat64 (context, vector.z));
            }
            if (value.getType () == DynamicValue::Vec4) {
                JS_SetPropertyStr (context, result, "w", JS_NewFloat64 (context, vector.w));
            }
            return result;
        }
        case DynamicValue::Null:
        default:
            return JS_NULL;
    }
}

FrescoScene::SceneScriptValueKind sceneScriptValueKind (const DynamicValue& value) {
    using Kind = FrescoScene::SceneScriptValueKind;
    switch (value.getType ()) {
        case DynamicValue::Vec2:
            return Kind::vector2;
        case DynamicValue::Vec3:
            return Kind::vector3;
        case DynamicValue::Vec4:
            return Kind::vector4;
        case DynamicValue::Float:
            return Kind::floatingPoint;
        case DynamicValue::Int:
            return Kind::integer;
        case DynamicValue::Boolean:
            return Kind::boolean;
        case DynamicValue::String:
            return Kind::string;
        case DynamicValue::Null:
        default:
            return Kind::null;
    }
}

bool finiteProperty (JSContext* context, JSValueConst object, const char* name, float& value) {
    JSValue property = JS_GetPropertyStr (context, object, name);
    double number = 0.0;
    const bool valid = JS_ToFloat64 (context, &number, property) == 0
        && std::isfinite (number);
    JS_FreeValue (context, property);
    if (valid) {
        value = static_cast<float> (number);
    }
    return valid;
}

bool updateDynamicValueFromJS (
    JSContext* context,
    JSValueConst result,
    DynamicValue& value
) {
    switch (value.getType ()) {
        case DynamicValue::Vec2: {
            float x = 0.0f;
            float y = 0.0f;
            if (!JS_IsObject (result)
                || !finiteProperty (context, result, "x", x)
                || !finiteProperty (context, result, "y", y)) {
                return false;
            }
            const glm::vec2 next (x, y);
            if (next != value.getVec2 ()) {
                value.update (next, DynamicValue::UpdateSource::Script);
            }
            return true;
        }
        case DynamicValue::Vec3: {
            float x = 0.0f;
            float y = 0.0f;
            float z = 0.0f;
            if (!JS_IsObject (result)
                || !finiteProperty (context, result, "x", x)
                || !finiteProperty (context, result, "y", y)
                || !finiteProperty (context, result, "z", z)) {
                return false;
            }
            const glm::vec3 next (x, y, z);
            if (next != value.getVec3 ()) {
                value.update (next, DynamicValue::UpdateSource::Script);
            }
            return true;
        }
        case DynamicValue::Vec4: {
            float x = 0.0f;
            float y = 0.0f;
            float z = 0.0f;
            if (!JS_IsObject (result)
                || !finiteProperty (context, result, "x", x)
                || !finiteProperty (context, result, "y", y)
                || !finiteProperty (context, result, "z", z)) {
                return false;
            }
            float w = value.getVec4 ().w;
            static_cast<void> (finiteProperty (context, result, "w", w));
            const glm::vec4 next (x, y, z, w);
            if (next != value.getVec4 ()) {
                value.update (next, DynamicValue::UpdateSource::Script);
            }
            return true;
        }
        case DynamicValue::Boolean:
            if (!JS_IsBool (result)) {
                return false;
            }
            if ((JS_ToBool (context, result) != 0) != value.getBool ()) {
                value.update (
                    JS_ToBool (context, result) != 0,
                    DynamicValue::UpdateSource::Script
                );
            }
            return true;
        case DynamicValue::Float: {
            double next = 0.0;
            if (JS_ToFloat64 (context, &next, result) != 0
                || !std::isfinite (next)) {
                return false;
            }
            if (static_cast<float> (next) != value.getFloat ()) {
                value.update (
                    static_cast<float> (next), DynamicValue::UpdateSource::Script
                );
            }
            return true;
        }
        case DynamicValue::Int: {
            int32_t next = 0;
            if (JS_ToInt32 (context, &next, result) != 0) {
                return false;
            }
            if (next != value.getInt ()) {
                value.update (next, DynamicValue::UpdateSource::Script);
            }
            return true;
        }
        default:
            return false;
    }
}

std::optional<FrescoScene::SharedScriptValue> sharedValueFromDynamicValue (
    const DynamicValue& value
) {
    switch (value.getType ()) {
        case DynamicValue::Boolean:
            return FrescoScene::SharedScriptValue (value.getBool ());
        case DynamicValue::Float:
            return FrescoScene::SharedScriptValue (
                static_cast<double> (value.getFloat ())
            );
        case DynamicValue::Int:
            return FrescoScene::SharedScriptValue (
                static_cast<double> (value.getInt ())
            );
        case DynamicValue::Vec3: {
            const auto vector = value.getVec3 ();
            return FrescoScene::SharedScriptValue (
                std::array<double, 3> {vector.x, vector.y, vector.z}
            );
        }
        default:
            return std::nullopt;
    }
}

FrescoScene::SharedScriptValue sharedValueFromJS (
    JSContext* context,
    JSValueConst value
) {
    if (JS_IsBool (value)) {
        return JS_ToBool (context, value) != 0;
    }
    if (JS_IsNumber (value)) {
        double number = 0.0;
        if (JS_ToFloat64 (context, &number, value) == 0
            && std::isfinite (number)) {
            return number;
        }
        return std::monostate {};
    }
    if (JS_IsString (value)) {
        const char* string = JS_ToCString (context, value);
        if (string == nullptr) {
            return std::monostate {};
        }
        std::string result (string);
        JS_FreeCString (context, string);
        return result;
    }
    if (JS_IsObject (value)) {
        float x = 0.0F;
        float y = 0.0F;
        float z = 0.0F;
        if (finiteProperty (context, value, "x", x)
            && finiteProperty (context, value, "y", y)
            && finiteProperty (context, value, "z", z)) {
            return std::array<double, 3> {x, y, z};
        }
    }
    return std::monostate {};
}

JSValue userPropertyToJS (
    JSContext* context,
    const WallpaperEngine::Audio::UserPropertyScalar& value
) {
    return std::visit (
        [context] (const auto& scalar) -> JSValue {
            using Scalar = std::decay_t<decltype (scalar)>;
            if constexpr (std::is_same_v<Scalar, bool>) {
                return JS_NewBool (context, scalar);
            } else if constexpr (std::is_same_v<Scalar, double>) {
                return JS_NewFloat64 (context, scalar);
            } else {
                return JS_NewString (context, scalar.c_str ());
            }
        },
        value
    );
}

std::string userPropertyString (
    const WallpaperEngine::Audio::UserPropertyScalar& value
) {
    return std::visit (
        [] (const auto& scalar) -> std::string {
            using Scalar = std::decay_t<decltype (scalar)>;
            if constexpr (std::is_same_v<Scalar, bool>) {
                return scalar ? "true" : "false";
            } else if constexpr (std::is_same_v<Scalar, double>) {
                return std::to_string (scalar);
            } else {
                return scalar;
            }
        },
        value
    );
}

std::vector<std::string> quotedCallArguments (
    std::string_view source, std::string_view call
) {
    std::vector<std::string> result;
    std::size_t position = 0;
    while ((position = source.find (call, position)) != std::string_view::npos) {
        position = source.find ('(', position + call.size ());
        if (position == std::string_view::npos) {
            break;
        }
        ++position;
        while (position < source.size ()
               && std::isspace (static_cast<unsigned char> (source[position]))) {
            ++position;
        }
        if (position >= source.size ()
            || (source[position] != '\'' && source[position] != '"')) {
            continue;
        }
        const char quote = source[position++];
        const std::size_t end = source.find (quote, position);
        if (end == std::string_view::npos) {
            break;
        }
        result.emplace_back (source.substr (position, end - position));
        position = end + 1;
    }
    return result;
}

std::vector<float> numericDynamicValue (const DynamicValue& value) {
    switch (value.getType ()) {
        case DynamicValue::Float:
            return { value.getFloat () };
        case DynamicValue::Int:
            return { static_cast<float> (value.getInt ()) };
        case DynamicValue::Vec2: {
            const auto vector = value.getVec2 ();
            return { vector.x, vector.y };
        }
        case DynamicValue::Vec3: {
            const auto vector = value.getVec3 ();
            return { vector.x, vector.y, vector.z };
        }
        case DynamicValue::Vec4: {
            const auto vector = value.getVec4 ();
            return { vector.x, vector.y, vector.z, vector.w };
        }
        default:
            return {};
    }
}

std::optional<float> scalarDynamicValue (const DynamicValue& value) {
    if (value.getType () == DynamicValue::Float) {
        return value.getFloat ();
    }
    if (value.getType () == DynamicValue::Int) {
        return static_cast<float> (value.getInt ());
    }
    return std::nullopt;
}

FrescoScene::SceneAudioVectorTransformConfiguration audioVectorConfiguration (
    DynamicValue& value
) {
    FrescoScene::SceneAudioVectorTransformConfiguration result;
    const auto assign = [&value] (std::string_view name, float& target) {
        const auto property = value.getProperties ().find (std::string (name));
        if (property == value.getProperties ().end ()
            || property->second == nullptr
            || property->second->value == nullptr) {
            return;
        }
        if (const auto scalar = scalarDynamicValue (*property->second->value)) {
            target = *scalar;
        }
    };
    float frequency = static_cast<float> (result.frequency);
    assign ("frequency", frequency);
    assign ("smoothing", result.smoothing);
    assign ("minvalue", result.minimum);
    assign ("maxvalue", result.maximum);
    if (std::isfinite (frequency) && frequency >= 0.0F) {
        result.frequency = static_cast<std::size_t> (frequency);
    } else {
        result.frequency = FrescoScene::sceneAudioVectorBins;
    }
    return result;
}

std::string_view soundControllerProfile (
    FrescoScene::SoundControllerCapabilityKind kind
) {
    switch (kind) {
        case FrescoScene::SoundControllerCapabilityKind::delayedSelection:
            return "bounded-private-music-visibility-v1";
        case FrescoScene::SoundControllerCapabilityKind::visibilitySelection:
            return "music-visibility-property-v1";
        case FrescoScene::SoundControllerCapabilityKind::cursorSingleShot:
            return "cursor-single-shot-v1";
    }
    return {};
}

}

class ScriptEngine::Impl {
public:
    explicit Impl (
        Render::Wallpapers::CScene& scene,
        Media::MediaSource& mediaSource
    )
        : m_quickJS (),
          m_runtime (m_quickJS.runtime ()),
          m_context (m_quickJS.context ()),
          m_audio (scene.getAudioContext ()),
          m_scene (scene),
          m_recorder (m_audio.getRecorder ()) {
        FrescoScene::installSoundScriptBridge (m_context, m_audio);
        if (auto *runtimeMedia
            = dynamic_cast<FrescoScene::RuntimeMediaSource *> (&mediaSource);
            runtimeMedia != nullptr && runtimeMedia->scriptStorage () != nullptr) {
            m_storage = runtimeMedia->scriptStorage ();
        }
        m_sceneLayerGraph = std::make_unique<FrescoScene::SceneScriptLayerGraph> (
            m_context, m_scene, *m_storage
        );
        FrescoScene::registerSceneVideoTextureControl (
            &m_scene, m_videoTextureControls
        );
    }

    ~Impl () {
        shutdown ();
        for (const auto& property : m_dynamicFloats) {
            JS_FreeValue (m_context, property.second.object);
        }
        for (const auto& layer : m_layers) {
            JS_FreeValue (m_context, layer.second.object);
        }
        // shutdown() drops this too, but it returns early once it has already
        // run, and nothing stops a tick from rebuilding the cache after it.
        invalidateSharedUserPropertiesJS ();
        m_quickJS.reset ();
        m_context = nullptr;
        m_runtime = nullptr;
    }

    void shutdown () {
        FrescoScene::clearScriptedTextureAnimationFrames (&m_scene);
        if (m_shutdown || m_context == nullptr) {
            return;
        }
        m_shutdown = true;
        for (auto& [key, script] : m_propertyScripts) {
            static_cast<void> (key);
            callPropertyHook (script, "destroy");
            JS_FreeValue (m_context, script.object);
        }
        m_propertyScripts.clear ();
        for (auto& [key, script] : m_cursorScripts) {
            static_cast<void> (key);
            JS_FreeValue (m_context, script.object);
        }
        m_cursorScripts.clear ();
        for (auto& [key, script] : m_genericPropertyScripts) {
            static_cast<void> (key);
            JS_FreeValue (m_context, script.object);
        }
        m_genericPropertyScripts.clear ();
        m_pendingLocalAnimationLayerScripts.clear ();
        m_rejectedLocalAnimationLayerScripts.clear ();
        FrescoScene::clearSceneVideoTextureControl (&m_scene);
        m_videoTextureControls.clear ();
        m_videoTextureAdapters.clear ();
        m_sceneLayerGraphOrder.clear ();
        m_sceneLayerGraph.reset ();
        FrescoScene::clearCamera2DControl (m_scene);
        FrescoScene::clearSceneZoom (m_scene);
        m_pendingUserProperties.clear ();
        m_initialUserProperties.clear ();
        invalidateSharedUserPropertiesJS ();
    }

    void createDynamicFloat (
        const std::string& key,
        DynamicValue& value,
        const std::string& source
    ) {
        if (m_dynamicFloats.contains (key)) {
            return;
        }

        std::ostringstream wrapper;
        wrapper
            << "(function () {\n"
            << "  const engine = {\n"
            << "    AUDIO_RESOLUTION_16: 16,\n"
            << "    registerAudioBuffers(resolution) {\n"
            << "      if (resolution !== 16) throw new RangeError('unsupported audio resolution');\n"
            << "      return { get average() { return [globalThis.__frescoAudioAverage0 || 0]; } };\n"
            << "    }\n"
            << "  };\n"
            << scriptBody (source) << "\n"
            << "  return { tick(value) { return update(value); } };\n"
            << "})()";

        const std::string code = wrapper.str ();
        JSValue object = JS_Eval (
            m_context, code.c_str (), code.size (), key.c_str (),
            JS_EVAL_TYPE_GLOBAL
        );
        if (JS_IsException (object)) {
            ++m_errorCount;
            logException (m_context, "dynamic-float creation");
            return;
        }

        m_dynamicFloats.emplace (
            key,
            DynamicFloat { .object = object, .value = &value }
        );
        refreshAudioAverage ();
        tickDynamicFloat (m_dynamicFloats.at (key));
    }

    void createPropertyScript (
        const std::string& key,
        DynamicValue& value,
        int objectId,
        const std::string& source,
        ScriptableObject* target = nullptr
    ) {
        if (m_shutdown || m_propertyScripts.contains (key)) {
            return;
        }
        const auto capability = value.getType () == DynamicValue::Boolean
            ? FrescoScene::parseSoundControllerCapability (source)
            : std::nullopt;
        if (capability.has_value ()
            && capability->kind
                == FrescoScene::SoundControllerCapabilityKind::cursorSingleShot) {
            createCursorScript (key, value, objectId, source);
            return;
        }
        if (!capability.has_value ()) {
            createGenericPropertyScript (key, value, objectId, source, target);
            return;
        }

        const auto delayEnabledName = capability->delayEnabledProperty;
        const auto delaySecondsName = capability->delaySecondsProperty;
        std::optional<std::string> delayUserProperty;

        JSValue global = JS_GetGlobalObject (m_context);
        JSValue seedProperties = JS_NewObject (m_context);
        for (const auto& [name, property] : value.getProperties ()) {
            JSValue propertyValue = dynamicValueToJS (m_context, *property->value);
            if (delaySecondsName.has_value () && name == *delaySecondsName) {
                JSValue stringValue = JS_ToString (m_context, propertyValue);
                JS_FreeValue (m_context, propertyValue);
                propertyValue = stringValue;
                if (property->property != nullptr) {
                    delayUserProperty = property->property->name;
                }
            }
            JS_SetPropertyStr (
                m_context, seedProperties, name.c_str (), propertyValue
            );
        }
        if (delayEnabledName.has_value () && delaySecondsName.has_value ()) {
            const auto enabled = value.getProperties ().find (*delayEnabledName);
            const auto delay = value.getProperties ().find (*delaySecondsName);
            if (enabled == value.getProperties ().end ()
                || delay == value.getProperties ().end ()
                || !delayUserProperty.has_value ()) {
                ++m_errorCount;
                ++m_propertyScriptErrorCount;
                JS_FreeValue (m_context, seedProperties);
                JS_FreeValue (m_context, global);
                return;
            }
            JS_SetPropertyStr (
                m_context, seedProperties, delayEnabledName->c_str (),
                dynamicValueToJS (m_context, *enabled->second->value)
            );
            JSValue delayValue = dynamicValueToJS (m_context, *delay->second->value);
            JSValue delayString = JS_ToString (m_context, delayValue);
            JS_FreeValue (m_context, delayValue);
            JS_SetPropertyStr (
                m_context, seedProperties, delaySecondsName->c_str (), delayString
            );
        }
        JS_SetPropertyStr (
            m_context, global, "__frescoPropertyScriptProperties", seedProperties
        );
        JS_FreeValue (m_context, global);

        std::ostringstream wrapper;
        wrapper
            << "(function () {\n"
            << "  const __properties = Object.assign({}, globalThis.__frescoPropertyScriptProperties || {});\n"
            << "  const thisLayer = {};\n"
            << "  const thisScene = {\n"
            << "    getLayer(key) { return globalThis.__frescoGetSoundLayer(key); }\n"
            << "  };\n"
            << "  const engine = {\n"
            << "    get frametime() { const c = globalThis.__frescoScene; return c ? c.dt : 0; },\n"
            << "    get time() { const c = globalThis.__frescoScene; return c ? c.time : 0; }\n"
            << "  };\n"
            << "  const console = { warn() {} };\n"
            << "  function createScriptProperties() {\n"
            << "    const builder = {\n"
            << "      addSlider(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      addCheckbox(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      addCombo(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      addColor(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      addText(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      finish() { return __properties; }\n"
            << "    };\n"
            << "    return builder;\n"
            << "  }\n"
            << scriptBody (source) << "\n"
            << "  return {\n"
            << "    init: (typeof init === 'function') ? init : null,\n"
            << "    apply: (typeof applyUserProperties === 'function') ? applyUserProperties : null,\n"
            << "    update: (typeof update === 'function') ? update : null,\n"
            << "    destroy: (typeof destroy === 'function') ? destroy : null,\n"
            << "    seedPrivate: values => Object.assign(__properties, values),\n"
            << "    seededDelay: () => Number.parseFloat(String(__properties[\""
            << delaySecondsName.value_or (std::string ())
            << "\"])),\n"
            << "    targetDelay: () => (typeof targetDelay === 'number' ? targetDelay : NaN)\n"
            << "  };\n"
            << "})()";

        const std::string code = wrapper.str ();
        JSValue script = JS_Eval (
            m_context, code.c_str (), code.size (), key.c_str (), JS_EVAL_TYPE_GLOBAL
        );
        global = JS_GetGlobalObject (m_context);
        JS_SetPropertyStr (
            m_context, global, "__frescoPropertyScriptProperties", JS_UNDEFINED
        );
        JS_FreeValue (m_context, global);
        if (JS_IsException (script)) {
            ++m_errorCount;
            ++m_propertyScriptErrorCount;
            logException (m_context, "property-script creation");
            JS_FreeValue (m_context, script);
            return;
        }
        m_propertyScripts.emplace (
            key,
            PropertyScript {
                .object = script,
                .value = &value,
                .profile = std::string (soundControllerProfile (capability->kind)),
                .objectId = objectId,
                .delaySecondsProperty = delaySecondsName,
                .delayUserProperty = std::move (delayUserProperty),
            }
        );
    }

    void createCursorScript (
        const std::string& key,
        DynamicValue& value,
        int objectId,
        const std::string& source
    ) {
        JSValue global = JS_GetGlobalObject (m_context);
        JSValue seedProperties = JS_NewObject (m_context);
        for (const auto& [name, property] : value.getProperties ()) {
            JS_SetPropertyStr (
                m_context, seedProperties, name.c_str (),
                dynamicValueToJS (m_context, *property->value)
            );
        }
        JS_SetPropertyStr (
            m_context, global, "__frescoCursorScriptProperties", seedProperties
        );
        JS_FreeValue (m_context, global);

        std::ostringstream wrapper;
        wrapper
            << "(function () {\n"
            << "  const __properties = Object.assign({}, globalThis.__frescoCursorScriptProperties || {});\n"
            << "  const thisScene = { getLayer(key) { return globalThis.__frescoGetSoundLayer(key); } };\n"
            << "  const engine = { get frametime() { const c = globalThis.__frescoScene; return c ? c.dt : 0; } };\n"
            << "  function createScriptProperties() {\n"
            << "    const builder = {\n"
            << "      addText(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      finish() { return __properties; }\n"
            << "    }; return builder;\n"
            << "  }\n"
            << scriptBody (source) << "\n"
            << "  return {\n"
            << "    click() { cursorClick({}); },\n"
            << "    tick() { if (typeof update === 'function') update(undefined); }\n"
            << "  };\n"
            << "})()";

        const std::string code = wrapper.str ();
        JSValue object = JS_Eval (
            m_context, code.c_str (), code.size (), key.c_str (), JS_EVAL_TYPE_GLOBAL
        );
        global = JS_GetGlobalObject (m_context);
        JS_SetPropertyStr (
            m_context, global, "__frescoCursorScriptProperties", JS_UNDEFINED
        );
        JS_FreeValue (m_context, global);
        if (JS_IsException (object)) {
            ++m_errorCount;
            logException (m_context, "cursor-script creation");
            JS_FreeValue (m_context, object);
            return;
        }
        m_cursorScripts.emplace (
            key, CursorScript { .object = object, .objectId = objectId }
        );
    }

    FrescoScene::LocalAnimationLayerTopology localAnimationLayerTopology (
        int objectId,
        const FrescoScene::LocalAnimationLayerPlayClickCapability& capability,
        ScriptableObject* target
    ) {
        FrescoScene::LocalAnimationLayerTopology topology;
        const auto& objects = m_scene.getScene ().objects;
        const auto found = std::ranges::find_if (
            objects, [objectId] (const auto& object) {
                return object != nullptr && object->id == objectId;
            }
        );
        if (found == objects.end () || !(*found)->is<Image> ()) {
            return topology;
        }
        const auto* image = (*found)->as<Image> ();
        topology.imageObject = true;
        topology.serializedAnimationLayerCount = image->animationLayers.size ();
        topology.effectCount = image->effects.size ();
        topology.modelPresent = image->model != nullptr;
        if (image->model == nullptr) {
            return topology;
        }
        topology.modelAutosize = image->model->autosize;
        topology.puppetModel = image->model->puppet.has_value ();
        if (image->model->material == nullptr) {
            return topology;
        }
        topology.materialPassCount = image->model->material->passes.size ();
        if (image->model->material->passes.size () != 1
            || image->model->material->passes.front () == nullptr) {
            return topology;
        }
        const auto& pass = *image->model->material->passes.front ();
        topology.materialShader = pass.shader;
        const auto* rendered = dynamic_cast<const
            WallpaperEngine::Render::Objects::CRenderable*> (target);
        if (rendered == nullptr) {
            rendered = dynamic_cast<const
                WallpaperEngine::Render::Objects::CRenderable*> (
                    m_scene.getObject (objectId)
                );
        }
        if (rendered != nullptr && rendered->getTexture () != nullptr) {
            const auto& texture = rendered->getTexture ();
            topology.textureAnimated = texture->isAnimated ();
            topology.textureImageCount = topology.textureAnimated
                ? texture->getFrames ().size () : 1;
        }
        const std::array<const DynamicValue*, 12> values = {
            image->origin->value.get (),
            image->groupScale->value.get (),
            image->groupAngles->value.get (),
            image->groupVisible->value.get (),
            image->scale->value.get (),
            image->angles->value.get (),
            image->visible->value.get (),
            image->alpha->value.get (),
            image->color->value.get (),
            image->parallaxDepth->value.get (),
            image->colorBlendMode->value.get (),
            image->brightness->value.get (),
        };
        topology.requestedNamedAnimationPresent = std::ranges::any_of (
            values, [&capability] (const auto* value) {
                const auto* animation = value == nullptr
                    ? nullptr : FrescoScene::dynamicValueAnimation (*value);
                return animation != nullptr && animation->supported ()
                    && animation->name () == capability.targetName;
            }
        );
        return topology;
    }

    void createGenericPropertyScript (
        const std::string& key,
        DynamicValue& value,
        int objectId,
        const std::string& source,
        ScriptableObject* target = nullptr
    ) {
        if (const auto existing = m_genericPropertyScripts.find (key);
            existing != m_genericPropertyScripts.end ()) {
            if (target != nullptr) {
                existing->second.target = target;
            }
            return;
        }
        if (const auto pending = m_pendingLocalAnimationLayerScripts.find (key);
            pending != m_pendingLocalAnimationLayerScripts.end ()) {
            if (target != nullptr) {
                pending->second.target = target;
            }
            return;
        }
        const auto cameraZoomCapability = key == "scene_zoom"
            ? FrescoScene::parseSceneCameraZoomCapability (
                sceneScriptValueKind (value), source
            )
            : std::nullopt;
        const auto localAnimationLayerCapability
            = key.starts_with ("visible_")
                && sceneScriptValueKind (value)
                    == FrescoScene::SceneScriptValueKind::boolean
            ? FrescoScene::parseLocalAnimationLayerPlayClickCapability (source)
            : std::nullopt;
        if (localAnimationLayerCapability.has_value ()) {
            m_pendingLocalAnimationLayerScripts.emplace (
                key,
                PendingLocalAnimationLayerScript {
                    .value = &value,
                    .objectId = objectId,
                    .target = target,
                    .capability = *localAnimationLayerCapability,
                }
            );
            return;
        }
        auto compatibility = cameraZoomCapability.has_value ()
            ? FrescoScene::SceneScriptCompatibility {
                .supported = true,
                .profile = "generic-scene-camera-zoom-property-v1",
            }
            : key == "scene_zoom"
                && FrescoScene::hasDistinctiveSceneCameraZoomKernel (source)
            ? FrescoScene::SceneScriptCompatibility {
                .supported = false,
                .reason = "distinctive camera zoom kernel failed exact classification",
            }
            : FrescoScene::classifyScenePropertyScript (
                key, sceneScriptValueKind (value), source
            );
        if (!compatibility.supported) {
            m_deferredScriptKeys.insert (key);
            if (std::getenv ("FRESCO_SCENE_SCRIPT_PROFILE_TRACE") != nullptr) {
                std::fprintf (
                    stderr,
                    "scene-script deferred key=%s object=%d bytes=%zu reason=%s\n",
                    key.c_str (), objectId, source.size (),
                    compatibility.reason.c_str ()
                );
            }
            return;
        }
        m_deferredScriptKeys.erase (key);
        if (std::getenv ("FRESCO_SCENE_SCRIPT_PROFILE_TRACE") != nullptr) {
            std::fprintf (
                stderr,
                "scene-script accepted key=%s object=%d bytes=%zu profile=%s\n",
                key.c_str (), objectId, source.size (), compatibility.profile.c_str ()
            );
        }
        if (compatibility.profile == "generic-audio-vector-transform-v1"
            || compatibility.profile
                == "exact-tracked-audio-vector-transform-v1") {
            FrescoScene::SceneAudioVectorTransform transform (
                value.getVec3 ().x,
                audioVectorConfiguration (value)
            );
            if (transform.error ()
                != FrescoScene::SceneAudioVectorTransformError::none) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                sLog.error (
                    "SceneScript audio vector creation failed: ",
                    FrescoScene::sceneAudioVectorTransformDiagnostic (
                        transform.error ()
                    )
                );
                return;
            }
            m_genericPropertyScripts.emplace (
                key,
                GenericPropertyScript {
                    .object = JS_UNDEFINED,
                    .value = &value,
                    .profile = compatibility.profile,
                    .objectId = objectId,
                    .target = target,
                    .propertyName = key.substr (0, key.rfind ('_')),
                    .audioVectorTransform = std::move (transform),
                }
            );
            return;
        }
        if (compatibility.profile == "generic-media-playback-visibility-v1"
            || compatibility.profile == "generic-media-thumbnail-primary-color-v1"
            || compatibility.profile == "generic-inert-comment-v1"
            || compatibility.profile == "generic-inert-type-mismatch-v1"
            || compatibility.profile == "generic-scene-camera-zoom-property-v1") {
            m_genericPropertyScripts.emplace (
                key,
                GenericPropertyScript {
                    .object = JS_UNDEFINED,
                    .value = &value,
                    .profile = compatibility.profile,
                    .objectId = objectId,
                    .target = target,
                    .sceneCameraZoom = cameraZoomCapability,
                    .primaryColorTransition
                        = compatibility.profile == "generic-media-thumbnail-primary-color-v1"
                        ? std::optional<FrescoScene::PrimaryColorTransition> (
                            std::in_place
                        )
                        : std::nullopt,
                }
            );
            if (compatibility.profile == "generic-scene-camera-zoom-property-v1") {
                static_cast<void> (FrescoScene::setSceneZoom (
                    m_scene, value.getFloat ()
                ));
            }
            return;
        }
        if (compatibility.profile == "generic-media-thumbnail-animation-play-v1") {
            auto* animation = FrescoScene::dynamicValueAnimation (value);
            if (animation == nullptr || !animation->supported ()) {
                return;
            }
            m_genericPropertyScripts.emplace (
                key,
                GenericPropertyScript {
                    .object = JS_UNDEFINED,
                    .value = &value,
                    .profile = compatibility.profile,
                    .objectId = objectId,
                    .target = target,
                }
            );
            return;
        }
        if (compatibility.profile == "generic-named-animation-double-click-v1") {
            const auto layerNames = quotedCallArguments (
                source, "thisScene.getLayer"
            );
            const auto animationNames = quotedCallArguments (
                source, ".getAnimation"
            );
            if (layerNames.empty () || layerNames.size () != animationNames.size ()) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                sLog.error (
                    "SceneScript named-animation controller has invalid layer/animation references"
                );
                return;
            }
            std::vector<NamedAnimationTarget> targets;
            targets.reserve (layerNames.size ());
            for (std::size_t index = 0; index < layerNames.size (); ++index) {
                auto targetAnimation = findNamedAnimation (
                    layerNames[index], animationNames[index]
                );
                if (!targetAnimation.has_value ()) {
                    ++m_errorCount;
                    ++m_genericPropertyScriptErrorCount;
                    sLog.error (
                        "SceneScript named animation not found: ", layerNames[index],
                        "/", animationNames[index]
                    );
                    return;
                }
                targets.push_back (*targetAnimation);
            }
            m_genericPropertyScripts.emplace (
                key,
                GenericPropertyScript {
                    .object = JS_UNDEFINED,
                    .value = &value,
                    .profile = compatibility.profile,
                    .objectId = objectId,
                    .target = target,
                    .namedAnimations = std::move (targets),
                }
            );
            return;
        }
        if (usesSceneLayerGraph (compatibility.profile)) {
            JSValue global = JS_GetGlobalObject (m_context);
            JSValue seedProperties = JS_NewObject (m_context);
            for (const auto& [name, property] : value.getProperties ()) {
                JS_SetPropertyStr (
                    m_context, seedProperties, name.c_str (),
                    dynamicValueToJS (m_context, *property->value)
                );
            }
            JS_SetPropertyStr (
                m_context, global, "__frescoGenericScriptProperties", seedProperties
            );
            JS_FreeValue (m_context, global);

            std::ostringstream wrapper;
            wrapper
                << "(function () {\n"
                << "  const __properties = Object.assign({}, globalThis.__frescoGenericScriptProperties || {});\n"
                << sceneLayerGraphPrelude (
                       objectId, m_scene.getScene ().camera.projection.width,
                       m_scene.getScene ().camera.projection.height,
                       scriptClockHour ()
                   )
                << genericPropertyScriptBody (source, compatibility.profile) << "\n"
                << "  let __frescoInitialized = false;\n"
                << "  function __frescoDispatch(name, event) {\n"
                << "    if (name === 'playback' && typeof mediaPlaybackChanged === 'function') { mediaPlaybackChanged(event); return true; }\n"
                << "    if (name === 'timeline' && typeof mediaTimelineChanged === 'function') { mediaTimelineChanged(event); return true; }\n"
                << "    if (name === 'thumbnail' && typeof mediaThumbnailChanged === 'function') { mediaThumbnailChanged(event); return true; }\n"
                << "    return false;\n"
                << "  }\n"
                << "  function __frescoCursor(name, event) {\n"
                << "    if (name === 'click' && typeof cursorClick === 'function') { cursorClick(event); return true; }\n"
                << "    if (name === 'down' && typeof cursorDown === 'function') { cursorDown(event); return true; }\n"
                << "    if (name === 'move' && typeof cursorMove === 'function') { cursorMove(event); return true; }\n"
                << "    if (name === 'up' && typeof cursorUp === 'function') { cursorUp(event); return true; }\n"
                << "    if (name === 'enter' && typeof cursorEnter === 'function') { cursorEnter(event); return true; }\n"
                << "    if (name === 'leave' && typeof cursorLeave === 'function') { cursorLeave(event); return true; }\n"
                << "    return false;\n"
                << "  }\n"
                << "  return {\n"
                << "    requiresContinuousEvaluation: typeof update === 'function' || __frescoSceneCallbacks.length !== 0,\n"
                << "    setProperties(values) { Object.assign(__properties, values); },\n"
                << "    setUserProperties(values) { if (typeof applyUserProperties === 'function') applyUserProperties(values); },\n"
                << "    dispatch(name, event) { return __frescoDispatch(name, event); },\n"
                << "    cursor(name, event) { return __frescoCursor(name, event); },\n"
                << (compatibility.profile
                            == "generic-cursor-storage-side-effect-init-v1"
                        ? "    initialize(value) { if (!__frescoInitialized) { __frescoInitialized = true; if (typeof init === 'function') init(value); } return value; },\n"
                        : "    initialize(value) { if (!__frescoInitialized) { __frescoInitialized = true; if (typeof init === 'function') { const seeded = init(value); if (seeded !== undefined) value = seeded; } } return value; },\n")
                << "    tick(value) {\n"
                << "      __frescoAdvanceHostObjects();\n"
                << "      if (typeof update === 'function') { const next = update(value); if (next !== undefined) value = next; }\n"
                << "      return { value, animation: __frescoTakeValueAnimationCommand() };\n"
                << "    }\n"
                << "  };\n"
                << "})()";
            const std::string code = wrapper.str ();
            JSValue object = JS_Eval (
                m_context, code.c_str (), code.size (), key.c_str (),
                JS_EVAL_TYPE_GLOBAL
            );
            global = JS_GetGlobalObject (m_context);
            JS_SetPropertyStr (
                m_context, global, "__frescoGenericScriptProperties", JS_UNDEFINED
            );
            JS_FreeValue (m_context, global);
            if (JS_IsException (object)) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                logException (m_context, "2D graph property creation");
                JS_FreeValue (m_context, object);
                return;
            }
            JSValue continuousValue = JS_GetPropertyStr (
                m_context, object, "requiresContinuousEvaluation"
            );
            const bool requiresContinuousEvaluation
                = JS_ToBool (m_context, continuousValue) != 0;
            JS_FreeValue (m_context, continuousValue);
            m_genericPropertyScripts.emplace (
                key,
                GenericPropertyScript {
                    .object = object,
                    .value = &value,
                    .profile = compatibility.profile,
                    .objectId = objectId,
                    .target = target,
                    .propertyName = key.substr (0, key.rfind ('_')),
                    .requiresContinuousEvaluation
                        = requiresContinuousEvaluation,
                }
            );
            m_sceneLayerGraphOrder.push_back (key);
            return;
        }
        auto camera2DControl = FrescoScene::takeCamera2DControl (value);
        if (camera2DControl.has_value ()
            && compatibility.profile != "generic-canvas-origin-v1") {
            ++m_errorCount;
            ++m_genericPropertyScriptErrorCount;
            sLog.error ("2D camera control requires a canvas-origin script");
            return;
        }
        const std::string profile = camera2DControl.has_value ()
            ? "generic-2d-camera-control-v1" : compatibility.profile;
        const bool usesCanvas = profile == "generic-canvas-origin-v1"
            || profile == "generic-2d-camera-control-v1";
        const bool usesTextureFrame
            = profile == "generic-clock-texture-frame-v1";
        const bool usesSharedState
            = profile == "generic-time-shared-state-v1"
            || profile == "generic-shared-state-value-v1";
        const bool usesWEMath = profile == "generic-time-shared-state-v1"
            || profile == "generic-time-user-property-scalar-v1";
        const bool usesLayerDrag
            = profile == "generic-bounded-layer-drag-v1";
        const bool usesLayerOriginInit
            = profile == "generic-script-properties-angle-z-v1";
        const bool usesCursorPosition
            = profile == "generic-cursor-angle-v1"
            || profile == "generic-cursor-scale-v1"
            || profile == "generic-cursor-parent-origin-v1";
        const bool usesCursorVectorMath
            = profile == "generic-cursor-scale-v1"
            || profile == "generic-cursor-parent-origin-v1";
        const int canvasWidth = usesCanvas || usesLayerDrag ? m_scene.getWidth () : 0;
        const int canvasHeight = usesCanvas || usesLayerDrag ? m_scene.getHeight () : 0;
        glm::vec3 layerOrigin = {};
        glm::vec3 layerScale (1.0f);
        glm::vec2 layerSize = {};
        glm::vec3 parentOrigin = {};
        if ((usesLayerDrag || usesCursorVectorMath || usesLayerOriginInit)
            && target != nullptr) {
            layerOrigin = target->getProperty ("origin").getVec3 ();
        }
        if (usesLayerDrag && target != nullptr) {
            layerScale = target->getProperty ("scale").getVec3 ();
            if (target->getObject ().is<Image> ()) {
                layerSize = target->getObject ().as<Image> ()->size;
            }
        }
        if (profile == "generic-cursor-parent-origin-v1") {
            const auto property = value.getProperties ().find ("parentName");
            const std::string parentName = property == value.getProperties ().end ()
                ? std::string () : property->second->value->getString ();
            for (const auto& object : m_scene.getScene ().objects) {
                if (object->name == parentName) {
                    parentOrigin = object->origin->value->getVec3 ();
                    break;
                }
            }
        }

        JSValue global = JS_GetGlobalObject (m_context);
        JSValue seedProperties = JS_NewObject (m_context);
        for (const auto& [name, property] : value.getProperties ()) {
            JS_SetPropertyStr (
                m_context, seedProperties, name.c_str (),
                dynamicValueToJS (m_context, *property->value)
            );
        }
        JS_SetPropertyStr (
            m_context, global, "__frescoGenericScriptProperties", seedProperties
        );
        JS_FreeValue (m_context, global);

        std::ostringstream wrapper;
        wrapper
            << "(function () {\n"
            << "  const __properties = Object.assign({}, globalThis.__frescoGenericScriptProperties || {});\n"
            << "  const __userProperties = {};\n"
            << "  const engine = { canvasSize: { x: " << canvasWidth
            << ", y: " << canvasHeight << " }, userProperties: __userProperties, timeOfDay: "
            << (static_cast<double> (scriptClockHour ()) / 24.0) << " };\n"
            << (usesSharedState
                ? "  const shared = globalThis.__frescoSharedScriptState || (globalThis.__frescoSharedScriptState = { night: 0, shownight: false, sunset: 0, showsunset: false });\n"
                  "  class Vec3 { constructor(x, y, z) { this.x = x; this.y = y; this.z = z; } }\n"
                : "")
            << (usesWEMath
                ? "  const WEMath = { smoothStep(edge0, edge1, x) { const t = Math.max(0, Math.min(1, (x - edge0) / (edge1 - edge0))); return t * t * (3 - 2 * t); } };\n"
                : "")
            << (usesLayerDrag || usesCursorVectorMath || usesLayerOriginInit
                ? "  class Vec3 {\n"
                  "    constructor(x = 0, y = 0, z = 0) { this.x = x; this.y = y; this.z = z; }\n"
                  "    add(v) { return new Vec3(this.x + v.x, this.y + v.y, this.z + (v.z || 0)); }\n"
                  "    subtract(v) { return new Vec3(this.x - v.x, this.y - v.y, this.z - (v.z || 0)); }\n"
                  "    multiply(v) { return new Vec3(this.x * v, this.y * v, this.z * v); }\n"
                  "    reflect(n) { const d = this.x * n.x + this.y * n.y + this.z * (n.z || 0); return new Vec3(this.x - 2 * d * n.x, this.y - 2 * d * n.y, this.z - 2 * d * (n.z || 0)); }\n"
                  "    length() { return Math.hypot(this.x, this.y, this.z); }\n"
                  "    normalize() { const n = this.length(); return n ? this.multiply(1 / n) : new Vec3(); }\n"
                  "  }\n"
                : "")
            << (usesCursorPosition ? "  const input = { cursorWorldPosition: " : "")
            << (usesCursorPosition
                ? (usesCursorVectorMath ? "new Vec3()" : "{ x: 0, y: 0, z: 0 }")
                : "")
            << (usesCursorPosition ? " };\n" : "")
            << (profile == "generic-cursor-scale-v1"
                ? "  const thisLayer = { origin: new Vec3(" : "")
            << (profile == "generic-cursor-scale-v1" ? std::to_string (layerOrigin.x) : "")
            << (profile == "generic-cursor-scale-v1" ? "," + std::to_string (layerOrigin.y) : "")
            << (profile == "generic-cursor-scale-v1" ? "," + std::to_string (layerOrigin.z) + ") };\n" : "")
            << (profile == "generic-cursor-parent-origin-v1"
                ? "  const thisScene = { getLayer() { return { origin: new Vec3(" : "")
            << (profile == "generic-cursor-parent-origin-v1" ? std::to_string (parentOrigin.x) : "")
            << (profile == "generic-cursor-parent-origin-v1" ? "," + std::to_string (parentOrigin.y) : "")
            << (profile == "generic-cursor-parent-origin-v1" ? "," + std::to_string (parentOrigin.z) + ") }; } };\n" : "")
            << (usesLayerOriginInit ? "  const thisLayer = { origin: new Vec3(" : "")
            << (usesLayerOriginInit ? std::to_string (layerOrigin.x) : "")
            << (usesLayerOriginInit ? "," + std::to_string (layerOrigin.y) : "")
            << (usesLayerOriginInit ? "," + std::to_string (layerOrigin.z) + ") };\n" : "")
            << (usesLayerDrag ? "  const thisLayer = { origin: new Vec3(" : "")
            << (usesLayerDrag ? std::to_string (layerOrigin.x) : "")
            << (usesLayerDrag ? "," + std::to_string (layerOrigin.y) : "")
            << (usesLayerDrag ? "," + std::to_string (layerOrigin.z) : "")
            << (usesLayerDrag ? "), scale: new Vec3(" : "")
            << (usesLayerDrag ? std::to_string (layerScale.x) : "")
            << (usesLayerDrag ? "," + std::to_string (layerScale.y) : "")
            << (usesLayerDrag ? "," + std::to_string (layerScale.z) : "")
            << (usesLayerDrag ? "), size: new Vec3(" : "")
            << (usesLayerDrag ? std::to_string (layerSize.x) : "")
            << (usesLayerDrag ? "," + std::to_string (layerSize.y) : "")
            << (usesLayerDrag ? ",0) };\n" : "")
            << (usesTextureFrame
                ? "  let __frescoTextureFrame = -1;\n"
                  "  const thisLayer = { getTextureAnimation() { return { setFrame(frame) { __frescoTextureFrame = frame; } }; } };\n"
                  "  class Date { getHours() { return "
                : "")
            << (usesTextureFrame ? std::to_string (scriptClockHour ()) : "")
            << (usesTextureFrame ? "; } }\n" : "")
            << "  function createScriptProperties() {\n"
            << "    const builder = {\n"
            << "      addSlider(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      addCheckbox(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      addCombo(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      addColor(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      addText(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      finish() { return __properties; }\n"
            << "    };\n"
            << "    return builder;\n"
            << "  }\n"
            << genericPropertyScriptBody (source, profile) << "\n"
            << "  return {\n"
            << "    setProperties(values) { Object.assign(__properties, values); },\n"
            << "    setUserProperties(values) { Object.assign(__userProperties, values); },\n"
            << (usesSharedState
                ? "    hasSharedField(name) { return Object.prototype.hasOwnProperty.call(shared, name); },\n"
                  "    getSharedField(name) { return shared[name]; },\n"
                : "")
            << (usesCursorPosition
                ? "    setCursor(position) { input.cursorWorldPosition.x = position.x; input.cursorWorldPosition.y = position.y; input.cursorWorldPosition.z = position.z || 0; },\n"
                : "")
            << (usesLayerDrag
                ? "    cursor(name, position) { const event = { worldPosition: new Vec3(position.x, position.y, position.z || 0) }; if (name === 'down') cursorDown(event); else if (name === 'move') cursorMove(event); else cursorUp(event); },\n"
                  "    tick(value) { const origin = update(thisLayer.origin); if (origin && typeof origin === 'object') thisLayer.origin = origin; return { value, origin: thisLayer.origin }; }\n"
                : usesCursorPosition && usesCursorVectorMath
                ? "    tick(value) { value = new Vec3(value.x, value.y, value.z || 0); if (!this.__initialized) { this.__initialized = true; if (typeof init === 'function') value = init(value); } return update(value); }\n"
                : usesCursorPosition
                ? "    tick(value) { if (!this.__initialized) { this.__initialized = true; if (typeof init === 'function') value = init(value); } return update(value); }\n"
                : usesLayerOriginInit
                ? "    tick(value) { if (!this.__initialized) { this.__initialized = true; if (typeof init === 'function') init(); } return update(value); }\n"
                : usesTextureFrame
                ? "    tick(value) { __frescoTextureFrame = -1; return { value: update(value), frame: __frescoTextureFrame }; }\n"
                : "    tick(value) { return update(value); }\n")
            << "  };\n"
            << "})()";

        const std::string code = wrapper.str ();
        JSValue object = JS_Eval (
            m_context, code.c_str (), code.size (), key.c_str (),
            JS_EVAL_TYPE_GLOBAL
        );
        global = JS_GetGlobalObject (m_context);
        JS_SetPropertyStr (
            m_context, global, "__frescoGenericScriptProperties", JS_UNDEFINED
        );
        JS_FreeValue (m_context, global);
        if (JS_IsException (object)) {
            ++m_errorCount;
            ++m_genericPropertyScriptErrorCount;
            logException (m_context, "generic-property creation");
            JS_FreeValue (m_context, object);
            return;
        }
        m_genericPropertyScripts.emplace (
            key,
            GenericPropertyScript {
                .object = object,
                .value = &value,
                .profile = profile,
                .objectId = objectId,
                .target = target,
                .camera2DControl = std::move (camera2DControl),
                .sharedField = profile == "generic-shared-state-value-v1"
                    ? sharedReaderField (source) : std::nullopt,
            }
        );
        if (profile != "generic-time-shared-state-v1"
            && profile != "generic-shared-state-value-v1") {
            tickGenericPropertyScript (m_genericPropertyScripts.at (key));
        }
    }

    void queueEffectScript (DynamicValue& value, int objectId) {
        const auto& source = value.getScriptSource ();
        if (!source.has_value ()) {
            return;
        }
        const std::string key = "effect_" + std::to_string (objectId) + "_"
            + std::to_string (m_nextEffectScriptId++);
        createGenericPropertyScript (key, value, objectId, *source);
    }

    void setInitialUserProperties (
        const WallpaperEngine::Audio::UserPropertyBatch& properties
    ) {
        m_initialUserProperties = properties.values;
        invalidateSharedUserPropertiesJS ();
        applyGenericUserProperties (properties.values);
        applySceneCameraZoom (properties.values);
    }

    void setUserProperties (
        const WallpaperEngine::Audio::UserPropertyBatch& properties
    ) {
        for (const auto& [key, value] : properties.values) {
            m_pendingUserProperties.insert_or_assign (key, value);
        }
    }

    void applyPendingUserProperties () {
        if (m_pendingUserProperties.empty () || m_shutdown) {
            return;
        }
        bool applied = applyGenericUserProperties (m_pendingUserProperties);
        applied = applySceneCameraZoom (m_pendingUserProperties) || applied;
        const bool hasGenericUserPropertyConsumer = std::ranges::any_of (
            m_genericPropertyScripts, [] (const auto& entry) {
                return entry.second.profile == "generic-time-shared-state-v1"
                    || entry.second.profile == "generic-user-property-scalar-v1"
                    || entry.second.profile == "generic-time-user-property-scalar-v1";
            }
        );
        for (const auto& [key, value] : m_pendingUserProperties) {
            m_initialUserProperties.insert_or_assign (key, value);
        }
        invalidateSharedUserPropertiesJS ();
        applied = applied || hasGenericUserPropertyConsumer;
        for (auto& [key, script] : m_propertyScripts) {
            static_cast<void> (key);
            if (!script.initialized) {
                continue;
            }
            applyUserProperties (script, m_pendingUserProperties);
            applied = true;
        }
        if (applied) {
            m_pendingUserProperties.clear ();
        }
    }

    ScriptLayerHandle createLayer (
        const std::string& source,
        std::map<std::string, std::unique_ptr<UserSetting>>& properties,
        const std::string& initialText
    ) {
        const auto compatibility = FrescoScene::classifySceneTextScript (source);
        JSValue global = JS_GetGlobalObject (m_context);
        JSValue seedProperties = JS_NewObject (m_context);
        for (const auto& property : properties) {
            JS_SetPropertyStr (
                m_context, seedProperties, property.first.c_str (),
                dynamicValueToJS (m_context, *property.second->value)
            );
        }
        JS_SetPropertyStr (m_context, global, "__frescoSeedProperties", seedProperties);
        JS_SetPropertyStr (
            m_context, global, "__frescoSeedText",
            JS_NewString (m_context, initialText.c_str ())
        );
        JS_FreeValue (m_context, global);

        std::ostringstream wrapper;
        wrapper
            << "(function () {\n"
            << pinnedDateShim (scriptClock ())
            << "  const __properties = Object.assign({}, globalThis.__frescoSeedProperties || {});\n"
            << "  const thisLayer = { text: String(globalThis.__frescoSeedText || '') };\n"
            << "  const thisScene = {\n"
            << "    get time() { const c = globalThis.__frescoScene; return c ? c.time : 0; },\n"
            << "    get currentTime() { const c = globalThis.__frescoScene; return c ? c.time : 0; },\n"
            << "    get dt() { const c = globalThis.__frescoScene; return c ? c.dt : 0; },\n"
            << "    get fps() { const c = globalThis.__frescoScene; return c ? c.fps : 60; },\n"
            << "    getLayer(key) { return globalThis.__frescoGetSoundLayer(key); }\n"
            << "  };\n"
            << "  const engine = {\n"
            << "    get frametime() { const c = globalThis.__frescoScene; return c ? c.dt : 0; },\n"
            << "    get time() { const c = globalThis.__frescoScene; return c ? c.time : 0; }\n"
            << "  };\n"
            << "  function createScriptProperties() {\n"
            << "    const builder = {\n"
            << "      addSlider(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      addCheckbox(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      addCombo(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      addColor(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      addText(o) { if (!(o.name in __properties)) __properties[o.name] = o.value; return builder; },\n"
            << "      finish() { return __properties; }\n"
            << "    };\n"
            << "    return builder;\n"
            << "  }\n"
            << scriptBody (source) << "\n"
            << "  let __initialized = false;\n"
            << "  function __frescoInitialize() {\n"
            << "    if (!__initialized) { __initialized = true; if (typeof init === 'function') init(); }\n"
            << "  }\n"
            << "  function __frescoUpdateText() {\n"
            << "    if (typeof update === 'function') {\n"
            << "      const value = update(thisLayer.text);\n"
            << "      if (typeof value === 'string') thisLayer.text = value;\n"
            << "    }\n"
            << "    return String(thisLayer.text);\n"
            << "  }\n"
            << "  return {\n"
            << "    tick() {\n"
            << "      __frescoInitialize();\n"
            << "      return __frescoUpdateText();\n"
            << "    },\n"
            << "    mediaProperties(event) {\n"
            << "      if (typeof mediaPropertiesChanged !== 'function') return false;\n"
            << "      __frescoInitialize();\n"
            << "      mediaPropertiesChanged(event);\n"
            << "      return __frescoUpdateText();\n"
            << "    },\n"
            << "    destroy() { if (typeof destroy === 'function') destroy(); }\n"
            << "  };\n"
            << "})()";

        const std::string code = wrapper.str ();
        JSValue object = JS_Eval (
            m_context, code.c_str (), code.size (), "<wallpaper-text-script>",
            JS_EVAL_TYPE_GLOBAL
        );
        if (JS_IsException (object)) {
            ++m_errorCount;
            logException (m_context, "creation");
            return kInvalidLayerHandle;
        }

        const ScriptLayerHandle handle = m_nextHandle++;
        m_layers.emplace (
            handle,
            Layer {
                .object = object,
                .text = initialText,
                .mediaProperties = compatibility.supported,
            }
        );
        return handle;
    }

    void setMediaProperties (
        const std::string& title,
        const std::string& artist,
        const std::string& album
    ) {
        if (m_shutdown) {
            return;
        }
        for (auto& [handle, layer] : m_layers) {
            static_cast<void> (handle);
            if (!layer.mediaProperties) {
                continue;
            }
            JSValue event = JS_NewObject (m_context);
            JS_SetPropertyStr (
                m_context, event, "title", JS_NewString (m_context, title.c_str ())
            );
            JS_SetPropertyStr (
                m_context, event, "artist", JS_NewString (m_context, artist.c_str ())
            );
            JS_SetPropertyStr (
                m_context, event, "album", JS_NewString (m_context, album.c_str ())
            );
            JS_SetPropertyStr (
                m_context, event, "albumTitle", JS_NewString (m_context, album.c_str ())
            );
            JSValue function = JS_GetPropertyStr (
                m_context, layer.object, "mediaProperties"
            );
            JSValue result = JS_Call (
                m_context, function, layer.object, 1, &event
            );
            JS_FreeValue (m_context, event);
            JS_FreeValue (m_context, function);
            if (JS_IsException (result)) {
                ++m_errorCount;
                ++m_mediaPropertyScriptErrors;
                logException (m_context, "media-properties");
                JS_FreeValue (m_context, result);
                continue;
            }
            const char* text = JS_IsString (result)
                ? JS_ToCString (m_context, result) : nullptr;
            if (text != nullptr) {
                const std::string nextText = text;
                if (nextText != layer.text) {
                    ++m_textChangeCount;
                    layer.text = nextText;
                }
                JS_FreeCString (m_context, text);
            }
            JS_FreeValue (m_context, result);
            ++m_mediaPropertyScriptDispatches;
        }
    }

    void mediaPlaybackChanged (int state) {
        if (m_shutdown) {
            return;
        }
        for (auto& [key, script] : m_genericPropertyScripts) {
            static_cast<void> (key);
            if (script.profile != "generic-media-playback-visibility-v1") {
                continue;
            }
            const bool prior = script.value->getBool ();
            const bool next = FrescoScene::mediaPlaybackVisible (state);
            if (next != prior) {
                script.value->update (next, DynamicValue::UpdateSource::Script);
                ++script.changes;
                ++m_genericPropertyScriptChangeCount;
            }
            ++script.updates;
            ++m_genericPropertyScriptUpdateCount;
            ++m_mediaPlaybackScriptDispatches;
        }
        JSValue event = JS_NewObject (m_context);
        JS_SetPropertyStr (m_context, event, "state", JS_NewInt32 (m_context, state));
        m_mediaPlaybackScriptDispatches +=
            dispatchGraphMediaEvent ("playback", event);
        JS_FreeValue (m_context, event);
    }

    void mediaTimelineChanged (double position, double duration) {
        if (m_shutdown) {
            return;
        }
        JSValue event = JS_NewObject (m_context);
        JS_SetPropertyStr (
            m_context, event, "position", JS_NewFloat64 (m_context, position)
        );
        JS_SetPropertyStr (
            m_context, event, "duration", JS_NewFloat64 (m_context, duration)
        );
        m_mediaTimelineScriptDispatches +=
            dispatchGraphMediaEvent ("timeline", event);
        JS_FreeValue (m_context, event);
    }

    void mediaThumbnailChanged (
        std::string_view primaryColor,
        std::string_view secondaryColor,
        std::string_view tertiaryColor,
        std::string_view textColor,
        std::string_view highContrastColor
    ) {
        if (m_shutdown) {
            return;
        }
        const auto parsedColor
            = FrescoScene::parseThumbnailPrimaryColor (primaryColor);
        for (auto& [key, script] : m_genericPropertyScripts) {
            static_cast<void> (key);
            if (script.profile == "generic-media-thumbnail-animation-play-v1") {
                auto* animation = FrescoScene::dynamicValueAnimation (*script.value);
                if (animation != nullptr) {
                    animation->play ();
                    ++m_mediaThumbnailScriptDispatches;
                }
            } else if (script.profile
                    == "generic-media-thumbnail-primary-color-v1"
                && parsedColor.has_value ()
                && script.primaryColorTransition.has_value ()) {
                script.primaryColorTransition->setTarget (*parsedColor);
                ++m_mediaThumbnailScriptDispatches;
            }
        }
        JSValue event = JS_NewObject (m_context);
        const auto setColor = [&] (const char* name, std::string_view encoded) {
            const auto color = FrescoScene::parseThumbnailPrimaryColor (encoded);
            if (!color.has_value ()) {
                return;
            }
            JS_SetPropertyStr (
                m_context, event, name, graphVector (*color)
            );
        };
        setColor ("primaryColor", primaryColor);
        setColor ("secondaryColor", secondaryColor);
        setColor ("tertiaryColor", tertiaryColor);
        setColor ("textColor", textColor);
        setColor ("highContrastColor", highContrastColor);
        m_mediaThumbnailScriptDispatches +=
            dispatchGraphMediaEvent ("thumbnail", event);
        JS_FreeValue (m_context, event);
    }

    void tickLayer (ScriptLayerHandle handle, double time, double deltaTime, double fps) {
        auto layer = m_layers.find (handle);
        if (layer == m_layers.end ()) {
            return;
        }

        JSValue scene = JS_NewObject (m_context);
        JS_SetPropertyStr (m_context, scene, "time", JS_NewFloat64 (m_context, time));
        JS_SetPropertyStr (m_context, scene, "dt", JS_NewFloat64 (m_context, deltaTime));
        JS_SetPropertyStr (m_context, scene, "fps", JS_NewFloat64 (m_context, fps));
        JSValue global = JS_GetGlobalObject (m_context);
        JS_SetPropertyStr (m_context, global, "__frescoScene", scene);
        JS_FreeValue (m_context, global);

        JSValue tick = JS_GetPropertyStr (m_context, layer->second.object, "tick");
        JSValue result = JS_Call (m_context, tick, layer->second.object, 0, nullptr);
        JS_FreeValue (m_context, tick);
        if (JS_IsException (result)) {
            ++m_errorCount;
            logException (m_context, "update");
            JS_FreeValue (m_context, result);
            return;
        }
        const char* text = JS_ToCString (m_context, result);
        if (text != nullptr) {
            const std::string nextText = text;
            if (nextText != layer->second.text) {
                ++m_textChangeCount;
                layer->second.text = nextText;
            }
            JS_FreeCString (m_context, text);
        }
        ++m_updateCount;
        JS_FreeValue (m_context, result);
    }

    std::string layerText (ScriptLayerHandle handle) const {
        const auto layer = m_layers.find (handle);
        return layer == m_layers.end () ? std::string () : layer->second.text;
    }

    void destroyLayer (ScriptLayerHandle handle) {
        const auto layer = m_layers.find (handle);
        if (layer == m_layers.end ()) {
            return;
        }
        JSValue destroy = JS_GetPropertyStr (m_context, layer->second.object, "destroy");
        JSValue result = JS_Call (m_context, destroy, layer->second.object, 0, nullptr);
        if (JS_IsException (result)) {
            ++m_errorCount;
            logException (m_context, "destroy");
        }
        JS_FreeValue (m_context, result);
        JS_FreeValue (m_context, destroy);
        JS_FreeValue (m_context, layer->second.object);
        m_layers.erase (layer);
    }

    [[nodiscard]] std::size_t layerCount () const { return m_layers.size (); }
    [[nodiscard]] std::size_t updateCount () const { return m_updateCount; }
    [[nodiscard]] std::size_t textChangeCount () const { return m_textChangeCount; }
    [[nodiscard]] std::size_t mediaPropertyScriptCount () const {
        return std::count_if (
            m_layers.begin (), m_layers.end (),
            [] (const auto& entry) { return entry.second.mediaProperties; }
        );
    }
    [[nodiscard]] std::size_t mediaPropertyScriptDispatchCount () const {
        return m_mediaPropertyScriptDispatches;
    }
    [[nodiscard]] std::size_t mediaPlaybackScriptDispatchCount () const {
        return m_mediaPlaybackScriptDispatches;
    }
    [[nodiscard]] std::size_t mediaTimelineScriptDispatchCount () const {
        return m_mediaTimelineScriptDispatches;
    }
    [[nodiscard]] std::size_t mediaThumbnailScriptDispatchCount () const {
        return m_mediaThumbnailScriptDispatches;
    }
    [[nodiscard]] std::size_t mediaPropertyScriptErrorCount () const {
        return m_mediaPropertyScriptErrors;
    }
    [[nodiscard]] std::vector<DynamicFloatEvidence> dynamicFloatEvidence () const {
        std::vector<DynamicFloatEvidence> result;
        result.reserve (m_dynamicFloats.size ());
        for (const auto& [key, dynamicFloat] : m_dynamicFloats) {
            result.push_back ({
                .key = key,
                .value = dynamicFloat.value->getFloat (),
                .updates = dynamicFloat.updates,
                .changes = dynamicFloat.changes,
            });
        }
        return result;
    }
    [[nodiscard]] std::size_t dynamicFloatUpdateCount () const {
        return m_dynamicFloatUpdateCount;
    }
    [[nodiscard]] std::size_t dynamicFloatChangeCount () const {
        return m_dynamicFloatChangeCount;
    }
    [[nodiscard]] std::size_t errorCount () const { return m_errorCount; }

    [[nodiscard]] std::vector<PropertyScriptEvidence> propertyScriptEvidence () const {
        std::vector<PropertyScriptEvidence> result;
        result.reserve (m_propertyScripts.size ());
        for (const auto& [key, script] : m_propertyScripts) {
            result.push_back ({
                .key = key,
                .profile = script.profile,
                .objectId = script.objectId,
                .property = "visible",
                .value = script.value->getBool (),
                .initialized = script.initialized,
                .seededDelaySeconds = script.seededDelaySeconds,
                .targetDelaySeconds = script.targetDelaySeconds,
                .propertyApplications = script.propertyApplications,
                .updates = script.updates,
            });
        }
        return result;
    }

    [[nodiscard]] std::size_t propertyScriptInitializationCount () const {
        return m_propertyScriptInitializationCount;
    }

    [[nodiscard]] std::size_t propertyScriptPropertyApplicationCount () const {
        return m_propertyScriptPropertyApplicationCount;
    }

    [[nodiscard]] std::size_t propertyScriptUpdateCount () const {
        return m_propertyScriptUpdateCount;
    }

    [[nodiscard]] std::size_t propertyScriptErrorCount () const {
        return m_propertyScriptErrorCount;
    }

    [[nodiscard]] std::size_t propertyScriptCount () const {
        return m_propertyScripts.size ();
    }

    [[nodiscard]] std::size_t genericPropertyScriptCount () const {
        return m_genericPropertyScripts.size ();
    }

    [[nodiscard]] std::vector<GenericPropertyScriptEvidence>
    genericPropertyScriptEvidence () const {
        std::vector<GenericPropertyScriptEvidence> result;
        result.reserve (m_genericPropertyScripts.size ());
        for (const auto& [key, script] : m_genericPropertyScripts) {
            result.push_back ({
                .key = key,
                .profile = script.profile,
                .objectId = script.objectId,
                .property = script.propertyName,
                .updates = script.updates,
                .changes = script.changes,
            });
        }
        return result;
    }

    [[nodiscard]] std::size_t continuousGenericPropertyScriptCount () const {
        return std::ranges::count_if (
            m_genericPropertyScripts,
            [] (const auto& entry) {
                return entry.second.requiresContinuousEvaluation;
            }
        );
    }

    [[nodiscard]] std::size_t genericPropertyScriptUpdateCount () const {
        return m_genericPropertyScriptUpdateCount;
    }

    [[nodiscard]] std::size_t genericPropertyScriptChangeCount () const {
        return m_genericPropertyScriptChangeCount;
    }

    [[nodiscard]] std::size_t genericPropertyScriptErrorCount () const {
        return m_genericPropertyScriptErrorCount;
    }

    [[nodiscard]] std::size_t audioVectorScriptCount () const {
        return std::ranges::count_if (
            m_genericPropertyScripts,
            [] (const auto& entry) {
                return entry.second.profile
                    == "generic-audio-vector-transform-v1"
                    || entry.second.profile
                        == "exact-tracked-audio-vector-transform-v1";
            }
        );
    }

    [[nodiscard]] std::size_t exactTrackedAudioVectorScriptCount () const {
        return std::ranges::count_if (
            m_genericPropertyScripts,
            [] (const auto& entry) {
                return entry.second.profile
                    == "exact-tracked-audio-vector-transform-v1";
            }
        );
    }

    [[nodiscard]] std::optional<float> audioVectorValueX () const {
        for (const auto& [key, script] : m_genericPropertyScripts) {
            static_cast<void> (key);
            if (script.profile == "generic-audio-vector-transform-v1"
                || script.profile
                    == "exact-tracked-audio-vector-transform-v1") {
                return script.value->getVec3 ().x;
            }
        }
        return std::nullopt;
    }

    [[nodiscard]] std::size_t audioVectorScriptUpdateCount () const {
        return m_audioVectorScriptUpdateCount;
    }

    [[nodiscard]] std::size_t audioVectorScriptChangeCount () const {
        return m_audioVectorScriptChangeCount;
    }

    [[nodiscard]] bool audioVectorContinuousRequired () const {
        return m_audioVectorContinuousRequired;
    }

    [[nodiscard]] std::size_t namedAnimationTargetPlayCount () const {
        return m_namedAnimationTargetPlayCount;
    }

    [[nodiscard]] std::size_t namedAnimationActiveCount () const {
        std::size_t result = 0;
        for (const auto& [key, script] : m_genericPropertyScripts) {
            static_cast<void> (key);
            result += std::ranges::count_if (
                script.namedAnimations, [] (const auto& target) {
                    return target.animation->state ()
                        == FrescoScene::DynamicValueAnimation::State::Playing;
                }
            );
        }
        return result;
    }

    [[nodiscard]] double namedAnimationFrameTotal () const {
        double result = 0.0;
        for (const auto& [key, script] : m_genericPropertyScripts) {
            static_cast<void> (key);
            for (const auto& target : script.namedAnimations) {
                result += target.animation->frame ();
            }
        }
        return result;
    }

    [[nodiscard]] std::size_t cursorScriptCount () const {
        return m_cursorScripts.size ();
    }

    [[nodiscard]] std::size_t deferredScriptCount () const {
        return m_deferredScriptKeys.size ();
    }

    [[nodiscard]] FrescoScene::SceneScriptTimerEvidence timerEvidence () const {
        return m_sceneLayerGraph == nullptr
            ? FrescoScene::SceneScriptTimerEvidence {}
            : m_sceneLayerGraph->timerEvidence ();
    }

    [[nodiscard]] bool acceptsUserProperty (std::string_view key) const {
        if (m_scene.getScene ().project.properties.contains (std::string (key))) {
            return true;
        }
        if (key == "music" && !m_propertyScripts.empty ()) {
            return true;
        }
        if (key == "timeofday" && std::ranges::any_of (
                m_genericPropertyScripts, [] (const auto& entry) {
                    return entry.second.profile == "generic-time-shared-state-v1"
                        || entry.second.profile == "generic-time-user-property-scalar-v1";
                }
            )) {
            return true;
        }
        if (key == "character" && std::ranges::any_of (
                m_genericPropertyScripts, [] (const auto& entry) {
                    return entry.second.profile == "generic-user-property-scalar-v1";
                }
            )) {
            return true;
        }
        for (const auto& [scriptKey, script] : m_genericPropertyScripts) {
            static_cast<void> (scriptKey);
            for (const auto& [name, setting] : script.value->getProperties ()) {
                static_cast<void> (name);
                if (setting->property != nullptr && setting->property->name == key) {
                    return true;
                }
            }
        }
        return false;
    }

    std::size_t applySceneLayerGraph () {
        const auto changes = m_sceneLayerGraph->applyToScene ();
        if (m_sceneLayerGraph->takeStorageRejection ()
            && !m_storageRejectionReported) {
            m_storageRejectionReported = true;
            ++m_errorCount;
            ++m_genericPropertyScriptErrorCount;
            sLog.error ("SceneScript local storage write rejected");
        }
        return changes;
    }

    void resolvePendingLocalAnimationLayerScripts () {
        for (auto& [key, pending] : m_pendingLocalAnimationLayerScripts) {
            const bool inert = FrescoScene::isTopologyProvenInert (
                pending.capability,
                localAnimationLayerTopology (
                    pending.objectId, pending.capability, pending.target
                )
            );
            if (inert) {
                m_genericPropertyScripts.emplace (
                    key,
                    GenericPropertyScript {
                        .object = JS_UNDEFINED,
                        .value = pending.value,
                        .profile
                            = "generic-inert-local-animation-layer-click-v1",
                        .objectId = pending.objectId,
                        .target = pending.target,
                    }
                );
                if (std::getenv ("FRESCO_SCENE_SCRIPT_PROFILE_TRACE") != nullptr) {
                    std::fprintf (
                        stderr,
                        "scene-script accepted key=%s object=%d profile=%s\n",
                        key.c_str (), pending.objectId,
                        "generic-inert-local-animation-layer-click-v1"
                    );
                }
            } else {
                m_rejectedLocalAnimationLayerScripts.emplace (
                    pending.objectId, pending.capability.targetName
                );
                if (std::getenv ("FRESCO_SCENE_SCRIPT_PROFILE_TRACE") != nullptr) {
                    std::fprintf (
                        stderr,
                        "scene-script deferred key=%s object=%d reason=%s\n",
                        key.c_str (), pending.objectId,
                        "local animation-layer topology is not proven inert"
                    );
                }
            }
        }
        m_pendingLocalAnimationLayerScripts.clear ();
    }

    void tick () {
        m_audioVectorContinuousRequired = false;
        FrescoScene::advanceAutomaticDynamicValueAnimations (
            m_scene.getDeltaTime ()
        );
        resolvePendingLocalAnimationLayerScripts ();
        JSValue scene = JS_NewObject (m_context);
        JS_SetPropertyStr (
            m_context, scene, "time", JS_NewFloat64 (m_context, m_scene.getTime ())
        );
        JS_SetPropertyStr (
            m_context, scene, "dt", JS_NewFloat64 (m_context, m_scene.getDeltaTime ())
        );
        JS_SetPropertyStr (
            m_context, scene, "fps", JS_NewFloat64 (m_context, m_scene.getFps ())
        );
        JSValue global = JS_GetGlobalObject (m_context);
        JS_SetPropertyStr (m_context, global, "__frescoScene", scene);
        JS_FreeValue (m_context, global);
        refreshAudioVector ();
        if (m_sceneLayerGraph != nullptr) {
            m_sceneLayerGraph->syncFromScene ();
            m_sceneLayerGraph->setCursor (m_cursorX, m_cursorY);
            bool timeVarying = true;
            if (const auto property = m_initialUserProperties.find ("timevarying");
                property != m_initialUserProperties.end ()) {
                if (const auto enabled = std::get_if<bool> (&property->second)) {
                    timeVarying = *enabled;
                }
            }
            m_sceneLayerGraph->setTimeVarying (timeVarying);
            for (const auto& key : m_sceneLayerGraphOrder) {
                initializeGraphPropertyScript (m_genericPropertyScripts.at (key));
            }
        }
        if (!m_dynamicFloats.empty ()) {
            refreshAudioAverage ();
            for (auto& [key, dynamicFloat] : m_dynamicFloats) {
                static_cast<void> (key);
                tickDynamicFloat (dynamicFloat);
            }
        }
        const auto tickProfile = [this] (std::string_view profile) {
            for (auto& [key, script] : m_genericPropertyScripts) {
                static_cast<void> (key);
                if (script.profile == profile) {
                    tickGenericPropertyScript (script);
                }
            }
        };
        tickProfile ("generic-time-shared-state-v1");
        for (auto& [key, script] : m_genericPropertyScripts) {
            static_cast<void> (key);
            if (usesSceneLayerGraph (script.profile)
                || script.profile == "generic-time-shared-state-v1"
                || script.profile == "generic-shared-state-value-v1") {
                continue;
            }
            tickGenericPropertyScript (script);
        }
        tickProfile ("generic-shared-state-value-v1");
        for (const auto& key : m_sceneLayerGraphOrder) {
            tickGenericPropertyScript (m_genericPropertyScripts.at (key));
        }
        if (m_sceneLayerGraph != nullptr) {
            m_genericPropertyScriptChangeCount +=
                applySceneLayerGraph ();
            for (const auto& command : m_sceneLayerGraph->takeCommands ()) {
                if (command.kind
                    == FrescoScene::SceneScriptLayerCommand::Kind::textureFrame) {
                    if (command.frame < 0) {
                        ++m_errorCount;
                        ++m_genericPropertyScriptErrorCount;
                        sLog.error ("SceneScript graph requested a negative texture frame");
                    } else if (FrescoScene::setScriptedTextureAnimationFrame (
                                   &m_scene, command.objectId,
                                   static_cast<uint32_t> (command.frame))) {
                        ++m_genericPropertyScriptChangeCount;
                    }
                } else if (command.kind
                           == FrescoScene::SceneScriptLayerCommand::Kind::textureStop) {
                    FrescoScene::clearScriptedTextureAnimationFrame (
                        &m_scene, command.objectId
                    );
                } else if (command.kind
                           == FrescoScene::SceneScriptLayerCommand::Kind::videoPlay) {
                    if (!controlSceneVideoTexture (command.objectId, false)) {
                        ++m_errorCount;
                        ++m_genericPropertyScriptErrorCount;
                    }
                } else if (command.kind
                           == FrescoScene::SceneScriptLayerCommand::Kind::videoPause) {
                    if (!controlSceneVideoTexture (command.objectId, true)) {
                        ++m_errorCount;
                        ++m_genericPropertyScriptErrorCount;
                    }
                } else if (command.kind
                           == FrescoScene::SceneScriptLayerCommand::Kind::animationLayerPlay) {
                    ++m_errorCount;
                    ++m_genericPropertyScriptErrorCount;
                    sLog.error (
                        "SceneScript graph animation layer is unavailable: ",
                        command.objectId, "/", command.name
                    );
                }
            }
        }
        tickCursorScripts ();
        tickPropertyScripts ();
    }

    bool cursorClick (
        int objectId, std::optional<double> injectedMonotonicMilliseconds
    ) {
        for (auto& [key, script] : m_genericPropertyScripts) {
            static_cast<void> (key);
            if (script.objectId == objectId
                && script.profile
                    == "generic-inert-local-animation-layer-click-v1") {
                return true;
            }
            if (script.objectId != objectId
                || script.profile != "generic-named-animation-double-click-v1") {
                continue;
            }
            const auto enabled = script.value->getProperties ().find ("kaiguan");
            const bool acceptsClick = enabled == script.value->getProperties ().end ()
                || enabled->second->value->getBool ();
            const double nowMilliseconds = injectedMonotonicMilliseconds.value_or (
                std::chrono::duration<double, std::milli> (
                    std::chrono::steady_clock::now ().time_since_epoch ()
                ).count ()
            );
            if (acceptsClick && script.lastClickMilliseconds.has_value ()
                && nowMilliseconds >= *script.lastClickMilliseconds
                && nowMilliseconds - *script.lastClickMilliseconds < 500.0) {
                for (auto& target : script.namedAnimations) {
                    target.animation->play ();
                }
                ++script.playRequests;
                m_namedAnimationTargetPlayCount += script.namedAnimations.size ();
            }
            if (acceptsClick) {
                script.lastClickMilliseconds = nowMilliseconds;
            } else {
                script.lastClickMilliseconds.reset ();
            }
            return true;
        }
        if (const auto rejected
                = m_rejectedLocalAnimationLayerScripts.find (objectId);
            rejected != m_rejectedLocalAnimationLayerScripts.end ()) {
            ++m_errorCount;
            ++m_genericPropertyScriptErrorCount;
            sLog.error (
                "SceneScript graph animation layer is unavailable: ",
                objectId, "/", rejected->second
            );
            return true;
        }
        for (auto& [key, script] : m_genericPropertyScripts) {
            static_cast<void> (key);
            if (script.objectId == objectId
                && usesSceneLayerGraph (script.profile)
                && callGraphCursor (script, "click", m_cursorX, m_cursorY)) {
                static_cast<void> (applySceneLayerGraph ());
                return true;
            }
        }
        for (auto& [key, script] : m_cursorScripts) {
            static_cast<void> (key);
            if (script.objectId != objectId) {
                continue;
            }
            return callCursorHook (script, "click");
        }
        return false;
    }

    std::size_t cursorEvent (std::string_view name, float x, float y) {
        m_cursorX = x;
        m_cursorY = y;
        std::size_t handled = 0;
        for (auto& [key, script] : m_genericPropertyScripts) {
            static_cast<void> (key);
            if (usesSceneLayerGraph (script.profile)) {
                handled += callGraphCursor (script, name, x, y) ? 1 : 0;
                continue;
            }
            if (script.profile != "generic-bounded-layer-drag-v1") {
                continue;
            }
            JSValue function = JS_GetPropertyStr (m_context, script.object, "cursor");
            JSValue arguments[] = {
                JS_NewStringLen (m_context, name.data (), name.size ()),
                JS_NewObject (m_context),
            };
            JS_SetPropertyStr (m_context, arguments[1], "x", JS_NewFloat64 (m_context, x));
            JS_SetPropertyStr (m_context, arguments[1], "y", JS_NewFloat64 (m_context, y));
            JSValue result = JS_Call (
                m_context, function, script.object, 2, arguments
            );
            JS_FreeValue (m_context, arguments[0]);
            JS_FreeValue (m_context, arguments[1]);
            JS_FreeValue (m_context, function);
            if (JS_IsException (result)) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                logException (m_context, "cursor event");
                JS_FreeValue (m_context, result);
                continue;
            }
            JS_FreeValue (m_context, result);
            ++handled;
        }
        handled += std::ranges::count_if (
            m_genericPropertyScripts, [] (const auto& entry) {
                return entry.second.profile.starts_with ("generic-cursor-")
                    && !usesSceneLayerGraph (entry.second.profile);
            }
        );
        if (m_sceneLayerGraph != nullptr) {
            static_cast<void> (applySceneLayerGraph ());
        }
        return handled;
    }

private:
    [[nodiscard]] static int scriptClockHour () {
        return scriptClock ().hour;
    }

    struct DynamicFloat {
        JSValue object;
        DynamicValue* value = nullptr;
        std::size_t updates = 0;
        std::size_t changes = 0;
    };

    struct Layer {
        JSValue object;
        std::string text;
        bool mediaProperties = false;
    };

    struct PropertyScript {
        JSValue object;
        DynamicValue* value = nullptr;
        std::string profile;
        int objectId = 0;
        std::optional<std::string> delaySecondsProperty;
        std::optional<std::string> delayUserProperty;
        bool initialized = false;
        double seededDelaySeconds = -1.0;
        double targetDelaySeconds = -1.0;
        std::size_t propertyApplications = 0;
        std::size_t updates = 0;
    };

    struct NamedAnimationTarget {
        DynamicValue* value = nullptr;
        FrescoScene::DynamicValueAnimation* animation = nullptr;
    };

    struct GenericPropertyScript {
        JSValue object;
        DynamicValue* value = nullptr;
        std::string profile;
        int objectId = 0;
        ScriptableObject* target = nullptr;
        std::optional<FrescoScene::Camera2DControlDefinition> camera2DControl;
        std::string propertyName;
        bool requiresContinuousEvaluation = true;
        std::optional<std::string> sharedField;
        bool graphInitialized = false;
        std::vector<NamedAnimationTarget> namedAnimations;
        std::optional<FrescoScene::SceneAudioVectorTransform>
            audioVectorTransform;
        std::optional<FrescoScene::SceneCameraZoomCapability>
            sceneCameraZoom;
        std::optional<FrescoScene::PrimaryColorTransition>
            primaryColorTransition;
        std::optional<double> lastClickMilliseconds;
        std::size_t playRequests = 0;
        std::size_t updates = 0;
        std::size_t changes = 0;
    };

    struct PendingLocalAnimationLayerScript {
        DynamicValue* value = nullptr;
        int objectId = 0;
        ScriptableObject* target = nullptr;
        FrescoScene::LocalAnimationLayerPlayClickCapability capability;
    };

    struct CursorScript {
        JSValue object;
        int objectId = 0;
    };

    std::optional<NamedAnimationTarget> findNamedAnimation (
        std::string_view layerName, std::string_view animationName
    ) {
        for (const auto& object : m_scene.getScene ().objects) {
            if (object->name != layerName) {
                continue;
            }
            std::vector<DynamicValue*> values = {
                object->origin->value.get (),
                object->groupScale->value.get (),
                object->groupAngles->value.get (),
                object->groupVisible->value.get (),
            };
            if (object->is<Image> ()) {
                auto* image = object->as<Image> ();
                values.insert (values.end (), {
                    image->scale->value.get (),
                    image->angles->value.get (),
                    image->visible->value.get (),
                    image->alpha->value.get (),
                    image->color->value.get (),
                    image->parallaxDepth->value.get (),
                    image->colorBlendMode->value.get (),
                    image->brightness->value.get (),
                });
            }
            for (auto* value : values) {
                if (value == nullptr) {
                    continue;
                }
                auto* animation = FrescoScene::dynamicValueAnimation (*value);
                if (animation != nullptr && animation->supported ()
                    && animation->name () == animationName) {
                    return NamedAnimationTarget {
                        .value = value,
                        .animation = animation,
                    };
                }
            }
            return std::nullopt;
        }
        return std::nullopt;
    }

    bool applyGenericUserProperties (
        const std::map<std::string, WallpaperEngine::Audio::UserPropertyScalar>& properties
    ) {
        bool applied = false;
        auto& projectProperties = m_scene.getScene ().project.properties;
        for (const auto& [key, value] : properties) {
            const auto property = projectProperties.find (key);
            if (property == projectProperties.end ()) {
                continue;
            }
            property->second->update (
                userPropertyString (value), DynamicValue::UpdateSource::User
            );
            applied = true;
        }
        return applied;
    }

    bool applySceneCameraZoom (
        const std::map<std::string, WallpaperEngine::Audio::UserPropertyScalar>& properties
    ) {
        bool applied = false;
        for (auto& [key, script] : m_genericPropertyScripts) {
            static_cast<void> (key);
            if (!script.sceneCameraZoom.has_value ()) {
                continue;
            }
            const auto property = properties.find (
                script.sceneCameraZoom->propertyKey
            );
            if (property == properties.end ()) {
                continue;
            }
            const auto* enabled = std::get_if<bool> (&property->second);
            if (enabled == nullptr) {
                continue;
            }
            const bool changed = FrescoScene::setSceneZoom (
                m_scene,
                *enabled ? script.sceneCameraZoom->enabledZoom
                         : script.sceneCameraZoom->disabledZoom
            );
            if (changed) {
                ++script.changes;
                ++m_genericPropertyScriptChangeCount;
            }
            ++script.updates;
            ++m_genericPropertyScriptUpdateCount;
            applied = true;
        }
        return applied;
    }

    bool callCursorHook (CursorScript& script, const char* name) {
        JSValue function = JS_GetPropertyStr (m_context, script.object, name);
        JSValue result = JS_Call (m_context, function, script.object, 0, nullptr);
        JS_FreeValue (m_context, function);
        if (JS_IsException (result)) {
            ++m_errorCount;
            logException (m_context, name);
            JS_FreeValue (m_context, result);
            return false;
        }
        JS_FreeValue (m_context, result);
        return true;
    }

    void tickCursorScripts () {
        if (m_cursorScripts.empty () || m_shutdown) {
            return;
        }
        JSValue scene = JS_NewObject (m_context);
        JS_SetPropertyStr (
            m_context, scene, "dt", JS_NewFloat64 (m_context, m_scene.getDeltaTime ())
        );
        JSValue global = JS_GetGlobalObject (m_context);
        JS_SetPropertyStr (m_context, global, "__frescoScene", scene);
        JS_FreeValue (m_context, global);
        for (auto& [key, script] : m_cursorScripts) {
            static_cast<void> (key);
            static_cast<void> (callCursorHook (script, "tick"));
        }
    }

    enum class HookResult {
        absent,
        success,
        error,
    };

    JSValue userPropertiesToJS (
        const std::map<std::string, WallpaperEngine::Audio::UserPropertyScalar>& properties
    ) {
        JSValue result = JS_NewObject (m_context);
        for (const auto& [key, value] : properties) {
            JS_SetPropertyStr (
                m_context, result, key.c_str (), userPropertyToJS (m_context, value)
            );
        }
        return result;
    }

    // Every generic property script is handed the same user properties, and they
    // change only when the properties themselves do, so the object is built once
    // and shared rather than rebuilt per script per tick. Elaina authors 104 of
    // them across 5651 bytes of key — one key is 847 characters, because the
    // workshop author pasted markup into property names — and interning those
    // atoms again for each script was 13.7% of the frame loop.
    //
    // Sharing one object is only sound because no script keeps or writes to it.
    // The non-graph wrapper copies out with Object.assign, and the graph wrapper
    // hands it to the author's applyUserProperties. A survey of all 27 installed
    // packages found 652 scripted values, of which 6 receive this object and none
    // retain or mutate it. Re-run that survey before relying on the sharing.
    JSValue sharedUserPropertiesJS () {
        if (JS_IsUndefined (m_userPropertiesJS)) {
            m_userPropertiesJS = userPropertiesToJS (m_initialUserProperties);
        }
        // The caller owns its reference, so a script that changes the properties
        // mid-tick cannot free the object out from under the call in progress.
        return JS_DupValue (m_context, m_userPropertiesJS);
    }

    void invalidateSharedUserPropertiesJS () {
        if (m_context == nullptr) {
            return;
        }
        JS_FreeValue (m_context, m_userPropertiesJS);
        m_userPropertiesJS = JS_UNDEFINED;
    }

    JSValue graphVector (const std::array<float, 3>& value) {
        JSValue global = JS_GetGlobalObject (m_context);
        JSValue constructor = JS_GetPropertyStr (
            m_context, global, "__frescoVec3"
        );
        JS_FreeValue (m_context, global);
        JSValue arguments[] = {
            JS_NewFloat64 (m_context, value[0]),
            JS_NewFloat64 (m_context, value[1]),
            JS_NewFloat64 (m_context, value[2]),
        };
        JSValue result = JS_CallConstructor (
            m_context, constructor, 3, arguments
        );
        for (auto& argument : arguments) {
            JS_FreeValue (m_context, argument);
        }
        JS_FreeValue (m_context, constructor);
        return result;
    }

    JSValue graphDynamicValueToJS (const DynamicValue& value) {
        if (value.getType () == DynamicValue::Vec3) {
            const auto vector = value.getVec3 ();
            return graphVector ({vector.x, vector.y, vector.z});
        }
        if (value.getType () == DynamicValue::Vec4) {
            const auto vector = value.getVec4 ();
            JSValue result = graphVector ({vector.x, vector.y, vector.z});
            JS_SetPropertyStr (
                m_context, result, "w", JS_NewFloat64 (m_context, vector.w)
            );
            return result;
        }
        return dynamicValueToJS (m_context, value);
    }

    std::size_t dispatchGraphMediaEvent (const char* name, JSValueConst event) {
        std::size_t deliveries = 0;
        for (auto& [key, script] : m_genericPropertyScripts) {
            static_cast<void> (key);
            if (!usesSceneLayerGraph (script.profile)) {
                continue;
            }
            JSValue function = JS_GetPropertyStr (
                m_context, script.object, "dispatch"
            );
            JSValue arguments[] = {
                JS_NewString (m_context, name),
                JS_DupValue (m_context, event),
            };
            JSValue result = JS_Call (
                m_context, function, script.object, 2, arguments
            );
            JS_FreeValue (m_context, arguments[0]);
            JS_FreeValue (m_context, arguments[1]);
            JS_FreeValue (m_context, function);
            if (JS_IsException (result)) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                logException (m_context, "2D graph media event");
            } else if (JS_ToBool (m_context, result) != 0) {
                ++deliveries;
            }
            JS_FreeValue (m_context, result);
        }
        return deliveries;
    }

    bool callGraphCursor (
        GenericPropertyScript& script, std::string_view name, float x, float y
    ) {
        JSValue function = JS_GetPropertyStr (m_context, script.object, "cursor");
        JSValue event = JS_NewObject (m_context);
        JSValue worldPosition = graphVector ({x, y, 0.0f});
        JS_SetPropertyStr (m_context, event, "worldPosition", worldPosition);
        JSValue arguments[] = {
            JS_NewStringLen (m_context, name.data (), name.size ()), event,
        };
        JSValue result = JS_Call (
            m_context, function, script.object, 2, arguments
        );
        JS_FreeValue (m_context, arguments[0]);
        JS_FreeValue (m_context, arguments[1]);
        JS_FreeValue (m_context, function);
        if (JS_IsException (result)) {
            ++m_errorCount;
            ++m_genericPropertyScriptErrorCount;
            logException (m_context, "2D graph cursor event");
            JS_FreeValue (m_context, result);
            return false;
        }
        const bool handled = JS_ToBool (m_context, result) != 0;
        JS_FreeValue (m_context, result);
        return handled;
    }

    HookResult callPropertyHook (
        PropertyScript& script,
        const char* name,
        int argumentCount = 0,
        JSValueConst* arguments = nullptr
    ) {
        JSValue function = JS_GetPropertyStr (m_context, script.object, name);
        if (!JS_IsFunction (m_context, function)) {
            JS_FreeValue (m_context, function);
            return HookResult::absent;
        }
        JSValue result = JS_Call (
            m_context, function, script.object, argumentCount, arguments
        );
        JS_FreeValue (m_context, function);
        if (JS_IsException (result)) {
            ++m_errorCount;
            ++m_propertyScriptErrorCount;
            logException (m_context, name);
            JS_FreeValue (m_context, result);
            return HookResult::error;
        }
        if (std::string_view (name) == "update" && JS_IsBool (result)) {
            const bool next = JS_ToBool (m_context, result) != 0;
            if (next != script.value->getBool ()) {
                script.value->update (next, DynamicValue::UpdateSource::Script);
            }
        }
        JS_FreeValue (m_context, result);
        return HookResult::success;
    }

    void applyUserProperties (
        PropertyScript& script,
        const std::map<std::string, WallpaperEngine::Audio::UserPropertyScalar>& properties
    ) {
        if (script.delaySecondsProperty.has_value ()
            && script.delayUserProperty.has_value ()) {
            if (const auto delay = properties.find (*script.delayUserProperty);
                delay != properties.end ()) {
                JSValue values = JS_NewObject (m_context);
                JSValue delayValue = userPropertyToJS (m_context, delay->second);
                JSValue delayString = JS_ToString (m_context, delayValue);
                JS_FreeValue (m_context, delayValue);
                JS_SetPropertyStr (
                    m_context, values, script.delaySecondsProperty->c_str (),
                    delayString
                );
                static_cast<void> (
                    callPropertyHook (script, "seedPrivate", 1, &values)
                );
                JS_FreeValue (m_context, values);
            }
        }
        JSValue argument = userPropertiesToJS (properties);
        const HookResult result = callPropertyHook (script, "apply", 1, &argument);
        JS_FreeValue (m_context, argument);
        if (result == HookResult::success) {
            ++script.propertyApplications;
            ++m_propertyScriptPropertyApplicationCount;
            refreshPrivateEvidence (script);
        }
    }

    double numericPropertyHook (PropertyScript& script, const char* name) {
        JSValue function = JS_GetPropertyStr (m_context, script.object, name);
        if (!JS_IsFunction (m_context, function)) {
            JS_FreeValue (m_context, function);
            return -1.0;
        }
        JSValue result = JS_Call (m_context, function, script.object, 0, nullptr);
        JS_FreeValue (m_context, function);
        double value = -1.0;
        if (JS_IsException (result)) {
            ++m_errorCount;
            ++m_propertyScriptErrorCount;
            logException (m_context, "private-property evidence");
        } else if (JS_ToFloat64 (m_context, &value, result) != 0
                   || !std::isfinite (value)) {
            value = -1.0;
        }
        JS_FreeValue (m_context, result);
        return value;
    }

    void refreshPrivateEvidence (PropertyScript& script) {
        if (!script.delaySecondsProperty.has_value ()) {
            return;
        }
        script.seededDelaySeconds = numericPropertyHook (script, "seededDelay");
        script.targetDelaySeconds = numericPropertyHook (script, "targetDelay");
    }

    void seedInitialPrivateProperties (PropertyScript& script) {
        if (!script.delaySecondsProperty.has_value ()
            || !script.delayUserProperty.has_value ()) {
            return;
        }
        if (const auto delay = m_initialUserProperties.find (*script.delayUserProperty);
            delay != m_initialUserProperties.end ()) {
            JSValue values = JS_NewObject (m_context);
            JSValue delayValue = userPropertyToJS (m_context, delay->second);
            JSValue delayString = JS_ToString (m_context, delayValue);
            JS_FreeValue (m_context, delayValue);
            JS_SetPropertyStr (
                m_context, values, script.delaySecondsProperty->c_str (), delayString
            );
            static_cast<void> (callPropertyHook (script, "seedPrivate", 1, &values));
            JS_FreeValue (m_context, values);
        }
        refreshPrivateEvidence (script);
    }

    void tickPropertyScripts () {
        if (m_propertyScripts.empty () || m_shutdown) {
            m_pendingUserProperties.clear ();
            return;
        }
        JSValue scene = JS_NewObject (m_context);
        JS_SetPropertyStr (
            m_context, scene, "time", JS_NewFloat64 (m_context, m_scene.getTime ())
        );
        JS_SetPropertyStr (
            m_context, scene, "dt", JS_NewFloat64 (m_context, m_scene.getDeltaTime ())
        );
        JS_SetPropertyStr (
            m_context, scene, "fps", JS_NewFloat64 (m_context, m_scene.getFps ())
        );
        JSValue global = JS_GetGlobalObject (m_context);
        JS_SetPropertyStr (m_context, global, "__frescoScene", scene);
        JS_FreeValue (m_context, global);

        for (auto& [key, script] : m_propertyScripts) {
            static_cast<void> (key);
            if (!script.initialized) {
                seedInitialPrivateProperties (script);
                const HookResult initialized = callPropertyHook (script, "init");
                script.initialized = true;
                if (initialized == HookResult::success) {
                    ++m_propertyScriptInitializationCount;
                }
                applyUserProperties (script, m_initialUserProperties);
            }
            if (!m_pendingUserProperties.empty ()) {
                applyUserProperties (script, m_pendingUserProperties);
            }
            JSValue argument = dynamicValueToJS (m_context, *script.value);
            const HookResult updated = callPropertyHook (
                script, "update", 1, &argument
            );
            JS_FreeValue (m_context, argument);
            if (updated == HookResult::success) {
                ++script.updates;
                ++m_propertyScriptUpdateCount;
            }
        }
        m_pendingUserProperties.clear ();
    }

    void refreshAudioAverage () {
        JSValue global = JS_GetGlobalObject (m_context);
        JS_SetPropertyStr (
            m_context, global, "__frescoAudioAverage0",
            JS_NewFloat64 (
                m_context,
                (m_recorder.audio16Left[0] + m_recorder.audio16Right[0]) * 0.5f
            )
        );
        JS_FreeValue (m_context, global);
    }

    void refreshAudioVector () {
        m_audioVectorSnapshot = FrescoScene::SceneAudioVectorSnapshot::fromStereo16 (
            m_recorder.audio16Left,
            m_recorder.audio16Right
        );
        JSValue vector = JS_NewArray (m_context);
        for (std::size_t index = 0;
             index < FrescoScene::sceneAudioVectorBins;
             ++index) {
            JS_SetPropertyUint32 (
                m_context,
                vector,
                static_cast<uint32_t> (index),
                JS_NewFloat64 (m_context, m_audioVectorSnapshot.average[index])
            );
        }
        JSValue global = JS_GetGlobalObject (m_context);
        JS_SetPropertyStr (m_context, global, "__frescoAudioAverage16", vector);
        JS_FreeValue (m_context, global);
    }

    bool controlSceneVideoTexture (int objectId, bool paused) {
        const auto* object = m_scene.getObject (objectId);
        const auto* renderable = dynamic_cast<
            const WallpaperEngine::Render::Objects::CRenderable*
        > (object);
        if (renderable == nullptr) {
            sLog.error (
                "getVideoTexture() layer object ", objectId,
                " is not an image layer"
            );
            return false;
        }
        const auto texture = renderable->getTexture ();
        if (texture == nullptr) {
            sLog.error (
                "getVideoTexture() layer object ", objectId,
                " has no texture provider"
            );
            return false;
        }
        const auto provider = static_cast<FrescoScene::VideoTextureProviderToken> (
            texture.get ()
        );
        const auto objectToken = static_cast<FrescoScene::VideoTextureObjectToken> (
            object
        );
        if (!m_videoTextureAdapters.contains (provider)) {
            const auto* videoTexture = dynamic_cast<
                const WallpaperEngine::Render::CTexture*
            > (texture.get ());
            if (videoTexture == nullptr || !videoTexture->isVideoTexture ()
                || videoTexture->getVideoPlayer () == nullptr) {
                static_cast<void> (
                    m_videoTextureControls.registerNonVideoTexture (provider)
                );
            } else {
                auto adapter
                    = std::make_unique<FrescoScene::GLPlayerVideoTextureControl> (
                        *videoTexture->getVideoPlayer ()
                    );
                static_cast<void> (m_videoTextureControls.registerVideoPlayer (
                    provider, adapter.get ()
                ));
                m_videoTextureAdapters.emplace (provider, std::move (adapter));
            }
        }
        static_cast<void> (m_videoTextureControls.registerObjectTexture (
            objectToken, provider
        ));
        std::string diagnostic;
        if (!FrescoScene::registerSceneVideoTextureObject (
                &m_scene, objectId, objectToken, diagnostic)) {
            sLog.error (diagnostic);
            return false;
        }
        if (!FrescoScene::setSceneVideoTexturePaused (
                &m_scene, objectId, paused, diagnostic)) {
            sLog.error (diagnostic);
            return false;
        }
        return true;
    }

    void initializeGraphPropertyScript (GenericPropertyScript& script) {
        if (script.graphInitialized || !usesSceneLayerGraph (script.profile)) {
            return;
        }
        JSValue function = JS_GetPropertyStr (
            m_context, script.object, "initialize"
        );
        JSValue argument = graphDynamicValueToJS (*script.value);
        JSValue result = JS_Call (
            m_context, function, script.object, 1, &argument
        );
        JS_FreeValue (m_context, argument);
        JS_FreeValue (m_context, function);
        if (JS_IsException (result)) {
            ++m_errorCount;
            ++m_genericPropertyScriptErrorCount;
            logException (m_context, "2D graph property initialization");
            JS_FreeValue (m_context, result);
            return;
        }
        if (!updateDynamicValueFromJS (m_context, result, *script.value)) {
            ++m_errorCount;
            ++m_genericPropertyScriptErrorCount;
            sLog.error (
                "SceneScript 2D graph initialization returned an incompatible value"
            );
            JS_FreeValue (m_context, result);
            return;
        }
        JS_FreeValue (m_context, result);
        script.graphInitialized = true;
        if (m_sceneLayerGraph != nullptr) {
            m_sceneLayerGraph->syncPropertyFromScene (
                script.objectId, script.propertyName
            );
        }
    }

    void tickGenericPropertyScript (GenericPropertyScript& script) {
        if (script.profile == "generic-audio-vector-transform-v1"
            || script.profile == "exact-tracked-audio-vector-transform-v1") {
            if (!script.audioVectorTransform.has_value ()) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                return;
            }
            const auto configurationError
                = script.audioVectorTransform->setConfiguration (
                    audioVectorConfiguration (*script.value)
                );
            if (configurationError
                != FrescoScene::SceneAudioVectorTransformError::none) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                sLog.error (
                    "SceneScript audio vector update failed: ",
                    FrescoScene::sceneAudioVectorTransformDiagnostic (
                        configurationError
                    )
                );
                return;
            }
            const auto sample = script.audioVectorTransform->update (
                m_audioVectorSnapshot,
                m_scene.getDeltaTime ()
            );
            if (!sample.has_value ()) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                sLog.error (
                    "SceneScript audio vector update failed: ",
                    FrescoScene::sceneAudioVectorTransformDiagnostic (
                        script.audioVectorTransform->error ()
                    )
                );
                return;
            }
            const glm::vec3 prior = script.value->getVec3 ();
            const glm::vec3 next (
                sample->vector[0], sample->vector[1], sample->vector[2]
            );
            if (next != prior) {
                script.value->update (next, DynamicValue::UpdateSource::Script);
                if (m_sceneLayerGraph != nullptr) {
                    m_sceneLayerGraph->syncPropertyFromScene (
                        script.objectId, script.propertyName
                    );
                }
                ++script.changes;
                ++m_audioVectorScriptChangeCount;
                ++m_genericPropertyScriptChangeCount;
                m_audioVectorContinuousRequired = true;
            }
            ++script.updates;
            ++m_audioVectorScriptUpdateCount;
            ++m_genericPropertyScriptUpdateCount;
            return;
        }
        if (script.profile == "generic-media-playback-visibility-v1"
            || script.profile == "generic-inert-comment-v1"
            || script.profile == "generic-inert-type-mismatch-v1"
            || script.profile
                == "generic-inert-local-animation-layer-click-v1"
            || script.profile == "generic-scene-camera-zoom-property-v1") {
            return;
        }
        if (script.profile == "generic-media-thumbnail-primary-color-v1") {
            if (!script.primaryColorTransition.has_value ()) {
                return;
            }
            const glm::vec4 prior = script.value->getVec4 ();
            const auto color = script.primaryColorTransition->advance (
                m_scene.getDeltaTime ()
            );
            const glm::vec4 next (color[0], color[1], color[2], prior.w);
            if (next != prior) {
                if (script.value->getType () == DynamicValue::Vec4) {
                    script.value->update (next, DynamicValue::UpdateSource::Script);
                } else {
                    script.value->update (
                        glm::vec3 (next), DynamicValue::UpdateSource::Script
                    );
                }
                ++script.changes;
                ++m_genericPropertyScriptChangeCount;
            }
            ++script.updates;
            ++m_genericPropertyScriptUpdateCount;
            return;
        }
        if (script.profile == "generic-media-thumbnail-animation-play-v1") {
            const glm::vec4 prior = script.value->getVec4 ();
            auto* animation = FrescoScene::dynamicValueAnimation (*script.value);
            if (animation == nullptr || !animation->supported ()) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                return;
            }
            animation->advance (m_scene.getDeltaTime ());
            ++m_genericPropertyScriptUpdateCount;
            if (script.value->getVec4 () != prior) {
                ++m_genericPropertyScriptChangeCount;
            }
            return;
        }
        if (script.profile == "generic-named-animation-double-click-v1") {
            bool changed = false;
            for (auto& target : script.namedAnimations) {
                const auto prior = numericDynamicValue (*target.value);
                target.animation->advance (m_scene.getDeltaTime ());
                changed = changed || numericDynamicValue (*target.value) != prior;
            }
            ++script.updates;
            ++m_genericPropertyScriptUpdateCount;
            if (changed) {
                ++script.changes;
                ++m_genericPropertyScriptChangeCount;
            }
            return;
        }
        JSValue properties = JS_NewObject (m_context);
        for (const auto& [name, property] : script.value->getProperties ()) {
            JS_SetPropertyStr (
                m_context, properties, name.c_str (),
                dynamicValueToJS (m_context, *property->value)
            );
        }
        JSValue setProperties = JS_GetPropertyStr (
            m_context, script.object, "setProperties"
        );
        JSValue setResult = JS_Call (
            m_context, setProperties, script.object, 1, &properties
        );
        JS_FreeValue (m_context, properties);
        JS_FreeValue (m_context, setProperties);
        if (JS_IsException (setResult)) {
            ++m_errorCount;
            ++m_genericPropertyScriptErrorCount;
            logException (m_context, "generic-property properties");
            JS_FreeValue (m_context, setResult);
            return;
        }
        JS_FreeValue (m_context, setResult);

        JSValue userProperties = sharedUserPropertiesJS ();
        JSValue setUserProperties = JS_GetPropertyStr (
            m_context, script.object, "setUserProperties"
        );
        JSValue setUserResult = JS_Call (
            m_context, setUserProperties, script.object, 1, &userProperties
        );
        JS_FreeValue (m_context, userProperties);
        JS_FreeValue (m_context, setUserProperties);
        if (JS_IsException (setUserResult)) {
            ++m_errorCount;
            ++m_genericPropertyScriptErrorCount;
            logException (m_context, "generic-property user properties");
            JS_FreeValue (m_context, setUserResult);
            return;
        }
        JS_FreeValue (m_context, setUserResult);

        if (script.profile.starts_with ("generic-cursor-")
            && !usesSceneLayerGraph (script.profile)) {
            JSValue position = JS_NewObject (m_context);
            JS_SetPropertyStr (
                m_context, position, "x", JS_NewFloat64 (m_context, m_cursorX)
            );
            JS_SetPropertyStr (
                m_context, position, "y", JS_NewFloat64 (m_context, m_cursorY)
            );
            JSValue setCursor = JS_GetPropertyStr (
                m_context, script.object, "setCursor"
            );
            JSValue cursorResult = JS_Call (
                m_context, setCursor, script.object, 1, &position
            );
            JS_FreeValue (m_context, position);
            JS_FreeValue (m_context, setCursor);
            if (JS_IsException (cursorResult)) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                logException (m_context, "generic-property cursor");
                JS_FreeValue (m_context, cursorResult);
                return;
            }
            JS_FreeValue (m_context, cursorResult);
        }

        const glm::vec4 prior = script.value->getVec4 ();
        JSValue tick = JS_GetPropertyStr (m_context, script.object, "tick");
        JSValue argument = usesSceneLayerGraph (script.profile)
            ? graphDynamicValueToJS (*script.value)
            : dynamicValueToJS (m_context, *script.value);
        JSValue result = JS_Call (
            m_context, tick, script.object, 1, &argument
        );
        JS_FreeValue (m_context, argument);
        JS_FreeValue (m_context, tick);
        if (JS_IsException (result)) {
            ++m_errorCount;
            ++m_genericPropertyScriptErrorCount;
            logException (m_context, "generic-property update");
            JS_FreeValue (m_context, result);
            return;
        }
        JSValue valueResult = result;
        bool ownsValueResult = false;
        bool frameChanged = false;
        std::string valueAnimationCommand;
        if (usesSceneLayerGraph (script.profile)) {
            valueResult = JS_GetPropertyStr (m_context, result, "value");
            ownsValueResult = true;
            JSValue animation = JS_GetPropertyStr (
                m_context, result, "animation"
            );
            const char* command = JS_ToCString (m_context, animation);
            if (command != nullptr) {
                valueAnimationCommand = command;
                JS_FreeCString (m_context, command);
            }
            JS_FreeValue (m_context, animation);
        } else if (script.profile == "generic-clock-texture-frame-v1") {
            valueResult = JS_GetPropertyStr (m_context, result, "value");
            ownsValueResult = true;
            JSValue frame = JS_GetPropertyStr (m_context, result, "frame");
            int32_t frameNumber = -1;
            if (JS_ToInt32 (m_context, &frameNumber, frame) != 0
                || frameNumber < 0) {
                JS_FreeValue (m_context, frame);
                JS_FreeValue (m_context, valueResult);
                JS_FreeValue (m_context, result);
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                sLog.error ("SceneScript texture-frame update returned an invalid frame");
                return;
            }
            JS_FreeValue (m_context, frame);
            frameChanged = FrescoScene::setScriptedTextureAnimationFrame (
                &m_scene, script.objectId, static_cast<uint32_t> (frameNumber)
            );
        } else if (script.profile == "generic-bounded-layer-drag-v1") {
            valueResult = JS_GetPropertyStr (m_context, result, "value");
            ownsValueResult = true;
            JSValue origin = JS_GetPropertyStr (m_context, result, "origin");
            float x = 0.0f;
            float y = 0.0f;
            float z = 0.0f;
            if (script.target == nullptr || !JS_IsObject (origin)
                || !finiteProperty (m_context, origin, "x", x)
                || !finiteProperty (m_context, origin, "y", y)
                || !finiteProperty (m_context, origin, "z", z)) {
                JS_FreeValue (m_context, origin);
                JS_FreeValue (m_context, valueResult);
                JS_FreeValue (m_context, result);
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                sLog.error ("SceneScript layer drag returned an invalid origin");
                return;
            }
            JS_FreeValue (m_context, origin);
            auto& targetOrigin = script.target->getProperty ("origin");
            const glm::vec3 next (x, y, z);
            if (next != targetOrigin.getVec3 ()) {
                targetOrigin.update (next, DynamicValue::UpdateSource::Script);
                frameChanged = true;
            }
        }
        if (script.profile == "generic-shared-state-value-v1") {
            const auto current = sharedValueFromDynamicValue (*script.value);
            if (!script.sharedField.has_value () || !current.has_value ()) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                sLog.error (
                    "SceneScript shared-state reader has an unsupported dependency"
                );
                JS_FreeValue (m_context, result);
                return;
            }
            JSValue hasSharedField = JS_GetPropertyStr (
                m_context, script.object, "hasSharedField"
            );
            JSValue field = JS_NewString (
                m_context, script.sharedField->c_str ()
            );
            JSValue ownResult = JS_Call (
                m_context, hasSharedField, script.object, 1, &field
            );
            JS_FreeValue (m_context, field);
            JS_FreeValue (m_context, hasSharedField);
            if (JS_IsException (ownResult)) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                logException (m_context, "generic-property shared dependency");
                JS_FreeValue (m_context, ownResult);
                JS_FreeValue (m_context, result);
                return;
            }
            const bool ownsField = JS_ToBool (m_context, ownResult) != 0;
            JS_FreeValue (m_context, ownResult);
            FrescoScene::SharedScriptState state;
            if (ownsField) {
                JSValue getSharedField = JS_GetPropertyStr (
                    m_context, script.object, "getSharedField"
                );
                JSValue sharedFieldName = JS_NewString (
                    m_context, script.sharedField->c_str ()
                );
                JSValue sharedFieldValue = JS_Call (
                    m_context, getSharedField, script.object, 1, &sharedFieldName
                );
                JS_FreeValue (m_context, sharedFieldName);
                JS_FreeValue (m_context, getSharedField);
                if (JS_IsException (sharedFieldValue)) {
                    ++m_errorCount;
                    ++m_genericPropertyScriptErrorCount;
                    logException (m_context, "generic-property shared value");
                    JS_FreeValue (m_context, sharedFieldValue);
                    JS_FreeValue (m_context, result);
                    return;
                }
                state.emplace (*script.sharedField, sharedValueFromJS (
                    m_context, sharedFieldValue
                ));
                JS_FreeValue (m_context, sharedFieldValue);
            }
            const auto dependency = FrescoScene::resolveSharedScriptDependency (
                state, sharedScriptSchema (), *script.sharedField, *current
            );
            if (dependency.status
                == FrescoScene::SharedDependencyStatus::deferred) {
                JS_FreeValue (m_context, result);
                return;
            }
            if (dependency.status
                != FrescoScene::SharedDependencyStatus::applied) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                sLog.error (
                    "SceneScript shared-state reader returned an incompatible value"
                );
                JS_FreeValue (m_context, result);
                return;
            }
        }
        if (!updateDynamicValueFromJS (m_context, valueResult, *script.value)) {
            ++m_errorCount;
            ++m_genericPropertyScriptErrorCount;
            sLog.error ("SceneScript generic-property update returned an incompatible value");
            if (ownsValueResult) {
                JS_FreeValue (m_context, valueResult);
            }
            JS_FreeValue (m_context, result);
            return;
        }
        if (ownsValueResult) {
            JS_FreeValue (m_context, valueResult);
        }
        JS_FreeValue (m_context, result);

        if (usesSceneLayerGraph (script.profile)) {
            if (m_sceneLayerGraph != nullptr) {
                m_sceneLayerGraph->syncPropertyFromScene (
                    script.objectId, script.propertyName
                );
            }
            if (!valueAnimationCommand.empty ()) {
                auto* animation = FrescoScene::dynamicValueAnimation (*script.value);
                if (animation == nullptr || !animation->supported ()) {
                    ++m_errorCount;
                    ++m_genericPropertyScriptErrorCount;
                    sLog.error (
                        "SceneScript value animation command targets a static value"
                    );
                    return;
                }
                if (valueAnimationCommand == "play") {
                    animation->play ();
                } else if (valueAnimationCommand == "restart") {
                    animation->restart ();
                } else if (valueAnimationCommand == "pause") {
                    animation->pause ();
                } else {
                    ++m_errorCount;
                    ++m_genericPropertyScriptErrorCount;
                    sLog.error (
                        "SceneScript requested an unsupported value animation command"
                    );
                    return;
                }
            }
        }

        if (script.profile == "generic-2d-camera-control-v1") {
            if (!script.camera2DControl.has_value ()
                || script.camera2DControl->zoom == nullptr
                || script.camera2DControl->zoom->value == nullptr
                || script.camera2DControl->zoom->value->getType ()
                    != DynamicValue::Float) {
                ++m_errorCount;
                ++m_genericPropertyScriptErrorCount;
                sLog.error ("2D camera control has an invalid zoom setting");
                return;
            }
            const auto origin = script.value->getVec3 ();
            frameChanged = FrescoScene::setCamera2DControl (
                m_scene, { origin.x, origin.y },
                script.camera2DControl->zoom->value->getFloat ()
            ) || frameChanged;
        }

        if (script.value->getVec4 () != prior || frameChanged) {
            ++script.changes;
            ++m_genericPropertyScriptChangeCount;
        }
        ++script.updates;
        ++m_genericPropertyScriptUpdateCount;
    }

    void tickDynamicFloat (DynamicFloat& dynamicFloat) {
        const float prior = dynamicFloat.value->getFloat ();
        JSValue tick = JS_GetPropertyStr (m_context, dynamicFloat.object, "tick");
        JSValue argument = JS_NewFloat64 (m_context, prior);
        JSValue result = JS_Call (
            m_context, tick, dynamicFloat.object, 1, &argument
        );
        JS_FreeValue (m_context, argument);
        JS_FreeValue (m_context, tick);
        if (JS_IsException (result)) {
            ++m_errorCount;
            logException (m_context, "dynamic-float update");
            JS_FreeValue (m_context, result);
            return;
        }

        double next = 0.0;
        if (JS_ToFloat64 (m_context, &next, result) < 0 || !std::isfinite (next)) {
            ++m_errorCount;
            sLog.error ("SceneScript dynamic-float update returned a non-finite number");
            JS_FreeValue (m_context, result);
            return;
        }
        JS_FreeValue (m_context, result);

        if (static_cast<float> (next) != prior) {
            dynamicFloat.value->update (
                static_cast<float> (next), DynamicValue::UpdateSource::Script
            );
            ++dynamicFloat.changes;
            ++m_dynamicFloatChangeCount;
        }
        ++dynamicFloat.updates;
        ++m_dynamicFloatUpdateCount;
    }

    FrescoScene::SceneScriptQuickJS m_quickJS;
    JSRuntime* m_runtime = nullptr;
    JSContext* m_context = nullptr;
    ScriptLayerHandle m_nextHandle = 1;
    WallpaperEngine::Audio::AudioContext& m_audio;
    Render::Wallpapers::CScene& m_scene;
    WallpaperEngine::Audio::Drivers::Recorders::PlaybackRecorder& m_recorder;
    FrescoScene::SceneAudioVectorSnapshot m_audioVectorSnapshot;
    FrescoScene::VideoTextureControlRegistry m_videoTextureControls;
    FrescoScene::SceneScriptStorage m_ephemeralStorage;
    FrescoScene::SceneScriptStorage *m_storage = &m_ephemeralStorage;
    std::map<
        FrescoScene::VideoTextureProviderToken,
        std::unique_ptr<FrescoScene::GLPlayerVideoTextureControl>
    > m_videoTextureAdapters;
    std::map<std::string, DynamicFloat> m_dynamicFloats;
    std::map<ScriptLayerHandle, Layer> m_layers;
    std::map<std::string, PropertyScript> m_propertyScripts;
    std::map<std::string, GenericPropertyScript> m_genericPropertyScripts;
    std::map<std::string, PendingLocalAnimationLayerScript>
        m_pendingLocalAnimationLayerScripts;
    std::multimap<int, std::string> m_rejectedLocalAnimationLayerScripts;
    std::vector<std::string> m_sceneLayerGraphOrder;
    std::unique_ptr<FrescoScene::SceneScriptLayerGraph> m_sceneLayerGraph;
    std::map<std::string, CursorScript> m_cursorScripts;
    std::set<std::string> m_deferredScriptKeys;
    std::map<std::string, WallpaperEngine::Audio::UserPropertyScalar>
        m_initialUserProperties;
    std::map<std::string, WallpaperEngine::Audio::UserPropertyScalar>
        m_pendingUserProperties;
    // Undefined until built; see sharedUserPropertiesJS.
    JSValue m_userPropertiesJS = JS_UNDEFINED;
    std::size_t m_dynamicFloatUpdateCount = 0;
    std::size_t m_dynamicFloatChangeCount = 0;
    std::size_t m_updateCount = 0;
    std::size_t m_textChangeCount = 0;
    std::size_t m_mediaPropertyScriptDispatches = 0;
    std::size_t m_mediaPlaybackScriptDispatches = 0;
    std::size_t m_mediaTimelineScriptDispatches = 0;
    std::size_t m_mediaThumbnailScriptDispatches = 0;
    std::size_t m_mediaPropertyScriptErrors = 0;
    std::size_t m_errorCount = 0;
    std::size_t m_propertyScriptInitializationCount = 0;
    std::size_t m_propertyScriptPropertyApplicationCount = 0;
    std::size_t m_propertyScriptUpdateCount = 0;
    std::size_t m_propertyScriptErrorCount = 0;
    std::size_t m_genericPropertyScriptUpdateCount = 0;
    std::size_t m_genericPropertyScriptChangeCount = 0;
    std::size_t m_genericPropertyScriptErrorCount = 0;
    std::size_t m_audioVectorScriptUpdateCount = 0;
    std::size_t m_audioVectorScriptChangeCount = 0;
    bool m_audioVectorContinuousRequired = false;
    std::size_t m_namedAnimationTargetPlayCount = 0;
    std::size_t m_nextEffectScriptId = 1;
    float m_cursorX = 0.0f;
    float m_cursorY = 0.0f;
    bool m_shutdown = false;
    bool m_storageRejectionReported = false;
};

ScriptEngine::ScriptEngine (
    Render::Wallpapers::CScene& scene, Media::MediaSource& mediaSource
) : m_impl (std::make_unique<Impl> (scene, mediaSource)) { }

ScriptEngine::~ScriptEngine () = default;

void ScriptEngine::queueScript (
    const std::string& key, DynamicValue& value, ScriptableObject& object
) {
    const auto& source = value.getScriptSource ();
    if (source.has_value ()) {
        if (FrescoScene::isTextLayerOwnedPropertyScript (
                key,
                sceneScriptValueKind (value),
                object.getObject ().is<Text> (),
                object.getId ())) {
            return;
        }
        m_impl->createPropertyScript (key, value, object.getId (), *source, &object);
    }
}

void ScriptEngine::queuePropertyScript (
    const std::string& key, DynamicValue& value, int objectId
) {
    const auto& source = value.getScriptSource ();
    if (source.has_value ()) {
        m_impl->createPropertyScript (key, value, objectId, *source);
    }
}

void ScriptEngine::queueAudioFloatScript (
    const std::string& key, DynamicValue& value
) {
    const auto& source = value.getScriptSource ();
    if (value.getType () != DynamicValue::Float || !source.has_value ()
        || !FrescoScene::supportsMonoAudioAverageTransform (*source)) {
        return;
    }
    m_impl->createDynamicFloat (key, value, *source);
}

void ScriptEngine::queueEffectScript (DynamicValue& value, int objectId) {
    m_impl->queueEffectScript (value, objectId);
}

void ScriptEngine::tick () { m_impl->tick (); }

void ScriptEngine::shutdown () { m_impl->shutdown (); }

void ScriptEngine::setInitialUserProperties (
    const WallpaperEngine::Audio::UserPropertyBatch& properties
) {
    m_impl->setInitialUserProperties (properties);
}

void ScriptEngine::setUserProperties (
    const WallpaperEngine::Audio::UserPropertyBatch& properties
) {
    m_impl->setUserProperties (properties);
}

void ScriptEngine::applyPendingUserProperties () {
    m_impl->applyPendingUserProperties ();
}

void ScriptEngine::setMediaProperties (
    const std::string& title,
    const std::string& artist,
    const std::string& album
) {
    m_impl->setMediaProperties (title, artist, album);
}

void ScriptEngine::mediaPlaybackChanged (int state) {
    m_impl->mediaPlaybackChanged (state);
}

void ScriptEngine::mediaTimelineChanged (double position, double duration) {
    m_impl->mediaTimelineChanged (position, duration);
}

void ScriptEngine::mediaThumbnailChanged (
    std::string_view primaryColor,
    std::string_view secondaryColor,
    std::string_view tertiaryColor,
    std::string_view textColor,
    std::string_view highContrastColor
) {
    m_impl->mediaThumbnailChanged (
        primaryColor, secondaryColor, tertiaryColor, textColor,
        highContrastColor
    );
}

bool ScriptEngine::cursorClick (
    int objectId, std::optional<double> monotonicMilliseconds
) {
    return m_impl->cursorClick (objectId, monotonicMilliseconds);
}

std::size_t ScriptEngine::cursorEvent (
    std::string_view name, float x, float y
) {
    return m_impl->cursorEvent (name, x, y);
}

ScriptLayerHandle ScriptEngine::createLayerScript (
    const std::string& source,
    std::map<std::string, std::unique_ptr<UserSetting>>& properties,
    const std::string& initialText
) {
    return m_impl->createLayer (source, properties, initialText);
}

void ScriptEngine::tickLayer (
    ScriptLayerHandle handle, double time, double deltaTime, double fps
) {
    m_impl->tickLayer (handle, time, deltaTime, fps);
}

std::string ScriptEngine::layerText (ScriptLayerHandle handle) {
    return m_impl->layerText (handle);
}

void ScriptEngine::destroyLayer (ScriptLayerHandle handle) {
    m_impl->destroyLayer (handle);
}

std::size_t ScriptEngine::layerCount () const { return m_impl->layerCount (); }

std::size_t ScriptEngine::updateCount () const { return m_impl->updateCount (); }

std::size_t ScriptEngine::textChangeCount () const {
    return m_impl->textChangeCount ();
}

std::size_t ScriptEngine::mediaPropertyScriptCount () const {
    return m_impl->mediaPropertyScriptCount ();
}

std::size_t ScriptEngine::mediaPropertyScriptDispatchCount () const {
    return m_impl->mediaPropertyScriptDispatchCount ();
}

std::size_t ScriptEngine::mediaPlaybackScriptDispatchCount () const {
    return m_impl->mediaPlaybackScriptDispatchCount ();
}

std::size_t ScriptEngine::mediaTimelineScriptDispatchCount () const {
    return m_impl->mediaTimelineScriptDispatchCount ();
}

std::size_t ScriptEngine::mediaThumbnailScriptDispatchCount () const {
    return m_impl->mediaThumbnailScriptDispatchCount ();
}

std::size_t ScriptEngine::mediaPropertyScriptErrorCount () const {
    return m_impl->mediaPropertyScriptErrorCount ();
}

std::vector<ScriptEngine::DynamicFloatEvidence>
ScriptEngine::dynamicFloatEvidence () const {
    return m_impl->dynamicFloatEvidence ();
}

std::size_t ScriptEngine::dynamicFloatUpdateCount () const {
    return m_impl->dynamicFloatUpdateCount ();
}

std::size_t ScriptEngine::dynamicFloatChangeCount () const {
    return m_impl->dynamicFloatChangeCount ();
}

std::size_t ScriptEngine::errorCount () const { return m_impl->errorCount (); }

std::vector<ScriptEngine::PropertyScriptEvidence>
ScriptEngine::propertyScriptEvidence () const {
    return m_impl->propertyScriptEvidence ();
}

std::size_t ScriptEngine::propertyScriptInitializationCount () const {
    return m_impl->propertyScriptInitializationCount ();
}

std::size_t ScriptEngine::propertyScriptPropertyApplicationCount () const {
    return m_impl->propertyScriptPropertyApplicationCount ();
}

std::size_t ScriptEngine::propertyScriptUpdateCount () const {
    return m_impl->propertyScriptUpdateCount ();
}

std::size_t ScriptEngine::propertyScriptErrorCount () const {
    return m_impl->propertyScriptErrorCount ();
}

std::size_t ScriptEngine::propertyScriptCount () const {
    return m_impl->propertyScriptCount ();
}

std::vector<ScriptEngine::GenericPropertyScriptEvidence>
ScriptEngine::genericPropertyScriptEvidence () const {
    return m_impl->genericPropertyScriptEvidence ();
}

std::size_t ScriptEngine::genericPropertyScriptCount () const {
    return m_impl->genericPropertyScriptCount ();
}

std::size_t ScriptEngine::continuousGenericPropertyScriptCount () const {
    return m_impl->continuousGenericPropertyScriptCount ();
}

std::size_t ScriptEngine::genericPropertyScriptUpdateCount () const {
    return m_impl->genericPropertyScriptUpdateCount ();
}

std::size_t ScriptEngine::genericPropertyScriptChangeCount () const {
    return m_impl->genericPropertyScriptChangeCount ();
}

std::size_t ScriptEngine::genericPropertyScriptErrorCount () const {
    return m_impl->genericPropertyScriptErrorCount ();
}

std::size_t ScriptEngine::audioVectorScriptCount () const {
    return m_impl->audioVectorScriptCount ();
}

std::size_t ScriptEngine::exactTrackedAudioVectorScriptCount () const {
    return m_impl->exactTrackedAudioVectorScriptCount ();
}

std::optional<float> ScriptEngine::audioVectorValueX () const {
    return m_impl->audioVectorValueX ();
}

std::size_t ScriptEngine::audioVectorScriptUpdateCount () const {
    return m_impl->audioVectorScriptUpdateCount ();
}

std::size_t ScriptEngine::audioVectorScriptChangeCount () const {
    return m_impl->audioVectorScriptChangeCount ();
}

bool ScriptEngine::audioVectorContinuousRequired () const {
    return m_impl->audioVectorContinuousRequired ();
}

std::size_t ScriptEngine::namedAnimationTargetPlayCount () const {
    return m_impl->namedAnimationTargetPlayCount ();
}

std::size_t ScriptEngine::namedAnimationActiveCount () const {
    return m_impl->namedAnimationActiveCount ();
}

double ScriptEngine::namedAnimationFrameTotal () const {
    return m_impl->namedAnimationFrameTotal ();
}

std::size_t ScriptEngine::cursorScriptCount () const {
    return m_impl->cursorScriptCount ();
}

std::size_t ScriptEngine::deferredScriptCount () const {
    return m_impl->deferredScriptCount ();
}

FrescoScene::SceneScriptTimerEvidence ScriptEngine::timerEvidence () const {
    return m_impl->timerEvidence ();
}

bool ScriptEngine::acceptsUserProperty (std::string_view key) const {
    return m_impl->acceptsUserProperty (key);
}
