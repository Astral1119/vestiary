#include "SoundScriptBridge.h"

#include "WallpaperEngine/Audio/AudioContext.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

using WallpaperEngine::Audio::AudioContext;

namespace {

struct SoundLayerHandle {
    AudioContext* audio;
    int id;
};

JSClassID soundLayerClass = 0;

SoundLayerHandle* soundLayer (JSContext* context, JSValueConst value) {
    return static_cast<SoundLayerHandle*> (
        JS_GetOpaque2 (context, value, soundLayerClass)
    );
}

void finalizeSoundLayer (JSRuntime*, JSValue value) {
    delete static_cast<SoundLayerHandle*> (
        JS_GetOpaque (value, soundLayerClass)
    );
}

JSValue getVolume (JSContext* context, JSValueConst thisValue) {
    const auto* layer = soundLayer (context, thisValue);
    if (layer == nullptr) {
        return JS_EXCEPTION;
    }
    const auto volume = layer->audio->soundVolume (layer->id);
    return volume.has_value () ? JS_NewFloat64 (context, *volume) : JS_UNDEFINED;
}

JSValue setVolume (
    JSContext* context,
    JSValueConst thisValue,
    JSValueConst value
) {
    auto* layer = soundLayer (context, thisValue);
    if (layer == nullptr) {
        return JS_EXCEPTION;
    }
    if (!JS_IsNumber (value)) {
        return JS_ThrowTypeError (context, "sound volume must be a number");
    }
    double volume = 0.0;
    if (JS_ToFloat64 (context, &volume, value) < 0) {
        return JS_EXCEPTION;
    }
    if (!std::isfinite (volume)) {
        return JS_ThrowRangeError (context, "sound volume must be finite");
    }
    layer->audio->setSoundVolume (
        layer->id,
        static_cast<float> (std::clamp (volume, 0.0, 1.0))
    );
    return JS_UNDEFINED;
}

JSValue play (
    JSContext* context,
    JSValueConst thisValue,
    int,
    JSValueConst*
) {
    auto* layer = soundLayer (context, thisValue);
    if (layer == nullptr) {
        return JS_EXCEPTION;
    }
    layer->audio->playSound (layer->id);
    return JS_UNDEFINED;
}

JSValue pause (
    JSContext* context,
    JSValueConst thisValue,
    int,
    JSValueConst*
) {
    auto* layer = soundLayer (context, thisValue);
    if (layer == nullptr) {
        return JS_EXCEPTION;
    }
    layer->audio->pauseSound (layer->id);
    return JS_UNDEFINED;
}

JSValue stop (
    JSContext* context,
    JSValueConst thisValue,
    int,
    JSValueConst*
) {
    auto* layer = soundLayer (context, thisValue);
    if (layer == nullptr) {
        return JS_EXCEPTION;
    }
    layer->audio->stopSound (layer->id);
    return JS_UNDEFINED;
}

JSValue isPlaying (
    JSContext* context,
    JSValueConst thisValue,
    int,
    JSValueConst*
) {
    const auto* layer = soundLayer (context, thisValue);
    if (layer == nullptr) {
        return JS_EXCEPTION;
    }
    return JS_NewBool (context, layer->audio->isSoundPlaying (layer->id));
}

constexpr JSCFunctionListEntry soundLayerFunctions[] = {
    JS_CGETSET_DEF ("volume", getVolume, setVolume),
    JS_CFUNC_DEF ("play", 0, play),
    JS_CFUNC_DEF ("pause", 0, pause),
    JS_CFUNC_DEF ("stop", 0, stop),
    JS_CFUNC_DEF ("isPlaying", 0, isPlaying),
};

JSValue makeSoundLayer (JSContext* context, AudioContext& audio, int id) {
    JSValue result = JS_NewObjectClass (context, soundLayerClass);
    if (JS_IsException (result)) {
        return result;
    }
    auto* handle = new SoundLayerHandle { .audio = &audio, .id = id };
    JS_SetOpaque (result, handle);
    JS_SetPropertyFunctionList (
        context,
        result,
        soundLayerFunctions,
        sizeof (soundLayerFunctions) / sizeof (soundLayerFunctions[0])
    );
    return result;
}

JSValue getSoundLayer (
    JSContext* context,
    JSValueConst,
    int argumentCount,
    JSValueConst* arguments,
    int,
    JSValue* functionData
) {
    int64_t address = 0;
    if (JS_ToInt64 (context, &address, functionData[0]) < 0) {
        return JS_EXCEPTION;
    }
    auto* audio = reinterpret_cast<AudioContext*> (static_cast<intptr_t> (address));
    if (argumentCount < 1) {
        return JS_NULL;
    }

    std::optional<int> id;
    if (JS_IsString (arguments[0])) {
        const char* name = JS_ToCString (context, arguments[0]);
        if (name == nullptr) {
            return JS_EXCEPTION;
        }
        id = audio->soundLayerId (name);
        JS_FreeCString (context, name);
    } else if (JS_IsNumber (arguments[0])) {
        double numericID = 0.0;
        if (JS_ToFloat64 (context, &numericID, arguments[0]) < 0) {
            return JS_EXCEPTION;
        }
        if (std::isfinite (numericID)
            && std::trunc (numericID) == numericID
            && numericID >= 0.0
            && numericID <= std::numeric_limits<int>::max ()) {
            id = audio->soundLayerIdAtIndex (
                static_cast<std::size_t> (numericID)
            );
        }
    }
    return id.has_value () ? makeSoundLayer (context, *audio, *id) : JS_NULL;
}

}

void FrescoScene::installSoundScriptBridge (
    JSContext* context,
    AudioContext& audio
) {
    if (soundLayerClass == 0) {
        JS_NewClassID (JS_GetRuntime (context), &soundLayerClass);
    }
    JSClassDef definition = {
        .class_name = "ISoundLayer",
        .finalizer = finalizeSoundLayer,
    };
    if (JS_NewClass (JS_GetRuntime (context), soundLayerClass, &definition) < 0) {
        JS_ThrowInternalError (context, "cannot register ISoundLayer");
        return;
    }

    JSValue address = JS_NewInt64 (
        context,
        static_cast<int64_t> (reinterpret_cast<intptr_t> (&audio))
    );
    JSValue lookup = JS_NewCFunctionData (
        context, getSoundLayer, 1, 0, 1, &address
    );
    JS_FreeValue (context, address);
    JSValue global = JS_GetGlobalObject (context);
    JS_SetPropertyStr (context, global, "__frescoGetSoundLayer", lookup);
    JS_FreeValue (context, global);
}
