#include "RuntimeMediaSource.h"

#include <chrono>

using namespace FrescoScene;
using WallpaperEngine::Media::MediaSource;

RuntimeMediaSource::RuntimeMediaSource (SceneScriptStorage *scriptStorage)
    : MediaSource (std::chrono::hours (24)),
      m_scriptStorage (scriptStorage) {}

MediaSessionChange RuntimeMediaSource::apply (const MediaSessionEvent& event) {
    const MediaSessionChange changes = m_state.apply (event);
    const auto& current = m_state.snapshot ();
    m_mediaInfo.available = current.available;
    m_mediaInfo.playbackState = static_cast<PlaybackState> (current.playback);
    m_mediaInfo.title = current.title;
    m_mediaInfo.artist = current.artist;
    m_mediaInfo.album = current.album;
    m_mediaInfo.position = current.positionSeconds;
    m_mediaInfo.duration = current.durationSeconds;
    m_mediaInfo.url = current.thumbnail.has_value ()
        ? std::optional<std::string> (current.thumbnail->uri)
        : std::nullopt;

    if (contains (changes, MediaSessionChange::thumbnail)) {
        const auto artworkUpdate = m_artwork.apply (m_mediaInfo.url);
        if (artworkUpdate == MediaArtworkUpdate::updated) {
            ++m_evidence.artworkUpdates;
        } else if (artworkUpdate == MediaArtworkUpdate::cleared) {
            ++m_evidence.artworkClears;
        } else if (artworkUpdate == MediaArtworkUpdate::rejected) {
            ++m_evidence.artworkErrors;
        }
    }

    ++m_evidence.events;
    ++m_evidence.eventsByKind[static_cast<std::size_t> (event.kind)];
    m_evidence.revision = current.revision;
    if (changes != MediaSessionChange::none
        && !contains (changes, MediaSessionChange::thumbnail)) {
        fireMetadataListeners ();
        ++m_evidence.metadataNotifications;
    }
    if (contains (changes, MediaSessionChange::thumbnail)) {
        fireAlbumArtListeners ();
        ++m_evidence.thumbnailNotifications;
    }
    return changes;
}

const MediaSessionSnapshot& RuntimeMediaSource::snapshot () const {
    return m_state.snapshot ();
}

const MediaArtworkSnapshot& RuntimeMediaSource::artwork () const {
    return m_artwork.snapshot ();
}

const RuntimeMediaEvidence& RuntimeMediaSource::evidence () const {
    return m_evidence;
}

SceneScriptStorage *RuntimeMediaSource::scriptStorage () const {
    return m_scriptStorage;
}

void RuntimeMediaSource::performUpdate () { }
