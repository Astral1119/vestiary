#pragma once

namespace FrescoScene {

enum class SessionActivityTransition {
    unchanged,
    activated,
    deactivated,
};

struct SessionActivityUpdate {
    SessionActivityTransition transition = SessionActivityTransition::unchanged;
    bool active = true;
};

class SessionActivityGate {
public:
    SessionActivityGate() = default;
    SessionActivityGate(bool visible, bool paused) noexcept;

    SessionActivityUpdate setVisible(bool visible) noexcept;
    SessionActivityUpdate setPaused(bool paused) noexcept;

    bool visible() const noexcept;
    bool paused() const noexcept;
    bool active() const noexcept;

private:
    SessionActivityUpdate update(bool wasActive) const noexcept;

    bool m_visible = true;
    bool m_paused = false;
};

} // namespace FrescoScene
