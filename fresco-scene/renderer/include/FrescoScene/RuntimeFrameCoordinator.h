#pragma once

#include "FrescoScene/FrameScheduler.h"
#include "FrescoScene/FrameRenderResult.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace FrescoScene {

struct RuntimeFrameCoordinatorConfiguration {
    bool provenStatic = false;
    bool active = true;
    std::uint32_t framesPerSecond = 60;
};

template<typename Value, std::size_t Capacity = 16>
struct FixedEvidenceItems {
    std::array<Value, Capacity> values{};
    std::size_t count = 0;
    std::size_t truncated = 0;
};

struct RuntimeFrameDecisionEvidence {
    std::uint64_t sequence = 0;
    MonotonicTime time{};
    bool evaluate = false;
    bool missedDeadline = false;
    std::optional<WorkStage> earliestRequiredWork;
    bool damagePresent = false;
    bool damageConservativeUnknown = true;
    FixedEvidenceItems<std::uint64_t> affectedDamageIds;
    FixedEvidenceItems<SchedulerReasonId> reasons;
    FixedEvidenceItems<ChangeRevision> readyChanges;
    FixedEvidenceItems<ProducerId> producers;
    FixedEvidenceItems<ProducerId> producerEvaluations;
    FixedEvidenceItems<LeaseOccurrence> leaseOccurrences;
    std::optional<MonotonicTime> nextWake;
};

struct RuntimePresentationEvidence {
    std::uint64_t decisionSequence = 0;
    bool evaluated = false;
    bool presented = false;
    SchedulerReasonId result = SchedulerReasonId::noWork;
    FixedEvidenceItems<ChangeRevision> acknowledgedChanges;
};

struct RuntimeFrameCoordinatorEvidence {
    std::uint64_t invalidations = 0;
    std::uint64_t scriptTimerDeadlineSchedules = 0;
    std::uint64_t scriptTimerDeadlineReleases = 0;
    std::uint64_t particleLeaseAcquisitions = 0;
    std::uint64_t particleLeaseReleases = 0;
    std::uint64_t mediaFrameDeadlineSchedules = 0;
    std::uint64_t mediaFrameDeadlineReplacements = 0;
    std::uint64_t mediaFrameDeadlineReleases = 0;
    bool mediaFrameDeadlineActive = false;
    std::uint64_t mediaFrameReadyInvalidations = 0;
    std::uint64_t mediaFrameReadyPresentations = 0;
    std::optional<ChangeRevision> lastMediaFrameReadyRevision;
    std::optional<ChangeRevision> lastPresentedMediaFrameReadyRevision;
    std::optional<std::uint64_t> lastMediaFrameReadyDecisionSequence;
    std::uint64_t audioEnvelopeDeadlineSchedules = 0;
    std::uint64_t audioEnvelopeDeadlineReplacements = 0;
    std::uint64_t audioEnvelopeDeadlineReleases = 0;
    bool audioEnvelopeDeadlineActive = false;
    std::uint64_t audioReadyInvalidations = 0;
    std::uint64_t audioReadyPresentations = 0;
    std::optional<ChangeRevision> lastAudioReadyRevision;
    std::optional<ChangeRevision> lastPresentedAudioReadyRevision;
    std::optional<std::uint64_t> lastAudioReadyDecisionSequence;
    std::uint64_t decisions = 0;
    std::uint64_t evaluations = 0;
    std::uint64_t presentations = 0;
    std::uint64_t presentationSuppressions = 0;
    std::uint64_t notEvaluated = 0;
    std::uint64_t externalPresentations = 0;
    std::uint64_t missedDeadlines = 0;
    std::array<std::uint64_t, 14> reasonCounts{};
    std::optional<RuntimeFrameDecisionEvidence> lastDecision;
    std::optional<RuntimePresentationEvidence> lastCompletion;
    std::optional<MonotonicTime> nextWake;
};

class RuntimeFrameCoordinator {
public:
    explicit RuntimeFrameCoordinator(
        RuntimeFrameCoordinatorConfiguration configuration
    );

    void setTime(MonotonicTime relativeTime);
    [[nodiscard]] MonotonicTime time() const noexcept;
    void setActive(bool active);
    void setFramesPerSecond(std::uint32_t framesPerSecond);
    void setScriptTimerDeadline(std::optional<MonotonicTime> deadline);
    void setParticleContinuousRequired(bool required);
    void setMediaFrameDeadline(std::optional<MonotonicTime> deadline);
    void setAudioEnvelopeDeadline(std::optional<MonotonicTime> deadline);

    [[nodiscard]] ChangeRevision invalidate(
        ProducerId producer,
        ChangeReasonId reason,
        WorkStage requiredWork = WorkStage::evaluate,
        std::optional<MonotonicTime> earliest = std::nullopt,
        std::optional<MonotonicTime> deadline = std::nullopt,
        std::optional<MonotonicTime> nextEvaluation = std::nullopt,
        ChangeDamage damage = ChangeDamage::unknown()
    );
    [[nodiscard]] ChangeRevision invalidateMediaFrameReady();
    [[nodiscard]] ChangeRevision invalidateAudioReady();

    [[nodiscard]] FrameDecision decide();
    [[nodiscard]] PresentationEvidence completeNotEvaluated(
        const FrameDecision& decision
    );
    [[nodiscard]] PresentationEvidence completeRendered(
        const FrameDecision& decision,
        FrameRenderResult result
    );
    void observeExternalPresentation(MonotonicTime relativeTime);

    [[nodiscard]] std::optional<MonotonicTime> nextWake() const noexcept;
    [[nodiscard]] std::optional<MonotonicTime> timeUntilNextWake() const noexcept;
    [[nodiscard]] std::optional<int> pollTimeoutMilliseconds() const noexcept;
    [[nodiscard]] const RuntimeFrameCoordinatorEvidence& evidence() const noexcept;
    [[nodiscard]] const ChangeIndex& changes() const noexcept;

private:
    void refreshNextWake();
    void recordDecisionEvidence(
        const FrameDecision& decision,
        const PresentationEvidence& completion
    ) noexcept;
    [[nodiscard]] MonotonicTime minimumInterval() const noexcept;

    static constexpr LeaseId continuousLeaseId = 1;
    static constexpr LeaseId scriptTimerLeaseId = 2;
    static constexpr LeaseId particleLeaseId = 3;
    static constexpr LeaseId mediaFrameLeaseId = 4;
    static constexpr LeaseId audioEnvelopeLeaseId = 5;

    VirtualSchedulerClock m_clock;
    ChangeIndex m_changes;
    FrameScheduler m_scheduler;
    RuntimeFrameCoordinatorEvidence m_evidence;
    std::uint32_t m_framesPerSecond = 60;
    bool m_provenStatic = false;
    std::optional<MonotonicTime> m_scriptTimerDeadline;
    bool m_particleContinuousRequired = false;
    std::optional<MonotonicTime> m_mediaFrameDeadline;
    std::optional<MonotonicTime> m_audioEnvelopeDeadline;
};

}
