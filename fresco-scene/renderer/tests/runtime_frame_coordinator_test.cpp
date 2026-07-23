#include "FrescoScene/RuntimeFrameCoordinator.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <vector>

namespace {

using namespace std::chrono_literals;
using FrescoScene::ChangeProducers::script;
using FrescoScene::ChangeProducers::media;
using FrescoScene::ChangeReasons::propertyChanged;
using FrescoScene::ChangeReasons::timeAdvanced;
using FrescoScene::FrameRenderResult;
using FrescoScene::RuntimeFrameCoordinator;
using FrescoScene::RuntimeFrameCoordinatorConfiguration;
using FrescoScene::SchedulerReasonId;

constexpr auto frame60 = 16'666'667ns;

static_assert(std::is_nothrow_move_assignable_v<
    FrescoScene::RuntimeFrameDecisionEvidence
>);
static_assert(std::is_nothrow_move_assignable_v<
    FrescoScene::RuntimePresentationEvidence
>);

bool hasReason(
    const FrescoScene::FrameDecision& decision,
    SchedulerReasonId reason
) {
    return std::find(decision.reasons.begin(), decision.reasons.end(), reason)
        != decision.reasons.end();
}

void completeNotEvaluated(
    RuntimeFrameCoordinator& coordinator,
    const FrescoScene::FrameDecision& decision
) {
    const auto completion = coordinator.completeNotEvaluated(decision);
    assert(!completion.evaluated);
    assert(!completion.presented);
}

void testStaticQuiescenceAndPropertyWake() {
    RuntimeFrameCoordinator coordinator({
        .provenStatic = true,
        .framesPerSecond = 60,
    });
    coordinator.observeExternalPresentation(0ns);
    assert(!coordinator.nextWake().has_value());
    assert(!coordinator.pollTimeoutMilliseconds().has_value());

    const auto idle = coordinator.decide();
    assert(!idle.evaluate);
    assert(!idle.nextWake.has_value());
    completeNotEvaluated(coordinator, idle);

    const auto revision = coordinator.invalidate(script, propertyChanged);
    assert(coordinator.evidence().invalidations == 1);
    const auto capped = coordinator.decide();
    assert(!capped.evaluate);
    assert(capped.nextWake == frame60);
    assert(hasReason(capped, SchedulerReasonId::fpsCeiling));
    completeNotEvaluated(coordinator, capped);
    assert(coordinator.timeUntilNextWake() == frame60);
    assert(coordinator.pollTimeoutMilliseconds() == 16);

    coordinator.setTime(frame60);
    assert(coordinator.timeUntilNextWake() == 0ns);
    assert(coordinator.pollTimeoutMilliseconds() == 0);
    const auto ready = coordinator.decide();
    assert(ready.evaluate);
    assert(ready.readyChanges.front() == revision);
    const auto completion = coordinator.completeRendered(
        ready,
        FrameRenderResult::presented
    );
    assert(completion.presented);
    assert(coordinator.changes().empty());

    const auto& evidence = coordinator.evidence();
    assert(evidence.decisions == 3);
    assert(evidence.evaluations == 1);
    assert(evidence.notEvaluated == 2);
    assert(evidence.presentations == 2);
    assert(evidence.externalPresentations == 1);
    assert(evidence.presentationSuppressions == 0);
    assert(evidence.lastCompletion->presented);
}

void testDynamicExternalFloorAndContinuousCadence() {
    RuntimeFrameCoordinator coordinator({
        .provenStatic = false,
        .framesPerSecond = 60,
    });
    coordinator.observeExternalPresentation(0ns);
    assert(coordinator.nextWake() == frame60);

    const auto capped = coordinator.decide();
    assert(!capped.evaluate);
    assert(capped.nextWake == frame60);
    assert(hasReason(capped, SchedulerReasonId::leaseContinuous));
    completeNotEvaluated(coordinator, capped);

    coordinator.setTime(frame60);
    const auto ready = coordinator.decide();
    assert(ready.evaluate);
    assert(ready.nextWake == frame60 + frame60);
    (void)coordinator.completeRendered(ready, FrameRenderResult::presented);

    coordinator.setTime(20ms);
    assert(coordinator.timeUntilNextWake() == 13'333'334ns);
    assert(coordinator.pollTimeoutMilliseconds() == 13);
}

void testSuppressionPreservesPendingRetry() {
    RuntimeFrameCoordinator coordinator({
        .provenStatic = true,
        .framesPerSecond = 60,
    });
    const auto revision = coordinator.invalidate(script, propertyChanged);
    const auto initial = coordinator.decide();
    assert(initial.evaluate);
    coordinator.setActive(false);
    assert(!coordinator.nextWake().has_value());
    const auto suppressed = coordinator.completeRendered(
        initial,
        FrameRenderResult::suppressedBeforePresentation
    );
    assert(!suppressed.presented);
    assert(coordinator.changes().pending().front().revision == revision);
    assert(coordinator.nextWake() == frame60);

    coordinator.setActive(true);
    assert(coordinator.nextWake() == frame60);
    const auto capped = coordinator.decide();
    assert(!capped.evaluate);
    assert(capped.nextWake == frame60);
    completeNotEvaluated(coordinator, capped);

    coordinator.setTime(frame60);
    const auto retry = coordinator.decide();
    assert(retry.evaluate);
    (void)coordinator.completeRendered(retry, FrameRenderResult::presented);
    assert(coordinator.changes().empty());
    assert(coordinator.evidence().presentationSuppressions == 1);
    assert(coordinator.evidence().presentations == 1);
}

void testTerminalSuppressionAcknowledgesWithoutRetry() {
    RuntimeFrameCoordinator coordinator({
        .provenStatic = true,
        .framesPerSecond = 60,
    });
    const auto revision = coordinator.invalidate(media, timeAdvanced);
    const auto decision = coordinator.decide();
    assert(decision.evaluate);
    const auto suppressed = coordinator.completeRendered(
        decision,
        FrameRenderResult::terminallySuppressedBeforePresentation
    );
    assert(!suppressed.presented);
    assert(suppressed.acknowledgedChanges == std::vector{revision});
    assert(coordinator.changes().empty());
    assert(!coordinator.nextWake().has_value());
    assert(coordinator.evidence().presentationSuppressions == 1);
}

void testMediaFrameDeadlineIsOneShot() {
    RuntimeFrameCoordinator coordinator({.provenStatic = true});
    coordinator.setMediaFrameDeadline(250ms);
    assert(coordinator.evidence().mediaFrameDeadlineSchedules == 1);
    assert(coordinator.evidence().mediaFrameDeadlineActive);
    assert(coordinator.nextWake() == 250ms);
    assert(coordinator.pollTimeoutMilliseconds() == 250);
    coordinator.setMediaFrameDeadline(250ms + 500us);
    assert(coordinator.evidence().mediaFrameDeadlineReplacements == 0);
    coordinator.setMediaFrameDeadline(200ms);
    assert(coordinator.evidence().mediaFrameDeadlineSchedules == 1);
    assert(coordinator.evidence().mediaFrameDeadlineReplacements == 1);
    assert(coordinator.nextWake() == 200ms);
    const auto waiting = coordinator.decide();
    assert(!waiting.evaluate);
    assert(waiting.nextWake == 200ms);
    completeNotEvaluated(coordinator, waiting);
    coordinator.setTime(200ms);
    const auto decision = coordinator.decide();
    assert(decision.evaluate);
    assert(hasReason(decision, SchedulerReasonId::leaseAt));
    assert(decision.leaseOccurrences.size() == 1);
    assert(decision.leaseOccurrences.front().id == 4);
    (void)coordinator.completeRendered(decision, FrameRenderResult::presented);
    coordinator.setMediaFrameDeadline(std::nullopt);
    assert(coordinator.evidence().mediaFrameDeadlineReleases == 1);
    assert(!coordinator.evidence().mediaFrameDeadlineActive);
    assert(!coordinator.nextWake().has_value());
    assert(!coordinator.pollTimeoutMilliseconds().has_value());
}

void testMediaFrameReadyRequiresCausalPresentation() {
    RuntimeFrameCoordinator coordinator({
        .provenStatic = true,
        .framesPerSecond = 60,
    });

    const auto generic = coordinator.invalidate(
        media,
        FrescoScene::ChangeReasons::resourceReady
    );
    const auto genericDecision = coordinator.decide();
    assert(genericDecision.readyChanges == std::vector{generic});
    (void)coordinator.completeRendered(
        genericDecision,
        FrameRenderResult::presented
    );
    assert(coordinator.evidence().mediaFrameReadyInvalidations == 0);
    assert(coordinator.evidence().mediaFrameReadyPresentations == 0);

    coordinator.setTime(frame60);
    const auto ready = coordinator.invalidateMediaFrameReady();
    const auto readyDecision = coordinator.decide();
    assert(readyDecision.readyChanges == std::vector{ready});
    const auto completion = coordinator.completeRendered(
        readyDecision,
        FrameRenderResult::presented
    );
    assert(completion.acknowledgedChanges == std::vector{ready});
    const auto& evidence = coordinator.evidence();
    assert(evidence.mediaFrameReadyInvalidations == 1);
    assert(evidence.mediaFrameReadyPresentations == 1);
    assert(evidence.lastMediaFrameReadyRevision == ready);
    assert(evidence.lastPresentedMediaFrameReadyRevision == ready);
    assert(evidence.lastMediaFrameReadyDecisionSequence
        == readyDecision.sequence);
}

void testAudioEnvelopeDeadlineIsOneShot() {
    RuntimeFrameCoordinator coordinator({.provenStatic = true});
    coordinator.setAudioEnvelopeDeadline(250ms);
    assert(coordinator.evidence().audioEnvelopeDeadlineSchedules == 1);
    assert(coordinator.evidence().audioEnvelopeDeadlineActive);
    assert(coordinator.nextWake() == 250ms);
    assert(coordinator.pollTimeoutMilliseconds() == 250);
    coordinator.setAudioEnvelopeDeadline(250ms);
    assert(coordinator.evidence().audioEnvelopeDeadlineReplacements == 0);
    coordinator.setAudioEnvelopeDeadline(200ms);
    assert(coordinator.evidence().audioEnvelopeDeadlineSchedules == 1);
    assert(coordinator.evidence().audioEnvelopeDeadlineReplacements == 1);
    assert(coordinator.nextWake() == 200ms);
    const auto waiting = coordinator.decide();
    assert(!waiting.evaluate);
    assert(waiting.nextWake == 200ms);
    completeNotEvaluated(coordinator, waiting);
    coordinator.setTime(200ms);
    const auto decision = coordinator.decide();
    assert(decision.evaluate);
    assert(hasReason(decision, SchedulerReasonId::leaseAt));
    assert(decision.leaseOccurrences.size() == 1);
    assert(decision.leaseOccurrences.front().id == 5);
    (void)coordinator.completeRendered(decision, FrameRenderResult::presented);
    assert(!coordinator.evidence().audioEnvelopeDeadlineActive);
    assert(coordinator.evidence().audioEnvelopeDeadlineReleases == 0);
    assert(!coordinator.nextWake().has_value());

    coordinator.setAudioEnvelopeDeadline(300ms);
    assert(coordinator.evidence().audioEnvelopeDeadlineSchedules == 2);
    coordinator.setAudioEnvelopeDeadline(std::nullopt);
    assert(coordinator.evidence().audioEnvelopeDeadlineReleases == 1);
    assert(!coordinator.evidence().audioEnvelopeDeadlineActive);
    assert(!coordinator.nextWake().has_value());
}

void testAudioReadyRequiresCausalPresentation() {
    RuntimeFrameCoordinator coordinator({
        .provenStatic = true,
        .framesPerSecond = 60,
    });

    const auto generic = coordinator.invalidate(
        script,
        FrescoScene::ChangeReasons::resourceReady
    );
    const auto genericDecision = coordinator.decide();
    assert(genericDecision.readyChanges == std::vector{generic});
    (void)coordinator.completeRendered(
        genericDecision,
        FrameRenderResult::presented
    );
    assert(coordinator.evidence().audioReadyInvalidations == 0);
    assert(coordinator.evidence().audioReadyPresentations == 0);

    coordinator.setTime(frame60);
    const auto ready = coordinator.invalidateAudioReady();
    const auto readyDecision = coordinator.decide();
    assert(readyDecision.readyChanges == std::vector{ready});
    const auto completion = coordinator.completeRendered(
        readyDecision,
        FrameRenderResult::presented
    );
    assert(completion.acknowledgedChanges == std::vector{ready});
    const auto& evidence = coordinator.evidence();
    assert(evidence.audioReadyInvalidations == 1);
    assert(evidence.audioReadyPresentations == 1);
    assert(evidence.lastAudioReadyRevision == ready);
    assert(evidence.lastPresentedAudioReadyRevision == ready);
    assert(evidence.lastAudioReadyDecisionSequence == readyDecision.sequence);
}

void testFpsUpdateChangesEligibleWake() {
    RuntimeFrameCoordinator coordinator({
        .provenStatic = false,
        .framesPerSecond = 60,
    });
    coordinator.observeExternalPresentation(0ns);
    coordinator.setFramesPerSecond(10);
    assert(coordinator.nextWake() == 100ms);
    assert(coordinator.pollTimeoutMilliseconds() == 100);

    const auto capped = coordinator.decide();
    assert(!capped.evaluate);
    assert(capped.nextWake == 100ms);
    completeNotEvaluated(coordinator, capped);
    assert(coordinator.timeUntilNextWake() == 100ms);
}

void testScriptTimerDeadlineIsOneShot() {
    RuntimeFrameCoordinator coordinator({.provenStatic = true, .framesPerSecond = 60});
    coordinator.observeExternalPresentation(0ns);
    coordinator.setScriptTimerDeadline(50ms);
    assert(coordinator.evidence().scriptTimerDeadlineSchedules == 1);
    assert(coordinator.nextWake() == 50ms);
    assert(coordinator.pollTimeoutMilliseconds() == 50);
    coordinator.setTime(50ms);
    const auto decision = coordinator.decide();
    assert(decision.evaluate);
    assert(hasReason(decision, SchedulerReasonId::leaseAt));
    assert(decision.leaseOccurrences.size() == 1);
    assert(decision.leaseOccurrences.front().id == 2);
    (void)coordinator.completeRendered(decision, FrameRenderResult::presented);
    const auto idle = coordinator.decide();
    assert(!idle.evaluate);
    assert(!hasReason(idle, SchedulerReasonId::leaseAt));
    completeNotEvaluated(coordinator, idle);
    assert(!coordinator.nextWake().has_value());
}

void testFiniteParticleLeaseReleasesAtQuiescence() {
    RuntimeFrameCoordinator coordinator({.provenStatic = true, .framesPerSecond = 60});
    coordinator.observeExternalPresentation(0ns);
    coordinator.setParticleContinuousRequired(true);
    assert(coordinator.evidence().particleLeaseAcquisitions == 1);
    assert(coordinator.nextWake() == frame60);
    assert(coordinator.pollTimeoutMilliseconds() == 16);

    coordinator.setTime(frame60);
    const auto active = coordinator.decide();
    assert(active.evaluate);
    assert(hasReason(active, SchedulerReasonId::leaseContinuous));
    assert(active.leaseOccurrences.size() == 1);
    assert(active.leaseOccurrences.front().id == 3);
    (void)coordinator.completeRendered(active, FrameRenderResult::presented);

    coordinator.setParticleContinuousRequired(false);
    assert(coordinator.evidence().particleLeaseReleases == 1);
    assert(!coordinator.nextWake().has_value());
    const auto idle = coordinator.decide();
    assert(!idle.evaluate);
    assert(!idle.nextWake.has_value());
    completeNotEvaluated(coordinator, idle);
}

void testExternalDiagnosticPreservesPendingDemand() {
    RuntimeFrameCoordinator coordinator({
        .provenStatic = true,
        .framesPerSecond = 60,
    });
    const auto revision = coordinator.invalidate(script, propertyChanged);
    coordinator.observeExternalPresentation(0ns);
    assert(coordinator.changes().pending().front().revision == revision);
    assert(coordinator.nextWake() == frame60);

    const auto capped = coordinator.decide();
    assert(!capped.evaluate);
    assert(capped.nextWake == frame60);
    completeNotEvaluated(coordinator, capped);

    coordinator.setTime(frame60);
    const auto retry = coordinator.decide();
    assert(retry.evaluate);
    (void)coordinator.completeRendered(retry, FrameRenderResult::presented);
    assert(coordinator.changes().empty());
    assert(coordinator.evidence().externalPresentations == 1);
    assert(coordinator.evidence().presentations == 2);
}

void testOutcomeValidationAndBackwardTime() {
    RuntimeFrameCoordinator coordinator({.provenStatic = true});
    bool rejectedBackward = false;
    coordinator.setTime(1ns);
    try {
        coordinator.setTime(0ns);
    } catch (const std::invalid_argument&) {
        rejectedBackward = true;
    }
    assert(rejectedBackward);

    (void)coordinator.invalidate(script, propertyChanged);
    const auto decision = coordinator.decide();
    bool rejectedResult = false;
    try {
        (void)coordinator.completeRendered(
            decision,
            static_cast<FrameRenderResult>(255)
        );
    } catch (const std::invalid_argument&) {
        rejectedResult = true;
    }
    assert(rejectedResult);
    (void)coordinator.completeRendered(decision, FrameRenderResult::presented);
}

void testStructuredEvidenceIsBoundedAndReportsTruncation() {
    RuntimeFrameCoordinator coordinator({.provenStatic = true});
    constexpr std::size_t changeCount = 24;
    for (std::size_t index = 0; index < changeCount; ++index) {
        (void)coordinator.invalidate(script, propertyChanged);
    }

    const auto decision = coordinator.decide();
    assert(decision.evaluate);
    assert(decision.readyChanges.size() == changeCount);
    (void)coordinator.completeRendered(decision, FrameRenderResult::presented);

    const auto& evidence = coordinator.evidence();
    assert(evidence.lastDecision->readyChanges.count == 16);
    assert(evidence.lastDecision->readyChanges.truncated == 8);
    assert(evidence.lastCompletion->acknowledgedChanges.count == 16);
    assert(evidence.lastCompletion->acknowledgedChanges.truncated == 8);
}

void testDamageEvidenceIsBoundedAndDistinguishesUnknown() {
    RuntimeFrameCoordinator coordinator({.provenStatic = true});
    std::vector<std::uint64_t> identifiers;
    for (std::uint64_t identifier = 1; identifier <= 24; ++identifier) {
        identifiers.push_back(identifier);
    }
    (void)coordinator.invalidate(
        script, propertyChanged, FrescoScene::WorkStage::evaluate,
        std::nullopt, std::nullopt, std::nullopt,
        FrescoScene::ChangeDamage::identifiers(identifiers)
    );
    const auto known = coordinator.decide();
    assert(known.damage == FrescoScene::ChangeDamage::identifiers(identifiers));
    (void)coordinator.completeRendered(known, FrameRenderResult::presented);
    const auto& knownEvidence = *coordinator.evidence().lastDecision;
    assert(knownEvidence.damagePresent);
    assert(!knownEvidence.damageConservativeUnknown);
    assert(knownEvidence.affectedDamageIds.count == 16);
    assert(knownEvidence.affectedDamageIds.truncated == 8);

    coordinator.setTime(20ms);
    (void)coordinator.invalidate(script, propertyChanged);
    const auto unknown = coordinator.decide();
    assert(unknown.damage == FrescoScene::ChangeDamage::unknown());
    (void)coordinator.completeRendered(unknown, FrameRenderResult::presented);
    const auto& unknownEvidence = *coordinator.evidence().lastDecision;
    assert(unknownEvidence.damagePresent);
    assert(unknownEvidence.damageConservativeUnknown);
    assert(unknownEvidence.affectedDamageIds.count == 0);
    assert(unknownEvidence.affectedDamageIds.truncated == 0);
}

void testOverflowPreflightPreservesAuthoritativeState() {
    const auto nearMaximum = FrescoScene::MonotonicTime::max() - 1ns;

    {
        RuntimeFrameCoordinator coordinator({.provenStatic = true});
        coordinator.setTime(nearMaximum);
        const auto revision = coordinator.invalidate(script, propertyChanged);
        const auto decision = coordinator.decide();
        assert(decision.evaluate);

        bool rejected = false;
        try {
            (void)coordinator.completeRendered(
                decision,
                FrameRenderResult::suppressedBeforePresentation
            );
        } catch (const std::overflow_error&) {
            rejected = true;
        }
        assert(rejected);
        assert(coordinator.evidence().decisions == 0);
        assert(coordinator.evidence().presentationSuppressions == 0);
        assert(coordinator.changes().pending().front().revision == revision);

        const auto committed = coordinator.completeRendered(
            decision,
            FrameRenderResult::presented
        );
        assert(committed.presented);
        assert(coordinator.changes().empty());
    }

    {
        RuntimeFrameCoordinator coordinator({.provenStatic = true});
        coordinator.setTime(nearMaximum);
        const auto revision = coordinator.invalidate(script, propertyChanged);
        bool rejected = false;
        try {
            coordinator.observeExternalPresentation(nearMaximum);
        } catch (const std::overflow_error&) {
            rejected = true;
        }
        assert(rejected);
        assert(coordinator.evidence().presentations == 0);
        assert(coordinator.evidence().externalPresentations == 0);
        assert(coordinator.nextWake() == nearMaximum);
        assert(coordinator.pollTimeoutMilliseconds() == 0);
        assert(coordinator.changes().pending().front().revision == revision);

        const auto decision = coordinator.decide();
        assert(decision.evaluate);
        (void)coordinator.completeRendered(
            decision,
            FrameRenderResult::presented
        );
    }
}

}

int main() {
    testStaticQuiescenceAndPropertyWake();
    testDynamicExternalFloorAndContinuousCadence();
    testSuppressionPreservesPendingRetry();
    testTerminalSuppressionAcknowledgesWithoutRetry();
    testMediaFrameDeadlineIsOneShot();
    testMediaFrameReadyRequiresCausalPresentation();
    testAudioEnvelopeDeadlineIsOneShot();
    testAudioReadyRequiresCausalPresentation();
    testFpsUpdateChangesEligibleWake();
    testScriptTimerDeadlineIsOneShot();
    testFiniteParticleLeaseReleasesAtQuiescence();
    testExternalDiagnosticPreservesPendingDemand();
    testOutcomeValidationAndBackwardTime();
    testStructuredEvidenceIsBoundedAndReportsTruncation();
    testDamageEvidenceIsBoundedAndDistinguishesUnknown();
    testOverflowPreflightPreservesAuthoritativeState();
}
