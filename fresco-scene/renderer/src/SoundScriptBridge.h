#pragma once

#include <quickjs.h>

namespace WallpaperEngine::Audio {
class AudioContext;
}

namespace FrescoScene {

void installSoundScriptBridge (
    JSContext* context,
    WallpaperEngine::Audio::AudioContext& audio
);

}
