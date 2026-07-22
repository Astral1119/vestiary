#include "FrescoScene/PuppetSecondaryMotion.h"

#include <array>
#include <cassert>
#include <cmath>
#include <vector>

namespace {

FrescoScene::PuppetSimulationConstraint constraint (
    float friction = 30.0f,
    float minimum = -3.1415926f,
    float maximum = 3.1415926f
) {
    return {
        .mode = 0,
        .rotationEnabled = true,
        .translationEnabled = false,
        .gravityEnabled = false,
        .inverseKinematicsEnabled = false,
        .rotationAxes = { false, false, true },
        .rotationLimited = true,
        .rotationMinimum = { 0.0f, 0.0f, minimum },
        .rotationMaximum = { 0.0f, 0.0f, maximum },
        .rotationFriction = friction,
        .rotationInertia = 30.0f,
        .rotationStiffness = 300.0f,
        .tipMass = 20.0f,
    };
}

std::vector<FrescoScene::PuppetBone> fiveBoneChain () {
    std::vector<FrescoScene::PuppetBone> bones (7);
    bones[0].parent = FrescoScene::PuppetBone::noParent;
    for (size_t index = 1; index < bones.size (); ++index) {
        bones[index].parent = static_cast<uint32_t> (index - 1);
    }
    const std::array<float, 5> friction { 38.0f, 33.0f, 29.0f, 27.0f, 26.0f };
    for (size_t index = 0; index < friction.size (); ++index) {
        auto simulation = constraint (friction[index]);
        const float pivotX = static_cast<float> (index) * 10.0f;
        const float pivotY = static_cast<float> (index) * 50.0f;
        bones[index + 2].localBind.values[12] = pivotX;
        bones[index + 2].localBind.values[13] = pivotY;
        simulation.tipPosition = { pivotX + 10.0f, pivotY + 50.0f, 0.0f };
        bones[index + 2].simulation = simulation;
    }
    return bones;
}

bool near (float left, float right, float tolerance = 1.0e-6f) {
    return std::abs (left - right) <= tolerance;
}

std::vector<float> runLinearStimulus (const std::vector<FrescoScene::PuppetBone>& bones,
    int updatesPerSecond) {
    FrescoScene::PuppetSecondaryMotion motion (bones);
    const std::array<float, 7> authored {};
    assert (motion.reset ({}, authored));
    for (int update = 1; update <= updatesPerSecond; ++update) {
        const float amount = static_cast<float> (update)
            / static_cast<float> (updatesPerSecond);
        assert (motion.advance (
            1.0 / static_cast<double> (updatesPerSecond),
            {
                .translationX = 12.0f * amount,
                .translationY = -5.0f * amount,
                .rotationZ = 0.4f * amount,
                .scaleX = 1.0f - 0.2f * amount,
                .scaleY = 1.0f + 0.1f * amount,
            },
            authored
        ));
    }
    assert (motion.evidence ().steps == 120);
    assert (motion.evidence ().changes == 120);
    return { motion.rotationOffsetsZ ().begin (), motion.rotationOffsetsZ ().end () };
}

}

int main () {
    const auto bones = fiveBoneChain ();
    FrescoScene::PuppetSecondaryMotion motion (bones);
    assert (motion.supported ());
    assert (near (static_cast<float> (motion.fixedStepSeconds ()), 1.0f / 120.0f));

    std::array<float, 7> authored {};
    assert (motion.reset ({}, authored));
    assert (motion.evidence ().resets == 1);
    float rootRotation = 0.8f;
    assert (motion.advance (1.0 / 60.0, { .rotationZ = rootRotation }, authored));
    assert (motion.evidence ().steps == 2);
    assert (motion.evidence ().changes == 2);
    const auto changed = motion.rotationOffsetsZ ();
    assert (changed[0] == 0.0f && changed[1] == 0.0f);
    assert (changed[2] < 0.0f);
    assert (changed[3] < 0.0f);
    for (size_t index = 2; index < changed.size (); ++index) {
        assert (std::abs (changed[index]) > 1.0e-6f);
    }

    FrescoScene::PuppetSecondaryMotion partitioned (bones);
    assert (partitioned.reset ({}, std::array<float, 7> {}));
    assert (partitioned.advance (
        1.0 / 120.0, { .rotationZ = rootRotation / 2.0f }, authored
    ));
    assert (partitioned.advance (
        1.0 / 120.0, { .rotationZ = rootRotation }, authored
    ));
    for (size_t index = 0; index < authored.size (); ++index) {
        assert (near (partitioned.rotationOffsetsZ ()[index], changed[index]));
    }

    motion.setPaused (true);
    const auto pausedOffsets = std::vector<float> (
        motion.rotationOffsetsZ ().begin (), motion.rotationOffsetsZ ().end ()
    );
    const auto pausedEvidence = motion.evidence ();
    rootRotation = -0.8f;
    assert (motion.advance (0.2, { .rotationZ = rootRotation }, authored));
    assert (std::equal (
        pausedOffsets.begin (), pausedOffsets.end (), motion.rotationOffsetsZ ().begin ()
    ));
    assert (motion.evidence ().steps == pausedEvidence.steps);
    assert (motion.evidence ().changes == pausedEvidence.changes);
    motion.setPaused (false);
    assert (motion.advance (1.0 / 120.0, { .rotationZ = rootRotation }, authored));
    assert (motion.evidence ().steps == pausedEvidence.steps + 1);

    assert (motion.reset ({ .rotationZ = rootRotation }, authored));
    assert (motion.evidence ().resets == 2);
    for (const float offset : motion.rotationOffsetsZ ()) assert (offset == 0.0f);
    const auto resetEvidence = motion.evidence ();
    assert (motion.advance (1.0 / 240.0, { .rotationZ = rootRotation }, authored));
    assert (motion.evidence ().steps == resetEvidence.steps);
    assert (motion.advance (1.0 / 240.0, { .rotationZ = rootRotation }, authored));
    assert (motion.evidence ().steps == resetEvidence.steps + 1);

    auto limitedBones = fiveBoneChain ();
    for (size_t index = 2; index < limitedBones.size (); ++index) {
        limitedBones[index].simulation->rotationFriction = 0.0f;
        limitedBones[index].simulation->rotationMinimum.z = -0.01f;
        limitedBones[index].simulation->rotationMaximum.z = 0.01f;
    }
    FrescoScene::PuppetSecondaryMotion limited (limitedBones);
    assert (limited.reset ({}, std::array<float, 7> {}));
    assert (limited.advance (1.0 / 120.0, { .rotationZ = 2.0f }, authored));
    assert (limited.rotationOffsetsZ ()[2] == -0.01f);

    auto unsupportedBones = fiveBoneChain ();
    unsupportedBones[2].simulation->translationEnabled = true;
    FrescoScene::PuppetSecondaryMotion unsupported (unsupportedBones);
    assert (!unsupported.supported ());
    assert (!unsupported.diagnostic ().empty ());
    assert (!unsupported.advance (1.0 / 60.0, {}, authored));

    FrescoScene::PuppetSecondaryMotion invalidStep (bones, 0.0);
    assert (!invalidStep.supported ());
    FrescoScene::PuppetSecondaryMotion unboundedStepCount (bones, 1.0e-9);
    assert (!unboundedStepCount.supported ());
    assert (!motion.advance (-1.0, {}, authored));
    auto nonFinite = authored;
    nonFinite[0] = std::nanf ("");
    assert (!motion.advance (1.0 / 60.0, {}, nonFinite));
    assert (!motion.advance (1.0 / 60.0, { .scaleX = 0.0f }, authored));
    assert (!motion.advance (
        1.0 / 60.0, { .translationX = std::nanf ("") }, authored
    ));

    FrescoScene::PuppetSecondaryMotion translated (bones);
    assert (translated.reset ({}, authored));
    assert (translated.advance (1.0 / 60.0, { .translationX = 10.0f }, authored));
    assert (translated.rotationOffsetsZ ()[2] > 0.0f);
    assert (translated.evidence ().steps == 2);
    assert (translated.evidence ().changes == 2);

    FrescoScene::PuppetSecondaryMotion scaled (bones);
    assert (scaled.reset ({}, authored));
    assert (scaled.advance (
        1.0 / 60.0, { .scaleX = 0.8f, .scaleY = 1.1f }, authored
    ));
    assert (scaled.evidence ().steps == 2);
    assert (scaled.evidence ().changes == 2);
    assert (std::abs (scaled.rotationOffsetsZ ()[3]) > 1.0e-6f);

    const auto at30 = runLinearStimulus (bones, 30);
    const auto at60 = runLinearStimulus (bones, 60);
    const auto at120 = runLinearStimulus (bones, 120);
    for (size_t index = 0; index < at30.size (); ++index) {
        assert (near (at30[index], at60[index], 2.0e-5f));
        assert (near (at60[index], at120[index], 2.0e-5f));
    }
    return 0;
}
