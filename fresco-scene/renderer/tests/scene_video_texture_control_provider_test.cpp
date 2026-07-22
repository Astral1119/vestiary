#include "FrescoScene/SceneVideoTextureControlProvider.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <string>

namespace {

struct FakePlayer final : FrescoScene::VideoTexturePlayerControl {
    void setScriptPaused (bool value) override { paused = value; }
    void setHostPaused (bool) override { }
    void setHostVisible (bool) override { }
    bool paused = false;
};

}

int main () {
    int scene = 0;
    int object = 0;
    int texture = 0;
    FakePlayer player;
    FrescoScene::VideoTextureControlRegistry registry;
    std::string diagnostic;

    assert (
        registry.registerVideoPlayer (&texture, &player)
        == FrescoScene::VideoTextureControlError::none
    );
    assert (
        registry.registerObjectTexture (&object, &texture)
        == FrescoScene::VideoTextureControlError::none
    );
    FrescoScene::registerSceneVideoTextureControl (&scene, registry);
    assert (FrescoScene::registerSceneVideoTextureObject (
        &scene, 781, &object, diagnostic
    ));
    assert (diagnostic.empty ());

    assert (FrescoScene::setSceneVideoTexturePaused (
        &scene, 781, false, diagnostic
    ));
    assert (!player.paused);
    assert (FrescoScene::setSceneVideoTexturePaused (
        &scene, 781, false, diagnostic
    ));
    const auto metrics = FrescoScene::sceneVideoTextureControlMetrics (&scene);
    assert (metrics.has_value ());
    assert (metrics->videoPlayers == 1);
    assert (metrics->requestedPlayingPlayers == 1);
    assert (metrics->playRequests == 2);

    assert (!FrescoScene::setSceneVideoTexturePaused (
        &scene, 960, true, diagnostic
    ));
    assert (
        diagnostic == "getVideoTexture() layer object 960 is not registered"
    );
    FrescoScene::clearSceneVideoTextureControl (&scene);
    assert (!FrescoScene::sceneVideoTextureControlMetrics (&scene).has_value ());
    assert (!FrescoScene::setSceneVideoTexturePaused (
        &scene, 781, false, diagnostic
    ));
    assert (diagnostic == "getVideoTexture() scene is not registered");
}
