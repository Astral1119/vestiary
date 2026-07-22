#include "FrescoScene/TextEffectChainDecision.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <initializer_list>
#include <string_view>
#include <vector>

using FrescoScene::TextEffectBlockerStage;
using FrescoScene::TextEffectChainDecision;
using FrescoScene::TextEffectChainMember;
using FrescoScene::TextEffectChainMode;
using FrescoScene::TextEffectChainRequest;
using FrescoScene::decideTextEffectChain;

namespace {

TextEffectChainMember supported (int id, bool active = true) {
    return {
        .effectId = id,
        .active = active,
        .effectSupported = true,
        .passSupported = true,
        .materialSupported = true,
    };
}

TextEffectChainMember blocked (
    int id, TextEffectBlockerStage stage, bool active = true
) {
    auto result = supported (id, active);
    if (stage == TextEffectBlockerStage::effect) {
        result.effectSupported = false;
    } else if (stage == TextEffectBlockerStage::pass) {
        result.passSupported = false;
    } else if (stage == TextEffectBlockerStage::material) {
        result.materialSupported = false;
    }
    return result;
}

void assertIds (const std::vector<int>& actual, std::initializer_list<int> expected) {
    assert (actual == std::vector<int> (expected));
}

void assertFallback (
    const TextEffectChainDecision& decision, int firstId,
    TextEffectBlockerStage firstStage, std::initializer_list<int> blockers
) {
    assert (decision.mode == TextEffectChainMode::directFallback);
    assert (decision.firstBlockingEffectId == firstId);
    assert (decision.firstBlockingStage == firstStage);
    assertIds (decision.blockingEffectIds, blockers);
    assert (decision.compositedEffectIds.empty ());
}

}

int main () {
    const auto empty = decideTextEffectChain ({
        .effects = {},
        .directFallbackAvailable = true,
    });
    assert (empty.mode == TextEffectChainMode::composited);
    assert (empty.reason == "text-effect-chain-supported");
    assert (empty.activeEffectIds.empty ());
    assert (empty.compositedEffectIds.empty ());

    const auto complete = decideTextEffectChain ({
        .effects = {supported (10), supported (20), supported (30)},
        .directFallbackAvailable = true,
    });
    assert (complete.mode == TextEffectChainMode::composited);
    assert (complete.supportedActiveEffects == 3);
    assertIds (complete.activeEffectIds, {10, 20, 30});
    assertIds (complete.compositedEffectIds, {10, 20, 30});

    const auto before = decideTextEffectChain ({
        .effects = {
            blocked (10, TextEffectBlockerStage::effect),
            supported (20),
            supported (30),
        },
        .directFallbackAvailable = true,
    });
    assertFallback (before, 10, TextEffectBlockerStage::effect, {10});
    assert (before.reason == "active-text-effect-unsupported");

    const auto between = decideTextEffectChain ({
        .effects = {
            supported (10),
            blocked (20, TextEffectBlockerStage::pass),
            supported (30),
        },
        .directFallbackAvailable = true,
    });
    assertFallback (between, 20, TextEffectBlockerStage::pass, {20});
    assert (between.reason == "active-text-effect-pass-unsupported");

    const auto after = decideTextEffectChain ({
        .effects = {
            supported (10),
            supported (20),
            blocked (30, TextEffectBlockerStage::material),
        },
        .directFallbackAvailable = true,
    });
    assertFallback (after, 30, TextEffectBlockerStage::material, {30});
    assert (after.reason == "active-text-effect-material-unsupported");

    const auto inactiveUnsupported = decideTextEffectChain ({
        .effects = {
            blocked (10, TextEffectBlockerStage::effect, false),
            supported (20),
            blocked (30, TextEffectBlockerStage::material, false),
        },
        .directFallbackAvailable = true,
    });
    assert (inactiveUnsupported.mode == TextEffectChainMode::composited);
    assertIds (inactiveUnsupported.activeEffectIds, {20});
    assertIds (inactiveUnsupported.compositedEffectIds, {20});
    assert (inactiveUnsupported.blockingEffectIds.empty ());

    const auto multiple = decideTextEffectChain ({
        .effects = {
            supported (10),
            blocked (20, TextEffectBlockerStage::pass),
            blocked (30, TextEffectBlockerStage::material),
        },
        .directFallbackAvailable = true,
    });
    assertFallback (multiple, 20, TextEffectBlockerStage::pass, {20, 30});
    assertIds (multiple.activeEffectIds, {10, 20, 30});
    assert (multiple.supportedActiveEffects == 1);

    const auto rejected = decideTextEffectChain ({
        .effects = {
            supported (10),
            blocked (20, TextEffectBlockerStage::material),
            supported (30),
        },
        .directFallbackAvailable = false,
    });
    assert (rejected.mode == TextEffectChainMode::rejected);
    assert (rejected.reason == "active-text-effect-material-unsupported");
    assert (rejected.firstBlockingEffectId == 20);
    assert (rejected.compositedEffectIds.empty ());

    assert (FrescoScene::textEffectChainModeName (complete.mode) == "composited");
    assert (FrescoScene::textEffectChainModeName (before.mode) == "direct-fallback");
    assert (FrescoScene::textEffectChainModeName (rejected.mode) == "rejected");
    assert (FrescoScene::textEffectBlockerStageName (
                TextEffectBlockerStage::material
            ) == "material");
}
