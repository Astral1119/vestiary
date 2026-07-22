#pragma once

#include "WallpaperEngine/Render/CObject.h"

namespace WallpaperEngine::Render::Objects {
class CSound final : public CObject {
public:
    CSound (Wallpapers::CScene& scene, const Data::Model::Sound& sound);
};
}
