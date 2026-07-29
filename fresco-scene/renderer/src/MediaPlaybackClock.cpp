#include "FrescoScene/MediaPlaybackClock.h"

#include <algorithm>
#include <cmath>

using namespace FrescoScene;

MediaPlaybackClock::MediaPlaybackClock (
    double durationSeconds, double framesPerSecond
) :
    m_durationSeconds (
        std::isfinite (durationSeconds) ? std::max (0.0, durationSeconds) : 0.0
    ),
    m_frameIntervalSeconds (
        std::isfinite (framesPerSecond) && framesPerSecond > 0.0
            ? 1.0 / framesPerSecond
            : 1.0 / 30.0
    ) { }

void MediaPlaybackClock::incrementUsage () {
    ++m_usageCount;
    resetAnchor ();
}

void MediaPlaybackClock::decrementUsage () {
    if (m_usageCount > 0) {
        --m_usageCount;
    }
    resetAnchor ();
}

void MediaPlaybackClock::setHostPaused (bool paused) {
    if (m_hostPaused != paused) {
        m_hostPaused = paused;
        resetAnchor ();
    }
}

void MediaPlaybackClock::setHostVisible (bool visible) {
    if (m_hostVisible != visible) {
        m_hostVisible = visible;
        resetAnchor ();
    }
}

void MediaPlaybackClock::setManuallyPaused (bool paused) {
    if (m_manuallyPaused != paused) {
        m_manuallyPaused = paused;
        resetAnchor ();
    }
}

void MediaPlaybackClock::seek (double positionSeconds) {
    const double finite = std::isfinite (positionSeconds)
        ? std::max (0.0, positionSeconds) : 0.0;
    m_positionSeconds = m_durationSeconds > 0.0
        ? std::fmod (finite, m_durationSeconds) : 0.0;
    m_lastDecodedPosition.reset ();
    resetAnchor ();
}

MediaPlaybackSample MediaPlaybackClock::sample (double monotonicSeconds) {
    if (!active () || !std::isfinite (monotonicSeconds)) {
        resetAnchor ();
        return { .positionSeconds = m_positionSeconds, .shouldDecode = false };
    }

    bool folded = false;
    if (m_lastMonotonicSeconds.has_value ()) {
        const double elapsed = std::max (
            0.0, monotonicSeconds - *m_lastMonotonicSeconds
        );
        constexpr double suspensionThresholdSeconds = 0.25;
        if (elapsed <= suspensionThresholdSeconds) {
            m_positionSeconds += elapsed;
        }
        if (m_durationSeconds > 0.0 && m_positionSeconds >= m_durationSeconds) {
            m_positionSeconds = std::fmod (m_positionSeconds, m_durationSeconds);
            folded = true;
        }
    }
    m_lastMonotonicSeconds = monotonicSeconds;

    // The fold is reported on its own rather than inferred from the last decode,
    // because a player can arrive here having never decoded successfully — seek
    // into the gap past the final frame reaches end-of-stream immediately and
    // clears the last decoded position, and inferring the wrap from it would
    // leave such a player unable to ever report one.
    const bool wrapped = folded
        || (m_lastDecodedPosition.has_value ()
            && m_positionSeconds < *m_lastDecodedPosition);
    const bool intervalElapsed = !m_lastDecodedPosition.has_value ()
        || std::abs (m_positionSeconds - *m_lastDecodedPosition)
            >= m_frameIntervalSeconds;
    return {
        .positionSeconds = m_positionSeconds,
        .shouldDecode = wrapped || intervalElapsed,
        .wrapped = wrapped,
    };
}

void MediaPlaybackClock::didDecode (double positionSeconds) {
    if (std::isfinite (positionSeconds)) {
        m_lastDecodedPosition = std::max (0.0, positionSeconds);
    }
}

double MediaPlaybackClock::positionSeconds () const { return m_positionSeconds; }

std::size_t MediaPlaybackClock::usageCount () const { return m_usageCount; }

bool MediaPlaybackClock::active () const {
    return m_usageCount > 0 && !m_hostPaused && m_hostVisible && !m_manuallyPaused;
}

void MediaPlaybackClock::resetAnchor () { m_lastMonotonicSeconds.reset (); }
