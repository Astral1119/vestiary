#pragma once

#include <cstddef>
#include <optional>

namespace FrescoScene {

struct SceneScriptTimerEvidence {
    std::size_t scheduled = 0;
    std::size_t fired = 0;
    std::size_t cancelled = 0;
    std::size_t pending = 0;
    std::optional<double> nextDueMilliseconds;
    std::optional<double> currentTimeMilliseconds;
    std::optional<double> lastScheduledDelayMilliseconds;
    std::optional<double> lastFiredDueMilliseconds;
    std::optional<double> lastFiredAtMilliseconds;
};

}
