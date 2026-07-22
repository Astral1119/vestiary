#pragma once

#include <string>

namespace WallpaperEngine::Data::Model {
struct ImageAnimationLayer;
struct Object;
}

namespace FrescoScene {

void clearPuppetLayerSemantics ();
void registerPuppetLayerSemantics (
    const WallpaperEngine::Data::Model::ImageAnimationLayer* layer, bool additive
);
[[nodiscard]] bool puppetLayerIsAdditive (
    const WallpaperEngine::Data::Model::ImageAnimationLayer* layer
);
void registerPuppetAttachment (
    const WallpaperEngine::Data::Model::Object* object, std::string attachment
);
[[nodiscard]] std::string puppetAttachment (
    const WallpaperEngine::Data::Model::Object* object
);

}
