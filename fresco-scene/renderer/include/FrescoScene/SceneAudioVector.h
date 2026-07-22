#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace FrescoScene {

inline constexpr std::size_t sceneAudioVectorBins = 16;

struct SceneAudioVectorSnapshot {
    std::array<float, sceneAudioVectorBins> left = {};
    std::array<float, sceneAudioVectorBins> right = {};
    std::array<float, sceneAudioVectorBins> average = {};

    [[nodiscard]] static SceneAudioVectorSnapshot fromSpectrum (
        const std::array<float, 128>& spectrum
    );

    [[nodiscard]] static SceneAudioVectorSnapshot fromStereo16 (
        const std::array<float, sceneAudioVectorBins>& left,
        const std::array<float, sceneAudioVectorBins>& right
    );

    [[nodiscard]] static SceneAudioVectorSnapshot fromStereo16 (
        const float (&left)[sceneAudioVectorBins],
        const float (&right)[sceneAudioVectorBins]
    );
};

struct SceneAudioVectorTransformConfiguration {
    std::size_t frequency = 0;
    float smoothing = 15.0F;
    float minimum = 0.8F;
    float maximum = 1.2F;
};

enum class SceneAudioVectorTransformError : std::uint8_t {
    none,
    frequencyOutOfRange,
    nonFiniteConfiguration,
    negativeSmoothing,
    reversedValueRange,
    nonFiniteFrameTime,
    negativeFrameTime,
};

[[nodiscard]] std::string_view sceneAudioVectorTransformDiagnostic (
    SceneAudioVectorTransformError error
);

struct SceneAudioVectorTransformSample {
    float scalar = 0.0F;
    std::array<float, 3> vector = {};
    float smoothedAudio = 0.0F;
};

class SceneAudioVectorTransform {
public:
    SceneAudioVectorTransform (
        float initialX,
        SceneAudioVectorTransformConfiguration configuration
    );

    [[nodiscard]] SceneAudioVectorTransformError error () const;
    [[nodiscard]] std::optional<SceneAudioVectorTransformSample> update (
        const SceneAudioVectorSnapshot& snapshot,
        float frameTimeSeconds
    );
    [[nodiscard]] float smoothedAudio () const;
    [[nodiscard]] SceneAudioVectorTransformError setConfiguration (
        SceneAudioVectorTransformConfiguration configuration
    );
    void reset ();

private:
    float m_initialX;
    SceneAudioVectorTransformConfiguration m_configuration;
    SceneAudioVectorTransformError m_error;
    float m_smoothedAudio = 0.0F;
};

}
