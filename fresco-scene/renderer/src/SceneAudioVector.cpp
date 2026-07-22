#include "FrescoScene/SceneAudioVector.h"

#include <algorithm>
#include <cmath>

namespace FrescoScene {
namespace {

constexpr std::size_t sourceBinsPerChannel = 64;
constexpr std::size_t sourceBinsPerVectorBin
    = sourceBinsPerChannel / sceneAudioVectorBins;

bool finiteConfiguration (
    const SceneAudioVectorTransformConfiguration& configuration
) {
    return std::isfinite (configuration.smoothing)
        && std::isfinite (configuration.minimum)
        && std::isfinite (configuration.maximum);
}

SceneAudioVectorTransformError validateConfiguration (
    float initialX,
    const SceneAudioVectorTransformConfiguration& configuration
) {
    if (configuration.frequency >= sceneAudioVectorBins) {
        return SceneAudioVectorTransformError::frequencyOutOfRange;
    }
    if (!std::isfinite (initialX) || !finiteConfiguration (configuration)) {
        return SceneAudioVectorTransformError::nonFiniteConfiguration;
    }
    if (configuration.smoothing < 0.0F) {
        return SceneAudioVectorTransformError::negativeSmoothing;
    }
    if (configuration.maximum < configuration.minimum) {
        return SceneAudioVectorTransformError::reversedValueRange;
    }
    return SceneAudioVectorTransformError::none;
}

}

SceneAudioVectorSnapshot SceneAudioVectorSnapshot::fromSpectrum (
    const std::array<float, 128>& spectrum
) {
    SceneAudioVectorSnapshot result;
    for (std::size_t output = 0; output < sceneAudioVectorBins; ++output) {
        float leftTotal = 0.0F;
        float rightTotal = 0.0F;
        for (std::size_t input = 0; input < sourceBinsPerVectorBin; ++input) {
            const std::size_t source = output * sourceBinsPerVectorBin + input;
            leftTotal += spectrum[source];
            rightTotal += spectrum[sourceBinsPerChannel + source];
        }
        result.left[output]
            = leftTotal / static_cast<float> (sourceBinsPerVectorBin);
        result.right[output]
            = rightTotal / static_cast<float> (sourceBinsPerVectorBin);
        result.average[output] = (result.left[output] + result.right[output]) * 0.5F;
    }
    return result;
}

SceneAudioVectorSnapshot SceneAudioVectorSnapshot::fromStereo16 (
    const std::array<float, sceneAudioVectorBins>& left,
    const std::array<float, sceneAudioVectorBins>& right
) {
    SceneAudioVectorSnapshot result { .left = left, .right = right };
    for (std::size_t index = 0; index < sceneAudioVectorBins; ++index) {
        result.average[index] = (left[index] + right[index]) * 0.5F;
    }
    return result;
}

SceneAudioVectorSnapshot SceneAudioVectorSnapshot::fromStereo16 (
    const float (&left)[sceneAudioVectorBins],
    const float (&right)[sceneAudioVectorBins]
) {
    SceneAudioVectorSnapshot result;
    for (std::size_t index = 0; index < sceneAudioVectorBins; ++index) {
        result.left[index] = left[index];
        result.right[index] = right[index];
        result.average[index] = (left[index] + right[index]) * 0.5F;
    }
    return result;
}

std::string_view sceneAudioVectorTransformDiagnostic (
    SceneAudioVectorTransformError error
) {
    switch (error) {
        case SceneAudioVectorTransformError::none:
            return {};
        case SceneAudioVectorTransformError::frequencyOutOfRange:
            return "audio vector transform frequency must be in [0, 15]";
        case SceneAudioVectorTransformError::nonFiniteConfiguration:
            return "audio vector transform configuration must be finite";
        case SceneAudioVectorTransformError::negativeSmoothing:
            return "audio vector transform smoothing must be non-negative";
        case SceneAudioVectorTransformError::reversedValueRange:
            return "audio vector transform maximum must be at least its minimum";
        case SceneAudioVectorTransformError::nonFiniteFrameTime:
            return "audio vector transform frame time must be finite";
        case SceneAudioVectorTransformError::negativeFrameTime:
            return "audio vector transform frame time must be non-negative";
    }
    return "audio vector transform failed with an unknown error";
}

SceneAudioVectorTransform::SceneAudioVectorTransform (
    float initialX,
    SceneAudioVectorTransformConfiguration configuration
) : m_initialX (initialX), m_configuration (configuration),
    m_error (validateConfiguration (initialX, configuration)) { }

SceneAudioVectorTransformError SceneAudioVectorTransform::error () const {
    return m_error;
}

std::optional<SceneAudioVectorTransformSample> SceneAudioVectorTransform::update (
    const SceneAudioVectorSnapshot& snapshot,
    float frameTimeSeconds
) {
    if (m_error != SceneAudioVectorTransformError::none) {
        return std::nullopt;
    }
    if (!std::isfinite (frameTimeSeconds)) {
        m_error = SceneAudioVectorTransformError::nonFiniteFrameTime;
        return std::nullopt;
    }
    if (frameTimeSeconds < 0.0F) {
        m_error = SceneAudioVectorTransformError::negativeFrameTime;
        return std::nullopt;
    }

    const float audio = snapshot.average[m_configuration.frequency];
    if (!std::isfinite (audio)) {
        m_error = SceneAudioVectorTransformError::nonFiniteConfiguration;
        return std::nullopt;
    }
    const float response = std::clamp (
        frameTimeSeconds * m_configuration.smoothing,
        0.0F,
        1.0F
    );
    m_smoothedAudio += (audio - m_smoothedAudio) * response;
    m_smoothedAudio = std::min (1.0F, m_smoothedAudio);
    const float valueDelta = m_configuration.maximum - m_configuration.minimum;
    const float scalar = m_initialX
        * (m_smoothedAudio * valueDelta + m_configuration.minimum);
    return SceneAudioVectorTransformSample {
        .scalar = scalar,
        .vector = { scalar, scalar, scalar },
        .smoothedAudio = m_smoothedAudio,
    };
}

float SceneAudioVectorTransform::smoothedAudio () const {
    return m_smoothedAudio;
}

SceneAudioVectorTransformError SceneAudioVectorTransform::setConfiguration (
    SceneAudioVectorTransformConfiguration configuration
) {
    const auto error = validateConfiguration (m_initialX, configuration);
    if (error != SceneAudioVectorTransformError::none) {
        return error;
    }
    m_configuration = configuration;
    return SceneAudioVectorTransformError::none;
}

void SceneAudioVectorTransform::reset () {
    m_smoothedAudio = 0.0F;
    if (m_error == SceneAudioVectorTransformError::nonFiniteFrameTime
        || m_error == SceneAudioVectorTransformError::negativeFrameTime) {
        m_error = SceneAudioVectorTransformError::none;
    }
}

}
