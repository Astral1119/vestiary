#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <optional>
#include <vector>

namespace FrescoScene {

struct PuppetVec3 {
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;
};

struct PuppetMat4 {
    std::array<float, 16> values {};

    static PuppetMat4 identity ();
};

struct PuppetVertex {
    PuppetVec3 position;
    std::array<uint32_t, 4> boneIndices {};
    std::array<float, 4> boneWeights {};
    std::array<float, 2> textureCoordinate {};
};

struct PuppetPart {
    uint32_t id = 0;
    uint32_t firstIndex = 0;
    uint32_t indexCount = 0;
};

struct PuppetMask {
    uint64_t source = 0;
    std::string texture;
    uint32_t flags = 0;
    std::vector<uint32_t> targetPartOrdinals;
    std::vector<uint32_t> maskPartOrdinals;
};

struct PuppetAttachment {
    uint16_t boneIndex = 0;
    std::string name;
    PuppetMat4 localTransform;
};

struct PuppetSimulationConstraint {
    int mode = 0;
    bool rotationEnabled = false;
    bool translationEnabled = false;
    bool gravityEnabled = false;
    bool inverseKinematicsEnabled = false;
    std::array<bool, 3> rotationAxes {};
    bool rotationLimited = false;
    PuppetVec3 rotationMinimum;
    PuppetVec3 rotationMaximum;
    float rotationFriction = 0.0f;
    float rotationInertia = 0.0f;
    float rotationStiffness = 0.0f;
    float tipMass = 0.0f;
    PuppetVec3 tipPosition;
};

struct PuppetBone {
    static constexpr uint32_t noParent = 0xffffffffu;

    std::string name;
    uint32_t parent = noParent;
    PuppetMat4 localBind;
    std::string constraintMetadata;
    std::optional<PuppetSimulationConstraint> simulation;
};

struct PuppetBoneFrame {
    PuppetVec3 position;
    PuppetVec3 angles;
    PuppetVec3 scale;
};

struct PuppetBoneTrack {
    std::vector<PuppetBoneFrame> frames;
};

enum class PuppetPlayMode {
    loop,
    mirror,
    single,
};

struct PuppetAnimation {
    int32_t id = 0;
    std::string name;
    PuppetPlayMode mode = PuppetPlayMode::loop;
    float framesPerSecond = 0.0f;
    int32_t length = 0;
    std::vector<PuppetBoneTrack> boneTracks;
};

class PuppetParseError final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class PuppetModel {
public:
    static PuppetModel parse (std::span<const std::byte> data);

    [[nodiscard]] int modelVersion () const { return m_modelVersion; }
    [[nodiscard]] int skeletonVersion () const { return m_skeletonVersion; }
    [[nodiscard]] int animationVersion () const { return m_animationVersion; }
    [[nodiscard]] const std::vector<PuppetVertex>& vertices () const { return m_vertices; }
    [[nodiscard]] const std::vector<std::array<uint32_t, 3>>& triangles () const { return m_triangles; }
    [[nodiscard]] const std::vector<PuppetPart>& parts () const { return m_parts; }
    [[nodiscard]] const std::vector<PuppetMask>& masks () const { return m_masks; }
    [[nodiscard]] const std::vector<PuppetAttachment>& attachments () const {
        return m_attachments;
    }
    [[nodiscard]] const std::vector<PuppetBone>& bones () const { return m_bones; }
    [[nodiscard]] const std::vector<PuppetAnimation>& animations () const { return m_animations; }
    [[nodiscard]] size_t partCount () const { return m_partCount; }
    [[nodiscard]] size_t maskCount () const { return m_maskCount; }
    [[nodiscard]] size_t attachmentCount () const { return m_attachmentCount; }
    [[nodiscard]] size_t constraintMetadataBoneCount () const {
        return m_constraintMetadataBoneCount;
    }
    [[nodiscard]] size_t simulationEnabledBoneCount () const {
        return m_simulationEnabledBoneCount;
    }
    [[nodiscard]] size_t activeIKBoneCount () const { return m_activeIKBoneCount; }
    [[nodiscard]] bool hasAnimationCurves () const { return m_hasAnimationCurves; }
    [[nodiscard]] bool hasMorphSections () const { return m_hasMorphSections; }
    [[nodiscard]] bool hasExtendedBindMetadata () const { return m_hasExtendedBindMetadata; }
    [[nodiscard]] float extendedBindMaxDifference () const {
        return m_extendedBindMaxDifference;
    }

    // Proof boundary: one selected MDLA animation with ordinary chained LBS.
    // Animation-layer composition, curves, masks, attachments, simulation,
    // IK, morphs, and MDLE metadata remain renderer-integration work.
    [[nodiscard]] std::vector<PuppetVec3> deformSingleAnimation (
        int32_t animationID, double seconds
    ) const;

    struct AnimationLayer {
        int32_t animationID = 0;
        double timeSeconds = 0.0;
        double blend = 1.0;
        bool visible = true;
        bool additive = false;
    };

    [[nodiscard]] std::vector<PuppetVec3> deformLayers (
        std::span<const AnimationLayer> layers,
        std::span<const float> localRotationOffsetsZ = {}
    ) const;

    [[nodiscard]] std::vector<float> localRotationZ (
        std::span<const AnimationLayer> layers
    ) const;

    [[nodiscard]] std::optional<PuppetVec3> attachmentPosition (
        std::string_view name,
        std::span<const AnimationLayer> layers,
        std::span<const float> localRotationOffsetsZ = {}
    ) const;

private:
    [[nodiscard]] std::vector<PuppetMat4> animatedBoneWorld (
        std::span<const AnimationLayer> layers,
        std::span<const float> localRotationOffsetsZ = {},
        std::vector<float>* localRotationZ = nullptr
    ) const;

    int m_modelVersion = 0;
    int m_skeletonVersion = 0;
    int m_animationVersion = 0;
    std::vector<PuppetVertex> m_vertices;
    std::vector<std::array<uint32_t, 3>> m_triangles;
    std::vector<PuppetPart> m_parts;
    std::vector<PuppetMask> m_masks;
    std::vector<PuppetAttachment> m_attachments;
    std::vector<PuppetBone> m_bones;
    std::vector<PuppetAnimation> m_animations;
    size_t m_partCount = 0;
    size_t m_maskCount = 0;
    size_t m_attachmentCount = 0;
    size_t m_constraintMetadataBoneCount = 0;
    size_t m_simulationEnabledBoneCount = 0;
    size_t m_activeIKBoneCount = 0;
    bool m_hasAnimationCurves = false;
    bool m_hasMorphSections = false;
    bool m_hasExtendedBindMetadata = false;
    float m_extendedBindMaxDifference = 0.0f;
};

}
