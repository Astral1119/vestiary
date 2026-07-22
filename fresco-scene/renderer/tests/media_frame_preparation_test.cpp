#include "FrescoScene/MediaFramePreparation.h"

#include <array>
#include <cstdlib>

using FrescoScene::MediaPlayerFramePreparationEvidence;
using FrescoScene::aggregateMediaFramePreparation;

namespace {

void require (bool condition) {
    if (!condition) {
        std::abort ();
    }
}

}

int main () {
    const std::array mixed {
        MediaPlayerFramePreparationEvidence { .terminal = true },
        MediaPlayerFramePreparationEvidence {
            .frameReady = 1,
            .nextWakeSeconds = 0.25,
        },
        MediaPlayerFramePreparationEvidence {
            .nextWakeSeconds = 0.125,
        },
    };
    const auto active = aggregateMediaFramePreparation (mixed);
    require (active.players == 3);
    require (active.readyPlayers == 1);
    require (active.terminalPlayers == 1);
    require (active.frameReady == 1);
    require (active.nextWakeSeconds == 0.125);
    require (!active.terminalStall);

    const std::array terminal {
        MediaPlayerFramePreparationEvidence { .stalled = 1, .terminal = true },
        MediaPlayerFramePreparationEvidence { .terminal = true },
    };
    const auto ended = aggregateMediaFramePreparation (terminal);
    require (ended.players == 2);
    require (ended.stalledPlayers == 1);
    require (ended.terminalPlayers == 2);
    require (ended.terminalStall);
}
