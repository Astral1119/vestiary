#include "FrescoScene/PuppetRenderEvidence.h"

#include <cstdint>
#include <cstring>
#include <mutex>
#include <unordered_map>

namespace FrescoScene {
namespace {

struct Registry {
    std::mutex mutex;
    PuppetRenderEvidence evidence;
    std::unordered_map<const void*, uint64_t> deformationHashes;
};

Registry& registry () {
    static Registry value;
    return value;
}

uint64_t hashPositions (std::span<const float> positions) {
    uint64_t hash = 1469598103934665603ULL;
    for (const float position : positions) {
        uint32_t bits = 0;
        static_assert (sizeof (bits) == sizeof (position));
        std::memcpy (&bits, &position, sizeof (bits));
        hash ^= bits;
        hash *= 1099511628211ULL;
    }
    return hash;
}

}

void resetPuppetRenderEvidence () {
    Registry& value = registry ();
    std::lock_guard lock (value.mutex);
    value.evidence = {};
    value.deformationHashes.clear ();
}

void recordPuppetMeshLoaded (
    std::size_t vertices,
    std::size_t masks,
    std::size_t attachments,
    std::size_t simulationEnabledBones,
    std::size_t activeIKBones
) {
    Registry& value = registry ();
    std::lock_guard lock (value.mutex);
    ++value.evidence.loadedMeshes;
    value.evidence.loadedVertices += vertices;
    value.evidence.loadedMasks += masks;
    value.evidence.loadedAttachments += attachments;
    value.evidence.simulationEnabledBoneCount += simulationEnabledBones;
    value.evidence.activeIKBoneCount += activeIKBones;
}

void recordPuppetDeformation (const void* owner, std::span<const float> positions) {
    Registry& value = registry ();
    const uint64_t hash = hashPositions (positions);
    std::lock_guard lock (value.mutex);
    ++value.evidence.deformationUploads;
    const auto previous = value.deformationHashes.find (owner);
    if (previous != value.deformationHashes.end () && previous->second != hash) {
        ++value.evidence.deformationChanges;
    }
    value.deformationHashes.insert_or_assign (owner, hash);
}

void recordPuppetSecondaryMotionStep (bool changed) {
    recordPuppetSecondaryMotionSteps (1, changed ? 1 : 0);
}

void recordPuppetSecondaryMotionSteps (uint64_t steps, uint64_t changes) {
    Registry& value = registry ();
    std::lock_guard lock (value.mutex);
    value.evidence.secondaryMotionSteps += steps;
    value.evidence.secondaryMotionChanges += changes;
}

void recordPuppetMaskPass () {
    Registry& value = registry ();
    std::lock_guard lock (value.mutex);
    ++value.evidence.maskPasses;
}

void recordPuppetAttachmentResolution () {
    Registry& value = registry ();
    std::lock_guard lock (value.mutex);
    ++value.evidence.attachmentResolutions;
}

PuppetRenderEvidence puppetRenderEvidence () {
    Registry& value = registry ();
    std::lock_guard lock (value.mutex);
    return value.evidence;
}

}
