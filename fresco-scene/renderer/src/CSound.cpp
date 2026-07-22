#include "WallpaperEngine/Render/Objects/CSound.h"

#include "WallpaperEngine/Assets/AssetLocator.h"
#include "WallpaperEngine/Audio/AudioContext.h"
#include "WallpaperEngine/Render/Wallpapers/CScene.h"

#include <iterator>
#include <utility>
#include <vector>

using namespace WallpaperEngine::Audio;
using namespace WallpaperEngine::Render::Objects;

CSound::CSound (Wallpapers::CScene& scene, const Data::Model::Sound& sound)
    : CObject (scene, sound) {
    const auto* assets = &getAssetLocator ();
    scene.getAudioContext ().registerSound (
        sound.id,
        sound.name,
        parseSoundPlaybackMode (sound.playbackmode),
        sound.sounds,
        [assets] (const std::string& path) {
            const auto stream = assets->read (path);
            return std::vector<std::uint8_t> (
                std::istreambuf_iterator<char> (*stream),
                std::istreambuf_iterator<char> ()
            );
        }
    );
}
