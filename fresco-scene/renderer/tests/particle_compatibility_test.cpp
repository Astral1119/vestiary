#include "FrescoScene/ParticleCompatibility.h"

#include <array>
#include <cmath>
#include <iostream>
#include <stdexcept>

using namespace FrescoScene;
using WallpaperEngine::Audio::Drivers::Recorders::PlaybackRecorder;

namespace {

bool near (float left, float right) {
    return std::abs (left - right) < 0.0001F;
}

void expect (bool condition) {
    if (!condition) {
        throw std::runtime_error ("particle compatibility assertion failed");
    }
}

}

int main () {
    const auto staticChild = particleChildContract ("static", "particles/child.json", 10);
    expect (staticChild.type == ParticleChildType::staticSystem);
    expect (staticChild.path == "particles/child.json");
    expect (staticChild.maximumCount == 10);
    expect (staticChild.renderable);
    expect (staticChild.diagnostic.empty ());

    expect (particleChildContract ("", "particles/child.json", 20).type
        == ParticleChildType::staticSystem);
    expect (particleChildContract ("eventfollow", "particles/trail.json", 20).type
        == ParticleChildType::eventFollow);
    expect (particleChildContract ("eventspawn", "particles/glow.json", 500).type
        == ParticleChildType::eventSpawn);
    expect (particleChildContract ("future", "particles/future.json", 1).diagnostic
        == "unsupported particle child type: future");
    expect (particleChildContract ("static", "", 1).diagnostic
        == "particle child path is empty");
    expect (particleChildContract ("static", "particles/child.json", 0).diagnostic
        == "particle child maximum count must be positive");

    PlaybackRecorder recorder;
    std::array<float, 128> spectrum {};
    for (std::size_t index = 0; index < 64; ++index) {
        spectrum[index] = 0.25F;
        spectrum[index + 64] = 0.75F;
    }
    recorder.setSpectrum (spectrum);

    const ParticleAudioConfiguration centered {
        .mode = 3,
        .lowerBound = 0.0F,
        .upperBound = 1.0F,
        .exponent = 1,
        .frequencyStart = 0,
        .frequencyEnd = 15,
    };
    const auto center = particleAudioFactor (recorder, centered);
    expect (center.supported);
    expect (near (center.level, 0.5F));
    expect (near (center.factor, 0.5F));

    auto bounded = centered;
    bounded.lowerBound = 0.4F;
    bounded.upperBound = 0.6F;
    bounded.exponent = 2;
    expect (near (particleAudioFactor (recorder, bounded).factor, 0.25F));

    auto bass = centered;
    bass.frequencyEnd = 0;
    spectrum.fill (0.0F);
    for (std::size_t index = 0; index < 4; ++index) {
        spectrum[index] = 1.0F;
        spectrum[index + 64] = 1.0F;
    }
    recorder.setSpectrum (spectrum);
    expect (near (particleAudioFactor (recorder, bass).factor, 1.0F));
    auto treble = bass;
    treble.frequencyStart = 15;
    treble.frequencyEnd = 15;
    expect (near (particleAudioFactor (recorder, treble).factor, 0.0F));

    auto off = centered;
    off.mode = 0;
    expect (near (particleAudioFactor (recorder, off).factor, 1.0F));
    auto unsupported = centered;
    unsupported.mode = 2;
    const auto unsupportedResult = particleAudioFactor (recorder, unsupported);
    expect (!unsupportedResult.supported);
    expect (near (unsupportedResult.factor, 0.0F));
    auto invalidRange = centered;
    invalidRange.frequencyStart = 12;
    invalidRange.frequencyEnd = 3;
    expect (!particleAudioFactor (recorder, invalidRange).supported);

    std::cout << "particle compatibility: child contracts and mode-3 center audio passed\n";
}
