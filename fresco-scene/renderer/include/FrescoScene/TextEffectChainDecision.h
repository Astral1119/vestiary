#pragma once

#include <cstddef>
#include <optional>
#include <string_view>
#include <vector>

namespace FrescoScene {

enum class TextEffectChainMode {
    composited,
    directFallback,
    rejected,
};

enum class TextEffectBlockerStage {
    none,
    effect,
    pass,
    material,
};

struct TextEffectChainMember {
    int effectId = 0;
    bool active = false;
    bool effectSupported = false;
    bool passSupported = false;
    bool materialSupported = false;
};

struct TextEffectChainRequest {
    std::vector<TextEffectChainMember> effects;
    bool directFallbackAvailable = false;
};

struct TextEffectChainDecision {
    TextEffectChainMode mode = TextEffectChainMode::rejected;
    std::vector<int> activeEffectIds;
    std::vector<int> blockingEffectIds;
    std::vector<int> compositedEffectIds;
    std::optional<int> firstBlockingEffectId;
    TextEffectBlockerStage firstBlockingStage = TextEffectBlockerStage::none;
    std::size_t supportedActiveEffects = 0;
    std::string_view reason = "text-effect-chain-uninitialized";
};

struct TextEffectChainEvidence {
    int objectId = 0;
    TextEffectChainMode mode = TextEffectChainMode::rejected;
    std::vector<int> activeEffectIds;
    std::vector<int> blockingEffectIds;
    std::optional<int> firstBlockingEffectId;
    TextEffectBlockerStage firstBlockingStage = TextEffectBlockerStage::none;
    std::size_t supportedActiveEffects = 0;
    std::string_view reason = "text-effect-chain-uninitialized";
};

[[nodiscard]] TextEffectChainDecision decideTextEffectChain (
    const TextEffectChainRequest& request
);

[[nodiscard]] std::string_view textEffectChainModeName (
    TextEffectChainMode mode
);

[[nodiscard]] std::string_view textEffectBlockerStageName (
    TextEffectBlockerStage stage
);

}
