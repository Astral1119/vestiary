#include "FrescoScene/GLPlayerVideoTextureControl.h"

#include "WallpaperEngine/VideoPlayback/MPV/GLPlayer.h"

namespace FrescoScene {

GLPlayerVideoTextureControl::GLPlayerVideoTextureControl (
    WallpaperEngine::VideoPlayback::MPV::GLPlayer& player
) : m_player (player) { }

void GLPlayerVideoTextureControl::setScriptPaused (bool paused) {
    m_player.setPaused (paused);
}

void GLPlayerVideoTextureControl::setHostPaused (bool paused) {
    m_player.setHostPaused (paused);
}

void GLPlayerVideoTextureControl::setHostVisible (bool visible) {
    m_player.setHostVisible (visible);
}

}
