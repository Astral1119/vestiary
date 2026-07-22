#pragma once

#include "FrescoScene/VideoTextureControl.h"

namespace WallpaperEngine::VideoPlayback::MPV {
class GLPlayer;
}

namespace FrescoScene {

class GLPlayerVideoTextureControl final : public VideoTexturePlayerControl {
public:
    explicit GLPlayerVideoTextureControl (
        WallpaperEngine::VideoPlayback::MPV::GLPlayer& player
    );

    void setScriptPaused (bool paused) override;
    void setHostPaused (bool paused) override;
    void setHostVisible (bool visible) override;

private:
    WallpaperEngine::VideoPlayback::MPV::GLPlayer& m_player;
};

}
