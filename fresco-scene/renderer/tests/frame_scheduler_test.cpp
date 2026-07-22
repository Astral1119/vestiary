#include "FrescoScene/FrameScheduler.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <limits>
#include <stdexcept>

namespace {

using namespace std::chrono_literals;
using FrescoScene::ActivityLease;
using FrescoScene::ChangeIndex;
using FrescoScene::ChangeDamage;
using FrescoScene::ChangeProducers::script;
using FrescoScene::CompletionOutcome;
using FrescoScene::FrameScheduler;
using FrescoScene::LeaseMode;
using FrescoScene::ProducerClassification;
using FrescoScene::ProducerId;
using FrescoScene::SchedulerReasonId;
using FrescoScene::VirtualSchedulerClock;
using FrescoScene::WorkStage;

bool hasReason(
    const FrescoScene::FrameDecision& decision,
    SchedulerReasonId reason
) {
    return std::find(decision.reasons.begin(), decision.reasons.end(), reason)
        != decision.reasons.end();
}

void completeNotEvaluated(
    FrameScheduler& scheduler,
    ChangeIndex& changes,
    const FrescoScene::FrameDecision& decision
) {
    assert(!decision.evaluate);
    const auto evidence = scheduler.complete(
        changes,
        decision,
        CompletionOutcome::notEvaluated
    );
    assert(!evidence.evaluated && !evidence.presented);
}

void testVirtualClockAndInvalidInputs() {
    VirtualSchedulerClock clock;
    clock.advance(5ms);
    assert(clock.now() == 5ms);

    bool rejectedBackward = false;
    try {
        clock.set(4ms);
    } catch (const std::invalid_argument&) {
        rejectedBackward = true;
    }
    assert(rejectedBackward);

    FrameScheduler scheduler(clock);
    for (const auto lease : {
             ActivityLease::periodic(0ns),
             ActivityLease::continuous(-1ns),
             ActivityLease::at(4ms),
             ActivityLease{
                 .mode = LeaseMode::onChange,
                 .interval = 1ms,
             },
             ActivityLease{
                 .mode = static_cast<LeaseMode>(255),
             },
         }) {
        bool rejected = false;
        try {
            scheduler.setLease(1, lease);
        } catch (const std::invalid_argument&) {
            rejected = true;
        }
        assert(rejected);
    }
    bool rejectedFps = false;
    try {
        scheduler.setFpsCeiling(0);
    } catch (const std::invalid_argument&) {
        rejectedFps = true;
    }
    assert(rejectedFps);
    bool rejectedExcessiveFps = false;
    try {
        scheduler.setFpsCeiling(241);
    } catch (const std::invalid_argument&) {
        rejectedExcessiveFps = true;
    }
    assert(rejectedExcessiveFps);

    bool rejectedClassification = false;
    try {
        scheduler.classifyProducer(
            ProducerId{77},
            static_cast<ProducerClassification>(255)
        );
    } catch (const std::invalid_argument&) {
        rejectedClassification = true;
    }
    assert(rejectedClassification);

    ChangeIndex changes;
    bool rejectedWorkStage = false;
    try {
        (void)changes.record({
            .requiredWork = static_cast<WorkStage>(255),
        });
    } catch (const std::invalid_argument&) {
        rejectedWorkStage = true;
    }
    assert(rejectedWorkStage);
    assert(changes.empty());
}

void testOnChangeAtAndKeyReplacement() {
    VirtualSchedulerClock clock;
    FrameScheduler scheduler(clock);
    ChangeIndex changes;

    scheduler.setLease(1, ActivityLease::onChange());
    auto idle = scheduler.decide(changes);
    assert(!idle.evaluate);
    assert(!idle.nextWake.has_value());
    bool rejectedRawOutcome = false;
    try {
        (void)scheduler.complete(
            changes,
            idle,
            static_cast<CompletionOutcome>(255)
        );
    } catch (const std::invalid_argument&) {
        rejectedRawOutcome = true;
    }
    assert(rejectedRawOutcome);
    completeNotEvaluated(scheduler, changes, idle);
    bool rejectedDuplicateCompletion = false;
    try {
        (void)scheduler.complete(
            changes,
            idle,
            CompletionOutcome::notEvaluated
        );
    } catch (const std::invalid_argument&) {
        rejectedDuplicateCompletion = true;
    }
    assert(rejectedDuplicateCompletion);

    scheduler.setLease(1, ActivityLease::at(20ms));
    auto waiting = scheduler.decide(changes);
    assert(!waiting.evaluate);
    assert(waiting.nextWake == 20ms);
    completeNotEvaluated(scheduler, changes, waiting);

    scheduler.setLease(1, ActivityLease::at(30ms));
    clock.set(20ms);
    auto replacedWaiting = scheduler.decide(changes);
    assert(!replacedWaiting.evaluate);
    completeNotEvaluated(scheduler, changes, replacedWaiting);
    scheduler.releaseLease(1);
    auto released = scheduler.decide(changes);
    assert(!released.nextWake.has_value());
    completeNotEvaluated(scheduler, changes, released);

    scheduler.setLease(2, ActivityLease::at(30ms));
    clock.set(30ms);
    const auto due = scheduler.decide(changes);
    assert(due.evaluate);
    assert(hasReason(due, SchedulerReasonId::leaseAt));
    const auto evidence = scheduler.complete(
        changes,
        due,
        CompletionOutcome::evaluatedUnchanged
    );
    assert(evidence.evaluated && !evidence.presented);
    assert(evidence.result == SchedulerReasonId::contentUnchanged);

    clock.set(50ms);
    auto completed = scheduler.decide(changes);
    assert(!completed.evaluate);
    completeNotEvaluated(scheduler, changes, completed);
}

void testPeriodicPhaseDoesNotDriftAndFpsCoalesces() {
    VirtualSchedulerClock clock;
    FrameScheduler scheduler(clock);
    ChangeIndex changes;
    scheduler.setFpsCeiling(10);
    scheduler.setLease(1, ActivityLease::periodic(30ms, 10ms));

    auto waiting = scheduler.decide(changes);
    assert(!waiting.evaluate && waiting.nextWake == 10ms);
    completeNotEvaluated(scheduler, changes, waiting);
    clock.set(10ms);
    auto first = scheduler.decide(changes);
    assert(first.evaluate);
    assert(first.leaseOccurrences.front().scheduledTime == 10ms);
    assert(first.nextWake == 110ms);
    (void)scheduler.complete(changes, first, CompletionOutcome::presented);

    clock.set(100ms);
    auto capped = scheduler.decide(changes);
    assert(!capped.evaluate);
    assert(hasReason(capped, SchedulerReasonId::fpsCeiling));
    assert(capped.nextWake == 110ms);
    completeNotEvaluated(scheduler, changes, capped);

    clock.set(110ms);
    auto second = scheduler.decide(changes);
    assert(second.evaluate);
    assert(second.leaseOccurrences.front().scheduledTime == 100ms);
    (void)scheduler.complete(changes, second, CompletionOutcome::presented);

    clock.set(130ms);
    auto next = scheduler.decide(changes);
    assert(!next.evaluate);
    assert(next.nextWake == 210ms);
    completeNotEvaluated(scheduler, changes, next);
}

void testContinuousPreferredIntervalAndPresentation() {
    VirtualSchedulerClock clock;
    FrameScheduler scheduler(clock);
    ChangeIndex changes;
    scheduler.setFpsCeiling(60);
    scheduler.setLease(1, ActivityLease::continuous(40ms));

    const auto first = scheduler.decide(changes);
    assert(first.evaluate);
    assert(hasReason(first, SchedulerReasonId::leaseContinuous));
    const auto presented = scheduler.complete(
        changes,
        first,
        CompletionOutcome::presented
    );
    assert(presented.presented);
    assert(presented.result == SchedulerReasonId::contentChanged);

    clock.set(39ms);
    auto waiting = scheduler.decide(changes);
    assert(!waiting.evaluate && waiting.nextWake == 40ms);
    completeNotEvaluated(scheduler, changes, waiting);
    clock.set(40ms);
    const auto due = scheduler.decide(changes);
    assert(due.evaluate);
    (void)scheduler.complete(
        changes,
        due,
        CompletionOutcome::evaluatedUnchanged
    );
}

void testSelectiveReadyChangesAndUnknownFailLiveRelease() {
    VirtualSchedulerClock clock;
    FrameScheduler scheduler(clock);
    ChangeIndex changes;
    constexpr ProducerId unregistered{91};
    const auto futureFirst = changes.record({
        .producer = script,
        .earliest = 50ms,
    });
    const auto readySecond = changes.record({
        .producer = unregistered,
        .earliest = 0ms,
    });

    const auto decision = scheduler.decide(changes);
    assert(decision.evaluate);
    assert(decision.readyChanges.size() == 1);
    assert(decision.readyChanges.front() == readySecond);
    assert(decision.nextWake == 16'666'667ns);
    assert(hasReason(decision, SchedulerReasonId::unknownProducerContinuous));
    const auto evidence = scheduler.complete(
        changes,
        decision,
        CompletionOutcome::evaluatedUnchanged
    );
    assert(evidence.acknowledgedChanges.size() == 1);
    assert(changes.acknowledgedRevision() == 0);
    assert(changes.pending().front().revision == futureFirst);

    clock.set(17ms);
    const auto live = scheduler.decide(changes);
    assert(live.evaluate);
    (void)scheduler.complete(
        changes,
        live,
        CompletionOutcome::evaluatedUnchanged
    );
    scheduler.releaseUnknownProducer(unregistered);
    const auto released = scheduler.decide(changes);
    assert(!released.evaluate);
    assert(released.nextWake == 50ms);
    completeNotEvaluated(scheduler, changes, released);

    const auto newUnknown = changes.record({
        .producer = unregistered,
        .earliest = 17ms,
    });
    auto reactivated = scheduler.decide(changes);
    assert(!reactivated.evaluate);
    assert(hasReason(reactivated, SchedulerReasonId::unknownProducerContinuous));
    completeNotEvaluated(scheduler, changes, reactivated);
    clock.set(34ms);
    reactivated = scheduler.decide(changes);
    assert(reactivated.evaluate);
    assert(reactivated.readyChanges.front() == newUnknown);
    (void)scheduler.complete(
        changes,
        reactivated,
        CompletionOutcome::evaluatedUnchanged
    );
    scheduler.releaseUnknownProducer(unregistered);

    scheduler.classifyProducer(script, ProducerClassification::onChange);
    clock.set(51ms);
    const auto future = scheduler.decide(changes);
    assert(future.evaluate);
    assert(!hasReason(future, SchedulerReasonId::unknownProducerContinuous));
    (void)scheduler.complete(
        changes,
        future,
        CompletionOutcome::evaluatedUnchanged
    );
    assert(changes.acknowledgedRevision() == newUnknown);
}

void testNextEvaluationSurvivesChangeAcknowledgement() {
    VirtualSchedulerClock clock;
    FrameScheduler scheduler(clock);
    ChangeIndex changes;
    scheduler.classifyProducer(script, ProducerClassification::onChange);
    (void)changes.record({
        .producer = script,
        .nextEvaluation = 25ms,
    });

    const auto initial = scheduler.decide(changes);
    assert(initial.evaluate);
    assert(initial.nextWake == 25ms);
    (void)scheduler.complete(
        changes,
        initial,
        CompletionOutcome::evaluatedUnchanged
    );
    assert(changes.empty());

    clock.set(24ms);
    const auto waiting = scheduler.decide(changes);
    assert(!waiting.evaluate);
    assert(waiting.nextWake == 25ms);
    completeNotEvaluated(scheduler, changes, waiting);

    clock.set(25ms);
    const auto scheduled = scheduler.decide(changes);
    assert(scheduled.evaluate);
    assert(hasReason(scheduled, SchedulerReasonId::producerNextEvaluation));
    assert(scheduled.producerEvaluations.size() == 1);
    assert(scheduled.producerEvaluations.front() == script);
    (void)scheduler.complete(
        changes,
        scheduled,
        CompletionOutcome::evaluatedUnchanged
    );

    clock.set(50ms);
    const auto finished = scheduler.decide(changes);
    assert(!finished.evaluate);
    completeNotEvaluated(scheduler, changes, finished);
}

void testDecisionOwnershipAndWorkStageAggregation() {
    VirtualSchedulerClock clock;
    FrameScheduler scheduler(clock);
    ChangeIndex changes;
    scheduler.classifyProducer(script, ProducerClassification::onChange);
    (void)changes.record({
        .producer = script,
        .requiredWork = WorkStage::encode,
    });
    (void)changes.record({
        .producer = script,
        .requiredWork = WorkStage::upload,
    });

    const auto decision = scheduler.decide(changes);
    assert(decision.evaluate);
    assert(decision.earliestRequiredWork == WorkStage::upload);

    bool rejectedOverlap = false;
    try {
        (void)scheduler.decide(changes);
    } catch (const std::logic_error&) {
        rejectedOverlap = true;
    }
    assert(rejectedOverlap);

    auto forged = decision;
    forged.readyChanges.clear();
    bool rejectedMutation = false;
    try {
        (void)scheduler.complete(changes, forged, CompletionOutcome::presented);
    } catch (const std::invalid_argument&) {
        rejectedMutation = true;
    }
    assert(rejectedMutation);
    assert(changes.pending().size() == 2);

    const auto evidence = scheduler.complete(
        changes,
        decision,
        CompletionOutcome::presented
    );
    assert(evidence.acknowledgedChanges.size() == 2);
    assert(changes.empty());
}

void testLeaseGenerationProtectsReplacementAndReuse() {
    VirtualSchedulerClock clock;
    FrameScheduler scheduler(clock);
    ChangeIndex changes;
    scheduler.setLease(1, ActivityLease::at(0ns));
    scheduler.setLease(2, ActivityLease::at(0ns));

    const auto old = scheduler.decide(changes);
    assert(old.evaluate);
    assert(old.leaseOccurrences.size() == 2);
    const auto oldFirstGeneration = old.leaseOccurrences[0].generation;
    const auto oldSecondGeneration = old.leaseOccurrences[1].generation;

    scheduler.setLease(1, ActivityLease::at(20ms));
    scheduler.releaseLease(2);
    scheduler.setLease(2, ActivityLease::at(40ms));
    (void)scheduler.complete(
        changes,
        old,
        CompletionOutcome::evaluatedUnchanged
    );

    clock.set(20ms);
    const auto replacement = scheduler.decide(changes);
    assert(replacement.evaluate);
    assert(replacement.leaseOccurrences.size() == 1);
    assert(replacement.leaseOccurrences.front().id == 1);
    assert(replacement.leaseOccurrences.front().generation
        != oldFirstGeneration);
    (void)scheduler.complete(
        changes,
        replacement,
        CompletionOutcome::evaluatedUnchanged
    );

    clock.set(40ms);
    const auto reused = scheduler.decide(changes);
    assert(reused.evaluate);
    assert(reused.leaseOccurrences.size() == 1);
    assert(reused.leaseOccurrences.front().id == 2);
    assert(reused.leaseOccurrences.front().generation
        != oldSecondGeneration);
    (void)scheduler.complete(
        changes,
        reused,
        CompletionOutcome::evaluatedUnchanged
    );
}

void testActiveToInactiveCompletionIsExplicitlySuppressed() {
    VirtualSchedulerClock clock;
    FrameScheduler scheduler(clock);
    ChangeIndex changes;
    scheduler.setLease(1, ActivityLease::continuous(20ms));
    const auto decision = scheduler.decide(changes);
    assert(decision.evaluate);
    scheduler.setActive(false);
    scheduler.setActive(true);

    bool rejectedUnchanged = false;
    try {
        (void)scheduler.complete(
            changes,
            decision,
            CompletionOutcome::evaluatedUnchanged
        );
    } catch (const std::invalid_argument&) {
        rejectedUnchanged = true;
    }
    assert(rejectedUnchanged);

    const auto suppressed = scheduler.complete(
        changes,
        decision,
        CompletionOutcome::presentationSuppressed
    );
    assert(suppressed.evaluated);
    assert(!suppressed.presented);
    assert(suppressed.result == SchedulerReasonId::presentationSuppressed);
}

void testFutureOnlyWakesHonorPriorEvaluationFloor() {
    constexpr auto floor = 16'666'667ns;

    {
        VirtualSchedulerClock clock;
        FrameScheduler scheduler(clock);
        ChangeIndex changes;
        scheduler.classifyProducer(script, ProducerClassification::onChange);
        (void)changes.record({.producer = script});
        const auto initial = scheduler.decide(changes);
        (void)scheduler.complete(
            changes,
            initial,
            CompletionOutcome::evaluatedUnchanged
        );
        (void)changes.record({.producer = script, .earliest = 5ms});
        const auto waiting = scheduler.decide(changes);
        assert(!waiting.evaluate);
        assert(waiting.nextWake == floor);
        completeNotEvaluated(scheduler, changes, waiting);
    }

    {
        VirtualSchedulerClock clock;
        FrameScheduler scheduler(clock);
        ChangeIndex changes;
        scheduler.classifyProducer(script, ProducerClassification::onChange);
        (void)changes.record({.producer = script});
        const auto initial = scheduler.decide(changes);
        (void)scheduler.complete(
            changes,
            initial,
            CompletionOutcome::evaluatedUnchanged
        );
        scheduler.setLease(1, ActivityLease::at(5ms));
        const auto waiting = scheduler.decide(changes);
        assert(!waiting.evaluate);
        assert(waiting.nextWake == floor);
        completeNotEvaluated(scheduler, changes, waiting);
    }

    {
        VirtualSchedulerClock clock;
        FrameScheduler scheduler(clock);
        ChangeIndex changes;
        scheduler.classifyProducer(script, ProducerClassification::onChange);
        (void)changes.record({.producer = script});
        const auto initial = scheduler.decide(changes);
        (void)scheduler.complete(
            changes,
            initial,
            CompletionOutcome::evaluatedUnchanged
        );
        scheduler.setLease(1, ActivityLease::periodic(10ms, 5ms));
        const auto waiting = scheduler.decide(changes);
        assert(!waiting.evaluate);
        assert(waiting.nextWake == floor);
        completeNotEvaluated(scheduler, changes, waiting);
    }
}

void testSuppressedPresentationPreservesChangeAndOneShotDemand() {
    {
        VirtualSchedulerClock clock;
        FrameScheduler scheduler(clock);
        ChangeIndex changes;
        scheduler.classifyProducer(script, ProducerClassification::onChange);
        const auto revision = changes.record({.producer = script});
        const auto initial = scheduler.decide(changes);
        assert(initial.evaluate);
        scheduler.setActive(false);
        scheduler.setActive(true);
        const auto suppressed = scheduler.complete(
            changes,
            initial,
            CompletionOutcome::presentationSuppressed
        );
        assert(!suppressed.presented);
        assert(suppressed.acknowledgedChanges.empty());
        assert(changes.pending().front().revision == revision);

        const auto capped = scheduler.decide(changes);
        assert(!capped.evaluate);
        assert(hasReason(capped, SchedulerReasonId::fpsCeiling));
        assert(capped.nextWake == 16'666'667ns);
        completeNotEvaluated(scheduler, changes, capped);

        clock.set(17ms);
        const auto retry = scheduler.decide(changes);
        assert(retry.evaluate);
        const auto presented = scheduler.complete(
            changes,
            retry,
            CompletionOutcome::presented
        );
        assert(presented.presented);
        assert(presented.acknowledgedChanges.size() == 1);
        assert(changes.empty());
    }

    {
        VirtualSchedulerClock clock;
        FrameScheduler scheduler(clock);
        ChangeIndex changes;
        scheduler.setLease(1, ActivityLease::at(0ns));
        const auto initial = scheduler.decide(changes);
        assert(initial.evaluate);
        scheduler.setActive(false);
        scheduler.setActive(true);
        (void)scheduler.complete(
            changes,
            initial,
            CompletionOutcome::presentationSuppressed
        );

        const auto capped = scheduler.decide(changes);
        assert(!capped.evaluate);
        assert(hasReason(capped, SchedulerReasonId::leaseAt));
        assert(hasReason(capped, SchedulerReasonId::fpsCeiling));
        completeNotEvaluated(scheduler, changes, capped);

        clock.set(17ms);
        const auto retry = scheduler.decide(changes);
        assert(retry.evaluate);
        assert(retry.leaseOccurrences.size() == 1);
        (void)scheduler.complete(
            changes,
            retry,
            CompletionOutcome::presented
        );

        clock.set(34ms);
        const auto consumed = scheduler.decide(changes);
        assert(!consumed.evaluate);
        completeNotEvaluated(scheduler, changes, consumed);
    }
}

void testTerminalSuppressionCommitsChangeAndLeaseState() {
    VirtualSchedulerClock clock;
    FrameScheduler scheduler(clock);
    scheduler.setFpsCeiling(240);
    ChangeIndex changes;
    scheduler.classifyProducer(script, ProducerClassification::onChange);
    const auto revision = changes.record({
        .producer = script,
        .nextEvaluation = 25ms,
    });
    scheduler.setLease(1, ActivityLease::at(0ns));
    scheduler.setLease(2, ActivityLease::periodic(10ms));
    scheduler.setLease(3, ActivityLease::continuous(20ms));

    const auto decision = scheduler.decide(changes);
    assert(decision.evaluate);
    assert(decision.readyChanges == std::vector{revision});
    assert(decision.leaseOccurrences.size() == 3);
    const auto terminal = scheduler.complete(
        changes,
        decision,
        CompletionOutcome::terminalPresentationSuppressed
    );
    assert(terminal.evaluated);
    assert(!terminal.presented);
    assert(terminal.result == SchedulerReasonId::presentationSuppressed);
    assert(terminal.acknowledgedChanges == std::vector{revision});
    assert(changes.empty());

    const auto waiting = scheduler.decide(changes);
    assert(!waiting.evaluate);
    assert(waiting.nextWake == 10ms);
    assert(!hasReason(waiting, SchedulerReasonId::leaseAt));
    completeNotEvaluated(scheduler, changes, waiting);

    clock.set(10ms);
    const auto periodic = scheduler.decide(changes);
    assert(!periodic.leaseOccurrences.empty());
    assert(periodic.leaseOccurrences.front().id == 2);
    (void)scheduler.complete(
        changes,
        periodic,
        CompletionOutcome::evaluatedUnchanged
    );

    clock.set(20ms);
    const auto repeating = scheduler.decide(changes);
    assert(std::ranges::any_of(
        repeating.leaseOccurrences,
        [](const auto& occurrence) { return occurrence.id == 2; }
    ));
    assert(std::ranges::any_of(
        repeating.leaseOccurrences,
        [](const auto& occurrence) { return occurrence.id == 3; }
    ));
    (void)scheduler.complete(
        changes,
        repeating,
        CompletionOutcome::evaluatedUnchanged
    );

    clock.set(25ms);
    const auto producer = scheduler.decide(changes);
    assert(producer.evaluate);
    assert(producer.producerEvaluations == std::vector{script});
    (void)scheduler.complete(
        changes,
        producer,
        CompletionOutcome::evaluatedUnchanged
    );
}

void testDecisionSequenceOverflowPreservesState() {
    VirtualSchedulerClock clock;
    constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
    FrameScheduler scheduler(clock, maximum);
    ChangeIndex changes;
    assert(scheduler.lastDecisionSequence() == maximum);

    for (int attempt = 0; attempt < 2; ++attempt) {
        bool rejected = false;
        try {
            (void)scheduler.decide(changes);
        } catch (const std::overflow_error&) {
            rejected = true;
        }
        assert(rejected);
        assert(scheduler.lastDecisionSequence() == maximum);
    }
}

void testInactiveSuppressesWithoutConsumption() {
    VirtualSchedulerClock clock;
    FrameScheduler scheduler(clock);
    ChangeIndex changes;
    scheduler.classifyProducer(script, ProducerClassification::onChange);
    const auto revision = changes.record({.producer = script});
    scheduler.setActive(false);

    const auto decision = scheduler.decide(changes);
    assert(!decision.evaluate);
    assert(hasReason(decision, SchedulerReasonId::inactive));
    const auto evidence = scheduler.complete(
        changes,
        decision,
        CompletionOutcome::notEvaluated
    );
    assert(!evidence.evaluated && !evidence.presented);
    assert(changes.pending().front().revision == revision);
}

void testDamageUnionAndUnknownDominance() {
    VirtualSchedulerClock clock;
    FrameScheduler scheduler(clock);
    ChangeIndex changes;
    scheduler.classifyProducer(script, ProducerClassification::onChange);

    (void)changes.record({
        .producer = script,
        .damage = ChangeDamage::identifiers({9, 3, 9}),
    });
    (void)changes.record({
        .producer = script,
        .damage = ChangeDamage::identifiers({7, 3}),
    });
    const auto known = scheduler.decide(changes);
    assert(known.damage == ChangeDamage::identifiers({3, 7, 9}));
    (void)scheduler.complete(changes, known, CompletionOutcome::presented);
    clock.set(20ms);

    (void)changes.record({
        .producer = script,
        .damage = ChangeDamage::identifiers({11}),
    });
    (void)changes.record({
        .producer = script,
        .damage = ChangeDamage::unknown(),
    });
    const auto unknown = scheduler.decide(changes);
    assert(unknown.damage == ChangeDamage::unknown());
    (void)scheduler.complete(changes, unknown, CompletionOutcome::presented);
}

void testDeadlineArithmeticFailsClosed() {
    VirtualSchedulerClock clock;
    const auto nearMaximum = FrescoScene::MonotonicTime::max() - 1ns;
    clock.set(nearMaximum);

    FrameScheduler periodic(clock);
    ChangeIndex noChanges;
    periodic.setLease(1, ActivityLease::periodic(2ns, nearMaximum));
    bool rejectedPeriodicOverflow = false;
    try {
        (void)periodic.decide(noChanges);
    } catch (const std::overflow_error&) {
        rejectedPeriodicOverflow = true;
    }
    assert(rejectedPeriodicOverflow);

    FrameScheduler capped(clock);
    ChangeIndex changes;
    capped.classifyProducer(script, ProducerClassification::onChange);
    (void)changes.record({.producer = script});
    const auto first = capped.decide(changes);
    assert(first.evaluate);
    (void)capped.complete(
        changes,
        first,
        CompletionOutcome::evaluatedUnchanged
    );
    (void)changes.record({.producer = script});
    bool rejectedCeilingOverflow = false;
    try {
        (void)capped.decide(changes);
    } catch (const std::overflow_error&) {
        rejectedCeilingOverflow = true;
    }
    assert(rejectedCeilingOverflow);
    assert(changes.pending().size() == 1);
}

}

int main() {
    testVirtualClockAndInvalidInputs();
    testOnChangeAtAndKeyReplacement();
    testPeriodicPhaseDoesNotDriftAndFpsCoalesces();
    testContinuousPreferredIntervalAndPresentation();
    testSelectiveReadyChangesAndUnknownFailLiveRelease();
    testNextEvaluationSurvivesChangeAcknowledgement();
    testDecisionOwnershipAndWorkStageAggregation();
    testLeaseGenerationProtectsReplacementAndReuse();
    testActiveToInactiveCompletionIsExplicitlySuppressed();
    testFutureOnlyWakesHonorPriorEvaluationFloor();
    testSuppressedPresentationPreservesChangeAndOneShotDemand();
    testTerminalSuppressionCommitsChangeAndLeaseState();
    testDecisionSequenceOverflowPreservesState();
    testInactiveSuppressesWithoutConsumption();
    testDamageUnionAndUnknownDominance();
    testDeadlineArithmeticFailsClosed();
}
