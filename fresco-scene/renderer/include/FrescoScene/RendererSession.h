#pragma once

#include "FrescoScene/MediaSession.h"
#include "FrescoScene/EffectRenderEvidence.h"
#include "FrescoScene/ParticleRuntimeEvidence.h"
#include "FrescoScene/PuppetRenderEvidence.h"
#include "FrescoScene/RenderAllocationEvidence.h"
#include "FrescoScene/RenderProgramCache.h"
#include "FrescoScene/RenderBackend.h"
#include "FrescoScene/SceneScriptTimerEvidence.h"
#include "FrescoScene/FrameRenderResult.h"
#include "FrescoScene/MediaFramePreparation.h"
#include "FrescoScene/TextEffectChainDecision.h"
#include "WallpaperEngine/Audio/AudioContext.h"
#include "WallpaperEngine/VideoPlayback/MPV/GLPlayer.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <chrono>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace FrescoScene {

class SceneScriptStoragePool;

struct PixelProbeRequest {
    std::string identity;
    std::uint16_t xMilli = 0;
    std::uint16_t yMilli = 0;
};

struct PixelRegionRequest {
    std::string identity;
    std::uint16_t leftMilli = 0;
    std::uint16_t bottomMilli = 0;
    std::uint16_t rightMilli = 1000;
    std::uint16_t topMilli = 1000;
};

enum class RendererClockMode {
    // Advance the animation clock by a fixed 1/fps step per frame. Decoupled
    // from wall time, so a sequence of frames is bit-for-bit reproducible.
    // This is the default because the framebuffer-hash evidence suite depends
    // on it; every test inherits it unless it opts out.
    FixedStep,
    // Advance the animation clock by the measured wall-clock interval between
    // frames. Production uses this so shaders, particles, and puppets animate
    // at real-world speed regardless of the frame-rate ceiling.
    RealTime,
};

struct RendererConfiguration {
    std::filesystem::path projectRoot;
    std::filesystem::path assetRoot;
    SceneScriptStoragePool *scriptStoragePool = nullptr;
    std::string scriptStorageIdentity;
    double x = 0.0;
    double y = 0.0;
    double width = 1280.0;
    double height = 720.0;
    double framesPerSecond = 60.0;
    uint32_t evidenceFrames = 0;
    bool collectRenderDurationSamples = false;
    bool visible = true;
    bool muted = false;
    WallpaperEngine::Audio::UserPropertyBatch initialUserProperties;
    std::vector<PixelProbeRequest> pixelProbes;
    std::vector<PixelRegionRequest> pixelRegions;
    RenderBackend backend = configuredBackend ();
    RendererClockMode clockMode = RendererClockMode::FixedStep;
};

struct PixelProbeEvidence {
    std::string identity;
    std::uint16_t xMilli = 0;
    std::uint16_t yMilli = 0;
    int x = 0;
    int y = 0;
    std::array<std::uint8_t, 4> rgba {};
};

struct PixelRegionEvidence {
    std::string identity;
    std::uint16_t leftMilli = 0;
    std::uint16_t bottomMilli = 0;
    std::uint16_t rightMilli = 1000;
    std::uint16_t topMilli = 1000;
    int left = 0;
    int bottom = 0;
    int right = 0;
    int top = 0;
    std::size_t pixels = 0;
    std::size_t varyingPixels = 0;
    std::uint64_t pixelRGBTotal = 0;
    std::uint64_t pixelRGBAHash = 0;
};

struct ScriptedDynamicFloatEvidence {
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

struct SoundControlEvidence {
    int id = 0;
    std::string name;
    bool playing = false;
    bool requestedPlaying = false;
    bool playerConstructed = false;
    std::optional<std::string> activeAsset;
    std::string error;
    std::size_t playRequests = 0;
    std::size_t pauseRequests = 0;
    std::size_t stopRequests = 0;
};

struct FrameEvidence {
    std::string_view backend;
    std::string_view graphicsAPI;
    ShaderTarget shaderTarget;
    int width = 0;
    int height = 0;
    // The authored orthographic projection, which is the space cursor events are
    // carried in. The host needs it to convert a screen position into one.
    int projectionWidth = 0;
    int projectionHeight = 0;
    int logicalWidth = 0;
    int logicalHeight = 0;
    int scaleMilli = 0;
    int maximumRefreshMilliHertz = 0;
    std::string colorSpace;
    std::size_t programCacheEntries = 0;
    std::size_t programCacheInsertions = 0;
    RenderResourceGeneration resourceGeneration = 0;
    RenderResourceLifecycleEvidence resourceLifecycle;
    uint8_t minimum = 0;
    uint8_t maximum = 0;
    std::size_t varyingPixels = 0;
    uint64_t pixelRGBTotal = 0;
    uint64_t pixelRGBAHash = 0;
    std::vector<PixelProbeEvidence> pixelProbes;
    std::vector<PixelRegionEvidence> pixelRegions;
    EffectRenderEvidence effectRender;
    std::vector<TextEffectChainEvidence> textEffectChains;
    std::size_t scriptLayers = 0;
    std::size_t scriptUpdates = 0;
    std::size_t scriptTextChanges = 0;
    std::size_t mediaPropertyScripts = 0;
    std::size_t mediaPropertyScriptDispatches = 0;
    std::size_t mediaPlaybackScriptDispatches = 0;
    std::size_t mediaTimelineScriptDispatches = 0;
    std::size_t mediaThumbnailScriptDispatches = 0;
    std::size_t mediaPropertyScriptErrors = 0;
    std::vector<ScriptedDynamicFloatEvidence> scriptedDynamicFloats;
    std::size_t scriptedDynamicFloatUpdates = 0;
    std::size_t scriptedDynamicFloatChanges = 0;
    std::size_t scriptErrors = 0;
    std::size_t soundVolumeBindings = 0;
    std::size_t soundVolumeProperties = 0;
    WallpaperEngine::Audio::SoundPropertyEvidence initialUserProperties;
    std::vector<PropertyScriptEvidence> propertyScripts;
    std::size_t propertyScriptControllers = 0;
    std::size_t propertyScriptInitializations = 0;
    std::size_t propertyScriptPropertyApplications = 0;
    std::size_t propertyScriptUpdates = 0;
    std::size_t propertyScriptErrors = 0;
    std::size_t genericPropertyScripts = 0;
    std::size_t continuousGenericPropertyScripts = 0;
    std::size_t genericPropertyScriptUpdates = 0;
    std::size_t genericPropertyScriptChanges = 0;
    std::size_t genericPropertyScriptErrors = 0;
    std::size_t audioVectorScripts = 0;
    std::size_t exactTrackedAudioVectorScripts = 0;
    double audioVectorValueX = 0.0;
    std::size_t audioVectorScriptUpdates = 0;
    std::size_t audioVectorScriptChanges = 0;
    std::size_t namedAnimationTargetPlays = 0;
    std::size_t namedAnimationActive = 0;
    double namedAnimationFrameTotal = 0.0;
    bool camera2DActive = false;
    double camera2DCenterX = 0.0;
    double camera2DCenterY = 0.0;
    double camera2DZoom = 1.0;
    bool sceneZoomActive = false;
    double sceneZoom = 1.0;
    std::size_t cursorScripts = 0;
    // The pointer as the shaders see it: normalized, after CScene::updateMouse
    // has mapped it through the viewport and the texture UVs.
    double pointerPositionX = 0.0;
    double pointerPositionY = 0.0;
    std::size_t deferredScriptValues = 0;
    SceneScriptTimerEvidence scriptTimers;
    double scriptTimeMilliseconds = 0.0;
    std::vector<SoundControlEvidence> soundControls;
    uint32_t frames = 0;
    bool drawComplete = false;
    bool ordered = false;
    int windowLevel = 0;
};

struct FrameDifferenceEvidence {
    FrameEvidence frame;
    bool presented = false;
    std::size_t changedPixels = 0;
    uint8_t maximumChannelDelta = 0;
    uint64_t totalChannelDelta = 0;
};

struct MediaSessionEvidence {
    std::size_t events = 0;
    std::size_t revision = 0;
    bool available = false;
    MediaPlaybackState playback = MediaPlaybackState::stopped;
    bool hasThumbnail = false;
    bool artworkReady = false;
    std::size_t artworkRevision = 0;
    uint64_t artworkRGBAHash = 0;
    std::string artworkError;
};

struct RendererMetrics {
    std::string_view backend;
    std::string_view graphicsAPI;
    ShaderTarget shaderTarget;
    std::size_t programCacheEntries = 0;
    std::size_t programCacheInsertions = 0;
    RenderResourceGeneration resourceGeneration = 0;
    RenderResourceLifecycleEvidence resourceLifecycle;
    uint32_t frames = 0;
    double targetFPS = 0.0;
    double elapsedMilliseconds = 0.0;
    // The scene animation clock (g_Time) driving shaders, particles, and
    // puppets. Reported beside elapsedMilliseconds, which is session wall time,
    // so the two can be compared to see whether scene time runs at wall rate.
    double sceneClockSeconds = 0.0;
    double averageFrameIntervalMilliseconds = 0.0;
    double maximumFrameIntervalMilliseconds = 0.0;
    double averageRenderMilliseconds = 0.0;
    double maximumRenderMilliseconds = 0.0;
    std::vector<double> renderDurationSamplesMilliseconds;
    RenderAllocationEvidence renderAllocations;
    EffectRenderEvidence effectRender;
    uint32_t missedFrameIntervals = 0;
    std::vector<TextEffectChainEvidence> textEffectChains;
    std::size_t scriptLayers = 0;
    std::size_t scriptUpdates = 0;
    std::size_t scriptTextChanges = 0;
    std::size_t mediaPropertyScripts = 0;
    std::size_t mediaPropertyScriptDispatches = 0;
    std::size_t mediaPlaybackScriptDispatches = 0;
    std::size_t mediaTimelineScriptDispatches = 0;
    std::size_t mediaThumbnailScriptDispatches = 0;
    std::size_t mediaPropertyScriptErrors = 0;
    std::vector<ScriptedDynamicFloatEvidence> scriptedDynamicFloats;
    std::size_t scriptedDynamicFloatUpdates = 0;
    std::size_t scriptedDynamicFloatChanges = 0;
    std::size_t scriptErrors = 0;
    std::size_t scriptStorageKeys = 0;
    std::size_t scriptStorageBytes = 0;
    std::size_t soundVolumeBindings = 0;
    std::size_t soundVolumeProperties = 0;
    std::vector<PropertyScriptEvidence> propertyScripts;
    std::size_t propertyScriptControllers = 0;
    std::size_t propertyScriptInitializations = 0;
    std::size_t propertyScriptPropertyApplications = 0;
    std::size_t propertyScriptUpdates = 0;
    std::size_t propertyScriptErrors = 0;
    std::size_t genericPropertyScripts = 0;
    std::size_t continuousGenericPropertyScripts = 0;
    std::size_t genericPropertyScriptUpdates = 0;
    std::size_t genericPropertyScriptChanges = 0;
    std::size_t genericPropertyScriptErrors = 0;
    std::size_t audioVectorScripts = 0;
    std::size_t exactTrackedAudioVectorScripts = 0;
    double audioVectorValueX = 0.0;
    std::size_t audioVectorScriptUpdates = 0;
    std::size_t audioVectorScriptChanges = 0;
    std::size_t audioSpectrumInputs = 0;
    std::size_t audioSpectrumChanges = 0;
    std::uint64_t audioSpectrumHash = 0;
    std::uint64_t audioVectorHash = 0;
    double audioVectorAverage0 = 0.0;
    bool audioEnvelopeContinuousRequired = false;
    std::size_t namedAnimationTargetPlays = 0;
    std::size_t namedAnimationActive = 0;
    std::size_t automaticDynamicValueAnimations = 0;
    double namedAnimationFrameTotal = 0.0;
    bool camera2DActive = false;
    double camera2DCenterX = 0.0;
    double camera2DCenterY = 0.0;
    double camera2DZoom = 1.0;
    bool sceneZoomActive = false;
    double sceneZoom = 1.0;
    std::size_t cursorScripts = 0;
    // The pointer as the shaders see it: normalized, after CScene::updateMouse
    // has mapped it through the viewport and the texture UVs.
    double pointerPositionX = 0.0;
    double pointerPositionY = 0.0;
    std::size_t deferredScriptValues = 0;
    SceneScriptTimerEvidence scriptTimers;
    double scriptTimeMilliseconds = 0.0;
    std::vector<SoundControlEvidence> soundControls;
    WallpaperEngine::VideoPlayback::MPV::MediaTextureMetrics mediaTextures;
    std::size_t particleSimulationSteps = 0;
    ParticleRuntimeEvidence particles;
    bool active = false;
    bool paused = false;
    bool muted = false;
    bool visible = false;
};

struct AudioSpectrumApplicationEvidence {
    bool changed = false;
    std::size_t inputs = 0;
    std::size_t changes = 0;
    std::uint64_t spectrumHash = 0;
    std::uint64_t vectorHash = 0;
    double vectorAverage0 = 0.0;
};

struct MediaTextureGlobalLifecycleEvidence {
    std::size_t livePlayers = 0;
    std::size_t constructions = 0;
    std::size_t destructions = 0;
};

[[nodiscard]] MediaTextureGlobalLifecycleEvidence
globalMediaTextureLifecycleEvidence ();

class RendererSession {
public:
    explicit RendererSession (const RendererConfiguration& configuration);
    ~RendererSession ();

    RendererSession (const RendererSession&) = delete;
    RendererSession& operator= (const RendererSession&) = delete;

    [[nodiscard]] const FrameEvidence& firstFrameEvidence () const;
    [[nodiscard]] bool active () const;
    [[nodiscard]] bool paused () const;
    [[nodiscard]] bool muted () const;
    void setPaused (bool paused);
    void setMuted (bool muted);
    void setVisible (bool visible);
    void setFramesPerSecond (double framesPerSecond);
    [[nodiscard]] AudioSpectrumApplicationEvidence setAudioSpectrum (
        const std::array<float, 128>& spectrum
    );
    void setTrackedAudioLifecycle (bool tracked);
    [[nodiscard]] MediaSessionEvidence setMediaSession (
        const MediaSessionEvent& event
    );
    bool cursorClick (
        int objectId,
        std::optional<double> monotonicMilliseconds = std::nullopt
    );
    std::size_t cursorEvent (std::string_view name, float x, float y);
    [[nodiscard]] WallpaperEngine::Audio::SoundPropertyEvidence setUserProperties (
        const WallpaperEngine::Audio::UserPropertyBatch& properties
    );
    FrameRenderResult renderFrame ();
    [[nodiscard]] MediaFramePreparationEvidence prepareMediaFrames ();
    void setTrackedMediaLifecycle (bool tracked);
    [[nodiscard]] std::size_t seekMediaTextures (double positionSeconds);
    [[nodiscard]] FrameDifferenceEvidence captureFrameDifference ();
    [[nodiscard]] std::chrono::microseconds frameInterval () const;
    [[nodiscard]] RendererMetrics metrics () const;
    [[nodiscard]] PuppetRenderEvidence puppetEvidence () const;

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

}
