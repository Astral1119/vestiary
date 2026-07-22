#include "FrescoScene/RendererClock.h"

#include <cstddef>
#include <exception>
#include <mutex>
#include <stdexcept>

float g_Time = 1.0F;
float g_TimeLast = 1.0F - (1.0F / 60.0F);
float g_Daytime = 0.5F;

namespace {

std::mutex clockMutex;
thread_local FrescoScene::RendererClock* activeClock = nullptr;
thread_local std::size_t activationDepth = 0;

}

FrescoScene::ScopedRendererClockActivation::ScopedRendererClockActivation (
    RendererClock& clock
) : m_clock (clock) {
    if (activeClock != nullptr) {
        if (activeClock != &clock) {
            throw std::logic_error ("cannot nest different renderer clocks");
        }
        ++activationDepth;
        return;
    }

    clockMutex.lock ();
    m_root = true;
    activeClock = &clock;
    activationDepth = 1;
    m_savedCurrent = g_Time;
    m_savedPrevious = g_TimeLast;
    m_savedDaytime = g_Daytime;
    g_Time = clock.current;
    g_TimeLast = clock.previous;
    g_Daytime = clock.daytime;
}

FrescoScene::ScopedRendererClockActivation::~ScopedRendererClockActivation () {
    if (!m_root) {
        if (activeClock != &m_clock || activationDepth <= 1) {
            std::terminate ();
        }
        --activationDepth;
        return;
    }

    if (activeClock != &m_clock || activationDepth != 1) {
        std::terminate ();
    }

    m_clock.current = g_Time;
    m_clock.previous = g_TimeLast;
    m_clock.daytime = g_Daytime;
    activeClock = nullptr;
    activationDepth = 0;
    g_Time = m_savedCurrent;
    g_TimeLast = m_savedPrevious;
    g_Daytime = m_savedDaytime;
    clockMutex.unlock ();
}
