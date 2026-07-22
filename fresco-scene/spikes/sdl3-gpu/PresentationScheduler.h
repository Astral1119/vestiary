#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace fresco::sdl3_spike {

struct SchedulerInputEvent {
    std::uint32_t sequence = 0;
    std::uint64_t appliedAtNanoseconds = 0;
    std::string kind;
    std::string reason;
    std::optional<std::uint64_t> targetNanoseconds;
    std::uint32_t requestedFpsCeiling = 0;
    std::uint32_t policyRevisionAfter = 0;
    std::optional<std::uint64_t> nextWakeAfterNanoseconds;
};

struct PresentationCompletion {
    std::uint32_t submissionOrdinal = 0;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint64_t wallObservedAtNanoseconds = 0;
};

struct SchedulerDecision {
    std::uint32_t sequence = 0;
    std::uint64_t semanticNanoseconds = 0;
    std::vector<std::string> reasons;
    std::uint32_t policyRevision = 0;
    std::uint32_t fpsCeiling = 0;
    std::uint64_t periodNanoseconds = 0;
    std::optional<std::uint64_t> nextWakeAfterNanoseconds;
    std::optional<PresentationCompletion> completion;
};

class PresentationAuthorization {
public:
    const SchedulerDecision& decision() const { return decision_; }

private:
    friend class PresentationScheduler;
    PresentationAuthorization(
        std::uint64_t token,
        SchedulerDecision decision)
        : token_(token), decision_(std::move(decision)) {}

    std::uint64_t token_ = 0;
    SchedulerDecision decision_;
};

class PresentationScheduler {
public:
    explicit PresentationScheduler(std::string faultMode = {});

    void configureStaticPolicy(std::uint32_t fpsCeiling);
    void invalidate(std::string reason, std::string kind = "invalidate");
    void startContinuousLease(std::uint32_t fpsCeiling);
    void retime(std::uint32_t fpsCeiling);
    void pause();
    void resume();

    void beginAdvance(std::uint64_t targetNanoseconds);
    std::optional<SchedulerDecision> nextDecision();
    PresentationAuthorization authorize(std::uint32_t requestedSequence);
    void complete(
        const PresentationAuthorization& authorization,
        PresentationCompletion completion);

    std::uint64_t nowNanoseconds() const { return nowNanoseconds_; }
    std::uint32_t fpsCeiling() const { return fpsCeiling_; }
    std::uint64_t periodNanoseconds() const;
    bool continuousLease() const { return continuousLease_; }
    bool paused() const { return paused_; }
    std::optional<std::uint64_t> nextWakeNanoseconds() const {
        return nextWakeNanoseconds_;
    }
    const std::vector<SchedulerInputEvent>& inputEvents() const {
        return inputEvents_;
    }
    const std::vector<SchedulerDecision>& decisions() const {
        return decisions_;
    }

private:
    void recordInput(
        std::string kind,
        std::string reason,
        std::optional<std::uint64_t> target,
        std::uint32_t requestedFps);
    void queueReason(std::string reason);
    void scheduleContinuousWake();
    std::uint64_t continuousDeadline() const;

    std::string faultMode_;
    std::uint64_t nowNanoseconds_ = 0;
    std::uint32_t fpsCeiling_ = 0;
    std::uint32_t policyRevision_ = 0;
    bool continuousLease_ = false;
    bool paused_ = false;
    std::uint64_t cadenceAnchorNanoseconds_ = 0;
    std::uint64_t cadenceOrdinal_ = 0;
    std::optional<std::uint64_t> nextWakeNanoseconds_;
    std::optional<std::uint64_t> advanceTargetNanoseconds_;
    std::optional<std::uint32_t> pendingDecisionSequence_;
    std::optional<std::uint32_t> authorizedDecisionSequence_;
    std::optional<std::uint64_t> authorizationToken_;
    std::uint64_t nextAuthorizationToken_ = 1;
    bool duplicateFaultApplied_ = false;
    std::vector<std::string> pendingReasons_;
    std::vector<SchedulerInputEvent> inputEvents_;
    std::vector<SchedulerDecision> decisions_;
};

}  // namespace fresco::sdl3_spike
