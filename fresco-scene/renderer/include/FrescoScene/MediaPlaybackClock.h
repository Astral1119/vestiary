#pragma once

#include <cstddef>
#include <optional>

namespace FrescoScene {

struct MediaPlaybackSample {
    double positionSeconds = 0.0;
    bool shouldDecode = false;
    // Position is behind the last frame decoded, which happens both when it
    // folds back to the start and, routinely, when a frame has been decoded
    // ahead of where the clock is. Enough to know a player that reached
    // end-of-stream should start decoding again.
    bool wrapped = false;
    // Position ran past the asset duration and folded back on this sample.
    // Strictly the loop point, so it is the signal to discard state belonging
    // to the previous pass; `wrapped` is true too often for that.
    bool folded = false;
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
