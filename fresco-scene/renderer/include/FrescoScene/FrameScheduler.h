#pragma once

#include "FrescoScene/ChangeIndex.h"

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <vector>

namespace FrescoScene {

using LeaseId = std::uint64_t;

class VirtualSchedulerClock {
public:
    [[nodiscard]] MonotonicTime now() const noexcept;
    void set(MonotonicTime time);
    void advance(MonotonicTime duration);

private:
    MonotonicTime m_now{};
};

enum class LeaseMode : std::uint8_t {
    onChange,
    at,
    periodic,
    continuous,
};

struct ActivityLease {
    LeaseMode mode = LeaseMode::onChange;
    MonotonicTime deadline{};
    MonotonicTime interval{};
    MonotonicTime phase{};

    static ActivityLease onChange();
    static ActivityLease at(MonotonicTime deadline);
    static ActivityLease periodic(
        MonotonicTime interval,
        MonotonicTime phase = MonotonicTime{}
    );
    static ActivityLease continuous(MonotonicTime preferredInterval);
};

enum class ProducerClassification : std::uint8_t {
    onChange,
    leaseManaged,
};

enum class SchedulerReasonId : std::uint16_t {
    inactive = 1,
    noWork = 2,
    changeReady = 3,
    leaseAt = 4,
    leasePeriodic = 5,
    leaseContinuous = 6,
    unknownProducerContinuous = 7,
    fpsCeiling = 8,
    waitingForEarliest = 9,
    contentChanged = 10,
    contentUnchanged = 11,
    producerNextEvaluation = 12,
    presentationSuppressed = 13,
};

struct LeaseOccurrence {
    LeaseId id = 0;
    std::uint64_t generation = 0;
    LeaseMode mode = LeaseMode::onChange;
    MonotonicTime scheduledTime{};

    friend bool operator==(const LeaseOccurrence&, const LeaseOccurrence&)
        = default;
};

struct FrameDecision {
    std::uint64_t sequence = 0;
    MonotonicTime time{};
    bool evaluate = false;
    bool missedDeadline = false;
    std::optional<WorkStage> earliestRequiredWork;
    std::optional<ChangeDamage> damage;
    std::vector<SchedulerReasonId> reasons;
    std::vector<ChangeRevision> readyChanges;
    std::vector<ProducerId> producers;
    std::vector<ProducerId> producerEvaluations;
    std::vector<LeaseOccurrence> leaseOccurrences;
    std::optional<MonotonicTime> nextWake;

    friend bool operator==(const FrameDecision&, const FrameDecision&) = default;
};

struct PresentationEvidence {
    std::uint64_t decisionSequence = 0;
    bool evaluated = false;
    bool presented = false;
    SchedulerReasonId result = SchedulerReasonId::noWork;
    std::vector<ChangeRevision> acknowledgedChanges;
};

enum class CompletionOutcome : std::uint8_t {
    notEvaluated,
    evaluatedUnchanged,
    presented,
    presentationSuppressed,
    terminalPresentationSuppressed,
};

class FrameScheduler {
public:
    explicit FrameScheduler(
        VirtualSchedulerClock& clock,
        std::uint64_t restoredDecisionSequence = 0
    );

    void setActive(bool active) noexcept;
    void setFpsCeiling(std::uint32_t framesPerSecond);
    void setLease(LeaseId id, ActivityLease lease);
    void releaseLease(LeaseId id) noexcept;
    void classifyProducer(ProducerId id, ProducerClassification classification);
    void releaseUnknownProducer(ProducerId id) noexcept;
    void observeExternalPresentation(MonotonicTime time);

    [[nodiscard]] FrameDecision decide(const ChangeIndex& changes);
    [[nodiscard]] std::optional<MonotonicTime> projectedNextWake(
        const ChangeIndex& changes
    ) const;
    [[nodiscard]] PresentationEvidence complete(
        ChangeIndex& changes,
        const FrameDecision& decision,
        CompletionOutcome outcome
    );
    [[nodiscard]] std::uint64_t lastDecisionSequence() const noexcept;

private:
    struct LeaseState {
        std::uint64_t generation = 0;
        ActivityLease lease;
        std::optional<MonotonicTime> lastCompletion;
    };

    [[nodiscard]] MonotonicTime minimumInterval() const noexcept;

    VirtualSchedulerClock& m_clock;
    bool m_active = true;
    std::uint32_t m_fpsCeiling = 60;
    std::uint64_t m_lastDecisionSequence = 0;
    std::uint64_t m_nextLeaseGeneration = 1;
    std::optional<FrameDecision> m_outstanding;
    bool m_outstandingPresentationSuppressed = false;
    std::optional<MonotonicTime> m_lastEvaluation;
    std::map<LeaseId, LeaseState> m_leases;
    std::map<std::uint32_t, ProducerClassification> m_classifications;
    std::set<std::uint32_t> m_unknownLive;
    std::map<std::uint32_t, ChangeRevision> m_unknownObservedRevision;
    std::map<std::uint32_t, ChangeRevision> m_unknownReleasedThrough;
    std::map<std::uint32_t, MonotonicTime> m_producerNextEvaluations;
};

}
