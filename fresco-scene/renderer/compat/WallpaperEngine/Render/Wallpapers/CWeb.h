#pragma once

#include "WallpaperEngine/Render/CWallpaper.h"

namespace WallpaperEngine::WebBrowser {
class WebBrowserContext;
}

namespace WallpaperEngine::Render::Wallpapers {
class CWeb final : public CWallpaper {
public:
    CWeb (
        const Wallpaper& wallpaper, RenderContext& context, AudioContext& audioContext,
        WebBrowser::WebBrowserContext&, const WallpaperState::TextureUVsScaling& scalingMode,
        const uint32_t& clampMode
    ) : CWallpaper (wallpaper, context, audioContext, scalingMode, clampMode) { }

    [[nodiscard]] int getWidth () const override { return 1; }
    [[nodiscard]] int getHeight () const override { return 1; }

protected:
    void renderFrame (const glm::ivec4&) override { }
};
}
