#pragma once

#include "FrescoScene/MediaArtwork.h"
#include "FrescoScene/MediaSession.h"
#include "WallpaperEngine/Media/MediaSource.h"

#include <array>
#include <cstddef>

namespace FrescoScene {

class SceneScriptStorage;

struct RuntimeMediaEvidence {
    std::size_t events = 0;
    std::array<std::size_t, 5> eventsByKind = {};
    std::size_t metadataNotifications = 0;
    std::size_t thumbnailNotifications = 0;
    std::size_t artworkUpdates = 0;
    std::size_t artworkClears = 0;
    std::size_t artworkErrors = 0;
    std::size_t revision = 0;
};

class RuntimeMediaSource final : public WallpaperEngine::Media::MediaSource {
public:
    explicit RuntimeMediaSource (SceneScriptStorage *scriptStorage = nullptr);

    [[nodiscard]] MediaSessionChange apply (const MediaSessionEvent& event);
    [[nodiscard]] const MediaSessionSnapshot& snapshot () const;
    [[nodiscard]] const MediaArtworkSnapshot& artwork () const;
    [[nodiscard]] const RuntimeMediaEvidence& evidence () const;
    [[nodiscard]] SceneScriptStorage *scriptStorage () const;

protected:
    void performUpdate () override;

private:
    MediaSessionState m_state;
    MediaArtworkState m_artwork;
    RuntimeMediaEvidence m_evidence;
    SceneScriptStorage *m_scriptStorage = nullptr;
};

}
