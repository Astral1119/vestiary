#include "WallpaperEngine/Audio/AudioContext.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <exception>
#include <map>
#include <numeric>
#include <random>
#include <set>
#include <string>
#include <utility>

using namespace WallpaperEngine::Audio;

namespace {

float normalizedVolume (float volume) {
    return std::isfinite (volume) ? std::clamp (volume, 0.0F, 1.0F) : 1.0F;
}

bool environmentFlag (const char* name) {
    const char* value = std::getenv (name);
    return value != nullptr && std::string (value) == "1";
}

constexpr std::size_t maximumDiagnostics = 16;

void addDiagnostic (std::vector<std::string>& diagnostics, std::string value) {
    if (diagnostics.size () < maximumDiagnostics) {
        diagnostics.push_back (std::move (value));
    }
}

}

class AudioContext::Impl {
public:
    enum class PendingControl {
        play,
        pause,
        stop,
    };

    struct Layer {
        SoundDefinition definition;
        SoundAssetLoader loader;
        std::unique_ptr<SoundPlayer> player;
        std::string error;
        std::vector<std::size_t> sequence;
        std::size_t sequencePosition = 0;
        std::optional<std::size_t> activeAssetIndex;
        bool observedPlaying = false;
    };

    Impl (std::unique_ptr<SoundBackend> soundBackend, std::uint64_t sequenceSeed)
        : backend (std::move (soundBackend)), generator (sequenceSeed) { }

    bool play (int id, bool countRequest = true) {
        const auto found = layers.find (id);
        if (found == layers.end ()) {
            if (metadata.contains (id)) {
                if (countRequest) {
                    ++playRequests[id];
                }
                requestedPlaying.insert (id);
                pendingControls.insert_or_assign (id, PendingControl::play);
                return true;
            }
            return false;
        }
        if (countRequest) {
            ++playRequests[id];
        }
        Layer& layer = found->second;
        if (layer.definition.mode != SoundPlaybackMode::loop
            && layer.definition.mode != SoundPlaybackMode::single
            && layer.definition.mode != SoundPlaybackMode::random) {
            requestedPlaying.erase (id);
            layer.error = "sound playback mode is not implemented";
            return false;
        }
        if (layer.definition.assets.empty ()) {
            requestedPlaying.erase (id);
            layer.error = "sound layer has no assets";
            return false;
        }
        requestedPlaying.insert (id);
        if (backend == nullptr) {
            return false;
        }
        if (contextPaused) {
            resumeAfterContextPause.insert (id);
            return true;
        }
        if (layer.player != nullptr && layer.player->isPlaying ()) {
            return true;
        }
        return start (id, layer);
    }

    bool start (int id, Layer& layer) {
        if (layer.player == nullptr) {
            try {
                const std::size_t assetIndex = selectAsset (layer);
                const auto data = layer.loader (layer.definition.assets[assetIndex]);
                if (data.empty ()) {
                    layer.error = "sound asset is empty";
                    return false;
                }
                layer.player = backend->createPlayer (data);
                layer.activeAssetIndex = assetIndex;
            } catch (const std::exception& error) {
                layer.error = error.what ();
                return false;
            } catch (...) {
                layer.error = "unknown audio load failure";
                return false;
            }
            if (layer.player == nullptr) {
                layer.error = "sound backend returned no player";
                return false;
            }
            layer.player->setLooping (
                layer.definition.mode == SoundPlaybackMode::loop
                    && layer.definition.assets.size () == 1
            );
            layer.player->setVolume (contextMuted ? 0.0F : layer.definition.volume);
        }
        if (!layer.player->play ()) {
            layer.error = "audio playback did not start";
            return false;
        }
        layer.observedPlaying = true;
        layer.error.clear ();
        return true;
    }

    std::size_t selectAsset (Layer& layer) {
        if (layer.definition.mode == SoundPlaybackMode::random) {
            std::uniform_int_distribution<std::size_t> distribution (
                0, layer.definition.assets.size () - 1
            );
            return distribution (generator);
        }
        if (layer.definition.mode != SoundPlaybackMode::loop
            || layer.definition.assets.size () == 1) {
            return 0;
        }
        if (layer.sequence.empty ()) {
            layer.sequence.resize (layer.definition.assets.size ());
            std::iota (layer.sequence.begin (), layer.sequence.end (), 0);
            std::shuffle (layer.sequence.begin (), layer.sequence.end (), generator);
            layer.sequencePosition = 0;
        }
        return layer.sequence[layer.sequencePosition];
    }

    void advanceSequence (int id, Layer& layer) {
        layer.player.reset ();
        layer.observedPlaying = false;
        layer.activeAssetIndex.reset ();
        if (layer.definition.mode != SoundPlaybackMode::loop
            || layer.definition.assets.size () < 2) {
            requestedPlaying.erase (id);
            return;
        }
        ++layer.sequencePosition;
        if (layer.sequencePosition == layer.sequence.size ()) {
            const std::size_t previous = layer.sequence.back ();
            std::shuffle (layer.sequence.begin (), layer.sequence.end (), generator);
            if (layer.sequence.size () > 1 && layer.sequence.front () == previous) {
                std::swap (layer.sequence.front (), layer.sequence[1]);
            }
            layer.sequencePosition = 0;
        }
        if (!start (id, layer)) {
            requestedPlaying.erase (id);
        }
    }

    std::unique_ptr<SoundBackend> backend;
    std::mt19937_64 generator;
    std::map<int, SoundMetadata> metadata;
    std::vector<int> metadataOrder;
    std::map<int, Layer> layers;
    std::map<std::string, std::vector<int>> volumeBindings;
    std::map<int, PendingControl> pendingControls;
    std::map<int, std::size_t> playRequests;
    std::map<int, std::size_t> pauseRequests;
    std::map<int, std::size_t> stopRequests;
    std::set<int> requestedPlaying;
    std::set<int> resumeAfterContextPause;
    bool contextPaused = false;
    bool contextMuted = true;
};

AudioContext::AudioContext ()
    : AudioContext (
        soundPlaybackEnabled () ? makeAVAudioPlayerBackend () : nullptr,
        std::random_device {} ()
    ) { }

AudioContext::AudioContext (std::unique_ptr<SoundBackend> backend)
    : AudioContext (std::move (backend), std::random_device {} ()) { }

AudioContext::AudioContext (
    std::unique_ptr<SoundBackend> backend,
    std::uint64_t sequenceSeed
) : m_impl (std::make_unique<Impl> (std::move (backend), sequenceSeed)) { }

AudioContext::~AudioContext () = default;

bool WallpaperEngine::Audio::soundPlaybackEnabled () {
    return environmentFlag ("FRESCO_SCENE_SOUND_EXPERIMENTAL")
        && !environmentFlag ("FRESCO_SCENE_AUDIO_DISABLED");
}

void AudioContext::setSoundMetadata (std::vector<SoundMetadata> metadata) {
    m_impl->metadata.clear ();
    m_impl->metadataOrder.clear ();
    m_impl->pendingControls.clear ();
    m_impl->requestedPlaying.clear ();
    m_impl->volumeBindings.clear ();
    for (auto& item : metadata) {
        item.volume = normalizedVolume (item.volume);
        item.volumeFallback = normalizedVolume (item.volumeFallback);
        if (item.volumeUserKey.has_value ()) {
            m_impl->volumeBindings[*item.volumeUserKey].push_back (item.id);
        }
        m_impl->metadataOrder.push_back (item.id);
        m_impl->metadata.insert_or_assign (item.id, std::move (item));
    }
}

void AudioContext::registerSound (
    int id,
    std::string name,
    SoundPlaybackMode mode,
    std::vector<std::string> assets,
    SoundAssetLoader loader
) {
    bool startSilent = false;
    float volume = 1.0F;
    if (const auto found = m_impl->metadata.find (id); found != m_impl->metadata.end ()) {
        startSilent = found->second.startSilent;
        volume = found->second.volume;
        if (!found->second.name.empty ()) {
            name = found->second.name;
        }
    }
    SoundDefinition definition {
        .id = id,
        .name = std::move (name),
        .mode = mode,
        .assets = std::move (assets),
        .startSilent = startSilent,
        .volume = normalizedVolume (volume),
    };
    m_impl->layers.insert_or_assign (
        id,
        Impl::Layer {
            .definition = std::move (definition),
            .loader = std::move (loader),
            .player = nullptr,
            .error = {},
            .sequence = {},
            .sequencePosition = 0,
            .activeAssetIndex = std::nullopt,
            .observedPlaying = false,
        }
    );
    const auto pending = m_impl->pendingControls.find (id);
    const bool shouldPlay = pending != m_impl->pendingControls.end ()
        ? pending->second == Impl::PendingControl::play
        : !startSilent;
    m_impl->pendingControls.erase (id);
    if (shouldPlay) {
        m_impl->play (id, false);
    }
}

bool AudioContext::playSound (int id) {
    return m_impl->play (id);
}

void AudioContext::pauseSound (int id) {
    if (m_impl->layers.contains (id) || m_impl->metadata.contains (id)) {
        ++m_impl->pauseRequests[id];
        m_impl->requestedPlaying.erase (id);
    }
    if (!m_impl->layers.contains (id) && m_impl->metadata.contains (id)) {
        m_impl->pendingControls.insert_or_assign (id, Impl::PendingControl::pause);
        return;
    }
    m_impl->resumeAfterContextPause.erase (id);
    if (const auto found = m_impl->layers.find (id);
        found != m_impl->layers.end () && found->second.player != nullptr) {
        found->second.player->pause ();
    }
}

void AudioContext::stopSound (int id) {
    if (m_impl->layers.contains (id) || m_impl->metadata.contains (id)) {
        ++m_impl->stopRequests[id];
        m_impl->requestedPlaying.erase (id);
    }
    if (!m_impl->layers.contains (id) && m_impl->metadata.contains (id)) {
        m_impl->pendingControls.insert_or_assign (id, Impl::PendingControl::stop);
        return;
    }
    m_impl->resumeAfterContextPause.erase (id);
    if (const auto found = m_impl->layers.find (id);
        found != m_impl->layers.end () && found->second.player != nullptr) {
        found->second.player->stop ();
        if (found->second.definition.assets.size () > 1) {
            found->second.player.reset ();
            found->second.activeAssetIndex.reset ();
            found->second.observedPlaying = false;
            found->second.sequence.clear ();
            found->second.sequencePosition = 0;
        }
    }
}

void AudioContext::updatePlayback () {
    if (m_impl->contextPaused) {
        return;
    }
    for (auto& [id, layer] : m_impl->layers) {
        if (!m_impl->requestedPlaying.contains (id)
            || layer.player == nullptr
            || !layer.observedPlaying
            || layer.player->isPlaying ()) {
            continue;
        }
        m_impl->advanceSequence (id, layer);
    }
}

void AudioContext::pauseAllSounds () {
    if (m_impl->contextPaused) {
        return;
    }
    m_impl->contextPaused = true;
    m_impl->resumeAfterContextPause.clear ();
    for (auto& [id, layer] : m_impl->layers) {
        if (layer.player != nullptr && layer.player->isPlaying ()) {
            m_impl->resumeAfterContextPause.insert (id);
            layer.player->pause ();
        }
    }
}

void AudioContext::resumeAllSounds () {
    if (!m_impl->contextPaused) {
        return;
    }
    m_impl->contextPaused = false;
    const auto resume = std::move (m_impl->resumeAfterContextPause);
    m_impl->resumeAfterContextPause.clear ();
    for (const int id : resume) {
        if (const auto found = m_impl->layers.find (id);
            found != m_impl->layers.end ()) {
            m_impl->start (id, found->second);
        }
    }
}

void AudioContext::setMuted (bool muted) {
    if (m_impl->contextMuted == muted) {
        return;
    }
    m_impl->contextMuted = muted;
    for (auto& [id, layer] : m_impl->layers) {
        static_cast<void> (id);
        if (layer.player != nullptr) {
            layer.player->setVolume (muted ? 0.0F : layer.definition.volume);
        }
    }
}

bool AudioContext::muted () const {
    return m_impl->contextMuted;
}

bool AudioContext::hasSoundLayer (int id) const {
    return m_impl->layers.contains (id) || m_impl->metadata.contains (id);
}

std::optional<int> AudioContext::soundLayerId (std::string_view name) const {
    std::optional<int> result;
    for (const int id : m_impl->metadataOrder) {
        const auto found = m_impl->metadata.find (id);
        if (found != m_impl->metadata.end () && found->second.name == name) {
            if (result.has_value ()) {
                return std::nullopt;
            }
            result = id;
        }
    }
    if (result.has_value ()) {
        return result;
    }
    for (const auto& [id, layer] : m_impl->layers) {
        if (layer.definition.name == name) {
            if (result.has_value ()) {
                return std::nullopt;
            }
            result = id;
        }
    }
    return result;
}

std::optional<int> AudioContext::soundLayerIdAtIndex (std::size_t index) const {
    for (const auto& [id, item] : m_impl->metadata) {
        if (item.layerIndex == index) {
            return id;
        }
    }
    return std::nullopt;
}

std::optional<float> AudioContext::soundVolume (int id) const {
    const auto found = m_impl->layers.find (id);
    if (found == m_impl->layers.end ()) {
        const auto metadata = m_impl->metadata.find (id);
        return metadata == m_impl->metadata.end ()
            ? std::nullopt
            : std::optional<float> (metadata->second.volume);
    }
    return found->second.definition.volume;
}

bool AudioContext::setSoundVolume (int id, float volume) {
    if (!std::isfinite (volume)) {
        return false;
    }
    const float normalized = normalizedVolume (volume);
    bool foundSound = false;
    if (const auto metadata = m_impl->metadata.find (id);
        metadata != m_impl->metadata.end ()) {
        metadata->second.volume = normalized;
        foundSound = true;
    }
    if (const auto found = m_impl->layers.find (id);
        found != m_impl->layers.end ()) {
        auto& layer = found->second;
        layer.definition.volume = normalized;
        if (layer.player != nullptr) {
            layer.player->setVolume (
                m_impl->contextMuted ? 0.0F : layer.definition.volume
            );
        }
        foundSound = true;
    }
    return foundSound;
}

SoundPropertyEvidence AudioContext::setUserProperties (
    const UserPropertyBatch& properties
) {
    SoundPropertyEvidence evidence {
        .received = properties.received,
        .ignored = properties.ignored,
        .diagnostics = properties.diagnostics,
    };
    if (evidence.diagnostics.size () > maximumDiagnostics) {
        evidence.diagnostics.resize (maximumDiagnostics);
    }
    for (const auto& [key, value] : properties.values) {
        const auto binding = m_impl->volumeBindings.find (key);
        if (binding == m_impl->volumeBindings.end ()) {
            ++evidence.ignored;
            addDiagnostic (
                evidence.diagnostics,
                "unbound user property: " + key
            );
            continue;
        }
        const auto* numeric = std::get_if<double> (&value);
        if (numeric == nullptr || !std::isfinite (*numeric)) {
            ++evidence.ignored;
            addDiagnostic (
                evidence.diagnostics,
                "invalid user property: " + key
            );
            continue;
        }
        ++evidence.appliedProperties;
        const float volume = static_cast<float> (
            std::clamp (*numeric, 0.0, 1.0)
        );
        for (const int id : binding->second) {
            if (setSoundVolume (id, volume)) {
                ++evidence.appliedSoundLayers;
            }
        }
    }
    return evidence;
}

std::size_t AudioContext::soundVolumeBindingCount () const {
    std::size_t result = 0;
    for (const auto& [key, ids] : m_impl->volumeBindings) {
        static_cast<void> (key);
        result += ids.size ();
    }
    return result;
}

std::size_t AudioContext::soundVolumePropertyCount () const {
    return m_impl->volumeBindings.size ();
}

bool AudioContext::hasSoundVolumeProperty (std::string_view key) const {
    return m_impl->volumeBindings.contains (std::string (key));
}

bool AudioContext::isSoundPlaying (int id) const {
    return m_impl->requestedPlaying.contains (id);
}

std::size_t AudioContext::soundLayerCount () const {
    return m_impl->layers.size ();
}

std::size_t AudioContext::constructedPlayerCount () const {
    return std::count_if (
        m_impl->layers.begin (), m_impl->layers.end (),
        [] (const auto& entry) { return entry.second.player != nullptr; }
    );
}

std::vector<SoundLayerSnapshot> AudioContext::soundLayers () const {
    std::vector<SoundLayerSnapshot> result;
    result.reserve (m_impl->layers.size ());
    for (const auto& [id, layer] : m_impl->layers) {
        static_cast<void> (id);
        result.push_back ({
            .definition = layer.definition,
            .playerConstructed = layer.player != nullptr,
            .playing = layer.player != nullptr && layer.player->isPlaying (),
            .requestedPlaying = m_impl->requestedPlaying.contains (id),
            .error = layer.error,
            .playRequests = m_impl->playRequests[id],
            .pauseRequests = m_impl->pauseRequests[id],
            .stopRequests = m_impl->stopRequests[id],
            .activeAssetIndex = layer.activeAssetIndex,
        });
    }
    return result;
}

SoundPlaybackMode WallpaperEngine::Audio::parseSoundPlaybackMode (
    const std::optional<std::string>& value
) {
    if (!value.has_value () || *value == "single") {
        return SoundPlaybackMode::single;
    }
    if (*value == "loop") {
        return SoundPlaybackMode::loop;
    }
    if (*value == "random") {
        return SoundPlaybackMode::random;
    }
    return SoundPlaybackMode::unsupported;
}

SoundPropertyEvidence WallpaperEngine::Audio::resolveSoundMetadataVolumes (
    std::vector<SoundMetadata>& metadata,
    const std::map<std::string, UserPropertyScalar>& properties
) {
    SoundPropertyEvidence evidence;
    std::set<std::string> appliedProperties;
    for (auto& item : metadata) {
        float volume = item.volumeUserKey.has_value ()
            ? item.volumeFallback
            : item.volume;
        if (!std::isfinite (volume)) {
            volume = 1.0F;
        }
        if (item.volumeUserKey.has_value ()) {
            const auto property = properties.find (*item.volumeUserKey);
            const auto* numeric = property == properties.end ()
                ? nullptr
                : std::get_if<double> (&property->second);
            if (numeric != nullptr && std::isfinite (*numeric)) {
                volume = static_cast<float> (
                    std::clamp (*numeric, 0.0, 1.0)
                );
                appliedProperties.insert (property->first);
                ++evidence.appliedSoundLayers;
            }
        }
        item.volume = volume;
    }
    evidence.appliedProperties = appliedProperties.size ();
    return evidence;
}
