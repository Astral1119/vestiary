#pragma once

#include "WallpaperEngine/Data/Model/Types.h"

#include <cstdint>
#include <vector>

namespace WallpaperEngine::Render::Wallpapers {
class CScene;
}

namespace FrescoScene {

class TextEffectRegistrySession final {
public:
    TextEffectRegistrySession ();
    ~TextEffectRegistrySession ();

    TextEffectRegistrySession (const TextEffectRegistrySession&) = delete;
    TextEffectRegistrySession& operator= (const TextEffectRegistrySession&) = delete;

    void activate () const;
    void bindScene (
        const WallpaperEngine::Render::Wallpapers::CScene* scene
    ) const;

private:
    std::uint64_t m_id = 0;
};

void registerTextEffects (
    int objectId,
    std::vector<WallpaperEngine::Data::Model::ImageEffectUniquePtr> effects
);

const std::vector<WallpaperEngine::Data::Model::ImageEffectUniquePtr>&
textEffects (int objectId);

const std::vector<WallpaperEngine::Data::Model::ImageEffectUniquePtr>&
textEffects (
    const WallpaperEngine::Render::Wallpapers::CScene* scene,
    int objectId
);

}
