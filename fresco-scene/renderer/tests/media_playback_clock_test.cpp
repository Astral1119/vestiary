#include "FrescoScene/MediaPlaybackClock.h"

#include <cstdlib>
#include <cstdio>
#include <source_location>

using FrescoScene::MediaPlaybackClock;

namespace {

void require (
    bool condition,
    std::source_location location = std::source_location::current ()
) {
    if (!condition) {
        std::fprintf (stderr, "require failed at line %u\n", location.line ());
        std::abort ();
    }
}

}

int main () {
    MediaPlaybackClock clock (2.0, 10.0);
    require (!clock.active ());
    require (!clock.sample (10.0).shouldDecode);

    clock.incrementUsage ();
    require (clock.active ());
    auto sample = clock.sample (10.0);
    require (sample.shouldDecode);
    require (sample.positionSeconds == 0.0);
    clock.didDecode (sample.positionSeconds);

    sample = clock.sample (10.05);
    require (!sample.shouldDecode);
    sample = clock.sample (10.11);
    require (sample.shouldDecode);
    clock.didDecode (sample.positionSeconds);

    clock.setHostPaused (true);
    require (!clock.active ());
    require (!clock.sample (20.0).shouldDecode);
    clock.setHostPaused (false);
    sample = clock.sample (30.0);
    require (sample.positionSeconds > 0.109 && sample.positionSeconds < 0.111);
    sample = clock.sample (30.2);
    require (sample.positionSeconds > 0.30 && sample.positionSeconds < 0.32);

    clock.setHostVisible (false);
    require (!clock.sample (40.0).shouldDecode);
    clock.setHostVisible (true);
    static_cast<void> (clock.sample (50.0));
    for (int step = 1; step <= 9; ++step) {
        sample = clock.sample (50.0 + 0.2 * step);
    }
    require (sample.positionSeconds > 0.10 && sample.positionSeconds < 0.12);

    clock.setManuallyPaused (true);
    require (!clock.active ());
    clock.setManuallyPaused (false);
    clock.decrementUsage ();
    require (!clock.active ());
    require (clock.usageCount () == 0);

    MediaPlaybackClock seekClock (2.0, 10.0);
    seekClock.incrementUsage ();
    seekClock.seek (1.25);
    sample = seekClock.sample (31.0);
    require (sample.shouldDecode);
    require (sample.positionSeconds == 1.25);
    seekClock.didDecode (sample.positionSeconds);
    seekClock.seek (2.25);
    sample = seekClock.sample (32.0);
    require (sample.shouldDecode);
    require (sample.positionSeconds == 0.25);
}
