#include "FrescoScene/VideoTextureControl.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <array>
#include <cassert>

namespace {

struct FakePlayer final : FrescoScene::VideoTexturePlayerControl {
    void setScriptPaused (bool value) override {
        scriptPaused = value;
        ++scriptPauseChanges;
    }
    void setHostPaused (bool value) override {
        hostPaused = value;
        ++hostPauseChanges;
    }
    void setHostVisible (bool value) override {
        hostVisible = value;
        ++hostVisibilityChanges;
    }

    bool scriptPaused = false;
    bool hostPaused = false;
    bool hostVisible = true;
    std::size_t scriptPauseChanges = 0;
    std::size_t hostPauseChanges = 0;
    std::size_t hostVisibilityChanges = 0;
};

}

int main () {
    FrescoScene::VideoTextureControlRegistry registry;
    std::array<int, 5> objects = {};
    std::array<int, 5> textures = {};
    std::array<FakePlayer, 5> players = {};

    for (std::size_t index = 0; index < objects.size (); ++index) {
        assert (
            registry.registerVideoPlayer (&textures[index], &players[index])
            == FrescoScene::VideoTextureControlError::none
        );
        assert (players[index].scriptPaused);
        assert (
            registry.registerObjectTexture (&objects[index], &textures[index])
            == FrescoScene::VideoTextureControlError::none
        );
    }
    auto metrics = registry.metrics ();
    assert (metrics.objects == 5);
    assert (metrics.textureProviders == 5);
    assert (metrics.videoPlayers == 5);
    assert (metrics.requestedPlayingPlayers == 0);

    for (std::size_t index = 0; index < objects.size (); ++index) {
        const auto result = registry.control (
            &objects[index],
            index == 2
                ? FrescoScene::VideoTextureMethod::play
                : FrescoScene::VideoTextureMethod::pause
        );
        assert (result);
        assert (players[index].scriptPaused == (index != 2));
    }
    metrics = registry.metrics ();
    assert (metrics.requestedPlayingPlayers == 1);
    assert (metrics.effectivePlayingPlayers == 1);
    assert (metrics.playRequests == 1);
    assert (metrics.pauseRequests == 4);

    registry.setHostPaused (true);
    metrics = registry.metrics ();
    assert (metrics.hostPaused);
    assert (metrics.requestedPlayingPlayers == 1);
    assert (metrics.effectivePlayingPlayers == 0);
    for (const auto& player : players) {
        assert (player.hostPaused);
    }
    registry.setHostPaused (false);
    registry.setHostVisible (false);
    metrics = registry.metrics ();
    assert (!metrics.hostPaused);
    assert (!metrics.hostVisible);
    assert (metrics.requestedPlayingPlayers == 1);
    assert (metrics.effectivePlayingPlayers == 0);
    registry.setHostVisible (true);
    assert (registry.metrics ().effectivePlayingPlayers == 1);

    int ordinaryObject = 0;
    int ordinaryTexture = 0;
    assert (
        registry.registerObjectTexture (&ordinaryObject, &ordinaryTexture)
        == FrescoScene::VideoTextureControlError::none
    );
    assert (
        registry.registerNonVideoTexture (&ordinaryTexture)
        == FrescoScene::VideoTextureControlError::none
    );
    auto failed = registry.control (
        &ordinaryObject, FrescoScene::VideoTextureMethod::play
    );
    assert (failed.error == FrescoScene::VideoTextureControlError::nonVideoHandle);
    assert (
        FrescoScene::videoTextureControlDiagnostic (failed.error)
        == "getVideoTexture() target is not a video texture"
    );
    failed = registry.control (&objects[2], FrescoScene::VideoTextureMethod::seek);
    assert (failed.error == FrescoScene::VideoTextureControlError::unsupportedMethod);
    assert (
        FrescoScene::videoTextureControlDiagnostic (failed.error)
        == "getVideoTexture() supports only play() and pause()"
    );

    registry.clear ();
    assert (players[2].scriptPaused);
    metrics = registry.metrics ();
    assert (metrics.objects == 0);
    assert (metrics.textureProviders == 0);
    assert (metrics.videoPlayers == 0);
    assert (metrics.requestedPlayingPlayers == 0);
    assert (metrics.playRequests == 0);
    assert (metrics.pauseRequests == 0);
    failed = registry.control (&objects[0], FrescoScene::VideoTextureMethod::play);
    assert (
        failed.error == FrescoScene::VideoTextureControlError::objectNotRegistered
    );
}
