#include "PresentationScheduler.h"

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>

namespace fresco::sdl3_spike {
namespace {

constexpr std::uint64_t kNanosecondsPerSecond = 1'000'000'000ULL;

}  // namespace

PresentationScheduler::PresentationScheduler(std::string faultMode)
    : faultMode_(std::move(faultMode)) {}

std::uint64_t PresentationScheduler::periodNanoseconds() const {
    if (fpsCeiling_ == 0) return 0;
    return kNanosecondsPerSecond / fpsCeiling_;
}

void PresentationScheduler::configureStaticPolicy(std::uint32_t fpsCeiling) {
    if (fpsCeiling == 0 || continuousLease_ || policyRevision_ != 0 ||
        advanceTargetNanoseconds_.has_value() ||
        pendingDecisionSequence_.has_value()) {
        throw std::logic_error("invalid static policy");
    }
    fpsCeiling_ = fpsCeiling;
    ++policyRevision_;
    recordInput("static-policy", "fps-ceiling", std::nullopt, fpsCeiling);
}

void PresentationScheduler::recordInput(
    std::string kind,
    std::string reason,
    std::optional<std::uint64_t> target,
    std::uint32_t requestedFps) {
    inputEvents_.push_back(SchedulerInputEvent{
        static_cast<std::uint32_t>(inputEvents_.size() + 1),
        nowNanoseconds_, std::move(kind), std::move(reason), target,
        requestedFps, policyRevision_, nextWakeNanoseconds_});
}

void PresentationScheduler::queueReason(std::string reason) {
    if (std::find(pendingReasons_.begin(), pendingReasons_.end(), reason) ==
        pendingReasons_.end()) {
        pendingReasons_.push_back(std::move(reason));
    }
}

void PresentationScheduler::invalidate(std::string reason, std::string kind) {
    if (advanceTargetNanoseconds_.has_value() ||
        pendingDecisionSequence_.has_value()) {
        throw std::logic_error("cannot invalidate during an advance");
    }
    queueReason(reason);
    if (!paused_ && !continuousLease_) nextWakeNanoseconds_ = nowNanoseconds_;
    recordInput(std::move(kind), std::move(reason), std::nullopt, 0);
}

std::uint64_t PresentationScheduler::continuousDeadline() const {
    if (fpsCeiling_ == 0 || cadenceOrdinal_ == 0) {
        throw std::logic_error("continuous deadline has no cadence");
    }
    const auto quotient = cadenceOrdinal_ / fpsCeiling_;
    const auto remainder = cadenceOrdinal_ % fpsCeiling_;
    if (quotient >
        (std::numeric_limits<std::uint64_t>::max() -
         cadenceAnchorNanoseconds_) / kNanosecondsPerSecond) {
        throw std::overflow_error("continuous deadline overflow");
    }
    std::uint64_t deadline = cadenceAnchorNanoseconds_ +
        quotient * kNanosecondsPerSecond +
        (remainder * kNanosecondsPerSecond) / fpsCeiling_;
    if (faultMode_ == "early-wake" && deadline > 0) --deadline;
    return deadline;
}

void PresentationScheduler::scheduleContinuousWake() {
    if (continuousLease_ && !paused_) {
        nextWakeNanoseconds_ = continuousDeadline();
    } else {
        nextWakeNanoseconds_.reset();
    }
}

void PresentationScheduler::startContinuousLease(std::uint32_t fpsCeiling) {
    if (fpsCeiling == 0 || advanceTargetNanoseconds_.has_value() ||
        pendingDecisionSequence_.has_value()) {
        throw std::logic_error("invalid continuous lease start");
    }
    continuousLease_ = true;
    paused_ = false;
    fpsCeiling_ = fpsCeiling;
    ++policyRevision_;
    cadenceAnchorNanoseconds_ = nowNanoseconds_;
    cadenceOrdinal_ = 1;
    scheduleContinuousWake();
    recordInput("lease-start", "continuous-lease", std::nullopt, fpsCeiling);
}

void PresentationScheduler::retime(std::uint32_t fpsCeiling) {
    if (!continuousLease_ || fpsCeiling == 0 ||
        advanceTargetNanoseconds_.has_value() ||
        pendingDecisionSequence_.has_value()) {
        throw std::logic_error("invalid continuous retime");
    }
    if (faultMode_ != "stale-fps-after-retime") fpsCeiling_ = fpsCeiling;
    ++policyRevision_;
    cadenceAnchorNanoseconds_ = nowNanoseconds_;
    cadenceOrdinal_ = 1;
    queueReason("fps-ceiling");
    scheduleContinuousWake();
    recordInput("retime", "fps-ceiling", std::nullopt, fpsCeiling);
}

void PresentationScheduler::pause() {
    if (!continuousLease_ || advanceTargetNanoseconds_.has_value() ||
        pendingDecisionSequence_.has_value()) {
        throw std::logic_error("invalid pause");
    }
    paused_ = true;
    if (faultMode_ != "pause-wake") nextWakeNanoseconds_.reset();
    recordInput("pause", "pause", std::nullopt, fpsCeiling_);
}

void PresentationScheduler::resume() {
    if (!continuousLease_ || !paused_ || advanceTargetNanoseconds_.has_value() ||
        pendingDecisionSequence_.has_value()) {
        throw std::logic_error("invalid resume");
    }
    paused_ = false;
    ++policyRevision_;
    cadenceAnchorNanoseconds_ = nowNanoseconds_;
    cadenceOrdinal_ = 1;
    queueReason("resume-invalidation");
    scheduleContinuousWake();
    recordInput("resume", "resume-invalidation", std::nullopt, fpsCeiling_);
}

void PresentationScheduler::beginAdvance(std::uint64_t targetNanoseconds) {
    if (targetNanoseconds < nowNanoseconds_ ||
        advanceTargetNanoseconds_.has_value() ||
        pendingDecisionSequence_.has_value()) {
        throw std::logic_error("invalid virtual-clock advance");
    }
    advanceTargetNanoseconds_ = targetNanoseconds;
    recordInput("advance", "", targetNanoseconds, 0);
}

std::optional<SchedulerDecision> PresentationScheduler::nextDecision() {
    if (!advanceTargetNanoseconds_.has_value()) {
        throw std::logic_error("no virtual-clock advance is active");
    }
    if (pendingDecisionSequence_.has_value()) {
        throw std::logic_error("scheduler decision is not complete");
    }
    if (!nextWakeNanoseconds_.has_value() ||
        *nextWakeNanoseconds_ > *advanceTargetNanoseconds_) {
        nowNanoseconds_ = *advanceTargetNanoseconds_;
        advanceTargetNanoseconds_.reset();
        return std::nullopt;
    }

    nowNanoseconds_ = *nextWakeNanoseconds_;
    if (continuousLease_ && (!paused_ || faultMode_ == "pause-wake")) {
        queueReason("continuous-lease");
        ++cadenceOrdinal_;
        scheduleContinuousWake();
    } else {
        nextWakeNanoseconds_.reset();
    }
    if (pendingReasons_.empty()) {
        throw std::logic_error("scheduled wake has no presentation reason");
    }

    std::vector<std::string> emittedReasons;
    if (faultMode_ == "duplicate-uncoalesced" && !duplicateFaultApplied_ &&
        pendingReasons_.size() > 1) {
        duplicateFaultApplied_ = true;
        emittedReasons.push_back(pendingReasons_.front());
        pendingReasons_.erase(pendingReasons_.begin());
        nextWakeNanoseconds_ = nowNanoseconds_;
    } else {
        emittedReasons = std::move(pendingReasons_);
        pendingReasons_.clear();
    }
    if (faultMode_ == "missing-reason" && !emittedReasons.empty()) {
        emittedReasons.pop_back();
    }
    const std::uint64_t recordedAt = nowNanoseconds_ +
        (faultMode_ == "altered-decision-timestamp" ? 1ULL : 0ULL);
    decisions_.push_back(SchedulerDecision{
        static_cast<std::uint32_t>(decisions_.size() + 1), recordedAt,
        std::move(emittedReasons), policyRevision_, fpsCeiling_,
        periodNanoseconds(), nextWakeNanoseconds_, std::nullopt});
    pendingDecisionSequence_ = decisions_.back().sequence;
    return decisions_.back();
}

PresentationAuthorization PresentationScheduler::authorize(
    std::uint32_t requestedSequence) {
    if (requestedSequence == 0) {
        throw std::logic_error("zero presentation sequence");
    }
    if (!pendingDecisionSequence_.has_value()) {
        if (requestedSequence <= decisions_.size() &&
            decisions_[requestedSequence - 1].completion.has_value()) {
            throw std::logic_error("presentation sequence is already complete");
        }
        throw std::logic_error("no scheduler decision awaits authorization");
    }
    if (requestedSequence != *pendingDecisionSequence_) {
        throw std::logic_error("presentation sequence is not current");
    }
    if (authorizedDecisionSequence_.has_value() ||
        authorizationToken_.has_value()) {
        throw std::logic_error("presentation decision is already authorized");
    }
    const auto token = nextAuthorizationToken_++;
    authorizedDecisionSequence_ = requestedSequence;
    authorizationToken_ = token;
    return PresentationAuthorization(token, decisions_[requestedSequence - 1]);
}

void PresentationScheduler::complete(
    const PresentationAuthorization& authorization,
    PresentationCompletion completion) {
    const auto decisionSequence = authorization.decision_.sequence;
    if (!pendingDecisionSequence_.has_value() ||
        *pendingDecisionSequence_ != decisionSequence ||
        !authorizedDecisionSequence_.has_value() ||
        *authorizedDecisionSequence_ != decisionSequence ||
        !authorizationToken_.has_value() ||
        *authorizationToken_ != authorization.token_ ||
        decisionSequence == 0 || decisionSequence > decisions_.size() ||
        decisions_[decisionSequence - 1].completion.has_value() ||
        completion.submissionOrdinal == 0) {
        throw std::logic_error("invalid presentation completion");
    }
    decisions_[decisionSequence - 1].completion = completion;
    authorizedDecisionSequence_.reset();
    authorizationToken_.reset();
    pendingDecisionSequence_.reset();
}

}  // namespace fresco::sdl3_spike
