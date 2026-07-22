#include "FrescoScene/RendererClock.h"

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

}

int main () {
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
