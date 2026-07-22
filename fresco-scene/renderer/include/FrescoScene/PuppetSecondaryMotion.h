#pragma once

#include "FrescoScene/PuppetModel.h"

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace FrescoScene {

struct PuppetSecondaryMotionEvidence {
    uint64_t steps = 0;
    uint64_t changes = 0;
    uint64_t resets = 0;
};

struct PuppetSecondaryMotionTransform2D {
    float translationX = 0.0f;
    float translationY = 0.0f;
    float rotationZ = 0.0f;
    float scaleX = 1.0f;
    float scaleY = 1.0f;
};

class PuppetSecondaryMotion {
public:
    explicit PuppetSecondaryMotion (
        std::span<const PuppetBone> bones,
        double fixedStepSeconds = 1.0 / 120.0
    );

    [[nodiscard]] bool supported () const { return m_diagnostic.empty (); }
    [[nodiscard]] const std::string& diagnostic () const { return m_diagnostic; }
    [[nodiscard]] double fixedStepSeconds () const { return m_fixedStepSeconds; }

    void setPaused (bool paused) { m_paused = paused; }
    [[nodiscard]] bool paused () const { return m_paused; }

    bool reset (
        PuppetSecondaryMotionTransform2D parentTransform,
        std::span<const float> authoredLocalRotationZ
    );
    bool advance (
        double deltaSeconds,
        PuppetSecondaryMotionTransform2D parentTransform,
        std::span<const float> authoredLocalRotationZ
    );
    bool reset (
        float rootWorldRotationZ,
        std::span<const float> authoredLocalRotationZ
    ) {
        return reset ({ .rotationZ = rootWorldRotationZ }, authoredLocalRotationZ);
    }
    bool advance (
        double deltaSeconds,
        float rootWorldRotationZ,
        std::span<const float> authoredLocalRotationZ
    ) {
        return advance (
            deltaSeconds, { .rotationZ = rootWorldRotationZ }, authoredLocalRotationZ
        );
    }

    [[nodiscard]] std::span<const float> rotationOffsetsZ () const {
        return m_rotationOffsetsZ;
    }
    [[nodiscard]] const PuppetSecondaryMotionEvidence& evidence () const {
        return m_evidence;
    }

private:
    struct BoneState {
        uint32_t parent = PuppetBone::noParent;
        std::optional<PuppetSimulationConstraint> constraint;
        float pivotX = 0.0f;
        float pivotY = 0.0f;
        float tipVectorX = 0.0f;
        float tipVectorY = 0.0f;
        float velocity = 0.0f;
        float previousParentWorldRotation = 0.0f;
        float previousDrivenPivotX = 0.0f;
        float previousDrivenPivotY = 0.0f;
        float previousScaledTipAngle = 0.0f;
    };

    bool validInput (std::span<const float> authoredLocalRotationZ) const;
    void synchronizeDrivers (
        PuppetSecondaryMotionTransform2D parentTransform,
        std::span<const float> authoredLocalRotationZ
    );
    void step (
        PuppetSecondaryMotionTransform2D parentTransform,
        std::span<const float> authoredLocalRotationZ
    );

    std::vector<BoneState> m_bones;
    std::vector<float> m_rotationOffsetsZ;
    std::vector<float> m_worldRotationZ;
    std::string m_diagnostic;
    double m_fixedStepSeconds = 0.0;
    double m_accumulatorSeconds = 0.0;
    float m_pendingTranslationX = 0.0f;
    float m_pendingTranslationY = 0.0f;
    float m_pendingRotationZ = 0.0f;
    float m_pendingScaleX = 0.0f;
    float m_pendingScaleY = 0.0f;
    PuppetSecondaryMotionTransform2D m_lastParentTransform;
    PuppetSecondaryMotionTransform2D m_integratedParentTransform;
    bool m_paused = false;
    bool m_primed = false;
    PuppetSecondaryMotionEvidence m_evidence;
};

}
