#pragma once

#include "WallpaperEngine/Audio/AudioContext.h"
#include "FrescoScene/SceneScriptTimerEvidence.h"

#include <cstddef>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace WallpaperEngine::Data::Model {
class DynamicValue;
struct UserSetting;
}
namespace WallpaperEngine::Media {
class MediaSource;
}
namespace WallpaperEngine::Render::Wallpapers {
class CScene;
}
namespace WallpaperEngine::Scripting {
class ScriptableObject;
using ScriptLayerHandle = int;
static constexpr ScriptLayerHandle kInvalidLayerHandle = 0;

class ScriptEngine {
public:
    struct DynamicFloatEvidence {
        std::string key;
        float value = 0.0f;
        std::size_t updates = 0;
        std::size_t changes = 0;
    };
    struct PropertyScriptEvidence {
        std::string key;
        std::string profile;
        int objectId = 0;
        std::string property;
        bool value = false;
        bool initialized = false;
        double seededDelaySeconds = -1.0;
        double targetDelaySeconds = -1.0;
        std::size_t propertyApplications = 0;
        std::size_t updates = 0;
    };

    struct GenericPropertyScriptEvidence {
        std::string key;
        std::string profile;
        int objectId = 0;
        std::string property;
        std::size_t updates = 0;
        std::size_t changes = 0;
    };

    ScriptEngine (Render::Wallpapers::CScene&, Media::MediaSource&);
    ~ScriptEngine ();

    ScriptEngine (const ScriptEngine&) = delete;
    ScriptEngine& operator= (const ScriptEngine&) = delete;

    void queueScript (
        const std::string&, Data::Model::DynamicValue&, ScriptableObject&
    );
    void queuePropertyScript (
        const std::string&, Data::Model::DynamicValue&, int objectId
    );
    void queueAudioFloatScript (
        const std::string&, Data::Model::DynamicValue&
    );
    void queueEffectScript (Data::Model::DynamicValue&, int objectId);

    void tick ();
    void shutdown ();
    void setInitialUserProperties (
        const Audio::UserPropertyBatch& properties
    );
    void setUserProperties (const Audio::UserPropertyBatch& properties);
    void applyPendingUserProperties ();
    void setMediaProperties (
        const std::string& title,
        const std::string& artist,
        const std::string& album
    );
    void mediaPlaybackChanged (int state);
    void mediaTimelineChanged (double position, double duration);
    void mediaThumbnailChanged (
        std::string_view primaryColor,
        std::string_view secondaryColor,
        std::string_view tertiaryColor,
        std::string_view textColor,
        std::string_view highContrastColor
    );
    bool cursorClick (int objectId, std::optional<double> monotonicMilliseconds = std::nullopt);
    std::size_t cursorEvent (std::string_view name, float x, float y);
    [[nodiscard]] bool acceptsCursorClick (int objectId) const;

    ScriptLayerHandle createLayerScript (
        const std::string&,
        std::map<std::string, std::unique_ptr<Data::Model::UserSetting>>&,
        const std::string&
    );

    void tickLayer (ScriptLayerHandle, double, double, double);
    [[nodiscard]] std::string layerText (ScriptLayerHandle);
    void destroyLayer (ScriptLayerHandle);
    [[nodiscard]] std::size_t layerCount () const;
    [[nodiscard]] std::size_t updateCount () const;
    [[nodiscard]] std::size_t textChangeCount () const;
    [[nodiscard]] std::size_t mediaPropertyScriptCount () const;
    [[nodiscard]] std::size_t mediaPropertyScriptDispatchCount () const;
    [[nodiscard]] std::size_t mediaPlaybackScriptDispatchCount () const;
    [[nodiscard]] std::size_t mediaTimelineScriptDispatchCount () const;
    [[nodiscard]] std::size_t mediaThumbnailScriptDispatchCount () const;
    [[nodiscard]] std::size_t mediaPropertyScriptErrorCount () const;
    [[nodiscard]] std::vector<DynamicFloatEvidence> dynamicFloatEvidence () const;
    [[nodiscard]] std::size_t dynamicFloatUpdateCount () const;
    [[nodiscard]] std::size_t dynamicFloatChangeCount () const;
    [[nodiscard]] std::size_t errorCount () const;
    [[nodiscard]] std::vector<PropertyScriptEvidence> propertyScriptEvidence () const;
    [[nodiscard]] std::size_t propertyScriptInitializationCount () const;
    [[nodiscard]] std::size_t propertyScriptPropertyApplicationCount () const;
    [[nodiscard]] std::size_t propertyScriptUpdateCount () const;
    [[nodiscard]] std::size_t propertyScriptErrorCount () const;
    [[nodiscard]] std::size_t propertyScriptCount () const;
    [[nodiscard]] std::vector<GenericPropertyScriptEvidence>
    genericPropertyScriptEvidence () const;
    [[nodiscard]] std::size_t genericPropertyScriptCount () const;
    [[nodiscard]] std::size_t continuousGenericPropertyScriptCount () const;
    [[nodiscard]] std::size_t genericPropertyScriptUpdateCount () const;
    [[nodiscard]] std::size_t genericPropertyScriptChangeCount () const;
    [[nodiscard]] std::size_t genericPropertyScriptErrorCount () const;
    [[nodiscard]] std::size_t audioVectorScriptCount () const;
    [[nodiscard]] std::size_t exactTrackedAudioVectorScriptCount () const;
    [[nodiscard]] std::optional<float> audioVectorValueX () const;
    [[nodiscard]] std::size_t audioVectorScriptUpdateCount () const;
    [[nodiscard]] std::size_t audioVectorScriptChangeCount () const;
    [[nodiscard]] bool audioVectorContinuousRequired () const;
    [[nodiscard]] std::size_t namedAnimationTargetPlayCount () const;
    [[nodiscard]] std::size_t namedAnimationActiveCount () const;
    [[nodiscard]] double namedAnimationFrameTotal () const;
    [[nodiscard]] std::size_t cursorScriptCount () const;
    [[nodiscard]] std::size_t deferredScriptCount () const;
    [[nodiscard]] FrescoScene::SceneScriptTimerEvidence timerEvidence () const;
    [[nodiscard]] bool acceptsUserProperty (std::string_view key) const;

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};
}
