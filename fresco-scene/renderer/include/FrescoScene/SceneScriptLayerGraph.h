#pragma once

#include <quickjs.h>

#include "FrescoScene/SceneScriptTimerEvidence.h"

#include <cstddef>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace WallpaperEngine::Render::Wallpapers {
class CScene;
}

namespace FrescoScene {

class SceneScriptStorage;

struct SceneScriptLayerCommand {
    enum class Kind {
        textureFrame,
        textureStop,
        animationLayerPlay,
        videoPlay,
        videoPause,
    };

    Kind kind = Kind::textureFrame;
    int objectId = 0;
    int frame = 0;
    std::string name;
};

class SceneScriptLayerGraph {
  public:
    SceneScriptLayerGraph (
        JSContext *,
        WallpaperEngine::Render::Wallpapers::CScene &,
        SceneScriptStorage &
    );
    ~SceneScriptLayerGraph ();

    SceneScriptLayerGraph (const SceneScriptLayerGraph &) = delete;
    SceneScriptLayerGraph &operator= (const SceneScriptLayerGraph &) = delete;

    void syncFromScene ();
    void syncObjectFromScene (int objectId);
    void syncPropertyFromScene (int objectId, std::string_view propertyName);
    [[nodiscard]] std::size_t applyToScene ();
    void setCursor (float x, float y);
    void setTimeVarying (bool enabled);
    [[nodiscard]] std::vector<SceneScriptLayerCommand> takeCommands ();
    [[nodiscard]] bool takeStorageRejection ();
    [[nodiscard]] SceneScriptTimerEvidence timerEvidence () const;

    [[nodiscard]] static std::string wrapperPrelude (int objectId, int canvasWidth,
                                                     int canvasHeight, int clockHour);

  private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace FrescoScene
