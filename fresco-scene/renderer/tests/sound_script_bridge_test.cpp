#include "SoundScriptBridge.h"
#include "WallpaperEngine/Audio/AudioContext.h"

#include <quickjs.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

using namespace WallpaperEngine::Audio;

namespace {

void requireAt (bool condition, int line) {
    if (!condition) {
        std::fprintf (stderr, "sound script bridge assertion failed at line %d\n", line);
        std::abort ();
    }
}

#define require(condition) requireAt ((condition), __LINE__)

struct PlayerRecord {
    bool playing = false;
    bool looping = false;
    float volume = -1.0F;
    int plays = 0;
    int pauses = 0;
    int stops = 0;
};

struct BackendState {
    int constructions = 0;
    std::vector<std::shared_ptr<PlayerRecord>> players;
};

class FakePlayer final : public SoundPlayer {
public:
    explicit FakePlayer (std::shared_ptr<PlayerRecord> player)
        : record (std::move (player)) { }

    bool play () override {
        record->playing = true;
        ++record->plays;
        return true;
    }
    void pause () override {
        record->playing = false;
        ++record->pauses;
    }
    void stop () override {
        record->playing = false;
        ++record->stops;
    }
    [[nodiscard]] bool isPlaying () const override { return record->playing; }
    void setLooping (bool looping) override { record->looping = looping; }
    void setVolume (float volume) override { record->volume = volume; }

private:
    std::shared_ptr<PlayerRecord> record;
};

class FakeBackend final : public SoundBackend {
public:
    explicit FakeBackend (std::shared_ptr<BackendState> backend)
        : state (std::move (backend)) { }

    std::unique_ptr<SoundPlayer> createPlayer (
        const std::vector<std::uint8_t>& data
    ) override {
        require (!data.empty ());
        auto record = std::make_shared<PlayerRecord> ();
        state->players.push_back (record);
        ++state->constructions;
        return std::make_unique<FakePlayer> (std::move (record));
    }

private:
    std::shared_ptr<BackendState> state;
};

JSValue evaluate (JSContext* context, const std::string& source) {
    return JS_Eval (
        context,
        source.c_str (),
        source.size (),
        "<sound-bridge-test>",
        JS_EVAL_TYPE_GLOBAL
    );
}

bool evaluateBool (JSContext* context, const std::string& source) {
    JSValue result = evaluate (context, source);
    require (!JS_IsException (result));
    const int value = JS_ToBool (context, result);
    JS_FreeValue (context, result);
    require (value >= 0);
    return value != 0;
}

void requireException (JSContext* context, const std::string& source) {
    JSValue result = evaluate (context, source);
    require (JS_IsException (result));
    JS_FreeValue (context, result);
    JSValue exception = JS_GetException (context);
    JS_FreeValue (context, exception);
}

void install (JSContext* context, AudioContext& audio) {
    FrescoScene::installSoundScriptBridge (context, audio);
    JSValue result = evaluate (
        context,
        "globalThis.thisScene = { getLayer(key) { "
        "return globalThis.__frescoGetSoundLayer(key); } };"
    );
    require (!JS_IsException (result));
    JS_FreeValue (context, result);
}

SoundAssetLoader loader () {
    return [] (const std::string&) {
        return std::vector<std::uint8_t> { 1, 2, 3 };
    };
}

}

int main () {
    auto state = std::make_shared<BackendState> ();
    AudioContext audio (std::make_unique<FakeBackend> (state));
    audio.setSoundMetadata ({
        { .id = 100, .name = "primary", .startSilent = true, .volume = 0.5F,
          .layerIndex = 2 },
        { .id = 200, .name = "duplicate", .startSilent = false, .volume = 0.75F,
          .layerIndex = 5 },
        { .id = 300, .name = "200", .startSilent = false, .volume = 0.25F,
          .layerIndex = 7 },
        { .id = 400, .name = "duplicate", .startSilent = true, .volume = 0.9F,
          .layerIndex = 8 },
    });

    JSRuntime* runtime = JS_NewRuntime ();
    require (runtime != nullptr);
    JSContext* context = JS_NewContext (runtime);
    require (context != nullptr);
    install (context, audio);

    require (evaluateBool (context,
        "const early = thisScene.getLayer('primary');"
        "early !== null && early.volume === 0.5"
    ));
    require (evaluateBool (context,
        "thisScene.getLayer(2).volume === 0.5"
        " && thisScene.getLayer(5).volume === 0.75"
        " && thisScene.getLayer(7).volume === 0.25"
    ));
    require (evaluateBool (context,
        "thisScene.getLayer(100) === null"
        " && thisScene.getLayer(-1) === null"
        " && thisScene.getLayer(2.5) === null"
        " && thisScene.getLayer(3) === null"
        " && thisScene.getLayer(99) === null"
        " && thisScene.getLayer('duplicate') === null"
        " && thisScene.getLayer('missing') === null"
    ));
    require (evaluateBool (context,
        "thisScene.getLayer('200').volume === 0.25"
    ));
    require (evaluateBool (context,
        "Object.getOwnPropertyNames(early).sort().join(',') === "
        "'isPlaying,pause,play,stop,volume'"
        " && !('id' in early) && !('name' in early)"
    ));

    require (evaluateBool (context,
        "early.play() === undefined && early.pause() === undefined"
        " && early.play() === undefined && early.isPlaying() === true"
        " && thisScene.getLayer(5).play() === undefined"
        " && thisScene.getLayer(5).pause() === undefined"
        " && thisScene.getLayer('200').play() === undefined"
        " && thisScene.getLayer('200').stop() === undefined"
    ));
    require (evaluateBool (context,
        "(early.volume = Number.MAX_VALUE, early.volume === 1)"
    ));
    require (audio.soundVolume (100) == 1.0F);
    requireException (context, "early.volume = '0.5'");
    requireException (context, "early.volume = true");
    requireException (context, "early.volume = NaN");
    require (audio.soundVolume (100) == 1.0F);

    audio.registerSound (
        100, "ignored", SoundPlaybackMode::loop, { "one.mp3" }, loader ()
    );
    audio.registerSound (
        200, "ignored", SoundPlaybackMode::loop, { "two.mp3" }, loader ()
    );
    audio.registerSound (
        300, "ignored", SoundPlaybackMode::loop, { "three.mp3" }, loader ()
    );
    require (state->constructions == 1);
    require (audio.soundVolume (100) == 1.0F);
    require (audio.isSoundPlaying (100));
    require (!audio.isSoundPlaying (200));
    require (!audio.isSoundPlaying (300));
    require (evaluateBool (context,
        "early.play() === undefined && early.isPlaying() === true"
    ));
    require (state->constructions == 1);
    require (state->players[0]->plays == 1);
    require (state->players[0]->volume == 0.0F);
    require (evaluateBool (context, "early.play() === undefined"));
    require (state->players[0]->plays == 1);

    audio.setMuted (false);
    require (state->players[0]->volume == 1.0F);
    require (evaluateBool (context,
        "(early.volume = 0.25, early.volume === 0.25)"
    ));
    require (std::abs (state->players[0]->volume - 0.25F) < 0.0001F);
    audio.setMuted (true);
    require (evaluateBool (context,
        "(early.volume = 0.75, early.volume === 0.75)"
    ));
    require (state->players[0]->volume == 0.0F);
    audio.setMuted (false);
    require (std::abs (state->players[0]->volume - 0.75F) < 0.0001F);

    require (evaluateBool (context,
        "early.pause() === undefined && early.isPlaying() === false"
    ));
    audio.pauseAllSounds ();
    require (evaluateBool (context, "early.play() === undefined"));
    require (state->players[0]->plays == 1);
    require (evaluateBool (context, "early.pause() === undefined"));
    audio.resumeAllSounds ();
    require (state->players[0]->plays == 1);
    audio.pauseAllSounds ();
    require (evaluateBool (context, "early.play() === undefined"));
    audio.resumeAllSounds ();
    require (state->players[0]->plays == 2);
    audio.pauseAllSounds ();
    require (evaluateBool (context,
        "early.play() === undefined && early.stop() === undefined"
    ));
    audio.resumeAllSounds ();
    require (state->players[0]->plays == 2);
    require (state->players[0]->stops == 1);

    JS_FreeContext (context);
    JS_FreeRuntime (runtime);

    AudioContext disabled (nullptr);
    disabled.setSoundMetadata ({
        { .id = 9, .name = "disabled", .startSilent = true, .volume = 0.5F,
          .layerIndex = 1 },
    });
    disabled.registerSound (
        9, "disabled", SoundPlaybackMode::single, { "disabled.mp3" }, loader ()
    );
    runtime = JS_NewRuntime ();
    context = JS_NewContext (runtime);
    install (context, disabled);
    require (evaluateBool (context,
        "const layer = thisScene.getLayer(1);"
        "layer.play() === undefined && layer.isPlaying() === true"
        " && (layer.volume = -2, layer.volume === 0)"
    ));
    require (disabled.constructedPlayerCount () == 0);
    JS_FreeContext (context);
    JS_FreeRuntime (runtime);
}
