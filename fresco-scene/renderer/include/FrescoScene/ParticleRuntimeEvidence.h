#pragma once

#include <cstddef>
#include <cstdint>

namespace FrescoScene {

struct ParticleSystemRuntimeEvidence {
    int objectId = 0;
    std::uint32_t seed = 0;
    bool finiteLifecycle = false;
    bool continuousRequired = true;
    bool quiescent = false;
    std::size_t updates = 0;
    std::size_t catchUpFrames = 0;
    double requestedMilliseconds = 0.0;
    double simulatedMilliseconds = 0.0;
    double droppedMilliseconds = 0.0;
    double maximumRequestedMilliseconds = 0.0;
    double maximumSimulatedMilliseconds = 0.0;
    std::size_t emitted = 0;
    std::size_t live = 0;
    std::size_t peakLive = 0;
    std::size_t poolCapacity = 0;
    std::size_t poolResizes = 0;
    std::size_t resourceInitializations = 0;
    std::uint64_t stateHash = 0;
};

struct ParticleRuntimeEvidence {
    std::size_t systems = 0;
    std::size_t finiteSystems = 0;
    std::size_t unknownSystems = 0;
    std::uint32_t minimumSeed = 0;
    std::uint32_t maximumSeed = 0;
    bool continuousRequired = false;
    bool quiescent = true;
    std::size_t updates = 0;
    std::size_t catchUpFrames = 0;
    double requestedMilliseconds = 0.0;
    double simulatedMilliseconds = 0.0;
    double droppedMilliseconds = 0.0;
    double maximumRequestedMilliseconds = 0.0;
    double maximumSimulatedMilliseconds = 0.0;
    std::size_t emitted = 0;
    std::size_t live = 0;
    std::size_t peakLive = 0;
    std::size_t poolCapacity = 0;
    std::size_t poolResizes = 0;
    std::size_t resourceInitializations = 0;
    std::uint64_t stateHash = 0;
};

}
