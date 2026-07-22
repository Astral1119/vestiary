#include "FrescoScene/TextEffectChainDecision.h"

namespace FrescoScene {
namespace {

TextEffectBlockerStage blockerStage (const TextEffectChainMember& effect) {
    if (!effect.effectSupported) {
        return TextEffectBlockerStage::effect;
    }
    if (!effect.passSupported) {
        return TextEffectBlockerStage::pass;
    }
    if (!effect.materialSupported) {
        return TextEffectBlockerStage::material;
    }
    return TextEffectBlockerStage::none;
}

std::string_view blockerReason (TextEffectBlockerStage stage) {
    switch (stage) {
        case TextEffectBlockerStage::effect:
            return "active-text-effect-unsupported";
        case TextEffectBlockerStage::pass:
            return "active-text-effect-pass-unsupported";
        case TextEffectBlockerStage::material:
            return "active-text-effect-material-unsupported";
        case TextEffectBlockerStage::none:
            return "text-effect-chain-supported";
    }
    return "text-effect-chain-invalid-blocker-stage";
}

}

TextEffectChainDecision decideTextEffectChain (
    const TextEffectChainRequest& request
) {
    TextEffectChainDecision result;
    result.activeEffectIds.reserve (request.effects.size ());
    result.blockingEffectIds.reserve (request.effects.size ());

    for (const auto& effect : request.effects) {
        if (!effect.active) {
            continue;
        }
        result.activeEffectIds.push_back (effect.effectId);
        const auto stage = blockerStage (effect);
        if (stage == TextEffectBlockerStage::none) {
            ++result.supportedActiveEffects;
            continue;
        }
        result.blockingEffectIds.push_back (effect.effectId);
        if (!result.firstBlockingEffectId.has_value ()) {
            result.firstBlockingEffectId = effect.effectId;
            result.firstBlockingStage = stage;
        }
    }

    if (result.blockingEffectIds.empty ()) {
        result.mode = TextEffectChainMode::composited;
        result.compositedEffectIds = result.activeEffectIds;
        result.reason = "text-effect-chain-supported";
        return result;
    }

    result.mode = request.directFallbackAvailable
        ? TextEffectChainMode::directFallback
        : TextEffectChainMode::rejected;
    result.reason = blockerReason (result.firstBlockingStage);
    return result;
}

std::string_view textEffectChainModeName (TextEffectChainMode mode) {
    switch (mode) {
        case TextEffectChainMode::composited:
            return "composited";
        case TextEffectChainMode::directFallback:
            return "direct-fallback";
        case TextEffectChainMode::rejected:
            return "rejected";
    }
    return "invalid";
}

std::string_view textEffectBlockerStageName (TextEffectBlockerStage stage) {
    switch (stage) {
        case TextEffectBlockerStage::none:
            return "none";
        case TextEffectBlockerStage::effect:
            return "effect";
        case TextEffectBlockerStage::pass:
            return "pass";
        case TextEffectBlockerStage::material:
            return "material";
    }
    return "invalid";
}

}
