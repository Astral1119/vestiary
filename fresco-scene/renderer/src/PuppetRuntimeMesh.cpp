#include "FrescoScene/PuppetRuntimeMesh.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace FrescoScene {

PuppetRuntimeMesh::PuppetRuntimeMesh (std::span<const std::byte> data)
    : m_model (PuppetModel::parse (data)), m_secondaryMotion (m_model.bones ()) {
    m_texcoords.reserve (m_model.vertices ().size () * 2);
    for (const PuppetVertex& vertex : m_model.vertices ()) {
        m_texcoords.push_back (vertex.textureCoordinate[0]);
        m_texcoords.push_back (vertex.textureCoordinate[1]);
    }
    m_indices.reserve (m_model.triangles ().size () * 3);
    for (const auto& triangle : m_model.triangles ()) {
        for (const uint32_t index : triangle) {
            if (index > std::numeric_limits<uint16_t>::max ()) {
                throw PuppetParseError ("bounded puppet mesh requires 16-bit indices");
            }
            m_indices.push_back (static_cast<uint16_t> (index));
        }
    }
}

void PuppetRuntimeMesh::configureLayers (std::span<const PuppetLayerInput> layers) {
    std::vector<LayerCursor> configured;
    configured.reserve (layers.size ());
    for (const PuppetLayerInput& layer : layers) {
        if (!std::isfinite (layer.rate) || !std::isfinite (layer.blend)) continue;
        const auto previous = std::find_if (m_layers.begin (), m_layers.end (),
            [&layer] (const auto& candidate) {
                return candidate.input.layerID == layer.layerID
                    && candidate.input.animationID == layer.animationID;
            });
        configured.push_back ({
            .input = layer,
            .timeSeconds = previous == m_layers.end () ? 0.0 : previous->timeSeconds,
        });
    }
    m_layers = std::move (configured);
}

PuppetSecondaryMotionUpdate PuppetRuntimeMesh::advance (
    double elapsedSeconds, PuppetSecondaryMotionTransform2D parentTransform
) {
    if (!std::isfinite (elapsedSeconds)) return {};
    if (m_lastElapsedSeconds < 0.0 || elapsedSeconds < m_lastElapsedSeconds) {
        m_lastElapsedSeconds = elapsedSeconds;
        m_authoredLocalRotationZ = m_model.localRotationZ ({});
        if (m_secondaryMotion.supported ()) {
            (void)m_secondaryMotion.reset (parentTransform, m_authoredLocalRotationZ);
        }
        return {};
    }
    const double delta = elapsedSeconds - m_lastElapsedSeconds;
    m_lastElapsedSeconds = elapsedSeconds;
    for (LayerCursor& layer : m_layers) {
        if (layer.input.visible) {
            layer.timeSeconds += delta * std::max (0.0, layer.input.rate);
        }
    }
    std::vector<PuppetModel::AnimationLayer> layers;
    layers.reserve (m_layers.size ());
    for (const LayerCursor& layer : m_layers) {
        layers.push_back ({
            .animationID = layer.input.animationID,
            .timeSeconds = layer.timeSeconds,
            .blend = layer.input.blend,
            .visible = layer.input.visible,
            .additive = layer.input.additive,
        });
    }
    m_authoredLocalRotationZ = m_model.localRotationZ (layers);
    if (!m_secondaryMotion.supported ()) return {};
    const PuppetSecondaryMotionEvidence before = m_secondaryMotion.evidence ();
    if (!m_secondaryMotion.advance (
        delta, parentTransform, m_authoredLocalRotationZ
    )) return {};
    const PuppetSecondaryMotionEvidence after = m_secondaryMotion.evidence ();
    return {
        .steps = after.steps - before.steps,
        .changes = after.changes - before.changes,
    };
}

std::vector<float> PuppetRuntimeMesh::positions (float width, float height) const {
    std::vector<PuppetModel::AnimationLayer> layers;
    layers.reserve (m_layers.size ());
    for (const LayerCursor& layer : m_layers) {
        layers.push_back ({
            .animationID = layer.input.animationID,
            .timeSeconds = layer.timeSeconds,
            .blend = layer.input.blend,
            .visible = layer.input.visible,
            .additive = layer.input.additive,
        });
    }
    const std::span<const float> offsets = m_secondaryMotion.supported ()
        ? m_secondaryMotion.rotationOffsetsZ () : std::span<const float> {};
    const auto deformed = m_model.deformLayers (layers, offsets);
    std::vector<float> result;
    result.reserve (deformed.size () * 3);
    for (const PuppetVec3 position : deformed) {
        result.push_back (width / 2.0f + position.x);
        result.push_back (height / 2.0f - position.y);
        result.push_back (position.z);
    }
    return result;
}

std::optional<PuppetVec3> PuppetRuntimeMesh::attachmentPosition (
    std::string_view name
) const {
    std::vector<PuppetModel::AnimationLayer> layers;
    layers.reserve (m_layers.size ());
    for (const LayerCursor& layer : m_layers) {
        layers.push_back ({
            .animationID = layer.input.animationID,
            .timeSeconds = layer.timeSeconds,
            .blend = layer.input.blend,
            .visible = layer.input.visible,
            .additive = layer.input.additive,
        });
    }
    const std::span<const float> offsets = m_secondaryMotion.supported ()
        ? m_secondaryMotion.rotationOffsetsZ () : std::span<const float> {};
    return m_model.attachmentPosition (name, layers, offsets);
}

}
