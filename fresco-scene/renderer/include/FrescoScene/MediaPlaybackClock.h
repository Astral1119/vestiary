#pragma once

#include <cstddef>
#include <optional>

namespace FrescoScene {

struct MediaPlaybackSample {
    double positionSeconds = 0.0;
    bool shouldDecode = false;
    // The position ran past the asset duration and folded back to the start.
    // Video textures loop, so a player that reached end-of-stream on the
    // previous pass has to start decoding again from here.
    bool wrapped = false;
};

class MediaPlaybackClock {
public:
    MediaPlaybackClock (double durationSeconds, double framesPerSecond);

    void incrementUsage ();
    void decrementUsage ();
    void setHostPaused (bool paused);
    void setHostVisible (bool visible);
    void setManuallyPaused (bool paused);
    void seek (double positionSeconds);

    [[nodiscard]] MediaPlaybackSample sample (double monotonicSeconds);
    void didDecode (double positionSeconds);

    [[nodiscard]] double positionSeconds () const;
    [[nodiscard]] std::size_t usageCount () const;
    [[nodiscard]] bool active () const;

private:
    void resetAnchor ();

    double m_durationSeconds;
    double m_frameIntervalSeconds;
    double m_positionSeconds = 0.0;
    std::size_t m_usageCount = 0;
    bool m_hostPaused = false;
    bool m_hostVisible = true;
    bool m_manuallyPaused = false;
    std::optional<double> m_lastMonotonicSeconds;
    std::optional<double> m_lastDecodedPosition;
};

}
