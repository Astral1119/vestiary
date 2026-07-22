#include "WallpaperEngine/Audio/AudioContext.h"

#include <array>
#include <cmath>
#include <cstdlib>

namespace {

bool closeEnough (float actual, float expected) {
    return std::abs (actual - expected) < 0.00001F;
}

void require (bool condition) {
    if (!condition) {
        std::abort ();
    }
}

}

int main () {
    std::array<float, 128> spectrum = {};
    spectrum[0] = 0.1F;
    spectrum[1] = 0.2F;
    spectrum[2] = 0.3F;
    spectrum[3] = 0.4F;
    spectrum[64] = 0.5F;
    spectrum[65] = 0.6F;
    spectrum[66] = 0.7F;
    spectrum[67] = 0.8F;

    WallpaperEngine::Audio::AudioContext audio;
    auto& recorder = audio.getRecorder ();
    recorder.setSpectrum (spectrum);

    require (closeEnough (recorder.audio64Left[0], 0.1F));
    require (closeEnough (recorder.audio64Right[0], 0.5F));
    require (closeEnough (recorder.audio32Left[0], 0.15F));
    require (closeEnough (recorder.audio32Right[0], 0.55F));
    require (closeEnough (recorder.audio16Left[0], 0.25F));
    require (closeEnough (recorder.audio16Right[0], 0.65F));
    require (closeEnough (recorder.audio16Left[1], 0.0F));
    require (closeEnough (recorder.audio16Right[1], 0.0F));

    recorder.setSpectrum ({});
    require (closeEnough (recorder.audio64Left[0], 0.0F));
    require (closeEnough (recorder.audio64Right[0], 0.0F));
    require (closeEnough (recorder.audio32Left[0], 0.0F));
    require (closeEnough (recorder.audio32Right[0], 0.0F));
    require (closeEnough (recorder.audio16Left[0], 0.0F));
    require (closeEnough (recorder.audio16Right[0], 0.0F));
}
