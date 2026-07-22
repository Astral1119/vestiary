#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace WallpaperEngine::Audio::Drivers::Recorders {
class PlaybackRecorder {
public:
    void setSpectrum (const std::array<float, 128>& spectrum) {
        downsample<64> (spectrum, 0, audio64Left);
        downsample<64> (spectrum, 64, audio64Right);
        downsample<32> (spectrum, 0, audio32Left);
        downsample<32> (spectrum, 64, audio32Right);
        downsample<16> (spectrum, 0, audio16Left);
        downsample<16> (spectrum, 64, audio16Right);
    }

    float audio16Left[16] = {};
    float audio16Right[16] = {};
    float audio32Left[32] = {};
    float audio32Right[32] = {};
    float audio64Left[64] = {};
    float audio64Right[64] = {};

private:
    template <std::size_t OutputSize>
    static void downsample (
        const std::array<float, 128>& spectrum,
        std::size_t channelOffset,
        float (&output)[OutputSize]
    ) {
        constexpr std::size_t inputSize = 64;
        constexpr std::size_t binsPerOutput = inputSize / OutputSize;
        for (std::size_t outputIndex = 0; outputIndex < OutputSize; ++outputIndex) {
            float total = 0.0f;
            for (std::size_t bin = 0; bin < binsPerOutput; ++bin) {
                total += spectrum[
                    channelOffset + outputIndex * binsPerOutput + bin
                ];
            }
            output[outputIndex] = total / static_cast<float> (binsPerOutput);
        }
    }
};
}

namespace WallpaperEngine::Audio {

enum class SoundPlaybackMode {
    loop,
    single,
    random,
    unsupported,
};

struct SoundMetadata {
    int id;
    std::string name;
    bool startSilent;
    float volume;
    std::optional<std::size_t> layerIndex = std::nullopt;
    std::optional<std::string> volumeUserKey = std::nullopt;
    float volumeFallback = 1.0F;
};

using UserPropertyScalar = std::variant<bool, double, std::string>;

struct UserPropertyBatch {
    std::map<std::string, UserPropertyScalar> values;
    std::size_t received = 0;
    std::size_t ignored = 0;
    std::vector<std::string> diagnostics;
};

struct SoundPropertyEvidence {
    std::size_t received = 0;
    std::size_t appliedProperties = 0;
    std::size_t appliedSoundLayers = 0;
    std::size_t acceptedScriptProperties = 0;
    std::size_t queuedPropertyScripts = 0;
    std::size_t ignored = 0;
    std::vector<std::string> diagnostics;
};

[[nodiscard]] SoundPropertyEvidence resolveSoundMetadataVolumes (
    std::vector<SoundMetadata>& metadata,
    const std::map<std::string, UserPropertyScalar>& properties
);

struct SoundDefinition {
    int id;
    std::string name;
    SoundPlaybackMode mode;
    std::vector<std::string> assets;
    bool startSilent;
    float volume;
};

struct SoundLayerSnapshot {
    SoundDefinition definition;
    bool playerConstructed;
    bool playing;
    bool requestedPlaying;
    std::string error;
    std::size_t playRequests = 0;
    std::size_t pauseRequests = 0;
    std::size_t stopRequests = 0;
    std::optional<std::size_t> activeAssetIndex = std::nullopt;
};

class SoundPlayer {
public:
    virtual ~SoundPlayer () = default;
    virtual bool play () = 0;
    virtual void pause () = 0;
    virtual void stop () = 0;
    [[nodiscard]] virtual bool isPlaying () const = 0;
    virtual void setLooping (bool looping) = 0;
    virtual void setVolume (float volume) = 0;
};

class SoundBackend {
public:
    virtual ~SoundBackend () = default;
    [[nodiscard]] virtual std::unique_ptr<SoundPlayer> createPlayer (
        const std::vector<std::uint8_t>& data
    ) = 0;
};

using SoundAssetLoader = std::function<std::vector<std::uint8_t> (const std::string&)>;

[[nodiscard]] std::unique_ptr<SoundBackend> makeAVAudioPlayerBackend ();
[[nodiscard]] bool soundPlaybackEnabled ();
[[nodiscard]] SoundPlaybackMode parseSoundPlaybackMode (
    const std::optional<std::string>& value
);

class AudioContext {
public:
    AudioContext ();
    explicit AudioContext (std::unique_ptr<SoundBackend> backend);
    AudioContext (std::unique_ptr<SoundBackend> backend, std::uint64_t sequenceSeed);
    ~AudioContext ();

    AudioContext (const AudioContext&) = delete;
    AudioContext& operator= (const AudioContext&) = delete;

    [[nodiscard]] Drivers::Recorders::PlaybackRecorder& getRecorder () {
        return m_recorder;
    }

    [[nodiscard]] const Drivers::Recorders::PlaybackRecorder& getRecorder () const {
        return m_recorder;
    }

    void setSoundMetadata (std::vector<SoundMetadata> metadata);
    void registerSound (
        int id,
        std::string name,
        SoundPlaybackMode mode,
        std::vector<std::string> assets,
        SoundAssetLoader loader
    );
    bool playSound (int id);
    void pauseSound (int id);
    void stopSound (int id);
    void updatePlayback ();
    void pauseAllSounds ();
    void resumeAllSounds ();
    void setMuted (bool muted);
    [[nodiscard]] bool muted () const;
    [[nodiscard]] bool hasSoundLayer (int id) const;
    [[nodiscard]] std::optional<int> soundLayerId (std::string_view name) const;
    [[nodiscard]] std::optional<int> soundLayerIdAtIndex (std::size_t index) const;
    [[nodiscard]] std::optional<float> soundVolume (int id) const;
    bool setSoundVolume (int id, float volume);
    [[nodiscard]] SoundPropertyEvidence setUserProperties (
        const UserPropertyBatch& properties
    );
    [[nodiscard]] std::size_t soundVolumeBindingCount () const;
    [[nodiscard]] std::size_t soundVolumePropertyCount () const;
    [[nodiscard]] bool hasSoundVolumeProperty (std::string_view key) const;
    [[nodiscard]] bool isSoundPlaying (int id) const;

    [[nodiscard]] std::size_t soundLayerCount () const;
    [[nodiscard]] std::size_t constructedPlayerCount () const;
    [[nodiscard]] std::vector<SoundLayerSnapshot> soundLayers () const;

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
    Drivers::Recorders::PlaybackRecorder m_recorder;
};

}
