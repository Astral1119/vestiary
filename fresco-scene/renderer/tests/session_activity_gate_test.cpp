#include "FrescoScene/SessionActivityGate.h"

#include <array>
#include <cassert>
#include <cstddef>

namespace {

using FrescoScene::SessionActivityGate;
using FrescoScene::SessionActivityTransition;

enum class Input {
    visible,
    paused,
};

struct Assignment {
    Input input;
    bool value;
};

void assertUpdate(const FrescoScene::SessionActivityUpdate &update,
                  SessionActivityTransition transition,
                  bool active) {
    assert(update.transition == transition);
    assert(update.active == active);
}

void testDefaultsAndInitialState() {
    SessionActivityGate defaultGate;
    assert(defaultGate.visible());
    assert(!defaultGate.paused());
    assert(defaultGate.active());

    SessionActivityGate hiddenPaused(false, true);
    assert(!hiddenPaused.visible());
    assert(hiddenPaused.paused());
    assert(!hiddenPaused.active());
}

void testHidePauseShowResume() {
    SessionActivityGate gate;

    assertUpdate(gate.setVisible(false), SessionActivityTransition::deactivated, false);
    assertUpdate(gate.setPaused(true), SessionActivityTransition::unchanged, false);
    assertUpdate(gate.setVisible(true), SessionActivityTransition::unchanged, false);
    assertUpdate(gate.setPaused(false), SessionActivityTransition::activated, true);
}

void testPauseHideResumeShow() {
    SessionActivityGate gate;

    assertUpdate(gate.setPaused(true), SessionActivityTransition::deactivated, false);
    assertUpdate(gate.setVisible(false), SessionActivityTransition::unchanged, false);
    assertUpdate(gate.setPaused(false), SessionActivityTransition::unchanged, false);
    assertUpdate(gate.setVisible(true), SessionActivityTransition::activated, true);
}

void testEveryAssignmentFromEveryState() {
    constexpr std::array<Assignment, 4> assignments{{
        {Input::visible, false},
        {Input::visible, true},
        {Input::paused, false},
        {Input::paused, true},
    }};

    for (const bool initialVisible : {false, true}) {
        for (const bool initialPaused : {false, true}) {
            for (const Assignment assignment : assignments) {
                SessionActivityGate gate(initialVisible, initialPaused);
                const bool wasActive = gate.active();
                const auto update = assignment.input == Input::visible
                    ? gate.setVisible(assignment.value)
                    : gate.setPaused(assignment.value);
                const bool isActive = gate.active();

                const auto expected = wasActive == isActive
                    ? SessionActivityTransition::unchanged
                    : (isActive ? SessionActivityTransition::activated
                                : SessionActivityTransition::deactivated);
                assertUpdate(update, expected, isActive);
            }
        }
    }
}

void testMixedAssignmentSequences() {
    constexpr std::array<Assignment, 4> assignments{{
        {Input::visible, false},
        {Input::visible, true},
        {Input::paused, false},
        {Input::paused, true},
    }};
    constexpr std::size_t sequenceLength = 6;
    constexpr std::size_t sequenceCount = 4096;

    for (const bool initialVisible : {false, true}) {
        for (const bool initialPaused : {false, true}) {
            for (std::size_t encoded = 0; encoded < sequenceCount; ++encoded) {
                SessionActivityGate gate(initialVisible, initialPaused);
                std::size_t remaining = encoded;
                for (std::size_t step = 0; step < sequenceLength; ++step) {
                    const Assignment assignment = assignments[remaining % assignments.size()];
                    remaining /= assignments.size();
                    const bool wasActive = gate.active();
                    const auto update = assignment.input == Input::visible
                        ? gate.setVisible(assignment.value)
                        : gate.setPaused(assignment.value);
                    const bool isActive = gate.active();
                    const auto expected = wasActive == isActive
                        ? SessionActivityTransition::unchanged
                        : (isActive ? SessionActivityTransition::activated
                                    : SessionActivityTransition::deactivated);
                    assertUpdate(update, expected, isActive);
                }
            }
        }
    }
}

void testIdempotentAssignments() {
    SessionActivityGate gate;
    for (std::size_t iteration = 0; iteration < 8; ++iteration) {
        assertUpdate(gate.setVisible(true), SessionActivityTransition::unchanged, true);
        assertUpdate(gate.setPaused(false), SessionActivityTransition::unchanged, true);
    }

    assertUpdate(gate.setPaused(true), SessionActivityTransition::deactivated, false);
    for (std::size_t iteration = 0; iteration < 8; ++iteration) {
        assertUpdate(gate.setPaused(true), SessionActivityTransition::unchanged, false);
        assertUpdate(gate.setVisible(true), SessionActivityTransition::unchanged, false);
    }
}

} // namespace

int main() {
    testDefaultsAndInitialState();
    testHidePauseShowResume();
    testPauseHideResumeShow();
    testEveryAssignmentFromEveryState();
    testMixedAssignmentSequences();
    testIdempotentAssignments();
}
