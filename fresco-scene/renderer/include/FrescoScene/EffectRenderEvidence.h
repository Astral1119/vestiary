#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace FrescoScene {

struct EffectPassExecutionEvidence {
    int objectId = 0;
    std::string shader;
    std::string authoredTarget;
    std::string drawTarget;
    std::string input;
    bool previousInput = false;
    int blendingMode = 0;
    std::size_t truncatedTokens = 0;
};

struct EffectRenderEvidence {
    std::vector<EffectPassExecutionEvidence> orderedPasses;
    std::size_t truncatedPasses = 0;
};

void beginEffectRenderFrame () noexcept;
void recordEffectPassExecution (
    int objectId,
    std::string_view shader,
    std::string_view authoredTarget,
    std::string_view drawTarget,
    std::string_view input,
    bool previousInput,
    int blendingMode
) noexcept;
[[nodiscard]] EffectRenderEvidence effectRenderEvidence ();

}
