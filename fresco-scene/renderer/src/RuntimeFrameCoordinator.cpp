#include "FrescoScene/RuntimeFrameCoordinator.h"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace FrescoScene {

namespace {

void incrementBounded(std::uint64_t& value) noexcept {
    if (value != std::numeric_limits<std::uint64_t>::max()) {
        ++value;
    }
}

MonotonicTime checkedAdd(MonotonicTime left, MonotonicTime right) {
    if (right < MonotonicTime{} || left > MonotonicTime::max() - right) {
        throw std::overflow_error("coordinator wake overflow");
    }
    return left + right;
}

template<typename Value>
void copyBounded(
    const std::vector<Value>& values,
    FixedEvidenceItems<Value>& evidence
) noexcept {
    evidence.count = std::min(values.size(), evidence.values.size());
    evidence.truncated = values.size() - evidence.count;
    for (std::size_t index = 0; index < evidence.count; ++index) {
        evidence.values[index] = values[index];
    }
}

RuntimeFrameDecisionEvidence boundedDecision(
    const FrameDecision& decision
) noexcept {
    RuntimeFrameDecisionEvidence evidence{
        .sequence = decision.sequence,
        .time = decision.time,
        .evaluate = decision.evaluate,
        .missedDeadline = decision.missedDeadline,
        .earliestRequiredWork = decision.earliestRequiredWork,
        .nextWake = decision.nextWake,
    };
    copyBounded(decision.reasons, evidence.reasons);
    copyBounded(decision.readyChanges, evidence.readyChanges);
    copyBounded(decision.producers, evidence.producers);
    copyBounded(decision.producerEvaluations, evidence.producerEvaluations);
    copyBounded(decision.leaseOccurrences, evidence.leaseOccurrences);
    evidence.damagePresent = decision.damage.has_value();
    if (decision.damage.has_value()) {
        evidence.damageConservativeUnknown
            = decision.damage->conservativeUnknown;
        copyBounded(
            decision.damage->affectedIds,
            evidence.affectedDamageIds
        );
    }
    return evidence;
}

RuntimePresentationEvidence boundedCompletion(
    const PresentationEvidence& completion
) noexcept {
    RuntimePresentationEvidence evidence{
        .decisionSequence = completion.decisionSequence,
        .evaluated = completion.evaluated,
        .presented = completion.presented,
        .result = completion.result,
    };
    copyBounded(
        completion.acknowledgedChanges,
        evidence.acknowledgedChanges
    );
    return evidence;
}

}

RuntimeFrameCoordinator::RuntimeFrameCoordinator(
    RuntimeFrameCoordinatorConfiguration configuration
) : m_scheduler(m_clock), m_provenStatic(configuration.provenStatic) {
    setFramesPerSecond(configuration.framesPerSecond);
    setActive(configuration.active);

    for (const ProducerId producer : {
             ChangeProducers::supervisor,
             ChangeProducers::scene,
             ChangeProducers::script,
             ChangeProducers::particle,
             ChangeProducers::media,
             ChangeProducers::audio,
         }) {
        m_scheduler.classifyProducer(
            producer,
            ProducerClassification::onChange
        );
    }
    if (!configuration.provenStatic) {
        m_scheduler.setLease(
            continuousLeaseId,
            ActivityLease::continuous(MonotonicTime(1))
        );
    }
    refreshNextWake();
}

void RuntimeFrameCoordinator::setTime(MonotonicTime relativeTime) {
    m_clock.set(relativeTime);
}

MonotonicTime RuntimeFrameCoordinator::time() const noexcept {
    return m_clock.now();
}

void RuntimeFrameCoordinator::setActive(bool active) {
    m_scheduler.setActive(active);
    refreshNextWake();
}

void RuntimeFrameCoordinator::setFramesPerSecond(
    std::uint32_t framesPerSecond
) {
    m_scheduler.setFpsCeiling(framesPerSecond);
    m_framesPerSecond = framesPerSecond;
    refreshNextWake();
}

void RuntimeFrameCoordinator::setScriptTimerDeadline(
    std::optional<MonotonicTime> deadline
) {
    if (deadline == m_scriptTimerDeadline) {
        return;
    }
    if (!deadline.has_value()) {
        m_scheduler.releaseLease(scriptTimerLeaseId);
        m_scriptTimerDeadline.reset();
        incrementBounded(m_evidence.scriptTimerDeadlineReleases);
        refreshNextWake();
        return;
    }
    m_scheduler.setLease(scriptTimerLeaseId, ActivityLease::at(*deadline));
    m_scriptTimerDeadline = deadline;
    incrementBounded(m_evidence.scriptTimerDeadlineSchedules);
    refreshNextWake();
}

void RuntimeFrameCoordinator::setParticleContinuousRequired(bool required) {
    if (required == m_particleContinuousRequired) {
        return;
    }
    if (required) {
        m_scheduler.setLease(
            particleLeaseId,
            ActivityLease::continuous(MonotonicTime(1))
        );
        incrementBounded(m_evidence.particleLeaseAcquisitions);
    } else {
        m_scheduler.releaseLease(particleLeaseId);
        incrementBounded(m_evidence.particleLeaseReleases);
    }
    m_particleContinuousRequired = required;
    refreshNextWake();
}

void RuntimeFrameCoordinator::setMediaFrameDeadline(
    std::optional<MonotonicTime> deadline
) {
    if (deadline.has_value() && m_mediaFrameDeadline.has_value()) {
        const MonotonicTime difference = *deadline > *m_mediaFrameDeadline
            ? *deadline - *m_mediaFrameDeadline
            : *m_mediaFrameDeadline - *deadline;
        if (difference <= std::chrono::milliseconds(1)) {
            return;
        }
    }
    if (m_mediaFrameDeadline == deadline) {
        return;
    }
    if (deadline.has_value()) {
        m_scheduler.setLease(mediaFrameLeaseId, ActivityLease::at(*deadline));
        if (m_mediaFrameDeadline.has_value()) {
            incrementBounded(m_evidence.mediaFrameDeadlineReplacements);
        } else {
            incrementBounded(m_evidence.mediaFrameDeadlineSchedules);
        }
    } else {
        m_scheduler.releaseLease(mediaFrameLeaseId);
        incrementBounded(m_evidence.mediaFrameDeadlineReleases);
    }
    m_mediaFrameDeadline = deadline;
    m_evidence.mediaFrameDeadlineActive = deadline.has_value();
    refreshNextWake();
}

ChangeRevision RuntimeFrameCoordinator::invalidateMediaFrameReady() {
    const ChangeRevision revision = invalidate(
        ChangeProducers::media,
        ChangeReasons::resourceReady
    );
    incrementBounded(m_evidence.mediaFrameReadyInvalidations);
    m_evidence.lastMediaFrameReadyRevision = revision;
    return revision;
}

void RuntimeFrameCoordinator::setAudioEnvelopeDeadline(
    std::optional<MonotonicTime> deadline
) {
    if (deadline == m_audioEnvelopeDeadline) {
        return;
    }
    if (deadline.has_value()) {
        m_scheduler.setLease(audioEnvelopeLeaseId, ActivityLease::at(*deadline));
        if (m_audioEnvelopeDeadline.has_value()) {
            incrementBounded(m_evidence.audioEnvelopeDeadlineReplacements);
        } else {
            incrementBounded(m_evidence.audioEnvelopeDeadlineSchedules);
        }
    } else {
        m_scheduler.releaseLease(audioEnvelopeLeaseId);
        incrementBounded(m_evidence.audioEnvelopeDeadlineReleases);
    }
    m_audioEnvelopeDeadline = deadline;
    m_evidence.audioEnvelopeDeadlineActive = deadline.has_value();
    refreshNextWake();
}

ChangeRevision RuntimeFrameCoordinator::invalidateAudioReady() {
    const ChangeRevision revision = invalidate(
        ChangeProducers::audio,
        ChangeReasons::resourceReady
    );
    incrementBounded(m_evidence.audioReadyInvalidations);
    m_evidence.lastAudioReadyRevision = revision;
    return revision;
}

ChangeRevision RuntimeFrameCoordinator::invalidate(
    ProducerId producer,
    ChangeReasonId reason,
    WorkStage requiredWork,
    std::optional<MonotonicTime> earliest,
    std::optional<MonotonicTime> deadline,
    std::optional<MonotonicTime> nextEvaluation,
    ChangeDamage damage
) {
    const ChangeRevision revision = m_changes.record({
        .producer = producer,
        .reason = reason,
        .damage = std::move(damage),
        .requiredWork = requiredWork,
        .earliest = earliest.value_or(m_clock.now()),
        .deadline = deadline,
        .nextEvaluation = nextEvaluation,
    });
    incrementBounded(m_evidence.invalidations);
    refreshNextWake();
    return revision;
}

FrameDecision RuntimeFrameCoordinator::decide() {
    return m_scheduler.decide(m_changes);
}

PresentationEvidence RuntimeFrameCoordinator::completeNotEvaluated(
    const FrameDecision& decision
) {
    const PresentationEvidence completion = m_scheduler.complete(
        m_changes,
        decision,
        CompletionOutcome::notEvaluated
    );
    recordDecisionEvidence(decision, completion);
    return completion;
}

PresentationEvidence RuntimeFrameCoordinator::completeRendered(
    const FrameDecision& decision,
    FrameRenderResult result
) {
    CompletionOutcome outcome;
    std::optional<MonotonicTime> retryWake;
    switch (result) {
    case FrameRenderResult::presented:
        outcome = CompletionOutcome::presented;
        break;
    case FrameRenderResult::suppressedBeforePresentation:
        outcome = CompletionOutcome::presentationSuppressed;
        retryWake = checkedAdd(decision.time, minimumInterval());
        break;
    case FrameRenderResult::terminallySuppressedBeforePresentation:
        outcome = CompletionOutcome::terminalPresentationSuppressed;
        break;
    default:
        throw std::invalid_argument("unknown frame render result");
    }
    const PresentationEvidence completion = m_scheduler.complete(
        m_changes,
        decision,
        outcome
    );
    if (completion.presented
        && m_evidence.lastMediaFrameReadyRevision.has_value()
        && std::find(
            decision.readyChanges.begin(),
            decision.readyChanges.end(),
            *m_evidence.lastMediaFrameReadyRevision
        ) != decision.readyChanges.end()
        && std::find(
            completion.acknowledgedChanges.begin(),
            completion.acknowledgedChanges.end(),
            *m_evidence.lastMediaFrameReadyRevision
        ) != completion.acknowledgedChanges.end()) {
        incrementBounded(m_evidence.mediaFrameReadyPresentations);
        m_evidence.lastPresentedMediaFrameReadyRevision
            = *m_evidence.lastMediaFrameReadyRevision;
        m_evidence.lastMediaFrameReadyDecisionSequence = decision.sequence;
    }
    if (completion.presented
        && m_evidence.lastAudioReadyRevision.has_value()
        && std::find(
            decision.readyChanges.begin(),
            decision.readyChanges.end(),
            *m_evidence.lastAudioReadyRevision
        ) != decision.readyChanges.end()
        && std::find(
            completion.acknowledgedChanges.begin(),
            completion.acknowledgedChanges.end(),
            *m_evidence.lastAudioReadyRevision
        ) != completion.acknowledgedChanges.end()) {
        incrementBounded(m_evidence.audioReadyPresentations);
        m_evidence.lastPresentedAudioReadyRevision
            = *m_evidence.lastAudioReadyRevision;
        m_evidence.lastAudioReadyDecisionSequence = decision.sequence;
    }
    if (outcome != CompletionOutcome::presentationSuppressed) {
        for (const LeaseOccurrence& occurrence : decision.leaseOccurrences) {
            if (occurrence.id == scriptTimerLeaseId
                && occurrence.mode == LeaseMode::at) {
                m_scriptTimerDeadline.reset();
            }
            if (occurrence.id == audioEnvelopeLeaseId
                && occurrence.mode == LeaseMode::at) {
                m_audioEnvelopeDeadline.reset();
                m_evidence.audioEnvelopeDeadlineActive = false;
            }
        }
    }
    recordDecisionEvidence(decision, completion);
    if (retryWake.has_value()
        && (!m_evidence.nextWake.has_value()
            || *retryWake < *m_evidence.nextWake)) {
        m_evidence.nextWake = retryWake;
    }
    return completion;
}

void RuntimeFrameCoordinator::observeExternalPresentation(
    MonotonicTime relativeTime
) {
    (void)checkedAdd(relativeTime, minimumInterval());
    m_scheduler.observeExternalPresentation(relativeTime);
    incrementBounded(m_evidence.presentations);
    incrementBounded(m_evidence.externalPresentations);
    refreshNextWake();
}

std::optional<MonotonicTime> RuntimeFrameCoordinator::nextWake() const noexcept {
    return m_evidence.nextWake;
}

std::optional<MonotonicTime>
RuntimeFrameCoordinator::timeUntilNextWake() const noexcept {
    if (!m_evidence.nextWake.has_value()) {
        return std::nullopt;
    }
    return *m_evidence.nextWake <= m_clock.now()
        ? MonotonicTime{}
        : *m_evidence.nextWake - m_clock.now();
}

std::optional<int>
RuntimeFrameCoordinator::pollTimeoutMilliseconds() const noexcept {
    const std::optional<MonotonicTime> remaining = timeUntilNextWake();
    if (!remaining.has_value()) {
        return std::nullopt;
    }
    constexpr std::int64_t nanosecondsPerMillisecond = 1'000'000;
    const std::int64_t nanoseconds = remaining->count();
    const std::int64_t milliseconds = nanoseconds / nanosecondsPerMillisecond;
    return static_cast<int>(std::min<std::int64_t>(
        milliseconds,
        std::numeric_limits<int>::max()
    ));
}

void RuntimeFrameCoordinator::refreshNextWake() {
    m_evidence.nextWake = m_scheduler.projectedNextWake(m_changes);
}

const RuntimeFrameCoordinatorEvidence&
RuntimeFrameCoordinator::evidence() const noexcept {
    return m_evidence;
}

const ChangeIndex& RuntimeFrameCoordinator::changes() const noexcept {
    return m_changes;
}

void RuntimeFrameCoordinator::recordDecisionEvidence(
    const FrameDecision& decision,
    const PresentationEvidence& completion
) noexcept {
    incrementBounded(m_evidence.decisions);
    if (completion.evaluated) {
        incrementBounded(m_evidence.evaluations);
    } else {
        incrementBounded(m_evidence.notEvaluated);
    }
    if (completion.presented) {
        incrementBounded(m_evidence.presentations);
    }
    if (completion.result == SchedulerReasonId::presentationSuppressed) {
        incrementBounded(m_evidence.presentationSuppressions);
    }
    if (decision.missedDeadline) {
        incrementBounded(m_evidence.missedDeadlines);
    }
    for (const SchedulerReasonId reason : decision.reasons) {
        const auto index = static_cast<std::size_t>(reason);
        if (index < m_evidence.reasonCounts.size()) {
            incrementBounded(m_evidence.reasonCounts[index]);
        }
    }
    m_evidence.lastDecision = boundedDecision(decision);
    m_evidence.lastCompletion = boundedCompletion(completion);
    m_evidence.nextWake = decision.nextWake;
}

MonotonicTime RuntimeFrameCoordinator::minimumInterval() const noexcept {
    constexpr std::int64_t second = 1'000'000'000;
    const auto fps = static_cast<std::int64_t>(m_framesPerSecond);
    return MonotonicTime((second + fps - 1) / fps);
}

}
