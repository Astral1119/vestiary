#include "WallpaperEngine/Audio/AudioContext.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <memory>
#include <limits>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using namespace WallpaperEngine::Audio;

namespace {

void require (bool condition) {
    if (!condition) {
        std::abort ();
    }
}

struct PlayerRecord {
    bool looping = false;
    float volume = -1.0F;
    bool playing = false;
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
    explicit FakePlayer (std::shared_ptr<PlayerRecord> player) : record (std::move (player)) { }

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
    explicit FakeBackend (std::shared_ptr<BackendState> backendState)
        : state (std::move (backendState)) { }

    std::unique_ptr<SoundPlayer> createPlayer (
        const std::vector<std::uint8_t>& data
    ) override {
        require (!data.empty ());
        ++state->constructions;
        auto record = std::make_shared<PlayerRecord> ();
        state->players.push_back (record);
        return std::make_unique<FakePlayer> (std::move (record));
    }

private:
    std::shared_ptr<BackendState> state;
};

SoundAssetLoader loader (int& loads) {
    return [&loads] (const std::string&) {
        ++loads;
        return std::vector<std::uint8_t> { 1, 2, 3 };
    };
}

}

int main () {
    require (parseSoundPlaybackMode (std::nullopt) == SoundPlaybackMode::single);
    require (parseSoundPlaybackMode ("single") == SoundPlaybackMode::single);
    require (parseSoundPlaybackMode ("loop") == SoundPlaybackMode::loop);
    require (parseSoundPlaybackMode ("random") == SoundPlaybackMode::random);

    auto sequenceState = std::make_shared<BackendState> ();
    AudioContext sequenceAudio (
        std::make_unique<FakeBackend> (sequenceState), 0x5eedU
    );
    sequenceAudio.setSoundMetadata ({
        { .id = 10, .name = "Persona shuffle", .startSilent = true, .volume = 0.6F,
          .volumeUserKey = "musicvolume", .volumeFallback = 0.6F },
        { .id = 20, .name = "Arknights random", .startSilent = true, .volume = 0.8F },
        { .id = 30, .name = "GBC voice", .startSilent = true, .volume = 1.0F },
    });
    std::vector<std::string> sequenceLoads;
    const auto recordingLoader = [&sequenceLoads] (const std::string& path) {
        sequenceLoads.push_back (path);
        return std::vector<std::uint8_t> { 1, 2, 3 };
    };
    std::vector<std::string> personaAssets;
    for (int index = 0; index < 16; ++index) {
        personaAssets.push_back ("persona-" + std::to_string (index) + ".ogg");
    }
    sequenceAudio.registerSound (
        10, "Persona shuffle", SoundPlaybackMode::loop,
        personaAssets, recordingLoader
    );
    require (sequenceLoads.empty ());
    require (sequenceAudio.playSound (10));
    require (sequenceLoads.size () == 1);
    require (!sequenceState->players.back ()->looping);
    require (sequenceState->players.back ()->volume == 0.0F);
    sequenceAudio.setMuted (false);
    require (std::abs (sequenceState->players.back ()->volume - 0.6F) < 0.0001F);
    sequenceAudio.pauseAllSounds ();
    require (!sequenceState->players.back ()->playing);
    sequenceAudio.updatePlayback ();
    require (sequenceLoads.size () == 1);
    sequenceAudio.resumeAllSounds ();
    require (sequenceState->players.back ()->playing);
    const auto sequenceVolume = sequenceAudio.setUserProperties ({
        .values = { { "musicvolume", 0.25 } }, .received = 1,
    });
    require (sequenceVolume.appliedSoundLayers == 1);
    require (std::abs (sequenceState->players.back ()->volume - 0.25F) < 0.0001F);
    sequenceAudio.setMuted (true);
    require (sequenceState->players.back ()->volume == 0.0F);
    sequenceAudio.setMuted (false);
    require (std::abs (sequenceState->players.back ()->volume - 0.25F) < 0.0001F);
    for (int completion = 0; completion < 16; ++completion) {
        sequenceState->players.back ()->playing = false;
        sequenceAudio.updatePlayback ();
    }
    require (sequenceLoads.size () == 17);
    std::vector<std::string> firstCycle (
        sequenceLoads.begin (), sequenceLoads.begin () + 16
    );
    std::vector<std::string> sortedPersonaAssets = personaAssets;
    std::sort (firstCycle.begin (), firstCycle.end ());
    std::sort (sortedPersonaAssets.begin (), sortedPersonaAssets.end ());
    require (firstCycle == sortedPersonaAssets);
    require (sequenceLoads[15] != sequenceLoads[16]);
    require (sequenceAudio.isSoundPlaying (10));
    const std::vector<std::string> expectedSequence = sequenceLoads;

    sequenceAudio.registerSound (
        20, "Arknights random", SoundPlaybackMode::random,
        { "one.flac", "two.flac", "three.flac" }, recordingLoader
    );
    require (sequenceAudio.playSound (20));
    const std::string firstRandom = sequenceLoads.back ();
    require (firstRandom == "one.flac" || firstRandom == "two.flac"
             || firstRandom == "three.flac");
    sequenceState->players.back ()->playing = false;
    sequenceAudio.updatePlayback ();
    require (!sequenceAudio.isSoundPlaying (20));
    require (sequenceAudio.playSound (20));
    const std::size_t randomLoadsBeforeStop = sequenceLoads.size ();
    sequenceAudio.stopSound (20);
    require (sequenceAudio.playSound (20));
    require (sequenceLoads.size () == randomLoadsBeforeStop + 1);
    std::set<std::string> selectedRandomAssets { firstRandom, sequenceLoads.back () };
    for (int selection = 0; selection < 32; ++selection) {
        sequenceAudio.stopSound (20);
        require (sequenceAudio.playSound (20));
        selectedRandomAssets.insert (sequenceLoads.back ());
    }
    require (selectedRandomAssets == std::set<std::string> ({
        "one.flac", "two.flac", "three.flac",
    }));

    sequenceAudio.registerSound (
        30, "GBC voice", SoundPlaybackMode::single,
        { "voice.mp3" }, recordingLoader
    );
    require (sequenceAudio.playSound (30));
    const std::size_t firstVoiceLoad = sequenceLoads.size ();
    sequenceState->players.back ()->playing = false;
    sequenceAudio.updatePlayback ();
    require (!sequenceAudio.isSoundPlaying (30));
    require (sequenceAudio.playSound (30));
    require (sequenceLoads.size () == firstVoiceLoad + 1);

    auto repeatedState = std::make_shared<BackendState> ();
    AudioContext repeatedAudio (
        std::make_unique<FakeBackend> (repeatedState), 0x5eedU
    );
    repeatedAudio.setSoundMetadata ({
        { .id = 10, .name = "Persona shuffle", .startSilent = true, .volume = 0.6F },
    });
    std::vector<std::string> repeatedLoads;
    repeatedAudio.registerSound (
        10, "Persona shuffle", SoundPlaybackMode::loop, personaAssets,
        [&repeatedLoads] (const std::string& path) {
            repeatedLoads.push_back (path);
            return std::vector<std::uint8_t> { 1, 2, 3 };
        }
    );
    require (repeatedAudio.playSound (10));
    for (int completion = 0; completion < 16; ++completion) {
        repeatedState->players.back ()->playing = false;
        repeatedAudio.updatePlayback ();
    }
    require (repeatedLoads == expectedSequence);

    std::vector<SoundMetadata> resolvedMetadata {
        {
            .id = 1,
            .name = "bound",
            .startSilent = false,
            .volume = 0.8F,
            .volumeUserKey = "musicvolume",
            .volumeFallback = 0.8F,
        },
        {
            .id = 2,
            .name = "fallback",
            .startSilent = true,
            .volume = 0.6F,
            .volumeUserKey = "missing",
            .volumeFallback = 0.6F,
        },
    };
    const auto resolution = resolveSoundMetadataVolumes (
        resolvedMetadata, { { "musicvolume", 0.35 } }
    );
    require (resolution.appliedProperties == 1);
    require (resolution.appliedSoundLayers == 1);
    require (std::abs (resolvedMetadata[0].volume - 0.35F) < 0.0001F);
    require (std::abs (resolvedMetadata[1].volume - 0.6F) < 0.0001F);
    const auto hugeResolution = resolveSoundMetadataVolumes (
        resolvedMetadata, { { "musicvolume", 1.0e300 } }
    );
    require (hugeResolution.appliedSoundLayers == 1);
    require (resolvedMetadata[0].volume == 1.0F);
    static_cast<void> (resolveSoundMetadataVolumes (
        resolvedMetadata, { { "musicvolume", 0.35 } }
    ));

    auto initialState = std::make_shared<BackendState> ();
    AudioContext initialAudio (std::make_unique<FakeBackend> (initialState));
    initialAudio.setSoundMetadata (std::move (resolvedMetadata));
    int initialLoads = 0;
    initialAudio.registerSound (
        1, "bound", SoundPlaybackMode::loop, { "bound.ogg" }, loader (initialLoads)
    );
    require (initialState->players.size () == 1);
    require (initialState->players[0]->volume == 0.0F);
    initialAudio.setMuted (false);
    require (std::abs (initialState->players[0]->volume - 0.35F) < 0.0001F);

    auto state = std::make_shared<BackendState> ();
    AudioContext audio (std::make_unique<FakeBackend> (state));
    audio.setSoundMetadata ({
        {
            .id = 127,
            .name = "NieR loop",
            .startSilent = false,
            .volume = 0.5F,
            .volumeUserKey = "musicvolume",
            .volumeFallback = 0.5F,
        },
        { .id = 283, .name = "GBC voice", .startSilent = true, .volume = 0.7F },
        { .id = 94, .name = "Arknights random", .startSilent = true, .volume = 1.0F },
    });

    int loopLoads = 0;
    audio.registerSound (
        127, "ignored", SoundPlaybackMode::loop, { "nier.mp3" }, loader (loopLoads)
    );
    require (audio.soundLayerCount () == 1);
    require (audio.constructedPlayerCount () == 1);
    require (loopLoads == 1);
    require (state->constructions == 1);
    require (state->players[0]->looping);
    require (audio.muted ());
    require (state->players[0]->volume == 0.0F);
    require (state->players[0]->plays == 1);
    require (audio.isSoundPlaying (127));

    audio.setMuted (false);
    require (!audio.muted ());
    require (std::abs (state->players[0]->volume - 0.5F) < 0.0001F);

    audio.pauseAllSounds ();
    require (state->players[0]->pauses == 1);
    require (!state->players[0]->playing);
    require (audio.isSoundPlaying (127));
    audio.setMuted (true);
    require (state->players[0]->pauses == 1);
    audio.resumeAllSounds ();
    require (state->players[0]->plays == 2);
    require (state->players[0]->playing);
    require (state->players[0]->volume == 0.0F);
    audio.setMuted (false);
    require (std::abs (state->players[0]->volume - 0.5F) < 0.0001F);
    require (audio.playSound (127));
    require (state->constructions == 1);

    audio.setMuted (true);
    const auto mutedUpdate = audio.setUserProperties ({
        .values = { { "musicvolume", 0.25 } },
        .received = 1,
    });
    require (mutedUpdate.appliedProperties == 1);
    require (mutedUpdate.appliedSoundLayers == 1);
    require (state->players[0]->volume == 0.0F);
    audio.setMuted (false);
    require (std::abs (state->players[0]->volume - 0.25F) < 0.0001F);
    const auto hugeUpdate = audio.setUserProperties ({
        .values = { { "musicvolume", 1.0e300 } },
        .received = 1,
    });
    require (hugeUpdate.appliedSoundLayers == 1);
    require (state->players[0]->volume == 1.0F);

    const auto ignoredUpdate = audio.setUserProperties ({
        .values = { { "unknown", 0.4 } },
        .received = 2,
        .ignored = 1,
        .diagnostics = { "invalid user property: invalid" },
    });
    require (ignoredUpdate.received == 2);
    require (ignoredUpdate.appliedSoundLayers == 0);
    require (ignoredUpdate.ignored == 2);
    require (ignoredUpdate.diagnostics.size () == 2);
    const auto nonfiniteUpdate = audio.setUserProperties ({
        .values = { { "musicvolume", std::numeric_limits<double>::infinity () } },
        .received = 1,
    });
    require (nonfiniteUpdate.appliedSoundLayers == 0);
    require (nonfiniteUpdate.ignored == 1);

    int singleLoads = 0;
    audio.registerSound (
        283, "Voice1", SoundPlaybackMode::single, { "voice.mp3" }, loader (singleLoads)
    );
    require (audio.soundLayerCount () == 2);
    require (audio.constructedPlayerCount () == 1);
    require (singleLoads == 0);
    require (audio.playSound (283));
    require (singleLoads == 1);
    require (audio.constructedPlayerCount () == 2);
    require (!state->players[1]->looping);
    require (std::abs (state->players[1]->volume - 0.7F) < 0.0001F);
    audio.pauseSound (283);
    require (state->players[1]->pauses == 1);
    require (!audio.isSoundPlaying (283));
    audio.setMuted (true);
    audio.setMuted (false);
    require (!state->players[1]->playing);
    require (state->players[1]->pauses == 1);
    require (audio.playSound (283));
    require (audio.isSoundPlaying (283));
    audio.stopSound (283);
    require (state->players[1]->stops == 1);
    require (!audio.isSoundPlaying (283));

    int randomLoads = 0;
    audio.registerSound (
        94, "random", SoundPlaybackMode::random,
        { "one.flac", "two.flac", "three.flac" }, loader (randomLoads)
    );
    require (audio.soundLayerCount () == 3);
    require (randomLoads == 0);

    audio.setSoundMetadata ({
        { .id = 500, .name = "broken", .startSilent = false, .volume = 1.0F },
    });
    audio.registerSound (
        500, "broken", SoundPlaybackMode::single, { "missing.mp3" },
        [] (const std::string&) -> std::vector<std::uint8_t> {
            throw std::runtime_error ("pinned decode failure");
        }
    );
    const auto failed = audio.soundLayers ();
    const auto broken = std::find_if (
        failed.begin (), failed.end (),
        [] (const auto& layer) { return layer.definition.id == 500; }
    );
    require (broken != failed.end ());
    require (!broken->playerConstructed);
    require (broken->error == "pinned decode failure");
    require (audio.playSound (94));
    require (randomLoads == 1);

    int personaLoads = 0;
    std::vector<SoundMetadata> personaMetadata;
    for (int id = 1000; id < 1017; ++id) {
        personaMetadata.push_back ({
            .id = id,
            .name = "Persona",
            .startSilent = true,
            .volume = 0.5F,
            .volumeUserKey = "musicvolume",
            .volumeFallback = 0.5F,
        });
    }
    personaMetadata.push_back ({
        .id = 1017,
        .name = "Persona train",
        .startSilent = true,
        .volume = 0.15F,
        .volumeUserKey = "trainsfxvolume",
        .volumeFallback = 0.15F,
    });
    const auto personaResolution = resolveSoundMetadataVolumes (
        personaMetadata,
        { { "musicvolume", 0.4 }, { "trainsfxvolume", 0.2 } }
    );
    require (personaResolution.appliedProperties == 2);
    require (personaResolution.appliedSoundLayers == 18);
    audio.setSoundMetadata (std::move (personaMetadata));
    for (int id = 1000; id < 1018; ++id) {
        audio.registerSound (
            id, "Persona", SoundPlaybackMode::loop,
            { "track.ogg" }, loader (personaLoads)
        );
    }
    require (personaLoads == 0);
    require (audio.constructedPlayerCount () == 3);
    require (audio.soundVolumeBindingCount () == 18);
    require (audio.soundVolumePropertyCount () == 2);

    const auto personaMusic = audio.setUserProperties ({
        .values = { { "musicvolume", 0.3 } },
        .received = 1,
    });
    require (personaMusic.appliedProperties == 1);
    require (personaMusic.appliedSoundLayers == 17);
    const auto personaTrain = audio.setUserProperties ({
        .values = { { "trainsfxvolume", 0.8 } },
        .received = 1,
    });
    require (personaTrain.appliedProperties == 1);
    require (personaTrain.appliedSoundLayers == 1);

    const auto layers = audio.soundLayers ();
    require (layers.size () == 22);
    require (layers[0].definition.name == "Arknights random");
    require (layers[1].definition.name == "NieR loop");
    require (layers[2].definition.name == "GBC voice");
    for (int id = 1000; id < 1017; ++id) {
        const auto layer = std::find_if (
            layers.begin (), layers.end (),
            [id] (const auto& item) { return item.definition.id == id; }
        );
        require (layer != layers.end ());
        require (std::abs (layer->definition.volume - 0.3F) < 0.0001F);
    }
    const auto train = std::find_if (
        layers.begin (), layers.end (),
        [] (const auto& item) { return item.definition.id == 1017; }
    );
    require (train != layers.end ());
    require (std::abs (train->definition.volume - 0.8F) < 0.0001F);
}
