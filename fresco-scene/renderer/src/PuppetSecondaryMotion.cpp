#include "FrescoScene/PuppetSecondaryMotion.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace FrescoScene {
namespace {

constexpr double maximumAdvanceSeconds = 0.25;
constexpr double minimumFixedStepSeconds = 1.0 / 1000.0;
constexpr float referenceStepsPerSecond = 60.0f;
constexpr float changeThreshold = 1.0e-6f;

bool finiteConstraint (const PuppetSimulationConstraint& constraint) {
    const auto finite = [] (float value) { return std::isfinite (value); };
    return finite (constraint.rotationMinimum.z)
        && finite (constraint.rotationMaximum.z)
        && finite (constraint.rotationFriction)
        && finite (constraint.rotationInertia)
        && finite (constraint.rotationStiffness)
        && finite (constraint.tipMass)
        && finite (constraint.tipPosition.x)
        && finite (constraint.tipPosition.y);
}

bool finiteTransform (PuppetSecondaryMotionTransform2D transform) {
    return std::isfinite (transform.translationX)
        && std::isfinite (transform.translationY)
        && std::isfinite (transform.rotationZ)
        && std::isfinite (transform.scaleX)
        && std::isfinite (transform.scaleY)
        && transform.scaleX > 0.0f
        && transform.scaleY > 0.0f;
}

std::array<float, 2> transformPoint (
    PuppetSecondaryMotionTransform2D transform,
    float x,
    float y
) {
    const float scaledX = x * transform.scaleX;
    const float scaledY = y * transform.scaleY;
    const float cosine = std::cos (transform.rotationZ);
    const float sine = std::sin (transform.rotationZ);
    return {
        transform.translationX + scaledX * cosine - scaledY * sine,
        transform.translationY + scaledX * sine + scaledY * cosine,
    };
}

bool supportedConstraint (const PuppetSimulationConstraint& constraint) {
    return constraint.mode == 0
        && constraint.rotationEnabled
        && !constraint.translationEnabled
        && !constraint.gravityEnabled
        && !constraint.inverseKinematicsEnabled
        && constraint.rotationAxes == std::array<bool, 3> { false, false, true }
        && constraint.rotationLimited
        && finiteConstraint (constraint)
        && constraint.rotationMinimum.z <= constraint.rotationMaximum.z
        && constraint.rotationFriction >= 0.0f
        && constraint.rotationFriction <= 100.0f
        && constraint.rotationInertia >= 0.0f
        && constraint.rotationInertia <= 100.0f
        && constraint.rotationStiffness >= 0.0f
        && constraint.tipMass > 0.0f;
}

float shortestAngleDifference (float current, float previous) {
    constexpr float pi = 3.14159265358979323846f;
    constexpr float twoPi = pi * 2.0f;
    float difference = std::fmod (current - previous, twoPi);
    if (difference > pi) difference -= twoPi;
    if (difference < -pi) difference += twoPi;
    return difference;
}

}

PuppetSecondaryMotion::PuppetSecondaryMotion (
    std::span<const PuppetBone> bones,
    double fixedStepSeconds
) : m_fixedStepSeconds (fixedStepSeconds) {
    if (!std::isfinite (fixedStepSeconds)
        || fixedStepSeconds < minimumFixedStepSeconds
        || fixedStepSeconds > maximumAdvanceSeconds) {
        m_diagnostic = "secondary-motion fixed step is outside the bounded range";
        return;
    }

    m_bones.reserve (bones.size ());
    m_rotationOffsetsZ.resize (bones.size (), 0.0f);
    m_worldRotationZ.resize (bones.size (), 0.0f);
    size_t simulatedBones = 0;
    for (size_t index = 0; index < bones.size (); ++index) {
        const PuppetBone& bone = bones[index];
        if (bone.parent != PuppetBone::noParent && bone.parent >= index) {
            m_diagnostic = "secondary-motion skeleton has a forward parent";
            return;
        }
        if (bone.simulation.has_value ()) {
            ++simulatedBones;
            if (!supportedConstraint (*bone.simulation)) {
                m_diagnostic = "secondary motion requires bounded Z-rotation spring constraints";
                return;
            }
            const float tipVectorX = bone.simulation->tipPosition.x
                - bone.localBind.values[12];
            const float tipVectorY = bone.simulation->tipPosition.y
                - bone.localBind.values[13];
            if (!std::isfinite (tipVectorX) || !std::isfinite (tipVectorY)
                || tipVectorX * tipVectorX + tipVectorY * tipVectorY <= 1.0e-6f) {
                m_diagnostic = "secondary motion requires nonzero 2D tip geometry";
                return;
            }
        }
        m_bones.push_back ({
            .parent = bone.parent,
            .constraint = bone.simulation,
            .pivotX = bone.localBind.values[12],
            .pivotY = bone.localBind.values[13],
            .tipVectorX = bone.simulation.has_value ()
                ? bone.simulation->tipPosition.x - bone.localBind.values[12] : 0.0f,
            .tipVectorY = bone.simulation.has_value ()
                ? bone.simulation->tipPosition.y - bone.localBind.values[13] : 0.0f,
        });
    }
    if (simulatedBones == 0) {
        m_diagnostic = "secondary-motion skeleton has no simulated bones";
    }
}

bool PuppetSecondaryMotion::validInput (
    std::span<const float> authoredLocalRotationZ
) const {
    if (!supported () || authoredLocalRotationZ.size () != m_bones.size ()) return false;
    return std::all_of (
        authoredLocalRotationZ.begin (), authoredLocalRotationZ.end (),
        [] (float value) { return std::isfinite (value); }
    );
}

void PuppetSecondaryMotion::synchronizeDrivers (
    PuppetSecondaryMotionTransform2D parentTransform,
    std::span<const float> authoredLocalRotationZ
) {
    std::fill (m_worldRotationZ.begin (), m_worldRotationZ.end (), 0.0f);
    for (size_t index = 0; index < m_bones.size (); ++index) {
        BoneState& bone = m_bones[index];
        const float parentWorld = bone.parent == PuppetBone::noParent
            ? parentTransform.rotationZ : m_worldRotationZ[bone.parent];
        bone.previousParentWorldRotation = parentWorld;
        const auto pivot = transformPoint (parentTransform, bone.pivotX, bone.pivotY);
        bone.previousDrivenPivotX = pivot[0];
        bone.previousDrivenPivotY = pivot[1];
        bone.previousScaledTipAngle = std::atan2 (
            bone.tipVectorY * parentTransform.scaleY,
            bone.tipVectorX * parentTransform.scaleX
        );
        m_worldRotationZ[index] = parentWorld + authoredLocalRotationZ[index]
            + m_rotationOffsetsZ[index];
    }
}

bool PuppetSecondaryMotion::reset (
    PuppetSecondaryMotionTransform2D parentTransform,
    std::span<const float> authoredLocalRotationZ
) {
    if (!finiteTransform (parentTransform) || !validInput (authoredLocalRotationZ)) {
        return false;
    }
    std::fill (m_rotationOffsetsZ.begin (), m_rotationOffsetsZ.end (), 0.0f);
    for (BoneState& bone : m_bones) bone.velocity = 0.0f;
    m_accumulatorSeconds = 0.0;
    m_pendingTranslationX = 0.0f;
    m_pendingTranslationY = 0.0f;
    m_pendingRotationZ = 0.0f;
    m_pendingScaleX = 0.0f;
    m_pendingScaleY = 0.0f;
    m_lastParentTransform = parentTransform;
    m_integratedParentTransform = parentTransform;
    synchronizeDrivers (parentTransform, authoredLocalRotationZ);
    m_primed = true;
    ++m_evidence.resets;
    return true;
}

bool PuppetSecondaryMotion::advance (
    double deltaSeconds,
    PuppetSecondaryMotionTransform2D parentTransform,
    std::span<const float> authoredLocalRotationZ
) {
    if (!validInput (authoredLocalRotationZ) || !std::isfinite (deltaSeconds)
        || !finiteTransform (parentTransform)
        || deltaSeconds < 0.0) {
        return false;
    }
    if (!m_primed) {
        m_lastParentTransform = parentTransform;
        m_integratedParentTransform = parentTransform;
        synchronizeDrivers (parentTransform, authoredLocalRotationZ);
        m_primed = true;
    }
    if (m_paused) {
        m_accumulatorSeconds = 0.0;
        m_pendingTranslationX = 0.0f;
        m_pendingTranslationY = 0.0f;
        m_pendingRotationZ = 0.0f;
        m_pendingScaleX = 0.0f;
        m_pendingScaleY = 0.0f;
        m_lastParentTransform = parentTransform;
        m_integratedParentTransform = parentTransform;
        synchronizeDrivers (parentTransform, authoredLocalRotationZ);
        return true;
    }

    const double acceptedSeconds = std::min (deltaSeconds, maximumAdvanceSeconds);
    m_accumulatorSeconds += acceptedSeconds;
    m_pendingTranslationX += parentTransform.translationX
        - m_lastParentTransform.translationX;
    m_pendingTranslationY += parentTransform.translationY
        - m_lastParentTransform.translationY;
    m_pendingRotationZ += shortestAngleDifference (
        parentTransform.rotationZ, m_lastParentTransform.rotationZ
    );
    m_pendingScaleX += parentTransform.scaleX - m_lastParentTransform.scaleX;
    m_pendingScaleY += parentTransform.scaleY - m_lastParentTransform.scaleY;
    m_lastParentTransform = parentTransform;
    while (m_accumulatorSeconds + std::numeric_limits<double>::epsilon ()
        >= m_fixedStepSeconds) {
        const float fraction = static_cast<float> (
            m_fixedStepSeconds / m_accumulatorSeconds
        );
        const float translationDeltaX = m_pendingTranslationX * fraction;
        const float translationDeltaY = m_pendingTranslationY * fraction;
        const float rotationDelta = m_pendingRotationZ * fraction;
        const float scaleDeltaX = m_pendingScaleX * fraction;
        const float scaleDeltaY = m_pendingScaleY * fraction;
        m_pendingTranslationX -= translationDeltaX;
        m_pendingTranslationY -= translationDeltaY;
        m_pendingRotationZ -= rotationDelta;
        m_pendingScaleX -= scaleDeltaX;
        m_pendingScaleY -= scaleDeltaY;
        m_integratedParentTransform.translationX += translationDeltaX;
        m_integratedParentTransform.translationY += translationDeltaY;
        m_integratedParentTransform.rotationZ += rotationDelta;
        m_integratedParentTransform.scaleX += scaleDeltaX;
        m_integratedParentTransform.scaleY += scaleDeltaY;
        step (m_integratedParentTransform, authoredLocalRotationZ);
        m_accumulatorSeconds -= m_fixedStepSeconds;
    }
    return true;
}

void PuppetSecondaryMotion::step (
    PuppetSecondaryMotionTransform2D parentTransform,
    std::span<const float> authoredLocalRotationZ
) {
    const float delta = static_cast<float> (m_fixedStepSeconds);
    std::fill (m_worldRotationZ.begin (), m_worldRotationZ.end (), 0.0f);
    bool changed = false;
    for (size_t index = 0; index < m_bones.size (); ++index) {
        BoneState& bone = m_bones[index];
        const float parentWorld = bone.parent == PuppetBone::noParent
            ? parentTransform.rotationZ : m_worldRotationZ[bone.parent];
        if (bone.constraint.has_value ()) {
            const PuppetSimulationConstraint& constraint = *bone.constraint;
            const float parentDelta = shortestAngleDifference (
                parentWorld, bone.previousParentWorldRotation
            );
            const float inertia = constraint.rotationInertia / 100.0f;
            bone.velocity -= parentDelta * inertia / delta;

            const auto drivenPivot = transformPoint (
                parentTransform, bone.pivotX, bone.pivotY
            );
            const float pivotDeltaX = drivenPivot[0] - bone.previousDrivenPivotX;
            const float pivotDeltaY = drivenPivot[1] - bone.previousDrivenPivotY;
            const float scaledTipX = bone.tipVectorX * parentTransform.scaleX;
            const float scaledTipY = bone.tipVectorY * parentTransform.scaleY;
            const float cosine = std::cos (parentWorld);
            const float sine = std::sin (parentWorld);
            const float tipX = scaledTipX * cosine - scaledTipY * sine;
            const float tipY = scaledTipX * sine + scaledTipY * cosine;
            const float displacedTipX = tipX - pivotDeltaX;
            const float displacedTipY = tipY - pivotDeltaY;
            const float translationDeflection = std::atan2 (
                tipX * displacedTipY - tipY * displacedTipX,
                tipX * displacedTipX + tipY * displacedTipY
            );
            bone.velocity += translationDeflection * inertia / delta;
            const float scaledTipAngle = std::atan2 (scaledTipY, scaledTipX);
            const float scaleAngleDelta = shortestAngleDifference (
                scaledTipAngle, bone.previousScaledTipAngle
            );
            bone.velocity -= scaleAngleDelta * inertia / delta;
            bone.previousDrivenPivotX = drivenPivot[0];
            bone.previousDrivenPivotY = drivenPivot[1];
            bone.previousScaledTipAngle = scaledTipAngle;

            const float springAcceleration = -m_rotationOffsetsZ[index]
                * constraint.rotationStiffness / constraint.tipMass;
            bone.velocity += springAcceleration * delta;
            const float retention = std::clamp (
                1.0f - constraint.rotationFriction / 100.0f, 0.0f, 1.0f
            );
            bone.velocity *= std::pow (retention, delta * referenceStepsPerSecond);

            const float previous = m_rotationOffsetsZ[index];
            m_rotationOffsetsZ[index] = std::clamp (
                previous + bone.velocity * delta,
                constraint.rotationMinimum.z,
                constraint.rotationMaximum.z
            );
            if (m_rotationOffsetsZ[index] == constraint.rotationMinimum.z
                || m_rotationOffsetsZ[index] == constraint.rotationMaximum.z) {
                bone.velocity = 0.0f;
            }
            changed = changed
                || std::abs (m_rotationOffsetsZ[index] - previous) > changeThreshold;
        }
        bone.previousParentWorldRotation = parentWorld;
        m_worldRotationZ[index] = parentWorld + authoredLocalRotationZ[index]
            + m_rotationOffsetsZ[index];
    }
    ++m_evidence.steps;
    if (changed) ++m_evidence.changes;
}

}
