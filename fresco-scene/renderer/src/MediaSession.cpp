#include "FrescoScene/MediaSession.h"

#include <algorithm>
#include <cmath>

using namespace FrescoScene;

namespace {

double normalizedTime (double value) {
    return std::isfinite (value) ? std::max (0.0, value) : 0.0;
}

}

MediaSessionChange FrescoScene::operator| (
    MediaSessionChange left, MediaSessionChange right
) {
    return static_cast<MediaSessionChange> (
        static_cast<unsigned> (left) | static_cast<unsigned> (right)
    );
}

bool FrescoScene::contains (
    MediaSessionChange changes, MediaSessionChange expected
) {
    return (static_cast<unsigned> (changes) & static_cast<unsigned> (expected))
        == static_cast<unsigned> (expected);
}

MediaSessionChange MediaSessionState::apply (const MediaSessionEvent& event) {
    MediaSessionChange changes = MediaSessionChange::none;
    switch (event.kind) {
        case MediaSessionEventKind::status:
            if (m_snapshot.available != event.available) {
                m_snapshot.available = event.available;
                changes = changes | MediaSessionChange::status;
            }
            if (!event.available
                && m_snapshot.playback != MediaPlaybackState::stopped) {
                m_snapshot.playback = MediaPlaybackState::stopped;
                changes = changes | MediaSessionChange::playback;
            }
            break;
        case MediaSessionEventKind::playback:
            if (m_snapshot.playback != event.playback) {
                m_snapshot.playback = event.playback;
                changes = changes | MediaSessionChange::playback;
            }
            break;
        case MediaSessionEventKind::properties:
            if (m_snapshot.title != event.title
                || m_snapshot.artist != event.artist
                || m_snapshot.album != event.album) {
                m_snapshot.title = event.title;
                m_snapshot.artist = event.artist;
                m_snapshot.album = event.album;
                changes = changes | MediaSessionChange::properties;
            }
            break;
        case MediaSessionEventKind::timeline: {
            const double duration = normalizedTime (event.durationSeconds);
            const double position = std::min (
                normalizedTime (event.positionSeconds),
                duration > 0.0 ? duration : normalizedTime (event.positionSeconds)
            );
            if (m_snapshot.positionSeconds != position
                || m_snapshot.durationSeconds != duration) {
                m_snapshot.positionSeconds = position;
                m_snapshot.durationSeconds = duration;
                changes = changes | MediaSessionChange::timeline;
            }
            break;
        }
        case MediaSessionEventKind::thumbnail:
            if (m_snapshot.thumbnail != event.thumbnail) {
                m_snapshot.thumbnail = event.thumbnail;
                changes = changes | MediaSessionChange::thumbnail;
            }
            break;
    }
    if (changes != MediaSessionChange::none) {
        ++m_snapshot.revision;
    }
    return changes;
}

const MediaSessionSnapshot& MediaSessionState::snapshot () const {
    return m_snapshot;
}

const char* FrescoScene::mediaSessionEventName (MediaSessionEventKind kind) {
    switch (kind) {
        case MediaSessionEventKind::status: return "status";
        case MediaSessionEventKind::playback: return "playback";
        case MediaSessionEventKind::properties: return "properties";
        case MediaSessionEventKind::timeline: return "timeline";
        case MediaSessionEventKind::thumbnail: return "thumbnail";
    }
    return "unknown";
}
