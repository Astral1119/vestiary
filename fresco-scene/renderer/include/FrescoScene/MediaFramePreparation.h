#pragma once

#include <algorithm>
#include <cstddef>
#include <optional>
#include <span>

namespace FrescoScene {

struct MediaPlayerFramePreparationEvidence {
    std::size_t frameReady = 0;
    std::size_t stalled = 0;
    std::optional<double> nextWakeSeconds;
    bool terminal = false;
};

struct MediaFramePreparationEvidence {
    std::size_t players = 0;
    std::size_t readyPlayers = 0;
    std::size_t stalledPlayers = 0;
    std::size_t terminalPlayers = 0;
    std::size_t frameReady = 0;
    std::size_t stalled = 0;
    std::optional<double> nextWakeSeconds;
    bool terminalStall = false;
};

[[nodiscard]] inline MediaFramePreparationEvidence
aggregateMediaFramePreparation (
    std::span<const MediaPlayerFramePreparationEvidence> players
) {
    MediaFramePreparationEvidence result { .players = players.size () };
    for (const auto& player : players) {
        result.readyPlayers += player.frameReady > 0 ? 1U : 0U;
        result.stalledPlayers += player.stalled > 0 ? 1U : 0U;
        result.terminalPlayers += player.terminal ? 1U : 0U;
        result.frameReady += player.frameReady;
        result.stalled += player.stalled;
        if (player.nextWakeSeconds.has_value ()) {
            result.nextWakeSeconds = result.nextWakeSeconds.has_value ()
                ? std::min (*result.nextWakeSeconds, *player.nextWakeSeconds)
                : player.nextWakeSeconds;
        }
    }
    result.terminalStall = result.players > 0
        && result.readyPlayers == 0
        && result.terminalPlayers == result.players;
    return result;
}

}
