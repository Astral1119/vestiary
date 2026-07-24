#include "FrescoScene/RendererClock.h"

#include <cmath>
#include <stdexcept>

extern float g_Time;
extern float g_TimeLast;
extern float g_Daytime;

namespace {

void require (bool condition) {
    if (!condition) {
        throw std::runtime_error ("renderer clock requirement failed");
    }
}

void requireNear (float actual, float expected) {
    require (std::fabs (actual - expected) < 1.0e-6F);
}

void checkTimeAdvance () {
    using FrescoScene::rendererTimeAdvanceSeconds;

    // Fixed step ignores the measured interval and reproduces exactly, even
    // when the interval is wildly different from nominal.
    require (rendererTimeAdvanceSeconds (false, false, 999.0, 60.0)
        == static_cast<float> (1.0 / 60.0));
    require (rendererTimeAdvanceSeconds (false, false, 1.0, 30.0)
        == static_cast<float> (1.0 / 30.0));

    // Evidence capture forces the fixed step even under a real-time clock, so
    // framebuffer hashes stay reproducible.
    require (rendererTimeAdvanceSeconds (true, true, 999.0, 60.0)
        == static_cast<float> (1.0 / 60.0));

    // Real-time, ordinary interval: advance by the measured wall time.
    requireNear (
        rendererTimeAdvanceSeconds (true, false, 16.6667, 60.0), 0.0166667F
    );
    requireNear (
        rendererTimeAdvanceSeconds (true, false, 33.3333, 30.0), 0.0333333F
    );

    // Real-time, a single long stall: clamp to four nominal frames so the
    // clock never leaps (66.667 ms at 60 fps).
    requireNear (
        rendererTimeAdvanceSeconds (true, false, 5000.0, 60.0), 0.0666667F
    );

    // Real-time, a short interval passes through unclamped.
    requireNear (
        rendererTimeAdvanceSeconds (true, false, 4.0, 60.0), 0.004F
    );
}

}

int main () {
    checkTimeAdvance ();

    g_Time = 12.0F;
    g_TimeLast = 11.0F;
    g_Daytime = 0.25F;

    FrescoScene::RendererClock first;
    FrescoScene::RendererClock second;
    {
        FrescoScene::ScopedRendererClockActivation activation (first);
        require (g_Time == 1.0F);
        require (g_TimeLast == 1.0F - (1.0F / 60.0F));
        g_Time = 2.0F;
        g_TimeLast = 1.5F;
        g_Daytime = 0.75F;
        {
            FrescoScene::ScopedRendererClockActivation nested (first);
            g_Time = 3.0F;
        }
        bool rejected = false;
        try {
            FrescoScene::ScopedRendererClockActivation invalid (second);
        } catch (const std::logic_error&) {
            rejected = true;
        }
        require (rejected);
        require (g_Time == 3.0F);
    }
    require (first.current == 3.0F);
    require (first.previous == 1.5F);
    require (first.daytime == 0.75F);
    require (g_Time == 12.0F && g_TimeLast == 11.0F && g_Daytime == 0.25F);

    try {
        FrescoScene::ScopedRendererClockActivation activation (second);
        require (g_Time == 1.0F);
        g_Time = 4.0F;
        throw std::runtime_error ("injected clock scope failure");
    } catch (const std::runtime_error&) {
    }
    require (second.current == 4.0F);
    require (g_Time == 12.0F && g_TimeLast == 11.0F && g_Daytime == 0.25F);

    {
        FrescoScene::ScopedRendererClockActivation activation (first);
        require (g_Time == 3.0F);
        require (g_TimeLast == 1.5F);
        require (g_Daytime == 0.75F);
    }
}
