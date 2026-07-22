#include "FrescoScene/VideoTextureControl.h"

#include <algorithm>

namespace FrescoScene {

std::string_view videoTextureControlDiagnostic (VideoTextureControlError error) {
    switch (error) {
        case VideoTextureControlError::none:
            return {};
        case VideoTextureControlError::nullObject:
            return "video texture control received a null scene object";
        case VideoTextureControlError::nullTextureProvider:
            return "video texture control received a null texture provider";
        case VideoTextureControlError::objectNotRegistered:
            return "video texture control scene object is not registered";
        case VideoTextureControlError::textureProviderNotRegistered:
            return "video texture control provider is not registered";
        case VideoTextureControlError::nonVideoHandle:
            return "getVideoTexture() target is not a video texture";
        case VideoTextureControlError::playerUnavailable:
            return "getVideoTexture() video player is unavailable";
        case VideoTextureControlError::unsupportedMethod:
            return "getVideoTexture() supports only play() and pause()";
    }
    return "video texture control failed with an unknown error";
}

VideoTextureControlError VideoTextureControlRegistry::registerObjectTexture (
    VideoTextureObjectToken object,
    VideoTextureProviderToken textureProvider
) {
    if (object == nullptr) {
        return VideoTextureControlError::nullObject;
    }
    if (textureProvider == nullptr) {
        return VideoTextureControlError::nullTextureProvider;
    }
    m_objects.insert_or_assign (object, textureProvider);
    return VideoTextureControlError::none;
}

VideoTextureControlError VideoTextureControlRegistry::registerVideoPlayer (
    VideoTextureProviderToken textureProvider,
    VideoTexturePlayerControl* player
) {
    if (textureProvider == nullptr) {
        return VideoTextureControlError::nullTextureProvider;
    }
    m_textures.insert_or_assign (
        textureProvider,
        TextureBinding { .player = player, .isVideo = true }
    );
    if (player != nullptr) {
        player->setHostPaused (m_hostPaused);
        player->setHostVisible (m_hostVisible);
        player->setScriptPaused (true);
    }
    return player == nullptr
        ? VideoTextureControlError::playerUnavailable
        : VideoTextureControlError::none;
}

VideoTextureControlError VideoTextureControlRegistry::registerNonVideoTexture (
    VideoTextureProviderToken textureProvider
) {
    if (textureProvider == nullptr) {
        return VideoTextureControlError::nullTextureProvider;
    }
    m_textures.insert_or_assign (textureProvider, TextureBinding {});
    return VideoTextureControlError::none;
}

void VideoTextureControlRegistry::unregisterObject (VideoTextureObjectToken object) {
    m_objects.erase (object);
}

void VideoTextureControlRegistry::unregisterTexture (
    VideoTextureProviderToken textureProvider
) {
    const auto texture = m_textures.find (textureProvider);
    if (texture != m_textures.end () && texture->second.player != nullptr) {
        texture->second.player->setScriptPaused (true);
    }
    m_textures.erase (textureProvider);
    std::erase_if (
        m_objects,
        [textureProvider] (const auto& item) {
            return item.second == textureProvider;
        }
    );
}

void VideoTextureControlRegistry::clear () {
    for (auto& [provider, binding] : m_textures) {
        static_cast<void> (provider);
        if (binding.player != nullptr) {
            binding.player->setScriptPaused (true);
        }
    }
    m_objects.clear ();
    m_textures.clear ();
    m_playRequests = 0;
    m_pauseRequests = 0;
    m_errors = 0;
}

VideoTextureControlResult VideoTextureControlRegistry::control (
    VideoTextureObjectToken object,
    VideoTextureMethod method
) {
    const auto failed = [this] (VideoTextureControlError error) {
        ++m_errors;
        return VideoTextureControlResult { .error = error };
    };
    if (object == nullptr) {
        return failed (VideoTextureControlError::nullObject);
    }
    const auto objectBinding = m_objects.find (object);
    if (objectBinding == m_objects.end ()) {
        return failed (VideoTextureControlError::objectNotRegistered);
    }
    const auto texture = m_textures.find (objectBinding->second);
    if (texture == m_textures.end ()) {
        return failed (VideoTextureControlError::textureProviderNotRegistered);
    }
    if (!texture->second.isVideo) {
        return failed (VideoTextureControlError::nonVideoHandle);
    }
    if (texture->second.player == nullptr) {
        return failed (VideoTextureControlError::playerUnavailable);
    }
    if (method != VideoTextureMethod::play && method != VideoTextureMethod::pause) {
        return failed (VideoTextureControlError::unsupportedMethod);
    }

    const bool requestedPlaying = method == VideoTextureMethod::play;
    const bool changed = requestedPlaying != texture->second.requestedPlaying;
    texture->second.requestedPlaying = requestedPlaying;
    texture->second.player->setScriptPaused (!requestedPlaying);
    if (requestedPlaying) {
        ++m_playRequests;
    } else {
        ++m_pauseRequests;
    }
    return { .changed = changed };
}

void VideoTextureControlRegistry::setHostPaused (bool paused) {
    if (m_hostPaused == paused) {
        return;
    }
    m_hostPaused = paused;
    for (auto& [provider, binding] : m_textures) {
        static_cast<void> (provider);
        if (binding.player != nullptr) {
            binding.player->setHostPaused (paused);
        }
    }
}

void VideoTextureControlRegistry::setHostVisible (bool visible) {
    if (m_hostVisible == visible) {
        return;
    }
    m_hostVisible = visible;
    for (auto& [provider, binding] : m_textures) {
        static_cast<void> (provider);
        if (binding.player != nullptr) {
            binding.player->setHostVisible (visible);
        }
    }
}

VideoTextureControlMetrics VideoTextureControlRegistry::metrics () const {
    VideoTextureControlMetrics result {
        .objects = m_objects.size (),
        .textureProviders = m_textures.size (),
        .playRequests = m_playRequests,
        .pauseRequests = m_pauseRequests,
        .errors = m_errors,
        .hostPaused = m_hostPaused,
        .hostVisible = m_hostVisible,
    };
    for (const auto& [provider, binding] : m_textures) {
        static_cast<void> (provider);
        if (binding.isVideo && binding.player != nullptr) {
            ++result.videoPlayers;
        }
        if (binding.requestedPlaying) {
            ++result.requestedPlayingPlayers;
            if (!m_hostPaused && m_hostVisible && binding.player != nullptr) {
                ++result.effectivePlayingPlayers;
            }
        }
    }
    return result;
}

}
