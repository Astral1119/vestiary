#include "FrescoScene/PuppetLayerSemantics.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>

int main () {
    int layerStorage = 0;
    int objectStorage = 0;
    const auto* layer = reinterpret_cast<
        const WallpaperEngine::Data::Model::ImageAnimationLayer*
    > (&layerStorage);
    const auto* object = reinterpret_cast<
        const WallpaperEngine::Data::Model::Object*
    > (&objectStorage);

    FrescoScene::registerPuppetLayerSemantics (layer, true);
    FrescoScene::registerPuppetAttachment (object, "Attachment");
    assert (FrescoScene::puppetLayerIsAdditive (layer));
    assert (FrescoScene::puppetAttachment (object) == "Attachment");

    FrescoScene::clearPuppetLayerSemantics ();
    assert (!FrescoScene::puppetLayerIsAdditive (layer));
    assert (FrescoScene::puppetAttachment (object).empty ());
}
