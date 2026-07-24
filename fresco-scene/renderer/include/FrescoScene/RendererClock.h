#pragma once

namespace FrescoScene {

// Seconds to advance the shared animation clock (g_Time) for one frame.
//
// When realTime is set and this is not an evidence-capture frame, the clock
// tracks wall time: it advances by the measured inter-frame interval, clamped
// to four nominal frames so a single stall (or the gap spanning a paused/
// media-suppressed span) cannot make the clock leap. Otherwise it advances by
// the fixed nominal step 1/targetFPS, which is decoupled from wall time and so
// reproduces bit-for-bit — the invariant the framebuffer-hash evidence suite
// depends on. The fixed branch keeps the exact 1.0/targetFPS expression to
// preserve those hashes.
float rendererTimeAdvanceSeconds (
    bool realTime,
    bool captureEvidence,
    double frameIntervalMs,
    double targetFPS);

struct RendererClock {
    float current = 1.0F;
    float previous = 1.0F - (1.0F / 60.0F);
    float daytime = 0.5F;
};

class ScopedRendererClockActivation {
public:
    explicit ScopedRendererClockActivation (RendererClock& clock);
    ~ScopedRendererClockActivation ();

    ScopedRendererClockActivation (const ScopedRendererClockActivation&) = delete;
    ScopedRendererClockActivation& operator= (
        const ScopedRendererClockActivation&
    ) = delete;

private:
    RendererClock& m_clock;
    float m_savedCurrent = 0.0F;
    float m_savedPrevious = 0.0F;
    float m_savedDaytime = 0.0F;
    bool m_root = false;
};

}
