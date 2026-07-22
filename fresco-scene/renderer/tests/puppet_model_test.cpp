#include "FrescoScene/PuppetModel.h"
#include "FrescoScene/PuppetRuntimeMesh.h"
#include "FrescoScene/PuppetSecondaryMotion.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

std::vector<std::byte> readFile (const char* path) {
    std::ifstream input (path, std::ios::binary);
    if (!input) throw std::runtime_error (std::string ("cannot read ") + path);
    std::vector<char> bytes {
        std::istreambuf_iterator<char> (input), std::istreambuf_iterator<char> ()
    };
    std::vector<std::byte> result (bytes.size ());
    for (size_t index = 0; index < bytes.size (); ++index) {
        result[index] = static_cast<std::byte> (bytes[index]);
    }
    return result;
}

void require (bool condition, const char* message) {
    if (!condition) throw std::runtime_error (message);
}

template<typename Operation>
void requireThrows (Operation operation, const char* message) {
    try {
        operation ();
    } catch (const FrescoScene::PuppetParseError&) {
        return;
    }
    throw std::runtime_error (message);
}

}

int main (int argc, char** argv) {
    try {
        require (argc == 8, "expected the seven pinned puppet models");
        size_t models = 0;
        size_t animations = 0;
        size_t deformedModels = 0;
        size_t activeIKBones = 0;
        size_t simulationBones = 0;
        struct Expected {
            size_t vertices;
            size_t bones;
            size_t animations;
            size_t parts;
            size_t masks;
            size_t attachments;
            size_t constraints;
            bool extendedBind;
        };
        const std::array<Expected, 7> expected {{
            { 768, 55, 2, 51, 2, 0, 55, true },
            { 22, 3, 1, 3, 0, 0, 0, true },
            { 227, 1, 2, 1, 0, 1, 0, false },
            { 551, 3, 1, 3, 0, 0, 2, false },
            { 413, 14, 2, 14, 0, 0, 0, true },
            { 425, 17, 1, 17, 0, 0, 17, true },
            { 309, 7, 0, 7, 0, 0, 7, false },
        }};
        for (int index = 1; index < argc; ++index) {
            const auto bytes = readFile (argv[index]);
            const auto model = FrescoScene::PuppetModel::parse (bytes);
            const Expected& pinned = expected[static_cast<size_t> (index - 1)];
            require (model.modelVersion () == 23, "unexpected model version");
            require (model.skeletonVersion () == 4, "unexpected skeleton version");
            require (model.vertices ().size () == pinned.vertices, "puppet vertex count changed");
            require (!model.triangles ().empty (), "missing puppet triangles");
            require (model.bones ().size () == pinned.bones, "puppet bone count changed");
            require (model.animations ().size () == pinned.animations,
                "puppet animation count changed");
            require (model.partCount () == pinned.parts, "puppet part count changed");
            require (model.maskCount () == pinned.masks, "puppet mask count changed");
            require (model.attachmentCount () == pinned.attachments,
                "puppet attachment count changed");
            require (model.constraintMetadataBoneCount () == pinned.constraints,
                "puppet constraint metadata changed");
            require (model.hasExtendedBindMetadata () == pinned.extendedBind,
                "puppet extended bind metadata changed");
            if (pinned.extendedBind) {
                require (model.extendedBindMaxDifference () > 100.0f,
                    "MDLE unexpectedly became inverse-bind metadata");
            }
            require (!model.hasAnimationCurves (), "pinned puppet gained animation curves");
            require (!model.hasMorphSections (), "pinned puppet gained morph sections");
            if (index == 1) {
                require (model.masks ()[0].texture == "masks/clipping_mask_9a677fed",
                    "first Hyuga clipping mask changed");
                require (model.masks ()[1].texture == "masks/clipping_mask_2a57129f",
                    "second Hyuga clipping mask changed");
                for (const auto& mask : model.masks ()) {
                    require (mask.flags == 0, "unsupported Hyuga clipping-mask flags");
                    require (mask.targetPartOrdinals.size () == 1,
                        "Hyuga clipping target count changed");
                    require (mask.maskPartOrdinals.size () == 1,
                        "Hyuga clipping source count changed");
                }
                auto truncated = bytes;
                truncated.resize (64);
                requireThrows ([&] { (void)FrescoScene::PuppetModel::parse (truncated); },
                    "truncated puppet was accepted");
                auto wrongVersion = bytes;
                wrongVersion[7] = std::byte { '2' };
                requireThrows ([&] { (void)FrescoScene::PuppetModel::parse (wrongVersion); },
                    "unsupported puppet version was accepted");
            }
            if (!model.animations ().empty ()) {
                require (model.animationVersion () == 6, "unexpected animation version");
                const auto first = model.deformSingleAnimation (
                    model.animations ().front ().id, 0.0
                );
                const auto later = model.deformSingleAnimation (
                    model.animations ().front ().id, 0.37
                );
                require (first.size () == model.vertices ().size (), "deformation size mismatch");
                require (later.size () == first.size (), "temporal deformation size mismatch");
                bool changed = false;
                for (size_t vertex = 0; vertex < first.size (); ++vertex) {
                    const auto finite = [] (const auto& value) {
                        return std::isfinite (value.x) && std::isfinite (value.y)
                            && std::isfinite (value.z);
                    };
                    require (finite (first[vertex]) && finite (later[vertex]),
                        "non-finite puppet deformation");
                    changed = changed || std::abs (first[vertex].x - later[vertex].x) > 1.0e-4f
                        || std::abs (first[vertex].y - later[vertex].y) > 1.0e-4f
                        || std::abs (first[vertex].z - later[vertex].z) > 1.0e-4f;
                }
                deformedModels += changed ? 1 : 0;
                requireThrows ([&] { (void)model.deformSingleAnimation (-1, 0.0); },
                    "missing puppet animation was accepted");
            }
            if (index == 1) {
                FrescoScene::PuppetRuntimeMesh runtime (bytes);
                require (runtime.textureCoordinates ().size () == model.vertices ().size () * 2,
                    "runtime texture coordinate count mismatch");
                require (runtime.indices ().size () == model.triangles ().size () * 3,
                    "runtime index count mismatch");
                const std::array<FrescoScene::PuppetLayerInput, 2> layers {{
                    { 435, 267, 0.9, 1.0, true, false },
                    { 1372, 777, 1.0, 1.0, true, true },
                }};
                runtime.configureLayers (layers);
                runtime.advance (0.0);
                const auto initial = runtime.positions (1920.0f, 1080.0f);
                runtime.advance (0.37);
                const auto temporal = runtime.positions (1920.0f, 1080.0f);
                require (initial.size () == model.vertices ().size () * 3,
                    "runtime position count mismatch");
                require (initial != temporal, "replace/additive puppet stack did not advance");
                auto hidden = layers;
                hidden[0].visible = hidden[1].visible = false;
                runtime.configureLayers (hidden);
                const auto bind = runtime.positions (1920.0f, 1080.0f);
                require (bind != temporal, "puppet visibility inputs did not affect geometry");
                auto frozen = layers;
                frozen[0].rate = frozen[1].rate = 0.0;
                runtime.configureLayers (frozen);
                runtime.advance (0.74);
                const auto paused = runtime.positions (1920.0f, 1080.0f);
                runtime.advance (1.11);
                require (paused == runtime.positions (1920.0f, 1080.0f),
                    "zero-rate puppet layer advanced");
            }
            if (index == 3) {
                require (model.attachments ()[0].name == "Attachment",
                    "Subaru attachment name changed");
                require (model.attachments ()[0].boneIndex == 0,
                    "Subaru attachment bone changed");
                FrescoScene::PuppetRuntimeMesh runtime (bytes);
                const std::array<FrescoScene::PuppetLayerInput, 1> layers {{
                    { 435, 196, 1.0, 1.0, true, false },
                }};
                runtime.configureLayers (layers);
                runtime.advance (0.0);
                const auto initial = runtime.attachmentPosition ("Attachment");
                runtime.advance (0.37);
                const auto temporal = runtime.attachmentPosition ("Attachment");
                require (initial.has_value () && temporal.has_value (),
                    "Subaru attachment did not resolve");
                require (initial->x != temporal->x || initial->y != temporal->y
                        || initial->z != temporal->z,
                    "Subaru attachment did not follow its animated bone");
            }
            if (index == 7) {
                require (model.animations ().empty (),
                    "simulation-bearing Subaru ahoge gained authored animation");
                require (model.simulationEnabledBoneCount () == 5,
                    "Subaru ahoge simulation inventory changed");
                const std::array<uint32_t, 5> expectedParents {{ 1, 2, 3, 4, 5 }};
                const std::array<int, 5> expectedFriction {{ 38, 33, 29, 27, 26 }};
                for (size_t offset = 0; offset < expectedParents.size (); ++offset) {
                    const auto& bone = model.bones ()[offset + 2];
                    require (bone.parent == expectedParents[offset],
                        "Subaru ahoge simulation chain changed");
                    require (bone.simulation.has_value (),
                        "Subaru ahoge simulation enablement changed");
                    const auto& simulation = *bone.simulation;
                    require (simulation.mode == 0,
                        "Subaru ahoge simulation mode changed");
                    require (simulation.rotationEnabled,
                        "Subaru ahoge rotational simulation changed");
                    require (!simulation.translationEnabled,
                        "Subaru ahoge unexpectedly enables translation physics");
                    require (!simulation.gravityEnabled,
                        "Subaru ahoge unexpectedly enables gravity");
                    require (!simulation.inverseKinematicsEnabled,
                        "Subaru ahoge unexpectedly enables IK");
                    require (simulation.rotationAxes == std::array<bool, 3> { false, false, true },
                        "Subaru ahoge rotation axes changed");
                    require (simulation.rotationFriction == expectedFriction[offset],
                        "Subaru ahoge rotational friction changed");
                    require (simulation.rotationInertia == 30,
                        "Subaru ahoge rotational inertia changed");
                    require (simulation.rotationStiffness == 300,
                        "Subaru ahoge rotational stiffness changed");
                    require (simulation.tipMass == 20,
                        "Subaru ahoge tip mass changed");
                    require (simulation.rotationLimited,
                        "Subaru ahoge rotation limits changed");
                    require (std::abs (simulation.rotationMinimum.z + 3.14159f) < 0.00001f
                            && std::abs (simulation.rotationMaximum.z - 3.14159f) < 0.00001f,
                        "Subaru ahoge rotation limit values changed");
                    require (simulation.rotationMinimum.x == 0
                            && simulation.rotationMinimum.y == 0
                            && simulation.rotationMaximum.x == 0
                            && simulation.rotationMaximum.y == 0,
                        "Subaru ahoge gained non-Z rotation limits");
                    if (offset + 3 < model.bones ().size ()) {
                        const auto& next = model.bones ()[offset + 3];
                        require (
                            std::abs (simulation.tipPosition.x
                                - next.localBind.values[12]) < 0.001f
                                && std::abs (simulation.tipPosition.y
                                    - next.localBind.values[13]) < 0.001f,
                            "Subaru ahoge tip positions are no longer skeleton-space joints"
                        );
                    }
                }
                size_t affectedVertices = 0;
                double activeWeight = 0.0;
                for (const auto& vertex : model.vertices ()) {
                    bool affected = false;
                    for (size_t influence = 0; influence < vertex.boneWeights.size (); ++influence) {
                        const auto bone = vertex.boneIndices[influence];
                        if (vertex.boneWeights[influence] > 0.0f
                            && model.bones ()[bone].simulation.has_value ()) {
                            affected = true;
                            activeWeight += vertex.boneWeights[influence];
                        }
                    }
                    affectedVertices += affected ? 1 : 0;
                }
                std::cout << "  simulation sensitivity: " << affectedVertices
                          << " vertices, active weight=" << activeWeight << '\n';
                require (affectedVertices == 246,
                    "Subaru ahoge simulation vertex coverage changed");
                require (std::abs (activeWeight - 223.2) < 0.1,
                    "Subaru ahoge simulation weight coverage changed");
                FrescoScene::PuppetSecondaryMotion secondaryMotion (model.bones ());
                require (secondaryMotion.supported (),
                    "Subaru ahoge secondary-motion boundary changed");
                std::vector<float> authoredRotation (model.bones ().size (), 0.0f);
                require (secondaryMotion.reset ({}, authoredRotation),
                    "Subaru ahoge secondary motion did not reset");
                require (secondaryMotion.advance (
                        1.0 / 60.0, { .rotationZ = 0.8f }, authoredRotation
                    ),
                    "Subaru ahoge secondary motion did not advance");
                require (secondaryMotion.evidence ().steps == 2
                        && secondaryMotion.evidence ().changes == 2,
                    "Subaru ahoge secondary-motion evidence did not advance");
                for (size_t boneIndex = 2; boneIndex < 7; ++boneIndex) {
                    require (
                        std::abs (secondaryMotion.rotationOffsetsZ ()[boneIndex]) > 1.0e-6f,
                        "Subaru ahoge secondary-motion chain did not propagate");
                }
                auto invalidConstraint = bytes;
                constexpr std::string_view frictionMarker = "\"rf\":38";
                const auto marker = std::search (
                    invalidConstraint.begin (), invalidConstraint.end (),
                    reinterpret_cast<const std::byte*> (frictionMarker.data ()),
                    reinterpret_cast<const std::byte*> (
                        frictionMarker.data () + frictionMarker.size ()
                    )
                );
                require (marker != invalidConstraint.end (),
                    "Subaru ahoge friction marker disappeared");
                marker[5] = std::byte { '-' };
                requireThrows (
                    [&] { (void)FrescoScene::PuppetModel::parse (invalidConstraint); },
                    "negative simulation friction was accepted"
                );
            }
            activeIKBones += model.activeIKBoneCount ();
            simulationBones += model.simulationEnabledBoneCount ();
            animations += model.animations ().size ();
            ++models;
            std::cout << argv[index] << ": " << model.vertices ().size () << " vertices, "
                      << model.bones ().size () << " bones, " << model.animations ().size ()
                      << " animations, " << model.partCount () << " parts, "
                      << model.maskCount () << " masks, " << model.attachmentCount ()
                      << " attachments, " << model.constraintMetadataBoneCount ()
                      << " bones with constraint metadata, curves="
                      << model.hasAnimationCurves () << ", morphs=" << model.hasMorphSections ()
                      << ", extended-bind=" << model.hasExtendedBindMetadata ()
                      << ", extended-bind-max-difference="
                      << model.extendedBindMaxDifference () << '\n';
            for (const auto& animation : model.animations ()) {
                std::cout << "  animation " << animation.id << " " << animation.name << ", "
                          << animation.framesPerSecond << " fps, " << animation.length
                          << " intervals\n";
            }
            for (const auto& mask : model.masks ()) {
                std::cout << "  mask " << mask.texture << ", flags=" << mask.flags
                          << ", targets=" << mask.targetPartOrdinals.size ()
                          << ", sources=" << mask.maskPartOrdinals.size () << '\n';
            }
            for (const auto& attachment : model.attachments ()) {
                std::cout << "  attachment " << attachment.name << " on bone "
                          << attachment.boneIndex << '\n';
            }
        }
        require (models == 7, "pinned puppet model count changed");
        require (animations > 0, "pinned puppets have no animations");
        require (deformedModels > 0, "pinned puppet animations do not move geometry");
        require (activeIKBones == 0, "pinned puppet corpus gained active IK");
        require (simulationBones == 5,
            "pinned puppet simulation-enabled bone inventory changed");
        std::cout << "puppet model proof: " << models << " models, " << animations
                  << " animations, " << deformedModels << " temporal deformations, "
                  << activeIKBones << " active IK bones, " << simulationBones
                  << " static-puppet simulation bones\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "fail: " << error.what () << '\n';
        return 1;
    }
}
