#include "FrescoScene/PuppetRenderEvidence.h"

#include <algorithm>
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
    std::unordered_map<const void*, std::vector<float>> previousLocal;
    std::unordered_map<const void*, std::vector<float>> previousScene;
    std::unordered_map<const void*, std::vector<float>> baselineLocal;
    std::unordered_map<const void*, std::vector<float>> baselineScene;
};

double maximumDelta (
    std::span<const float> current, const std::vector<float>& previous
) {
    if (previous.size () != current.size ()) return 0.0;
    double result = 0.0;
    for (std::size_t index = 0; index < current.size (); ++index) {
        result = std::max (
            result, static_cast<double> (std::abs (current[index] - previous[index]))
        );
    }
    return result;
}

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
    value.previousLocal.clear ();
    value.previousScene.clear ();
    value.baselineLocal.clear ();
    value.baselineScene.clear ();
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

void recordPuppetImageState (
    const void* owner,
    PuppetImageRecord record,
    std::span<const float> localPositions,
    std::span<const float> scenePositions
) {
    Registry& value = registry ();
    std::lock_guard lock (value.mutex);
    record.vertices = localPositions.size () / 3;
    record.localDeltaMax = maximumDelta (localPositions, value.previousLocal[owner]);
    record.sceneDeltaMax = maximumDelta (scenePositions, value.previousScene[owner]);
    value.previousLocal[owner].assign (localPositions.begin (), localPositions.end ());
    value.previousScene[owner].assign (scenePositions.begin (), scenePositions.end ());

    auto& baselineLocal = value.baselineLocal[owner];
    auto& baselineScene = value.baselineScene[owner];
    if (baselineLocal.empty ()) {
        baselineLocal.assign (localPositions.begin (), localPositions.end ());
        baselineScene.assign (scenePositions.begin (), scenePositions.end ());
    }
    record.localAmplitude = maximumDelta (localPositions, baselineLocal);
    record.sceneAmplitude = maximumDelta (scenePositions, baselineScene);

    const auto existing = std::find_if (
        value.evidence.images.begin (), value.evidence.images.end (),
        [&record] (const PuppetImageRecord& candidate) {
            return candidate.objectID == record.objectID;
        }
    );
    if (existing == value.evidence.images.end ()) {
        record.updates = 1;
        value.evidence.images.push_back (record);
        return;
    }
    record.updates = existing->updates + 1;
    // Frame-to-frame movement is noisy, so keep the largest seen rather than
    // the latest: a sampled read must not miss the peak between two reads.
    record.localDeltaMax = std::max (record.localDeltaMax, existing->localDeltaMax);
    record.sceneDeltaMax = std::max (record.sceneDeltaMax, existing->sceneDeltaMax);
    record.localAmplitude = std::max (record.localAmplitude, existing->localAmplitude);
    record.sceneAmplitude = std::max (record.sceneAmplitude, existing->sceneAmplitude);
    *existing = record;
}

void recordPuppetAttachmentTransform (const PuppetAttachmentRecord& record) {
    Registry& value = registry ();
    std::lock_guard lock (value.mutex);
    const auto existing = std::find_if (
        value.evidence.attachments.begin (), value.evidence.attachments.end (),
        [&record] (const PuppetAttachmentRecord& candidate) {
            return candidate.objectID == record.objectID
                && candidate.name == record.name;
        }
    );
    if (existing == value.evidence.attachments.end ()) {
        value.evidence.attachments.push_back (record);
        value.evidence.attachments.back ().updates = 1;
        return;
    }
    const std::size_t updates = existing->updates + 1;
    *existing = record;
    existing->updates = updates;
}

void recordPuppetLayerState (
    int32_t objectID, std::span<const PuppetLayerEvidence> layers
) {
    Registry& value = registry ();
    std::lock_guard lock (value.mutex);
    for (const PuppetLayerEvidence& layer : layers) {
        const auto existing = std::find_if (
            value.evidence.layers.begin (), value.evidence.layers.end (),
            [objectID, &layer] (const PuppetLayerRecord& candidate) {
                return candidate.objectID == objectID
                    && candidate.layerID == layer.layerID;
            }
        );
        PuppetLayerRecord record {
            .objectID = objectID,
            .layerID = layer.layerID,
            .animationID = layer.animationID,
            .rate = layer.rate,
            .requestedBlend = layer.requestedBlend,
            .appliedBlend = layer.appliedBlend,
            .framesAdvanced = layer.framesAdvanced,
            .frameWithinClip = layer.frameWithinClip,
            .length = layer.length,
            .framesPerSecond = layer.framesPerSecond,
            .visible = layer.visible,
            .additive = layer.additive,
            .sampled = layer.sampled,
            .replacement = layer.replacement,
            .promotedToReplacement = layer.promotedToReplacement,
            .updates = 1,
        };
        if (existing == value.evidence.layers.end ()) {
            value.evidence.layers.push_back (record);
            continue;
        }
        record.updates = existing->updates + 1;
        *existing = record;
    }
}

PuppetRenderEvidence puppetRenderEvidence () {
    Registry& value = registry ();
    std::lock_guard lock (value.mutex);
    return value.evidence;
}

}
