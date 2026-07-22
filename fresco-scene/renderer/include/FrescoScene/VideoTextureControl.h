#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>
#include <unordered_map>

namespace FrescoScene {

using VideoTextureObjectToken = const void*;
using VideoTextureProviderToken = const void*;

enum class VideoTextureMethod : std::uint8_t {
    play,
    pause,
    stop,
    seek,
};

enum class VideoTextureControlError : std::uint8_t {
    none,
    nullObject,
    nullTextureProvider,
    objectNotRegistered,
    textureProviderNotRegistered,
    nonVideoHandle,
    playerUnavailable,
    unsupportedMethod,
};

[[nodiscard]] std::string_view videoTextureControlDiagnostic (
    VideoTextureControlError error
);

class VideoTexturePlayerControl {
public:
    virtual ~VideoTexturePlayerControl () = default;

    virtual void setScriptPaused (bool paused) = 0;
    virtual void setHostPaused (bool paused) = 0;
    virtual void setHostVisible (bool visible) = 0;
};

struct VideoTextureControlResult {
    VideoTextureControlError error = VideoTextureControlError::none;
    bool changed = false;

    [[nodiscard]] explicit operator bool () const {
        return error == VideoTextureControlError::none;
    }
};

struct VideoTextureControlMetrics {
    std::size_t objects = 0;
    std::size_t textureProviders = 0;
    std::size_t videoPlayers = 0;
    std::size_t requestedPlayingPlayers = 0;
    std::size_t effectivePlayingPlayers = 0;
    std::size_t playRequests = 0;
    std::size_t pauseRequests = 0;
    std::size_t errors = 0;
    bool hostPaused = false;
    bool hostVisible = true;
};

class VideoTextureControlRegistry {
public:
    [[nodiscard]] VideoTextureControlError registerObjectTexture (
        VideoTextureObjectToken object,
        VideoTextureProviderToken textureProvider
    );
    [[nodiscard]] VideoTextureControlError registerVideoPlayer (
        VideoTextureProviderToken textureProvider,
        VideoTexturePlayerControl* player
    );
    [[nodiscard]] VideoTextureControlError registerNonVideoTexture (
        VideoTextureProviderToken textureProvider
    );
    void unregisterObject (VideoTextureObjectToken object);
    void unregisterTexture (VideoTextureProviderToken textureProvider);
    void clear ();

    [[nodiscard]] VideoTextureControlResult control (
        VideoTextureObjectToken object,
        VideoTextureMethod method
    );
    void setHostPaused (bool paused);
    void setHostVisible (bool visible);
    [[nodiscard]] VideoTextureControlMetrics metrics () const;

private:
    struct TextureBinding {
        VideoTexturePlayerControl* player = nullptr;
        bool isVideo = false;
        bool requestedPlaying = false;
    };

    std::unordered_map<VideoTextureObjectToken, VideoTextureProviderToken> m_objects;
    std::unordered_map<VideoTextureProviderToken, TextureBinding> m_textures;
    std::size_t m_playRequests = 0;
    std::size_t m_pauseRequests = 0;
    std::size_t m_errors = 0;
    bool m_hostPaused = false;
    bool m_hostVisible = true;
};

}
