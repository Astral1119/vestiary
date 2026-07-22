#pragma once

#include <cstddef>
#include <span>

namespace FrescoScene {

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
[[nodiscard]] PuppetRenderEvidence puppetRenderEvidence ();

}
