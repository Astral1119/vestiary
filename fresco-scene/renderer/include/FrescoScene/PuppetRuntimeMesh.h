#pragma once

#include "FrescoScene/PuppetModel.h"
#include "FrescoScene/PuppetSecondaryMotion.h"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace FrescoScene {

struct PuppetLayerInput {
    int32_t layerID = 0;
    int32_t animationID = 0;
    double rate = 1.0;
    double blend = 1.0;
    bool visible = true;
    bool additive = false;
};

struct PuppetSecondaryMotionUpdate {
    uint64_t steps = 0;
    uint64_t changes = 0;
};

class PuppetRuntimeMesh {
public:
    explicit PuppetRuntimeMesh (std::span<const std::byte> data);

    void configureLayers (std::span<const PuppetLayerInput> layers);
    PuppetSecondaryMotionUpdate advance (
        double elapsedSeconds,
        PuppetSecondaryMotionTransform2D parentTransform = {}
    );

    [[nodiscard]] std::vector<float> positions (float width, float height) const;
    [[nodiscard]] std::optional<PuppetVec3> attachmentPosition (
        std::string_view name
    ) const;
    [[nodiscard]] const std::vector<float>& textureCoordinates () const { return m_texcoords; }
    [[nodiscard]] const std::vector<uint16_t>& indices () const { return m_indices; }
    [[nodiscard]] const PuppetModel& model () const { return m_model; }
    [[nodiscard]] bool secondaryMotionSupported () const {
        return m_secondaryMotion.supported ();
    }
    [[nodiscard]] const std::string& secondaryMotionDiagnostic () const {
        return m_secondaryMotion.diagnostic ();
    }

private:
    struct LayerCursor {
        PuppetLayerInput input;
        double timeSeconds = 0.0;
    };

    PuppetModel m_model;
    PuppetSecondaryMotion m_secondaryMotion;
    std::vector<float> m_texcoords;
    std::vector<uint16_t> m_indices;
    std::vector<LayerCursor> m_layers;
    std::vector<float> m_authoredLocalRotationZ;
    double m_lastElapsedSeconds = -1.0;
};

}
