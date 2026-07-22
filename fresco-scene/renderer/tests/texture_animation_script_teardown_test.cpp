#include "FrescoScene/TextureAnimationScript.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>

int main () {
    int sceneAStorage = 0;
    int sceneBStorage = 0;
    const void* sceneA = &sceneAStorage;
    const void* sceneB = &sceneBStorage;

    assert (FrescoScene::setScriptedTextureAnimationFrame (sceneA, 1, 4));
    assert (FrescoScene::setScriptedTextureAnimationFrame (sceneA, 2, 7));
    assert (FrescoScene::setScriptedTextureAnimationFrame (sceneB, 1, 9));
    assert (!FrescoScene::setScriptedTextureAnimationFrame (sceneA, 1, 4));

    FrescoScene::clearScriptedTextureAnimationFrames (sceneA);
    assert (!FrescoScene::scriptedTextureAnimationFrame (sceneA, 1).has_value ());
    assert (!FrescoScene::scriptedTextureAnimationFrame (sceneA, 2).has_value ());
    assert (FrescoScene::scriptedTextureAnimationFrame (sceneB, 1) == 9);

    // A reloaded scene may occupy the same address as its predecessor. The
    // first graph-set in that lifetime must not inherit the old frame or look
    // unchanged against it.
    const void* reusedScene = sceneA;
    assert (FrescoScene::setScriptedTextureAnimationFrame (reusedScene, 1, 4));
    assert (FrescoScene::scriptedTextureAnimationFrame (reusedScene, 1) == 4);
    FrescoScene::clearScriptedTextureAnimationFrame (reusedScene, 1);
    assert (!FrescoScene::scriptedTextureAnimationFrame (reusedScene, 1).has_value ());

    assert (FrescoScene::setScriptedTextureAnimationFrame (reusedScene, 3, 12));
    FrescoScene::clearScriptedTextureAnimationFrames (reusedScene);
    assert (FrescoScene::setScriptedTextureAnimationFrame (reusedScene, 3, 12));
    assert (FrescoScene::scriptedTextureAnimationFrame (reusedScene, 3) == 12);

    FrescoScene::clearScriptedTextureAnimationFrames (sceneB);
    FrescoScene::clearScriptedTextureAnimationFrames (reusedScene);
}
