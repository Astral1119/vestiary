#include "FrescoScene/FrameScheduler.h"

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>

namespace FrescoScene {

namespace {

void includeWake(
    std::optional<MonotonicTime>& nextWake,
    MonotonicTime candidate
) {
    if (!nextWake.has_value() || candidate < *nextWake) {
        nextWake = candidate;
    }
}

void includeReason(
    std::vector<SchedulerReasonId>& reasons,
    SchedulerReasonId reason
) {
    if (std::find(reasons.begin(), reasons.end(), reason) == reasons.end()) {
        reasons.push_back(reason);
    }
}

void includeProducer(std::vector<ProducerId>& producers, ProducerId producer) {
    if (std::find(producers.begin(), producers.end(), producer)
        == producers.end()) {
        producers.push_back(producer);
    }
}

MonotonicTime checkedAdd(MonotonicTime left, MonotonicTime right) {
    if (right < MonotonicTime{} || left > MonotonicTime::max() - right) {
        throw std::overflow_error("scheduler deadline overflow");
    }
    return left + right;
}

}

MonotonicTime VirtualSchedulerClock::now() const noexcept {
    return m_now;
}

void VirtualSchedulerClock::set(MonotonicTime time) {
    if (time < m_now) {
        throw std::invalid_argument("virtual scheduler time cannot move backward");
    }
    m_now = time;
}

void VirtualSchedulerClock::advance(MonotonicTime duration) {
    if (duration < MonotonicTime{}) {
        throw std::invalid_argument("virtual scheduler duration cannot be negative");
    }
    if (duration > MonotonicTime::max() - m_now) {
        throw std::overflow_error("virtual scheduler time overflow");
    }
    m_now += duration;
}

ActivityLease ActivityLease::onChange() {
    return {};
}

ActivityLease ActivityLease::at(MonotonicTime deadline) {
    return {.mode = LeaseMode::at, .deadline = deadline};
}

ActivityLease ActivityLease::periodic(
    MonotonicTime interval,
    MonotonicTime phase
) {
    return {
        .mode = LeaseMode::periodic,
        .interval = interval,
        .phase = phase,
    };
}

ActivityLease ActivityLease::continuous(MonotonicTime preferredInterval) {
    return {
        .mode = LeaseMode::continuous,
        .interval = preferredInterval,
    };
}

FrameScheduler::FrameScheduler(
    VirtualSchedulerClock& clock,
    std::uint64_t restoredDecisionSequence
) : m_clock(clock), m_lastDecisionSequence(restoredDecisionSequence) {}

void FrameScheduler::setActive(bool active) noexcept {
    if (!active && m_outstanding.has_value() && m_outstanding->evaluate) {
        m_outstandingPresentationSuppressed = true;
    }
    m_active = active;
}

void FrameScheduler::setFpsCeiling(std::uint32_t framesPerSecond) {
    if (framesPerSecond == 0 || framesPerSecond > 240) {
        throw std::invalid_argument("FPS ceiling must be between 1 and 240");
    }
    m_fpsCeiling = framesPerSecond;
}

void FrameScheduler::setLease(LeaseId id, ActivityLease lease) {
    if (id == 0) {
        throw std::invalid_argument("lease ID zero is reserved");
    }
    if (lease.deadline < MonotonicTime{}
        || lease.interval < MonotonicTime{}
        || lease.phase < MonotonicTime{}) {
        throw std::invalid_argument("lease time cannot be negative");
    }
    switch (lease.mode) {
    case LeaseMode::onChange:
    case LeaseMode::at:
    case LeaseMode::periodic:
    case LeaseMode::continuous:
        break;
    default:
        throw std::invalid_argument("unknown lease mode");
    }
    if ((lease.mode == LeaseMode::periodic
         || lease.mode == LeaseMode::continuous)
        && lease.interval <= MonotonicTime{}) {
        throw std::invalid_argument("repeating lease interval must be positive");
    }
    if (lease.mode == LeaseMode::onChange
        && (lease.deadline != MonotonicTime{}
            || lease.interval != MonotonicTime{}
            || lease.phase != MonotonicTime{})) {
        throw std::invalid_argument("on-change lease carries a time field");
    }
    if (lease.mode == LeaseMode::at
        && (lease.interval != MonotonicTime{}
            || lease.phase != MonotonicTime{})) {
        throw std::invalid_argument("one-shot lease carries a repeat field");
    }
    if ((lease.mode == LeaseMode::periodic
         || lease.mode == LeaseMode::continuous)
        && lease.deadline != MonotonicTime{}) {
        throw std::invalid_argument("repeating lease carries a deadline");
    }
    if (lease.mode == LeaseMode::at && lease.deadline < m_clock.now()) {
        throw std::invalid_argument("one-shot lease deadline is in the past");
    }
    if (lease.mode != LeaseMode::periodic && lease.phase != MonotonicTime{}) {
        throw std::invalid_argument("only periodic leases accept a phase");
    }

    if (m_nextLeaseGeneration == 0) {
        throw std::overflow_error("lease generation exhausted");
    }
    const std::uint64_t generation = m_nextLeaseGeneration++;
    m_leases.insert_or_assign(id, LeaseState{
        .generation = generation,
        .lease = lease,
    });
}

void FrameScheduler::releaseLease(LeaseId id) noexcept {
    m_leases.erase(id);
}

void FrameScheduler::classifyProducer(
    ProducerId id,
    ProducerClassification classification
) {
    switch (classification) {
    case ProducerClassification::onChange:
    case ProducerClassification::leaseManaged:
        break;
    default:
        throw std::invalid_argument("unknown producer classification");
    }
    m_classifications.insert_or_assign(id.value, classification);
    m_unknownLive.erase(id.value);
}

void FrameScheduler::releaseUnknownProducer(ProducerId id) noexcept {
    m_unknownLive.erase(id.value);
    const auto observed = m_unknownObservedRevision.find(id.value);
    if (observed != m_unknownObservedRevision.end()) {
        m_unknownReleasedThrough.insert_or_assign(id.value, observed->second);
    }
}

void FrameScheduler::observeExternalPresentation(MonotonicTime time) {
    if (m_outstanding.has_value()) {
        throw std::logic_error(
            "cannot observe presentation with a decision outstanding"
        );
    }
    if (time < MonotonicTime{}) {
        throw std::invalid_argument("external presentation time is negative");
    }
    m_clock.set(time);
    m_lastEvaluation = time;
}

MonotonicTime FrameScheduler::minimumInterval() const noexcept {
    constexpr std::int64_t second = 1'000'000'000;
    const auto ceiling = static_cast<std::int64_t>(m_fpsCeiling);
    return MonotonicTime((second + ceiling - 1) / ceiling);
}

FrameDecision FrameScheduler::decide(const ChangeIndex& changes) {
    if (m_outstanding.has_value()) {
        throw std::logic_error("previous scheduler decision is outstanding");
    }
    if (m_lastDecisionSequence == std::numeric_limits<std::uint64_t>::max()) {
        throw std::overflow_error("scheduler decision sequence exhausted");
    }
    const std::uint64_t sequence = m_lastDecisionSequence + 1;
    FrameDecision decision{
        .sequence = sequence,
        .time = m_clock.now(),
    };
    const auto own = [this](FrameDecision& result) {
        m_outstanding = result;
        m_outstandingPresentationSuppressed = false;
        m_lastDecisionSequence = result.sequence;
        return result;
    };
    if (!m_active) {
        decision.reasons.push_back(SchedulerReasonId::inactive);
        return own(decision);
    }

    bool workReady = false;
    for (const ChangeRecord& change : changes.pending()) {
        if (change.earliest > decision.time) {
            includeWake(decision.nextWake, change.earliest);
            includeReason(decision.reasons, SchedulerReasonId::waitingForEarliest);
            continue;
        }

        workReady = true;
        decision.readyChanges.push_back(change.revision);
        if (!decision.damage.has_value()) {
            decision.damage = change.damage;
        } else if (decision.damage->conservativeUnknown
                   || change.damage.conservativeUnknown) {
            decision.damage = ChangeDamage::unknown();
        } else {
            decision.damage->affectedIds.insert(
                decision.damage->affectedIds.end(),
                change.damage.affectedIds.begin(),
                change.damage.affectedIds.end()
            );
            std::sort(
                decision.damage->affectedIds.begin(),
                decision.damage->affectedIds.end()
            );
            decision.damage->affectedIds.erase(
                std::unique(
                    decision.damage->affectedIds.begin(),
                    decision.damage->affectedIds.end()
                ),
                decision.damage->affectedIds.end()
            );
        }
        includeProducer(decision.producers, change.producer);
        includeReason(decision.reasons, SchedulerReasonId::changeReady);
        if (!decision.earliestRequiredWork.has_value()
            || static_cast<unsigned>(change.requiredWork)
                < static_cast<unsigned>(*decision.earliestRequiredWork)) {
            decision.earliestRequiredWork = change.requiredWork;
        }
        if (change.deadline.has_value() && decision.time > *change.deadline) {
            decision.missedDeadline = true;
        }
        if (change.nextEvaluation.has_value()
            && *change.nextEvaluation > decision.time) {
            includeWake(decision.nextWake, *change.nextEvaluation);
        }

        if (!m_classifications.contains(change.producer.value)) {
            auto& observed = m_unknownObservedRevision[change.producer.value];
            observed = std::max(observed, change.revision);
            const auto released = m_unknownReleasedThrough.find(
                change.producer.value
            );
            if (released == m_unknownReleasedThrough.end()
                || change.revision > released->second) {
                m_unknownLive.insert(change.producer.value);
            }
        }
    }

    for (const auto& [producerValue, evaluation] :
         m_producerNextEvaluations) {
        if (decision.time >= evaluation) {
            workReady = true;
            const ProducerId producer{producerValue};
            includeProducer(decision.producers, producer);
            decision.producerEvaluations.push_back(producer);
            includeReason(
                decision.reasons,
                SchedulerReasonId::producerNextEvaluation
            );
        } else {
            includeWake(decision.nextWake, evaluation);
        }
    }

    for (auto& [id, state] : m_leases) {
        const ActivityLease& lease = state.lease;
        if (lease.mode == LeaseMode::onChange) {
            continue;
        }
        if (lease.mode == LeaseMode::at) {
            if (decision.time >= lease.deadline) {
                workReady = true;
                decision.leaseOccurrences.push_back({
                    .id = id,
                    .generation = state.generation,
                    .mode = lease.mode,
                    .scheduledTime = lease.deadline,
                });
                includeReason(decision.reasons, SchedulerReasonId::leaseAt);
                decision.missedDeadline |= decision.time > lease.deadline;
            } else {
                includeWake(decision.nextWake, lease.deadline);
            }
            continue;
        }
        if (lease.mode == LeaseMode::periodic) {
            if (decision.time < lease.phase) {
                includeWake(decision.nextWake, lease.phase);
                continue;
            }
            const MonotonicTime elapsed = decision.time - lease.phase;
            const MonotonicTime tick = decision.time
                - (elapsed % lease.interval);
            if (!state.lastCompletion.has_value()
                || tick > *state.lastCompletion) {
                workReady = true;
                decision.leaseOccurrences.push_back({
                    .id = id,
                    .generation = state.generation,
                    .mode = lease.mode,
                    .scheduledTime = tick,
                });
                includeReason(decision.reasons, SchedulerReasonId::leasePeriodic);
            }
            includeWake(decision.nextWake, checkedAdd(tick, lease.interval));
            continue;
        }

        const MonotonicTime effectiveInterval = std::max(
            lease.interval,
            minimumInterval()
        );
        const auto dueTime = state.lastCompletion.has_value()
            ? std::optional<MonotonicTime>(checkedAdd(
                *state.lastCompletion,
                effectiveInterval
            ))
            : std::nullopt;
        if (!dueTime.has_value() || decision.time >= *dueTime) {
            workReady = true;
            decision.leaseOccurrences.push_back({
                .id = id,
                .generation = state.generation,
                .mode = lease.mode,
                .scheduledTime = decision.time,
            });
            includeReason(decision.reasons, SchedulerReasonId::leaseContinuous);
            includeWake(
                decision.nextWake,
                checkedAdd(decision.time, effectiveInterval)
            );
        } else {
            includeWake(decision.nextWake, *dueTime);
        }
    }

    if (!m_unknownLive.empty()) {
        workReady = true;
        includeReason(
            decision.reasons,
            SchedulerReasonId::unknownProducerContinuous
        );
        includeWake(
            decision.nextWake,
            checkedAdd(decision.time, minimumInterval())
        );
    }

    if (workReady && m_lastEvaluation.has_value()) {
        const MonotonicTime ceilingWake = checkedAdd(
            *m_lastEvaluation,
            minimumInterval()
        );
        if (decision.time < ceilingWake) {
            includeReason(decision.reasons, SchedulerReasonId::fpsCeiling);
            decision.nextWake = ceilingWake;
            return own(decision);
        }
    }

    decision.evaluate = workReady;
    if (workReady && !decision.earliestRequiredWork.has_value()) {
        decision.earliestRequiredWork = WorkStage::evaluate;
    }
    if (decision.evaluate && decision.nextWake.has_value()) {
        const MonotonicTime postEvaluationFloor = checkedAdd(
            decision.time,
            minimumInterval()
        );
        if (*decision.nextWake < postEvaluationFloor) {
            decision.nextWake = postEvaluationFloor;
        }
    }
    if (m_lastEvaluation.has_value() && decision.nextWake.has_value()) {
        const MonotonicTime priorEvaluationFloor = checkedAdd(
            *m_lastEvaluation,
            minimumInterval()
        );
        if (*decision.nextWake < priorEvaluationFloor) {
            decision.nextWake = priorEvaluationFloor;
        }
    }
    if (!workReady && decision.reasons.empty()) {
        decision.reasons.push_back(SchedulerReasonId::noWork);
    }
    return own(decision);
}

std::optional<MonotonicTime> FrameScheduler::projectedNextWake(
    const ChangeIndex& changes
) const {
    FrameScheduler projection(*this);
    projection.m_outstanding.reset();
    projection.m_outstandingPresentationSuppressed = false;
    if (projection.m_lastDecisionSequence
        == std::numeric_limits<std::uint64_t>::max()) {
        projection.m_lastDecisionSequence = 0;
    }
    const FrameDecision decision = projection.decide(changes);
    return decision.evaluate
        ? std::optional<MonotonicTime>(m_clock.now())
        : decision.nextWake;
}

PresentationEvidence FrameScheduler::complete(
    ChangeIndex& changes,
    const FrameDecision& decision,
    CompletionOutcome outcome
) {
    switch (outcome) {
    case CompletionOutcome::notEvaluated:
    case CompletionOutcome::evaluatedUnchanged:
    case CompletionOutcome::presented:
    case CompletionOutcome::presentationSuppressed:
    case CompletionOutcome::terminalPresentationSuppressed:
        break;
    default:
        throw std::invalid_argument("unknown completion outcome");
    }
    if (!m_outstanding.has_value() || decision != *m_outstanding) {
        throw std::invalid_argument(
            "scheduler decision is forged, mutated, or stale"
        );
    }
    if ((!decision.evaluate && outcome != CompletionOutcome::notEvaluated)
        || (decision.evaluate && outcome == CompletionOutcome::notEvaluated)) {
        throw std::invalid_argument("completion outcome contradicts decision");
    }
    if (decision.evaluate
        && (m_outstandingPresentationSuppressed || !m_active)
        && outcome != CompletionOutcome::presentationSuppressed) {
        throw std::invalid_argument(
            "suppressed outstanding decision requires suppression outcome"
        );
    }

    PresentationEvidence evidence{
        .decisionSequence = decision.sequence,
        .evaluated = decision.evaluate,
        .presented = outcome == CompletionOutcome::presented,
        .result = decision.evaluate
            ? (outcome == CompletionOutcome::presented
                   ? SchedulerReasonId::contentChanged
                   : (outcome == CompletionOutcome::evaluatedUnchanged
                          ? SchedulerReasonId::contentUnchanged
                          : SchedulerReasonId::presentationSuppressed))
            : (decision.reasons.empty() ? SchedulerReasonId::noWork
                                        : decision.reasons.back()),
    };
    if (!decision.evaluate) {
        m_outstanding.reset();
        m_outstandingPresentationSuppressed = false;
        return evidence;
    }

    if (outcome == CompletionOutcome::presentationSuppressed) {
        m_lastEvaluation = decision.time;
        m_outstanding.reset();
        m_outstandingPresentationSuppressed = false;
        return evidence;
    }

    std::vector<std::pair<ProducerId, MonotonicTime>> nextEvaluations;
    nextEvaluations.reserve(decision.readyChanges.size());
    evidence.acknowledgedChanges.reserve(decision.readyChanges.size());
    for (const ChangeRevision revision : decision.readyChanges) {
        const auto record = std::find_if(
            changes.pending().begin(),
            changes.pending().end(),
            [revision](const ChangeRecord& change) {
                return change.revision == revision;
            }
        );
        if (record == changes.pending().end()) {
            throw std::logic_error("ready change disappeared before completion");
        }
        if (record->nextEvaluation.has_value()
            && *record->nextEvaluation > decision.time) {
            nextEvaluations.emplace_back(
                record->producer,
                *record->nextEvaluation
            );
        }
    }

    auto prospectiveProducerNextEvaluations = m_producerNextEvaluations;
    for (const ProducerId producer : decision.producerEvaluations) {
        prospectiveProducerNextEvaluations.erase(producer.value);
    }
    for (const auto& [producer, evaluation] : nextEvaluations) {
        const auto existing = prospectiveProducerNextEvaluations.find(
            producer.value
        );
        if (existing == prospectiveProducerNextEvaluations.end()
            || evaluation < existing->second) {
            prospectiveProducerNextEvaluations.insert_or_assign(
                producer.value,
                evaluation
            );
        }
    }

    ChangeIndex prospectiveChanges = changes;
    for (const ChangeRevision revision : decision.readyChanges) {
        prospectiveChanges.acknowledge(revision);
    }

    auto prospectiveLeases = m_leases;
    for (const LeaseOccurrence& occurrence : decision.leaseOccurrences) {
        const auto state = prospectiveLeases.find(occurrence.id);
        if (state == prospectiveLeases.end()) {
            continue;
        }
        if (state->second.generation != occurrence.generation) {
            continue;
        }
        if (state->second.lease.mode == LeaseMode::at) {
            prospectiveLeases.erase(state);
        } else {
            state->second.lastCompletion = occurrence.scheduledTime;
        }
    }

    m_lastEvaluation = decision.time;
    m_producerNextEvaluations.swap(prospectiveProducerNextEvaluations);
    changes.swap(prospectiveChanges);
    m_leases.swap(prospectiveLeases);
    for (const ChangeRevision revision : decision.readyChanges) {
        evidence.acknowledgedChanges.push_back(revision);
    }
    m_outstanding.reset();
    m_outstandingPresentationSuppressed = false;
    return evidence;
}

std::uint64_t FrameScheduler::lastDecisionSequence() const noexcept {
    return m_lastDecisionSequence;
}

}
