#pragma once

#include "FrescoScene/PuppetRuntimeMesh.h"

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace FrescoScene {

// One authored animation layer as the draw path last applied it. Keyed by
// object so a scene with several puppets stays readable; `requestedBlend` is
// the authored slider, which ranges past the [0,1] the composition clamps to.
struct PuppetLayerRecord {
    int32_t objectID = 0;
    int32_t layerID = 0;
    int32_t animationID = 0;
    double rate = 0.0;
    double requestedBlend = 0.0;
    double appliedBlend = 0.0;
    double framesAdvanced = 0.0;
    double frameWithinClip = 0.0;
    int32_t length = 0;
    float framesPerSecond = 0.0f;
    bool visible = false;
    bool additive = false;
    bool sampled = false;
    bool replacement = false;
    bool promotedToReplacement = false;
    std::size_t updates = 0;
};

// One resolved attachment as the transform seam last applied it. `authoredX/Y`
// is the carrier's own origin before the attachment contributes, so a reference
// session can tell whether Wallpaper Engine adds to it or replaces it.
// `appliedAngle` is in scene space, which is y-down, so it is the negation of
// the puppet-space bone angle recorded beside it.
struct PuppetAttachmentRecord {
    int32_t objectID = 0;
    int32_t parentObjectID = 0;
    std::string name;
    double anchorX = 0.0;
    double anchorY = 0.0;
    double boneAngle = 0.0;
    // What the seam actually applied, against what the bone frame offers. The
    // fold applies the full frame, so the pairs match; both stay recorded so a
    // reference session can still falsify the convention.
    double appliedAngle = 0.0;
    double availableAngle = 0.0;
    double appliedScaleX = 1.0;
    double appliedScaleY = 1.0;
    double availableScaleX = 1.0;
    double availableScaleY = 1.0;
    double authoredX = 0.0;
    double authoredY = 0.0;
    double resolvedX = 0.0;
    double resolvedY = 0.0;
    std::size_t updates = 0;
};

// One puppet-bearing image as the draw path last saw it. `sceneDeltaMax` is the
// frame-to-frame vertex movement in scene units and `localDeltaMax` the same in
// mesh-local units, so the ratio against spanX/sizeX says whether the
// local-to-scene mapping is preserving the authored amplitude or collapsing it.
// `activeIsScene` reports which buffer the drawing pass actually bound.
struct PuppetImageRecord {
    int32_t objectID = 0;
    bool runtimePresent = false;
    bool hasPuppetMesh = false;
    bool activeIsScene = false;
    bool activeIsLocal = false;
    double localDeltaMax = 0.0;
    double sceneDeltaMax = 0.0;
    // Excursion from the first frame seen. Frame-to-frame delta says whether a
    // mesh is moving; amplitude says how far, which is what decides whether a
    // motion is too small to see. The local figure is object-independent; the
    // scene one also carries whole-object translation.
    double localAmplitude = 0.0;
    double sceneAmplitude = 0.0;
    double sizeX = 0.0;
    double sizeY = 0.0;
    double spanX = 0.0;
    double spanY = 0.0;
    std::size_t vertices = 0;
    std::size_t updates = 0;
};

struct PuppetRenderEvidence {
    std::size_t loadedMeshes = 0;
    std::size_t loadedVertices = 0;
    std::size_t loadedMasks = 0;
    std::size_t loadedAttachments = 0;
    std::size_t simulationEnabledBoneCount = 0;
    std::size_t activeIKBoneCount = 0;
    std::size_t secondaryMotionSteps = 0;
    std::size_t secondaryMotionChanges = 0;
    std::size_t deformationUploads = 0;
    std::size_t deformationChanges = 0;
    std::size_t maskPasses = 0;
    std::size_t attachmentResolutions = 0;
    std::vector<PuppetLayerRecord> layers;
    std::vector<PuppetAttachmentRecord> attachments;
    std::vector<PuppetImageRecord> images;
};

void resetPuppetRenderEvidence ();
void recordPuppetMeshLoaded (
    std::size_t vertices,
    std::size_t masks,
    std::size_t attachments,
    std::size_t simulationEnabledBones,
    std::size_t activeIKBones
);
void recordPuppetDeformation (const void* owner, std::span<const float> positions);
void recordPuppetSecondaryMotionStep (bool changed);
void recordPuppetSecondaryMotionSteps (uint64_t steps, uint64_t changes);
void recordPuppetMaskPass ();
void recordPuppetAttachmentResolution ();
void recordPuppetLayerState (
    int32_t objectID, std::span<const PuppetLayerEvidence> layers
);
void recordPuppetAttachmentTransform (const PuppetAttachmentRecord& record);
void recordPuppetImageState (
    const void* owner,
    PuppetImageRecord record,
    std::span<const float> localPositions,
    std::span<const float> scenePositions
);
[[nodiscard]] PuppetRenderEvidence puppetRenderEvidence ();

}
