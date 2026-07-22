#pragma once

#include "MemoryStreamProtocol.h"
#include "FrescoScene/MediaFramePreparation.h"

#include <GL/glew.h>
#include <cstdint>
#include <memory>
#include <optional>

namespace WallpaperEngine::Render {
class RenderContext;
}

namespace WallpaperEngine::VideoPlayback::MPV {
struct MediaTextureMetrics {
    std::size_t players = 0;
    std::size_t referencedPlayers = 0;
    std::size_t temporallyActivePlayers = 0;
    std::size_t scriptControlledPlayers = 0;
    std::size_t scriptPlayingPlayers = 0;
    std::size_t scriptPausedPlayers = 0;
    std::size_t minimumDecodesPerPlayer = 0;
    std::size_t maximumDecodesPerPlayer = 0;
    std::size_t decodes = 0;
    std::uint64_t uploadedBytes = 0;
    double decodeMilliseconds = 0.0;
    double uploadSubmissionMilliseconds = 0.0;
    std::size_t decodeAttempts = 0;
    std::size_t decodedFrames = 0;
    std::size_t frameReadyEvents = 0;
    std::size_t stalledFrames = 0;
    std::size_t frameUploads = 0;
    std::size_t pendingFrames = 0;
    std::size_t seekRequests = 0;
    std::size_t fallbackPlayers = 0;
    std::size_t globalLivePlayers = 0;
    std::size_t globalPlayerConstructions = 0;
    std::size_t globalPlayerDestructions = 0;
    std::uint64_t lastDecodedFrameHash = 0;
    std::uint64_t decodedFrameSequenceHash = 0;
    double lastDecodedPresentationSeconds = 0.0;
    std::size_t endOfStreamPlayers = 0;
};

struct MediaTextureGlobalLifecycleEvidence {
    std::size_t livePlayers = 0;
    std::size_t constructions = 0;
    std::size_t destructions = 0;
};

[[nodiscard]] MediaTextureGlobalLifecycleEvidence
globalMediaTextureLifecycleEvidence ();

class MediaTextureHost {
public:
    explicit MediaTextureHost (Render::RenderContext&);
    ~MediaTextureHost ();

    MediaTextureHost (const MediaTextureHost&) = delete;
    MediaTextureHost& operator= (const MediaTextureHost&) = delete;

    void setPaused (bool paused);
    void setVisible (bool visible);
    [[nodiscard]] FrescoScene::MediaFramePreparationEvidence prepareFrames ();
    [[nodiscard]] bool hasPendingFrames () const;
    std::size_t seek (double positionSeconds);
    [[nodiscard]] MediaTextureMetrics metrics () const;

private:
    friend class GLPlayer;

    class Impl;
    std::unique_ptr<Impl> m_implementation;
};

class GLPlayer {
public:
    GLPlayer (
        Render::RenderContext&, GLuint, MemoryStreamProtocolUniquePtr,
        int64_t, int64_t, GLuint = GL_NONE
    );

    ~GLPlayer ();

    void incrementUsageCount ();
    void decrementUsageCount ();
    void setUntimed ();
    void setMuted ();
    void setVolume (double);
    void setPaused (bool paused);
    void setHostPaused (bool paused);
    void setHostVisible (bool visible);
    [[nodiscard]] FrescoScene::MediaPlayerFramePreparationEvidence prepareFrame ();
    [[nodiscard]] bool hasPendingFrame () const;
    void seek (double positionSeconds);
    void render () const;

private:
    friend class MediaTextureHost;

    MediaTextureHost* m_host = nullptr;

    class Impl;
    std::unique_ptr<Impl> m_implementation;
};

using GLPlayerUniquePtr = std::unique_ptr<GLPlayer>;
}
