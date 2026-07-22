#pragma once

namespace FrescoScene {

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
