#pragma once

#include <cstddef>
#include <optional>
#include <string>

namespace FrescoScene {

enum class MediaPlaybackState {
    stopped = 0,
    playing = 1,
    paused = 2,
};

enum class MediaSessionEventKind {
    status,
    playback,
    properties,
    timeline,
    thumbnail,
};

struct MediaThumbnail {
    std::string uri;
    std::string primaryColor;
    std::string secondaryColor;
    std::string tertiaryColor;
    std::string textColor;
    std::string highContrastColor;

    bool operator== (const MediaThumbnail&) const = default;
};

struct MediaSessionSnapshot {
    bool available = false;
    MediaPlaybackState playback = MediaPlaybackState::stopped;
    std::string title;
    std::string artist;
    std::string album;
    double positionSeconds = 0.0;
    double durationSeconds = 0.0;
    std::optional<MediaThumbnail> thumbnail;
    std::size_t revision = 0;
};

struct MediaSessionEvent {
    MediaSessionEventKind kind = MediaSessionEventKind::status;
    bool available = false;
    MediaPlaybackState playback = MediaPlaybackState::stopped;
    std::string title;
    std::string artist;
    std::string album;
    double positionSeconds = 0.0;
    double durationSeconds = 0.0;
    std::optional<MediaThumbnail> thumbnail;
};

enum class MediaSessionChange : unsigned {
    none = 0,
    status = 1U << 0,
    playback = 1U << 1,
    properties = 1U << 2,
    timeline = 1U << 3,
    thumbnail = 1U << 4,
};

[[nodiscard]] MediaSessionChange operator| (
    MediaSessionChange left, MediaSessionChange right
);
[[nodiscard]] bool contains (
    MediaSessionChange changes, MediaSessionChange expected
);

class MediaSessionState {
public:
    [[nodiscard]] MediaSessionChange apply (const MediaSessionEvent& event);
    [[nodiscard]] const MediaSessionSnapshot& snapshot () const;

private:
    MediaSessionSnapshot m_snapshot;
};

[[nodiscard]] const char* mediaSessionEventName (MediaSessionEventKind kind);

}
