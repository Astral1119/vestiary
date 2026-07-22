#include "FrescoScene/EffectRenderEvidence.h"

#include <algorithm>
#include <array>
#include <string_view>

namespace FrescoScene {
namespace {

constexpr std::size_t maximumPassEvidence = 32;
constexpr std::size_t maximumTokenBytes = 96;

struct FixedToken {
    std::array<char, maximumTokenBytes> bytes {};
    std::size_t size = 0;
    bool truncated = false;
};

struct FixedPassEvidence {
    int objectId = 0;
    FixedToken shader;
    FixedToken authoredTarget;
    FixedToken drawTarget;
    FixedToken input;
    bool previousInput = false;
    int blendingMode = 0;
};

struct FixedEffectEvidence {
    std::array<FixedPassEvidence, maximumPassEvidence> orderedPasses {};
    std::size_t passCount = 0;
    std::size_t truncatedPasses = 0;
};

thread_local FixedEffectEvidence currentEvidence;

[[nodiscard]] FixedToken fixedToken (std::string_view value) noexcept {
    FixedToken result;
    result.size = std::min (value.size (), result.bytes.size ());
    result.truncated = value.size () > result.bytes.size ();
    std::copy_n (value.data (), result.size, result.bytes.data ());
    return result;
}

[[nodiscard]] std::string dynamicToken (const FixedToken& value) {
    return std::string (value.bytes.data (), value.size);
}

}

void beginEffectRenderFrame () noexcept {
    currentEvidence = {};
}

void recordEffectPassExecution (
    int objectId,
    std::string_view shader,
    std::string_view authoredTarget,
    std::string_view drawTarget,
    std::string_view input,
    bool previousInput,
    int blendingMode
) noexcept {
    if (currentEvidence.passCount == maximumPassEvidence) {
        ++currentEvidence.truncatedPasses;
        return;
    }
    currentEvidence.orderedPasses [currentEvidence.passCount++] = {
        .objectId = objectId,
        .shader = fixedToken (shader),
        .authoredTarget = fixedToken (authoredTarget),
        .drawTarget = fixedToken (drawTarget),
        .input = fixedToken (input),
        .previousInput = previousInput,
        .blendingMode = blendingMode,
    };
}

EffectRenderEvidence effectRenderEvidence () {
    EffectRenderEvidence result;
    result.orderedPasses.reserve (currentEvidence.passCount);
    for (std::size_t index = 0; index < currentEvidence.passCount; ++index) {
        const auto& pass = currentEvidence.orderedPasses [index];
        result.orderedPasses.push_back ({
            .objectId = pass.objectId,
            .shader = dynamicToken (pass.shader),
            .authoredTarget = dynamicToken (pass.authoredTarget),
            .drawTarget = dynamicToken (pass.drawTarget),
            .input = dynamicToken (pass.input),
            .previousInput = pass.previousInput,
            .blendingMode = pass.blendingMode,
            .truncatedTokens = static_cast<std::size_t> (pass.shader.truncated)
                + static_cast<std::size_t> (pass.authoredTarget.truncated)
                + static_cast<std::size_t> (pass.drawTarget.truncated)
                + static_cast<std::size_t> (pass.input.truncated),
        });
    }
    result.truncatedPasses = currentEvidence.truncatedPasses;
    return result;
}

}
