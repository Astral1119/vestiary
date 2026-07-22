#import <AVFAudio/AVFAudio.h>

#include "WallpaperEngine/Audio/AudioContext.h"

#include <memory>
#include <stdexcept>
#include <utility>

using namespace WallpaperEngine::Audio;

namespace {

class AVAudioSoundPlayer final : public SoundPlayer {
public:
    explicit AVAudioSoundPlayer (const std::vector<std::uint8_t>& bytes) {
        NSData* data = [NSData dataWithBytes:bytes.data () length:bytes.size ()];
        NSError* error = nil;
        m_player = [[AVAudioPlayer alloc] initWithData:data error:&error];
        if (m_player == nil) {
            const char* message = error == nil
                ? "AVAudioPlayer rejected audio data"
                : error.localizedDescription.UTF8String;
            throw std::runtime_error (message == nullptr ? "audio decode failed" : message);
        }
        if (![m_player prepareToPlay]) {
            throw std::runtime_error ("AVAudioPlayer could not prepare decoded audio");
        }
    }

    bool play () override { return [m_player play]; }
    void pause () override { [m_player pause]; }
    void stop () override {
        [m_player stop];
        m_player.currentTime = 0.0;
    }
    [[nodiscard]] bool isPlaying () const override { return m_player.isPlaying; }
    void setLooping (bool looping) override { m_player.numberOfLoops = looping ? -1 : 0; }
    void setVolume (float volume) override { m_player.volume = volume; }

private:
    AVAudioPlayer* m_player;
};

class AVAudioPlayerBackend final : public SoundBackend {
public:
    [[nodiscard]] std::unique_ptr<SoundPlayer> createPlayer (
        const std::vector<std::uint8_t>& data
    ) override {
        return std::make_unique<AVAudioSoundPlayer> (data);
    }
};

}

std::unique_ptr<SoundBackend> WallpaperEngine::Audio::makeAVAudioPlayerBackend () {
    return std::make_unique<AVAudioPlayerBackend> ();
}
