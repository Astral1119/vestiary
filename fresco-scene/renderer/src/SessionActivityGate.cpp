#include "FrescoScene/SessionActivityGate.h"

namespace FrescoScene {

SessionActivityGate::SessionActivityGate(bool visible, bool paused) noexcept
    : m_visible(visible), m_paused(paused) {}

SessionActivityUpdate SessionActivityGate::setVisible(bool visible) noexcept {
    const bool wasActive = active();
    m_visible = visible;
    return update(wasActive);
}

SessionActivityUpdate SessionActivityGate::setPaused(bool paused) noexcept {
    const bool wasActive = active();
    m_paused = paused;
    return update(wasActive);
}

bool SessionActivityGate::visible() const noexcept {
    return m_visible;
}

bool SessionActivityGate::paused() const noexcept {
    return m_paused;
}

bool SessionActivityGate::active() const noexcept {
    return m_visible && !m_paused;
}

SessionActivityUpdate SessionActivityGate::update(bool wasActive) const noexcept {
    const bool isActive = active();
    if (wasActive == isActive) {
        return {SessionActivityTransition::unchanged, isActive};
    }
    return {
        isActive ? SessionActivityTransition::activated
                 : SessionActivityTransition::deactivated,
        isActive,
    };
}

} // namespace FrescoScene
