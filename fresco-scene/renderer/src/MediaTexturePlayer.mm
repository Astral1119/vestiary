#include "WallpaperEngine/VideoPlayback/MPV/GLPlayer.h"

#include "FrescoScene/MediaPlaybackClock.h"
#include "FrescoScene/MediaVideoDecoder.h"
#include "WallpaperEngine/Logging/Log.h"

#include <algorithm>
#include <cmath>
#include <chrono>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>

using FrescoScene::MediaPlaybackClock;
using FrescoScene::MediaVideoDecoder;
using FrescoScene::MediaVideoError;
using FrescoScene::MediaVideoErrorCode;
using FrescoScene::MediaVideoFrame;
using FrescoScene::mediaVideoErrorName;
using namespace WallpaperEngine::VideoPlayback::MPV;

namespace {

double monotonicSeconds () {
    return std::chrono::duration<double> (
        std::chrono::steady_clock::now ().time_since_epoch ()
    ).count ();
}

std::unordered_map<WallpaperEngine::Render::RenderContext*, MediaTextureHost*> hosts;
std::size_t livePlayers = 0;
std::size_t playerConstructions = 0;
std::size_t playerDestructions = 0;

std::uint64_t frameHash (const FrescoScene::MediaVideoFrame& frame) {
    std::uint64_t hash = 1469598103934665603ULL;
    for (std::uint32_t y = 0; y < frame.height; ++y) {
        const auto* row = frame.pixels.get ()
            + static_cast<std::size_t> (y) * frame.bytesPerRow;
        for (std::uint32_t x = 0; x < frame.width * 4U; ++x) {
            hash ^= row[x];
            hash *= 1099511628211ULL;
        }
    }
    return hash;
}

}

class GLPlayer::Impl {
public:
    Impl (
        GLuint texture, MemoryStreamProtocolUniquePtr stream,
        bool hostPaused, bool hostVisible
    ) :
        texture (texture), clock (0.0, 30.0) {
        MediaVideoError error;
        decoder = MediaVideoDecoder::create (stream->data (), stream->size (), error);
        if (decoder == nullptr) {
            fallback = true;
            diagnostic = std::string (mediaVideoErrorName (error.code))
                + ": " + error.message;
            const std::uint8_t transparent[] = { 0, 0, 0, 0 };
            glBindTexture (GL_TEXTURE_2D, texture);
            glTexImage2D (
                GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0,
                GL_RGBA, GL_UNSIGNED_BYTE, transparent
            );
            sLog.error ("Video texture fallback: ", diagnostic);
            return;
        }

        clock = MediaPlaybackClock (decoder->durationSeconds (), 30.0);
        clock.setHostPaused (hostPaused);
        clock.setHostVisible (hostVisible);
        static_cast<void> (prepareFrame (0.0));
    }

    FrescoScene::MediaPlayerFramePreparationEvidence prepareFrame (
        double positionSeconds
    ) {
        if (decoder == nullptr) {
            return {};
        }
        if (endOfStream) {
            return { .terminal = true };
        }
        if (pendingFrame.has_value ()) {
            if (pendingFrameReady) {
                return {};
            }
            const double remaining = std::max (
                0.0, pendingFrame->presentationSeconds - positionSeconds
            );
            if (remaining > 0.0005) {
                return { .nextWakeSeconds = remaining };
            }
            pendingFrameReady = true;
            ++frameReadyEvents;
            return { .frameReady = 1 };
        }
        MediaVideoError error;
        const auto decodeStart = std::chrono::steady_clock::now ();
        ++decodeAttempts;
        const auto frame = decoder->frameAt (positionSeconds, error);
        decodeMilliseconds += std::chrono::duration<double, std::milli> (
            std::chrono::steady_clock::now () - decodeStart
        ).count ();
        if (!frame.has_value ()) {
            ++stalledFrames;
            endOfStream = error.code == MediaVideoErrorCode::endOfStream;
            if (error.code != MediaVideoErrorCode::endOfStream
                && !decodeFailureReported) {
                sLog.error (
                    "Video texture frame fallback: ",
                    mediaVideoErrorName (error.code), ": ", error.message
                );
                decodeFailureReported = true;
            }
            return { .stalled = 1, .terminal = endOfStream };
        }

        ++decodedFrames;
        const std::uint64_t hash = frameHash (*frame);
        const bool duplicate = lastPreparedPresentationSeconds.has_value ()
            && std::abs (
                *lastPreparedPresentationSeconds - frame->presentationSeconds
            ) <= 0.000001
            && lastDecodedFrameHash == hash;
        clock.didDecode (frame->presentationSeconds);
        if (duplicate) {
            ++stalledFrames;
            return { .stalled = 1 };
        }
        lastPreparedPresentationSeconds = frame->presentationSeconds;
        lastDecodedPresentationSeconds = frame->presentationSeconds;
        lastDecodedFrameHash = hash;
        decodedFrameSequenceHash ^= hash;
        decodedFrameSequenceHash *= 1099511628211ULL;
        pendingFrame = frame;
        const double remaining = std::max (
            0.0, frame->presentationSeconds - positionSeconds
        );
        pendingFrameReady = remaining <= 0.0005;
        if (pendingFrameReady) {
            ++frameReadyEvents;
            return { .frameReady = 1 };
        }
        return { .nextWakeSeconds = remaining };
    }

    void uploadPendingFrame () {
        if (!pendingFrame.has_value () || !pendingFrameReady) {
            return;
        }
        const auto frame = std::move (*pendingFrame);
        pendingFrame.reset ();
        pendingFrameReady = false;

        const auto uploadStart = std::chrono::steady_clock::now ();
        glBindTexture (GL_TEXTURE_2D, texture);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_R, GL_BLUE);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_G, GL_GREEN);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_B, GL_RED);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, GL_ALPHA);
        glPixelStorei (
            GL_UNPACK_ROW_LENGTH,
            static_cast<GLint> (frame.bytesPerRow / 4U)
        );
        if (frame.width != width || frame.height != height) {
            width = frame.width;
            height = frame.height;
            glTexImage2D (
                GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0,
                GL_RGBA, GL_UNSIGNED_BYTE, frame.pixels.get ()
            );
        } else {
            glTexSubImage2D (
                GL_TEXTURE_2D, 0, 0, 0, width, height,
                GL_RGBA, GL_UNSIGNED_BYTE, frame.pixels.get ()
            );
        }
        glPixelStorei (GL_UNPACK_ROW_LENGTH, 0);
        uploadSubmissionMilliseconds += std::chrono::duration<double, std::milli> (
            std::chrono::steady_clock::now () - uploadStart
        ).count ();
        ++decodes;
        ++frameUploads;
        uploadedBytes += static_cast<std::uint64_t> (frame.width)
            * static_cast<std::uint64_t> (frame.height) * 4U;
    }

    void seek (double positionSeconds) {
        clock.seek (positionSeconds);
        pendingFrame.reset ();
        pendingFrameReady = false;
        lastPreparedPresentationSeconds.reset ();
        decodedFrameSequenceHash = 1469598103934665603ULL;
        ++seekRequests;
        endOfStream = false;
    }

    GLuint texture;
    std::unique_ptr<MediaVideoDecoder> decoder;
    MediaPlaybackClock clock;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    bool fallback = false;
    bool decodeFailureReported = false;
    bool endOfStream = false;
    std::size_t usageCount = 0;
    std::size_t decodes = 0;
    std::size_t decodeAttempts = 0;
    std::size_t decodedFrames = 0;
    std::size_t frameReadyEvents = 0;
    std::size_t stalledFrames = 0;
    std::size_t frameUploads = 0;
    std::size_t seekRequests = 0;
    std::uint64_t uploadedBytes = 0;
    double decodeMilliseconds = 0.0;
    double uploadSubmissionMilliseconds = 0.0;
    std::optional<MediaVideoFrame> pendingFrame;
    bool pendingFrameReady = false;
    std::optional<double> lastPreparedPresentationSeconds;
    std::uint64_t lastDecodedFrameHash = 0;
    std::uint64_t decodedFrameSequenceHash = 1469598103934665603ULL;
    double lastDecodedPresentationSeconds = 0.0;
    std::string diagnostic;
};

class MediaTextureHost::Impl {
public:
    WallpaperEngine::Render::RenderContext* context = nullptr;
    bool paused = false;
    bool visible = true;
    std::unordered_set<GLPlayer*> players;
};

MediaTextureHost::MediaTextureHost (WallpaperEngine::Render::RenderContext& context)
    : m_implementation (std::make_unique<Impl> ()) {
    if (hosts.contains (&context)) {
        throw std::runtime_error ("media texture host already registered for render context");
    }
    m_implementation->context = &context;
    hosts.emplace (&context, this);
}

MediaTextureHost::~MediaTextureHost () {
    if (!m_implementation->players.empty ()) {
        std::terminate ();
    }
    hosts.erase (m_implementation->context);
}

GLPlayer::GLPlayer (
    Render::RenderContext& context, GLuint texture, MemoryStreamProtocolUniquePtr stream,
    int64_t, int64_t, GLuint
) {
    const auto found = hosts.find (&context);
    if (found == hosts.end ()) {
        throw std::runtime_error ("media texture player has no render-context host");
    }
    m_host = found->second;
    m_implementation = std::make_unique<Impl> (
        texture, std::move (stream),
        m_host->m_implementation->paused, m_host->m_implementation->visible
    );
    ++livePlayers;
    ++playerConstructions;
    m_host->m_implementation->players.insert (this);
}

GLPlayer::~GLPlayer () {
    if (m_host != nullptr) {
        m_host->m_implementation->players.erase (this);
    }
    --livePlayers;
    ++playerDestructions;
}

void GLPlayer::incrementUsageCount () {
    ++m_implementation->usageCount;
    m_implementation->clock.incrementUsage ();
}

void GLPlayer::decrementUsageCount () {
    if (m_implementation->usageCount > 0) {
        --m_implementation->usageCount;
    }
    m_implementation->clock.decrementUsage ();
}

void GLPlayer::setUntimed () { }

void GLPlayer::setMuted () { }

void GLPlayer::setVolume (double) { }

void GLPlayer::setPaused (bool paused) {
    m_implementation->clock.setManuallyPaused (paused);
}

void GLPlayer::setHostPaused (bool paused) {
    m_implementation->clock.setHostPaused (paused);
}

void GLPlayer::setHostVisible (bool visible) {
    m_implementation->clock.setHostVisible (visible);
}

void GLPlayer::render () const {
    m_implementation->uploadPendingFrame ();
}

FrescoScene::MediaPlayerFramePreparationEvidence GLPlayer::prepareFrame () {
    const auto sample = m_implementation->clock.sample (monotonicSeconds ());
    if (!m_implementation->clock.active ()) {
        return {};
    }
    return m_implementation->prepareFrame (sample.positionSeconds);
}

bool GLPlayer::hasPendingFrame () const {
    return m_implementation->pendingFrame.has_value ()
        && m_implementation->pendingFrameReady;
}

void GLPlayer::seek (double positionSeconds) {
    m_implementation->seek (positionSeconds);
}

FrescoScene::MediaFramePreparationEvidence MediaTextureHost::prepareFrames () {
    std::vector<FrescoScene::MediaPlayerFramePreparationEvidence> players;
    players.reserve (m_implementation->players.size ());
    for (auto* player : m_implementation->players) {
        players.push_back (player->prepareFrame ());
    }
    return FrescoScene::aggregateMediaFramePreparation (players);
}

bool MediaTextureHost::hasPendingFrames () const {
    return std::ranges::any_of (
        m_implementation->players,
        [] (const auto* player) { return player->hasPendingFrame (); }
    );
}

std::size_t MediaTextureHost::seek (double positionSeconds) {
    for (auto* player : m_implementation->players) {
        player->seek (positionSeconds);
    }
    return m_implementation->players.size ();
}

void MediaTextureHost::setPaused (bool paused) {
    m_implementation->paused = paused;
    for (auto* player : m_implementation->players) {
        player->setHostPaused (paused);
    }
}

void MediaTextureHost::setVisible (bool visible) {
    m_implementation->visible = visible;
    for (auto* player : m_implementation->players) {
        player->setHostVisible (visible);
    }
}

MediaTextureMetrics MediaTextureHost::metrics () const {
    MediaTextureMetrics result {
        .players = m_implementation->players.size (),
        .globalLivePlayers = livePlayers,
        .globalPlayerConstructions = playerConstructions,
        .globalPlayerDestructions = playerDestructions,
    };
    for (const auto* player : m_implementation->players) {
        const auto& implementation = *player->m_implementation;
        result.referencedPlayers += implementation.usageCount > 0 ? 1U : 0U;
        result.temporallyActivePlayers += implementation.decodes > 1 ? 1U : 0U;
        if (result.minimumDecodesPerPlayer == 0) {
            result.minimumDecodesPerPlayer = implementation.decodes;
        } else {
            result.minimumDecodesPerPlayer = std::min (
                result.minimumDecodesPerPlayer, implementation.decodes
            );
        }
        result.maximumDecodesPerPlayer = std::max (
            result.maximumDecodesPerPlayer, implementation.decodes
        );
        result.decodes += implementation.decodes;
        result.uploadedBytes += implementation.uploadedBytes;
        result.decodeMilliseconds += implementation.decodeMilliseconds;
        result.uploadSubmissionMilliseconds
            += implementation.uploadSubmissionMilliseconds;
        result.decodeAttempts += implementation.decodeAttempts;
        result.decodedFrames += implementation.decodedFrames;
        result.frameReadyEvents += implementation.frameReadyEvents;
        result.stalledFrames += implementation.stalledFrames;
        result.frameUploads += implementation.frameUploads;
        result.pendingFrames += implementation.pendingFrame.has_value () ? 1U : 0U;
        result.seekRequests += implementation.seekRequests;
        result.fallbackPlayers += implementation.fallback ? 1U : 0U;
        result.lastDecodedFrameHash ^= implementation.lastDecodedFrameHash;
        result.decodedFrameSequenceHash
            ^= implementation.decodedFrameSequenceHash;
        result.lastDecodedPresentationSeconds = std::max (
            result.lastDecodedPresentationSeconds,
            implementation.lastDecodedPresentationSeconds
        );
        result.endOfStreamPlayers += implementation.endOfStream ? 1U : 0U;
    }
    return result;
}

MediaTextureGlobalLifecycleEvidence
WallpaperEngine::VideoPlayback::MPV::globalMediaTextureLifecycleEvidence () {
    return {
        .livePlayers = livePlayers,
        .constructions = playerConstructions,
        .destructions = playerDestructions,
    };
}
