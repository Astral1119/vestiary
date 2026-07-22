#pragma once

#include <chrono>
#include <cstdint>
#include <optional>
#include <set>
#include <vector>

namespace FrescoScene {

using ChangeRevision = std::uint64_t;
using MonotonicTime = std::chrono::nanoseconds;

struct ProducerId {
    std::uint32_t value = 0;

    friend bool operator==(ProducerId, ProducerId) = default;
};

struct ChangeReasonId {
    std::uint32_t value = 0;

    friend bool operator==(ChangeReasonId, ChangeReasonId) = default;
};

namespace ChangeProducers {

inline constexpr ProducerId unknown{0};
inline constexpr ProducerId supervisor{1};
inline constexpr ProducerId scene{2};
inline constexpr ProducerId script{3};
inline constexpr ProducerId particle{4};
inline constexpr ProducerId media{5};
inline constexpr ProducerId audio{6};

}

namespace ChangeReasons {

inline constexpr ChangeReasonId unknown{0};
inline constexpr ChangeReasonId initialLoad{1};
inline constexpr ChangeReasonId externalEvent{2};
inline constexpr ChangeReasonId timeAdvanced{3};
inline constexpr ChangeReasonId resourceReady{4};
inline constexpr ChangeReasonId propertyChanged{5};
inline constexpr ChangeReasonId policyChanged{6};

}

enum class WorkStage : std::uint8_t {
    // Ordered from the earliest pipeline stage that must be repeated to the
    // latest. Aggregation selects the minimum stage.
    evaluate,
    upload,
    encode,
    present,
};

struct ChangeDamage {
    bool conservativeUnknown = true;
    std::vector<std::uint64_t> affectedIds;

    static ChangeDamage unknown();
    static ChangeDamage identifiers(std::vector<std::uint64_t> affectedIds);

    friend bool operator==(const ChangeDamage&, const ChangeDamage&) = default;
};

struct ChangeRequest {
    ProducerId producer = ChangeProducers::unknown;
    ChangeReasonId reason = ChangeReasons::unknown;
    ChangeDamage damage;
    WorkStage requiredWork = WorkStage::evaluate;
    MonotonicTime earliest{};
    std::optional<MonotonicTime> deadline;
    std::optional<MonotonicTime> nextEvaluation;
};

struct ChangeRecord {
    ChangeRevision revision = 0;
    ProducerId producer = ChangeProducers::unknown;
    ChangeReasonId reason = ChangeReasons::unknown;
    ChangeDamage damage;
    WorkStage requiredWork = WorkStage::evaluate;
    MonotonicTime earliest{};
    std::optional<MonotonicTime> deadline;
    std::optional<MonotonicTime> nextEvaluation;
};

class ChangeIndex {
public:
    ChangeIndex() = default;

    // A restored index has no pending records; the restored revision has
    // already been acknowledged by the persisted consumer state.
    explicit ChangeIndex(ChangeRevision restoredRevision) noexcept;

    [[nodiscard]] ChangeRevision record(ChangeRequest request);
    void acknowledge(ChangeRevision revision);
    void acknowledgeThrough(ChangeRevision revision);
    void swap(ChangeIndex& other) noexcept;

    [[nodiscard]] ChangeRevision revision() const noexcept;
    [[nodiscard]] ChangeRevision acknowledgedRevision() const noexcept;
    [[nodiscard]] const std::vector<ChangeRecord>& pending() const noexcept;
    [[nodiscard]] bool empty() const noexcept;

private:
    void advanceAcknowledgedRevision() noexcept;

    ChangeRevision m_revision = 0;
    ChangeRevision m_acknowledgedRevision = 0;
    std::vector<ChangeRecord> m_pending;
    std::set<ChangeRevision> m_acknowledgedOutOfOrder;
};

}
