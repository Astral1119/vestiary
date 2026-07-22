#include "FrescoScene/ChangeIndex.h"

#include <cassert>
#include <chrono>
#include <limits>
#include <stdexcept>
#include <vector>

namespace {

using namespace std::chrono_literals;
using FrescoScene::ChangeDamage;
using FrescoScene::ChangeIndex;
using FrescoScene::ChangeProducers::media;
using FrescoScene::ChangeProducers::script;
using FrescoScene::ChangeReasons::externalEvent;
using FrescoScene::ChangeReasons::resourceReady;
using FrescoScene::WorkStage;

void testMonotonicRecordsAndStructuredEvidence() {
    ChangeIndex index;
    assert(index.empty());
    assert(index.revision() == 0);

    const auto first = index.record({
        .producer = script,
        .reason = externalEvent,
        .damage = ChangeDamage::identifiers({42, 7, 42}),
        .requiredWork = WorkStage::evaluate,
        .earliest = 10ms,
        .deadline = 15ms,
        .nextEvaluation = 12ms,
    });
    const auto second = index.record({
        .producer = media,
        .reason = resourceReady,
        .damage = ChangeDamage::unknown(),
        .requiredWork = WorkStage::upload,
        .earliest = 20ms,
    });

    assert(first == 1);
    assert(second == 2);
    assert(index.revision() == 2);
    assert(index.pending().size() == 2);

    const auto& scripted = index.pending().front();
    assert(scripted.revision == first);
    assert(scripted.producer == script);
    assert(scripted.reason == externalEvent);
    assert(!scripted.damage.conservativeUnknown);
    assert((scripted.damage.affectedIds == std::vector<std::uint64_t>{7, 42}));
    assert(scripted.requiredWork == WorkStage::evaluate);
    assert(scripted.earliest == 10ms);
    assert(scripted.deadline == 15ms);
    assert(scripted.nextEvaluation == 12ms);

    const auto& decodedFrame = index.pending().back();
    assert(decodedFrame.producer == media);
    assert(decodedFrame.reason == resourceReady);
    assert(decodedFrame.damage.conservativeUnknown);
    assert(decodedFrame.damage.affectedIds.empty());
    assert(decodedFrame.requiredWork == WorkStage::upload);
}

void testAcknowledgementIsOrderedAndBounded() {
    ChangeIndex index;
    const auto first = index.record({});
    const auto second = index.record({});
    const auto third = index.record({});

    index.acknowledgeThrough(second);
    assert(index.acknowledgedRevision() == second);
    assert(index.pending().size() == 1);
    assert(index.pending().front().revision == third);

    index.acknowledgeThrough(first);
    assert(index.acknowledgedRevision() == second);

    index.acknowledgeThrough(third);
    assert(index.empty());
    assert(index.revision() == third);

    bool rejectedFuture = false;
    try {
        index.acknowledgeThrough(third + 1);
    } catch (const std::out_of_range&) {
        rejectedFuture = true;
    }
    assert(rejectedFuture);
}

void testSelectiveAcknowledgementPreservesFutureEarlierRevision() {
    ChangeIndex index;
    const auto futureFirst = index.record({
        .producer = script,
        .reason = externalEvent,
        .earliest = 50ms,
    });
    const auto readySecond = index.record({
        .producer = media,
        .reason = resourceReady,
        .earliest = 0ms,
    });

    index.acknowledge(readySecond);
    assert(index.acknowledgedRevision() == 0);
    assert(index.pending().size() == 1);
    assert(index.pending().front().revision == futureFirst);
    assert(index.pending().front().earliest == 50ms);

    index.acknowledge(readySecond);
    assert(index.acknowledgedRevision() == 0);
    assert(index.pending().size() == 1);

    index.acknowledge(futureFirst);
    assert(index.acknowledgedRevision() == readySecond);
    assert(index.empty());
}

void testSelectiveAcknowledgementValidation() {
    ChangeIndex index;
    const auto revision = index.record({});

    bool rejectedZero = false;
    try {
        index.acknowledge(0);
    } catch (const std::invalid_argument&) {
        rejectedZero = true;
    }
    assert(rejectedZero);
    assert(index.pending().size() == 1);

    bool rejectedFuture = false;
    try {
        index.acknowledge(revision + 1);
    } catch (const std::out_of_range&) {
        rejectedFuture = true;
    }
    assert(rejectedFuture);
    assert(index.pending().size() == 1);

    index.acknowledgeThrough(0);
    assert(index.acknowledgedRevision() == 0);
    assert(index.pending().size() == 1);
}

void testAcknowledgeThroughFoldsSparseAcknowledgements() {
    ChangeIndex index;
    const auto first = index.record({});
    const auto second = index.record({});
    const auto third = index.record({});
    const auto fourth = index.record({});

    index.acknowledge(second);
    index.acknowledge(third);
    assert(index.acknowledgedRevision() == 0);
    assert(index.pending().size() == 2);
    assert(index.pending()[0].revision == first);
    assert(index.pending()[1].revision == fourth);

    index.acknowledgeThrough(first);
    assert(index.acknowledgedRevision() == third);
    assert(index.pending().size() == 1);
    assert(index.pending().front().revision == fourth);
}

void testInvalidTimeRangesFailClosed() {
    ChangeIndex index;
    bool rejectedDeadline = false;
    try {
        (void)index.record({.earliest = 20ms, .deadline = 19ms});
    } catch (const std::invalid_argument&) {
        rejectedDeadline = true;
    }
    assert(rejectedDeadline);
    assert(index.empty());

    bool rejectedEvaluation = false;
    try {
        (void)index.record({.earliest = 20ms, .nextEvaluation = 19ms});
    } catch (const std::invalid_argument&) {
        rejectedEvaluation = true;
    }
    assert(rejectedEvaluation);
    assert(index.empty());
}

void testRecordBoundaryNormalizesDamage() {
    ChangeIndex index;
    (void)index.record({
        .damage = ChangeDamage::identifiers({}),
    });
    assert(index.pending().front().damage.conservativeUnknown);

    (void)index.record({
        .damage = {
            .conservativeUnknown = false,
            .affectedIds = {},
        },
    });
    assert(index.pending().back().damage.conservativeUnknown);

    (void)index.record({
        .damage = {
            .conservativeUnknown = true,
            .affectedIds = {9, 3},
        },
    });
    assert(index.pending().back().damage.conservativeUnknown);
    assert(index.pending().back().damage.affectedIds.empty());

    (void)index.record({
        .damage = {
            .conservativeUnknown = false,
            .affectedIds = {9, 3, 9, 1, 3},
        },
    });
    assert(!index.pending().back().damage.conservativeUnknown);
    assert((index.pending().back().damage.affectedIds
        == std::vector<std::uint64_t>{1, 3, 9}));
}

void testRevisionOverflowPreservesRestoredState() {
    constexpr auto maximum = std::numeric_limits<
        FrescoScene::ChangeRevision
    >::max();
    ChangeIndex index(maximum);
    assert(index.revision() == maximum);
    assert(index.acknowledgedRevision() == maximum);
    assert(index.empty());

    bool rejected = false;
    try {
        (void)index.record({});
    } catch (const std::overflow_error&) {
        rejected = true;
    }
    assert(rejected);
    assert(index.revision() == maximum);
    assert(index.acknowledgedRevision() == maximum);
    assert(index.empty());
}

}

int main() {
    testMonotonicRecordsAndStructuredEvidence();
    testAcknowledgementIsOrderedAndBounded();
    testSelectiveAcknowledgementPreservesFutureEarlierRevision();
    testSelectiveAcknowledgementValidation();
    testAcknowledgeThroughFoldsSparseAcknowledgements();
    testInvalidTimeRangesFailClosed();
    testRecordBoundaryNormalizesDamage();
    testRevisionOverflowPreservesRestoredState();
}
