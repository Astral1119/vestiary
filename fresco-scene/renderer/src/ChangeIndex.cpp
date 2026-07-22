#include "FrescoScene/ChangeIndex.h"

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>

namespace FrescoScene {

namespace {

void normalizeDamage(ChangeDamage& damage) {
    if (damage.conservativeUnknown) {
        damage.affectedIds.clear();
        return;
    }

    std::sort(damage.affectedIds.begin(), damage.affectedIds.end());
    damage.affectedIds.erase(
        std::unique(damage.affectedIds.begin(), damage.affectedIds.end()),
        damage.affectedIds.end()
    );
    if (damage.affectedIds.empty()) {
        damage.conservativeUnknown = true;
    }
}

}

ChangeDamage ChangeDamage::unknown() {
    return {};
}

ChangeDamage ChangeDamage::identifiers(
    std::vector<std::uint64_t> affectedIds
) {
    return {
        .conservativeUnknown = false,
        .affectedIds = std::move(affectedIds),
    };
}

ChangeIndex::ChangeIndex(ChangeRevision restoredRevision) noexcept
    : m_revision(restoredRevision),
      m_acknowledgedRevision(restoredRevision) {}

ChangeRevision ChangeIndex::record(ChangeRequest request) {
    switch (request.requiredWork) {
    case WorkStage::evaluate:
    case WorkStage::upload:
    case WorkStage::encode:
    case WorkStage::present:
        break;
    default:
        throw std::invalid_argument("unknown work stage");
    }
    if (request.deadline.has_value()
        && *request.deadline < request.earliest) {
        throw std::invalid_argument("change deadline precedes earliest time");
    }
    if (request.nextEvaluation.has_value()
        && *request.nextEvaluation < request.earliest) {
        throw std::invalid_argument(
            "next evaluation precedes earliest time"
        );
    }
    if (m_revision == std::numeric_limits<ChangeRevision>::max()) {
        throw std::overflow_error("change revision exhausted");
    }
    normalizeDamage(request.damage);

    const ChangeRevision nextRevision = m_revision + 1;
    ChangeRecord record{
        .revision = nextRevision,
        .producer = request.producer,
        .reason = request.reason,
        .damage = std::move(request.damage),
        .requiredWork = request.requiredWork,
        .earliest = request.earliest,
        .deadline = request.deadline,
        .nextEvaluation = request.nextEvaluation,
    };
    m_pending.push_back(std::move(record));
    m_revision = nextRevision;
    return nextRevision;
}

void ChangeIndex::acknowledge(ChangeRevision revision) {
    if (revision == 0) {
        throw std::invalid_argument("change revision zero is not a record");
    }
    if (revision > m_revision) {
        throw std::out_of_range("cannot acknowledge a future revision");
    }
    if (revision <= m_acknowledgedRevision
        || m_acknowledgedOutOfOrder.contains(revision)) {
        return;
    }

    m_acknowledgedOutOfOrder.insert(revision);
    const auto pending = std::lower_bound(
        m_pending.begin(),
        m_pending.end(),
        revision,
        [](const ChangeRecord& record, ChangeRevision target) {
            return record.revision < target;
        }
    );
    if (pending != m_pending.end() && pending->revision == revision) {
        m_pending.erase(pending);
    }
    advanceAcknowledgedRevision();
}

void ChangeIndex::acknowledgeThrough(ChangeRevision revision) {
    if (revision > m_revision) {
        throw std::out_of_range("cannot acknowledge a future revision");
    }
    if (revision <= m_acknowledgedRevision) {
        return;
    }

    m_acknowledgedRevision = revision;
    const auto firstPending = std::upper_bound(
        m_pending.begin(),
        m_pending.end(),
        revision,
        [](ChangeRevision acknowledged, const ChangeRecord& record) {
            return acknowledged < record.revision;
        }
    );
    m_pending.erase(m_pending.begin(), firstPending);

    m_acknowledgedOutOfOrder.erase(
        m_acknowledgedOutOfOrder.begin(),
        m_acknowledgedOutOfOrder.upper_bound(revision)
    );
    advanceAcknowledgedRevision();
}

void ChangeIndex::advanceAcknowledgedRevision() noexcept {
    while (m_acknowledgedRevision < m_revision) {
        const ChangeRevision next = m_acknowledgedRevision + 1;
        const auto acknowledged = m_acknowledgedOutOfOrder.find(next);
        if (acknowledged == m_acknowledgedOutOfOrder.end()) {
            return;
        }
        m_acknowledgedOutOfOrder.erase(acknowledged);
        m_acknowledgedRevision = next;
    }
}

void ChangeIndex::swap(ChangeIndex& other) noexcept {
    using std::swap;
    swap(m_revision, other.m_revision);
    swap(m_acknowledgedRevision, other.m_acknowledgedRevision);
    m_pending.swap(other.m_pending);
    m_acknowledgedOutOfOrder.swap(other.m_acknowledgedOutOfOrder);
}

ChangeRevision ChangeIndex::revision() const noexcept {
    return m_revision;
}

ChangeRevision ChangeIndex::acknowledgedRevision() const noexcept {
    return m_acknowledgedRevision;
}

const std::vector<ChangeRecord>& ChangeIndex::pending() const noexcept {
    return m_pending;
}

bool ChangeIndex::empty() const noexcept {
    return m_pending.empty();
}

}
