#include "FrescoScene/SceneAudioVector.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cmath>

namespace {

bool near (float left, float right) {
    return std::abs (left - right) < 0.00001F;
}

}

int main () {
    std::array<float, 128> spectrum = {};
    for (std::size_t bin = 0; bin < 64; ++bin) {
        spectrum[bin] = static_cast<float> (bin);
        spectrum[64 + bin] = static_cast<float> (100 + bin);
    }
    const auto snapshot = FrescoScene::SceneAudioVectorSnapshot::fromSpectrum (
        spectrum
    );
    for (std::size_t bin = 0; bin < FrescoScene::sceneAudioVectorBins; ++bin) {
        const float left = static_cast<float> (bin * 4) + 1.5F;
        const float right = left + 100.0F;
        assert (near (snapshot.left[bin], left));
        assert (near (snapshot.right[bin], right));
        assert (near (snapshot.average[bin], left + 50.0F));
    }

    std::array<float, FrescoScene::sceneAudioVectorBins> left = {};
    std::array<float, FrescoScene::sceneAudioVectorBins> right = {};
    left[15] = 0.25F;
    right[15] = 0.75F;
    const auto stereo = FrescoScene::SceneAudioVectorSnapshot::fromStereo16 (
        left, right
    );
    assert (near (stereo.average[15], 0.5F));
    float rawLeft[FrescoScene::sceneAudioVectorBins] = {};
    float rawRight[FrescoScene::sceneAudioVectorBins] = {};
    rawLeft[7] = 0.2F;
    rawRight[7] = 0.6F;
    const auto rawStereo = FrescoScene::SceneAudioVectorSnapshot::fromStereo16 (
        rawLeft, rawRight
    );
    assert (near (rawStereo.average[7], 0.4F));

    FrescoScene::SceneAudioVectorTransform transform (
        0.5F,
        {
            .frequency = 15,
            .smoothing = 15.0F,
            .minimum = 0.8F,
            .maximum = 1.2F,
        }
    );
    const auto first = transform.update (stereo, 1.0F / 60.0F);
    assert (first.has_value ());
    assert (near (first->smoothedAudio, 0.125F));
    assert (near (first->scalar, 0.425F));
    const std::array<float, 3> expectedFirstVector = {
        0.425F, 0.425F, 0.425F,
    };
    assert (first->vector == expectedFirstVector);
    const auto saturated = transform.update (stereo, 1.0F);
    assert (saturated.has_value ());
    assert (near (saturated->smoothedAudio, 0.5F));
    assert (near (saturated->scalar, 0.5F));
    assert (
        transform.setConfiguration ({ .frequency = 7, .smoothing = 5.0F })
        == FrescoScene::SceneAudioVectorTransformError::none
    );
    const auto reconfigured = transform.update (rawStereo, 0.1F);
    assert (reconfigured.has_value ());
    assert (near (reconfigured->smoothedAudio, 0.45F));

    FrescoScene::SceneAudioVectorTransform invalid (
        1.0F,
        { .frequency = 16 }
    );
    assert (
        invalid.error ()
        == FrescoScene::SceneAudioVectorTransformError::frequencyOutOfRange
    );
    assert (!invalid.update (snapshot, 0.1F).has_value ());
    assert (
        FrescoScene::sceneAudioVectorTransformDiagnostic (invalid.error ())
        == "audio vector transform frequency must be in [0, 15]"
    );

    FrescoScene::SceneAudioVectorTransform negativeSmoothing (
        1.0F,
        { .smoothing = -0.01F }
    );
    assert (
        negativeSmoothing.error ()
        == FrescoScene::SceneAudioVectorTransformError::negativeSmoothing
    );
    assert (
        FrescoScene::sceneAudioVectorTransformDiagnostic (
            negativeSmoothing.error ()
        ) == "audio vector transform smoothing must be non-negative"
    );

    FrescoScene::SceneAudioVectorTransform reversedRange (
        1.0F,
        { .minimum = 1.2F, .maximum = 0.8F }
    );
    assert (
        reversedRange.error ()
        == FrescoScene::SceneAudioVectorTransformError::reversedValueRange
    );
    assert (
        FrescoScene::sceneAudioVectorTransformDiagnostic (reversedRange.error ())
        == "audio vector transform maximum must be at least its minimum"
    );

    FrescoScene::SceneAudioVectorTransform negativeFrameTime (1.0F, {});
    assert (!negativeFrameTime.update (snapshot, -0.001F).has_value ());
    assert (
        negativeFrameTime.error ()
        == FrescoScene::SceneAudioVectorTransformError::negativeFrameTime
    );
    assert (
        FrescoScene::sceneAudioVectorTransformDiagnostic (
            negativeFrameTime.error ()
        ) == "audio vector transform frame time must be non-negative"
    );
    negativeFrameTime.reset ();
    assert (
        negativeFrameTime.error ()
        == FrescoScene::SceneAudioVectorTransformError::none
    );
    assert (negativeFrameTime.update (snapshot, 0.0F).has_value ());
}
