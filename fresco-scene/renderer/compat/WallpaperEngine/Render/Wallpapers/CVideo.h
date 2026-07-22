#pragma once

#include "WallpaperEngine/Render/CWallpaper.h"

namespace WallpaperEngine::Render::Wallpapers {
class CVideo final : public CWallpaper {
public:
    CVideo (
        const Wallpaper& wallpaper, RenderContext& context, AudioContext& audioContext,
        const WallpaperState::TextureUVsScaling& scalingMode, const uint32_t& clampMode
    ) : CWallpaper (wallpaper, context, audioContext, scalingMode, clampMode) { }

    [[nodiscard]] int getWidth () const override { return 1; }
    [[nodiscard]] int getHeight () const override { return 1; }

protected:
    void renderFrame (const glm::ivec4&) override { }
};
}
