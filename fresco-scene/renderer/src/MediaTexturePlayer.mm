#include "WallpaperEngine/VideoPlayback/MPV/GLPlayer.h"

#include "FrescoScene/MediaPlaybackClock.h"
#include "FrescoScene/MediaVideoDecoder.h"
#include "WallpaperEngine/Logging/Log.h"

// Both backends bind the decoder's IOSurface rather than copying it, and they
// reach it by different routes: CGL on native OpenGL, EGL_ANGLE_iosurface_client_buffer
// on ANGLE. Only the bind differs; the rectangle-source-to-2D-destination blit
// below is shared, so the two paths cannot drift apart in what they produce.
#define FRESCO_SCENE_MEDIA_IOSURFACE_BLIT 1
#import <IOSurface/IOSurfaceRef.h>
#if defined(FRESCO_SCENE_ANGLE_RUNTIME)
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#else
#import <OpenGL/CGLCurrent.h>
#import <OpenGL/CGLIOSurface.h>
#endif

#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstdlib>
#include <cstring>
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

// Accumulates the whole of a scope into a caller-owned total. Timing an entry
// point this way cannot leave a region uncovered the way a timer placed around
// one call inside it can.
class ScopedMilliseconds {
public:
    explicit ScopedMilliseconds (double& total) :
        total (total), start (std::chrono::steady_clock::now ()) { }

    ~ScopedMilliseconds () {
        total += std::chrono::duration<double, std::milli> (
            std::chrono::steady_clock::now () - start
        ).count ();
    }

    ScopedMilliseconds (const ScopedMilliseconds&) = delete;
    ScopedMilliseconds& operator= (const ScopedMilliseconds&) = delete;

private:
    double& total;
    std::chrono::steady_clock::time_point start;
};

// Where the decoder's IOSurface arrives before it is blitted into the texture
// shaders sample. CGL binds only to a rectangle texture; ANGLE's rectangle
// target needs an extension of its own and buys nothing here, because the blit
// does not care which target it reads from.
#ifdef FRESCO_SCENE_ANGLE_RUNTIME
constexpr GLenum surfaceTextureTarget = GL_TEXTURE_2D;
#else
constexpr GLenum surfaceTextureTarget = GL_TEXTURE_RECTANGLE;
#endif

std::unordered_map<WallpaperEngine::Render::RenderContext*, MediaTextureHost*> hosts;
std::size_t livePlayers = 0;
std::size_t playerConstructions = 0;
std::size_t playerDestructions = 0;

// The hash confirms the duplicate that presentation time has already
// identified, and gives the media workload a content signature to compare
// across a seek and across a reload. Reading every byte to produce it made it
// the largest single cost in the helper's frame loop: 33 MB per decoded frame
// walked as one serial multiply chain, measured on Elaina at 48% of
// main-thread work against 15% for the texture upload and 4.5% for the
// AVFoundation decode. It sits outside both decodeMilliseconds and
// uploadSubmissionMilliseconds, so the counters ranked the upload first and
// never saw this at all.
//
// Sampling rows keeps the signature deterministic and content-sensitive at a
// cost that no longer scales with frame area — a 4K frame reads about 1 MB
// rather than 33. Rows are read whole, because a strided read within a row
// would trade the sequential access for no further saving.
constexpr std::uint32_t hashedRowBudget = 64;

std::uint64_t frameHash (const FrescoScene::MediaVideoFrame& frame) {
    constexpr std::uint64_t prime = 1099511628211ULL;
    std::uint64_t hash = 1469598103934665603ULL;
    // Geometry joins the signature because sampled rows alone cannot see a
    // resize that leaves the rows they land on alike.
    hash = (hash ^ static_cast<std::uint64_t> (frame.width)) * prime;
    hash = (hash ^ static_cast<std::uint64_t> (frame.height)) * prime;
    const std::uint32_t rowStride = std::max (
        1U, frame.height / hashedRowBudget
    );
    const std::size_t rowBytes = static_cast<std::size_t> (frame.width) * 4U;
    for (std::uint32_t y = 0; y < frame.height; y += rowStride) {
        const auto* row = frame.pixels.get ()
            + static_cast<std::size_t> (y) * frame.bytesPerRow;
        std::size_t x = 0;
        for (; x + sizeof (std::uint64_t) <= rowBytes;
             x += sizeof (std::uint64_t)) {
            std::uint64_t word = 0;
            std::memcpy (&word, row + x, sizeof (word));
            hash = (hash ^ word) * prime;
        }
        for (; x < rowBytes; ++x) {
            hash = (hash ^ row[x]) * prime;
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
        double positionSeconds, bool wrapped = false, bool folded = false
    ) {
        // Timed here rather than at GLPlayer::prepareFrame because the
        // constructor prepares its first frame through this function directly,
        // and a total that misses that path is smaller than the decode time it
        // is supposed to contain.
        const ScopedMilliseconds timer (framePreparationMilliseconds);
        if (decoder == nullptr) {
            return {};
        }
        if (endOfStream) {
            // The latch keeps a finished stream from re-decoding every frame,
            // but the playback clock folds position back to the start at the
            // asset duration and the decoder restarts its reader for any
            // position behind the last one it served. Holding the latch across
            // that wrap froze the texture on its final frame for the rest of
            // the scene's life while the frame loop carried on drawing it.
            if (!wrapped) {
                return { .terminal = true };
            }
            endOfStream = false;
        }
        // A frame decoded before the wrap and not yet due presents a whole loop
        // from where the clock now is. Waiting for it holds the texture on the
        // frame already uploaded and asks for no decode until position comes
        // back around, so the picture freezes for a full pass at a time. Drop it
        // and decode from where the clock actually is.
        // `folded` rather than `wrapped`: a pending frame ahead of the position
        // is the ordinary decoded-ahead state, and `wrapped` reports that too.
        const bool pendingPrecedesWrap = pendingFrame.has_value ()
            && !pendingFrameReady && folded
            && pendingFrame->presentationSeconds > positionSeconds;
        if (pendingPrecedesWrap) {
            pendingFrame.reset ();
            lastPreparedPresentationSeconds.reset ();
            ++wrapDiscardedFrames;
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
        const ScopedMilliseconds timer (frameUploadMilliseconds);
        if (!pendingFrame.has_value () || !pendingFrameReady) {
            return;
        }
        const auto frame = std::move (*pendingFrame);
        pendingFrame.reset ();
        pendingFrameReady = false;

        const auto uploadStart = std::chrono::steady_clock::now ();
        if (uploadThroughSurface (frame)) {
            ++surfaceBlitUploads;
        } else {
            uploadThroughMappedPixels (frame);
        }
        uploadSubmissionMilliseconds += std::chrono::duration<double, std::milli> (
            std::chrono::steady_clock::now () - uploadStart
        ).count ();
        ++decodes;
        ++frameUploads;
        uploadedBytes += static_cast<std::uint64_t> (frame.width)
            * static_cast<std::uint64_t> (frame.height) * 4U;
    }

    // The decoder already hands back a GPU-addressable IOSurface. Copying it
    // through the CPU cost a 33 MB glTexSubImage2D per frame; binding it and
    // blitting moves that to the GPU side.
    //
    // On native OpenGL the surface has to arrive on a rectangle texture,
    // because CGLTexImageIOSurface2D binds to no other target, and rectangle
    // textures take unnormalized coordinates and sampler2DRect. Authored
    // shaders in the corpus sample video through sampler2D, so the surface
    // cannot be put where they can see it. Blitting into the GL_TEXTURE_2D they
    // already sample keeps them untouched, and ANGLE takes the same shape even
    // though EGL would let it bind straight to a 2D texture -- one blit for
    // both backends is what keeps a later comparison between them honest.
    //
    // Returns false for anything it cannot do, and the mapped-pixel path
    // stands behind it unchanged.
    bool uploadThroughSurface ([[maybe_unused]] const MediaVideoFrame& frame) {
#ifndef FRESCO_SCENE_MEDIA_IOSURFACE_BLIT
        return false;
#else
        // The two paths must put the same picture in the texture, and nothing
        // else can hold one against the other -- the smoke tool builds no
        // MediaTextureHost, so no scene with a video texture renders under it.
        // This is the lever that compares them.
        static const bool disabled =
            std::getenv ("FRESCO_SCENE_MEDIA_SURFACE_BLIT_DISABLED") != nullptr;
        if (disabled) {
            return false;
        }
        auto* const surface = static_cast<IOSurfaceRef> (frame.surface);
        if (surface == nullptr || frame.width == 0 || frame.height == 0) {
            return false;
        }
        if (surfaceTexture == 0) {
            glGenTextures (1, &surfaceTexture);
            glGenFramebuffers (1, &readFramebuffer);
            glGenFramebuffers (1, &drawFramebuffer);
        }
        if (!bindSurface (surface, frame.width, frame.height)) {
            return false;
        }

        glBindTexture (GL_TEXTURE_2D, texture);
        clearSwizzle ();
        if (frame.width != width || frame.height != height) {
            width = frame.width;
            height = frame.height;
            glTexImage2D (
                GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0,
                GL_RGBA, GL_UNSIGNED_BYTE, nullptr
            );
        }

        // Uploads run inside the scene's frame, so every binding and every
        // piece of state the blit depends on belongs to whatever pass is in
        // progress. A leaked glClearColor blanked the scene once already.
        GLint previousRead = 0;
        GLint previousDraw = 0;
        glGetIntegerv (GL_READ_FRAMEBUFFER_BINDING, &previousRead);
        glGetIntegerv (GL_DRAW_FRAMEBUFFER_BINDING, &previousDraw);
        const GLboolean scissor = glIsEnabled (GL_SCISSOR_TEST);
        GLboolean colorMask[4] = { GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE };
        glGetBooleanv (GL_COLOR_WRITEMASK, colorMask);
        if (scissor == GL_TRUE) {
            glDisable (GL_SCISSOR_TEST);
        }
        glColorMask (GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

        glBindFramebuffer (GL_READ_FRAMEBUFFER, readFramebuffer);
        glFramebufferTexture2D (
            GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            surfaceTextureTarget, surfaceTexture, 0
        );
        glReadBuffer (GL_COLOR_ATTACHMENT0);
        glBindFramebuffer (GL_DRAW_FRAMEBUFFER, drawFramebuffer);
        glFramebufferTexture2D (
            GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0
        );
        // glDrawBuffers rather than glDrawBuffer: the singular form is desktop
        // GL only and this path compiles against GLES under ANGLE.
        const GLenum drawTarget = GL_COLOR_ATTACHMENT0;
        glDrawBuffers (1, &drawTarget);

        const bool complete =
            glCheckFramebufferStatus (GL_READ_FRAMEBUFFER)
                == GL_FRAMEBUFFER_COMPLETE
            && glCheckFramebufferStatus (GL_DRAW_FRAMEBUFFER)
                == GL_FRAMEBUFFER_COMPLETE;
        if (complete) {
            const auto blitWidth = static_cast<GLint> (width);
            const auto blitHeight = static_cast<GLint> (height);
            glBlitFramebuffer (
                0, 0, blitWidth, blitHeight, 0, 0, blitWidth, blitHeight,
                GL_COLOR_BUFFER_BIT, GL_NEAREST
            );
        }

        glBindFramebuffer (GL_READ_FRAMEBUFFER, previousRead);
        glBindFramebuffer (GL_DRAW_FRAMEBUFFER, previousDraw);
        glColorMask (colorMask[0], colorMask[1], colorMask[2], colorMask[3]);
        if (scissor == GL_TRUE) {
            glEnable (GL_SCISSOR_TEST);
        }
        releaseSurface ();

        if (!complete) {
            // The destination has been reallocated and its swizzle cleared, so
            // the mapped path must run to put a correct picture in it.
            reportSurfaceUnavailable ("IOSurface blit framebuffers are incomplete");
            return false;
        }
        return true;
#endif
    }

#ifdef FRESCO_SCENE_MEDIA_IOSURFACE_BLIT
#ifdef FRESCO_SCENE_ANGLE_RUNTIME
    // ANGLE reaches an IOSurface through a pbuffer bound as a texture image.
    // The surface arrives on a GL_TEXTURE_2D rather than a rectangle texture,
    // because ANGLE's rectangle target needs its own extension and the blit
    // does not care which target it reads from.
    bool bindSurface (IOSurfaceRef surface, std::uint32_t frameWidth,
                      std::uint32_t frameHeight) {
        EGLDisplay const display = eglGetCurrentDisplay ();
        if (display == EGL_NO_DISPLAY) {
            return false;
        }
        if (!surfaceConfigResolved) {
            surfaceConfigResolved = true;
            // The window config is chosen for EGL_WINDOW_BIT and will not
            // serve a pbuffer, so this asks for its own.
            const EGLint configAttributes[] = {
                EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
                EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                EGL_BIND_TO_TEXTURE_RGBA, EGL_TRUE,
                EGL_NONE,
            };
            EGLint configCount = 0;
            if (eglChooseConfig (
                    display, configAttributes, &surfaceConfig, 1, &configCount
                ) == EGL_FALSE
                || configCount == 0) {
                surfaceConfig = nullptr;
            }
        }
        if (surfaceConfig == nullptr) {
            reportSurfaceUnavailable ("no EGL config binds an IOSurface pbuffer");
            return false;
        }
        // GL_BGRA_EXT with an unsigned byte type is what makes the component
        // order come out right on read, which is why the destination's swizzle
        // is cleared rather than kept -- the same reasoning as the CGL path.
        const EGLint surfaceAttributes[] = {
            EGL_WIDTH, static_cast<EGLint> (frameWidth),
            EGL_HEIGHT, static_cast<EGLint> (frameHeight),
            EGL_IOSURFACE_PLANE_ANGLE, 0,
            EGL_TEXTURE_TARGET, EGL_TEXTURE_2D,
            EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
            EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
            EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
            EGL_IOSURFACE_USAGE_HINT_ANGLE, EGL_IOSURFACE_READ_HINT_ANGLE,
            EGL_NONE,
        };
        surfacePbuffer = eglCreatePbufferFromClientBuffer (
            display, EGL_IOSURFACE_ANGLE, surface, surfaceConfig,
            surfaceAttributes
        );
        if (surfacePbuffer == EGL_NO_SURFACE) {
            reportSurfaceUnavailable ("cannot create an IOSurface pbuffer");
            return false;
        }
        glBindTexture (GL_TEXTURE_2D, surfaceTexture);
        if (eglBindTexImage (display, surfacePbuffer, EGL_BACK_BUFFER)
            == EGL_FALSE) {
            eglDestroySurface (display, surfacePbuffer);
            surfacePbuffer = EGL_NO_SURFACE;
            reportSurfaceUnavailable ("cannot bind an IOSurface pbuffer to a texture");
            return false;
        }
        glBindTexture (GL_TEXTURE_2D, 0);
        return true;
    }

    // The pbuffer holds the texture image, so it lives exactly as long as the
    // blit that reads it. Each decoded frame arrives on a different surface
    // from AVFoundation's pool, so there is nothing to keep between frames.
    void releaseSurface () {
        if (surfacePbuffer == EGL_NO_SURFACE) {
            return;
        }
        EGLDisplay const display = eglGetCurrentDisplay ();
        if (display != EGL_NO_DISPLAY) {
            eglReleaseTexImage (display, surfacePbuffer, EGL_BACK_BUFFER);
            eglDestroySurface (display, surfacePbuffer);
        }
        surfacePbuffer = EGL_NO_SURFACE;
    }
#else
    bool bindSurface (IOSurfaceRef surface, std::uint32_t frameWidth,
                      std::uint32_t frameHeight) {
        CGLContextObj const context = CGLGetCurrentContext ();
        if (context == nullptr) {
            return false;
        }
        glBindTexture (GL_TEXTURE_RECTANGLE, surfaceTexture);
        // GL_BGRA with the reversed packed type is what makes the component
        // order come out right on read, which is why the destination's swizzle
        // is cleared rather than kept.
        const CGLError bound = CGLTexImageIOSurface2D (
            context, GL_TEXTURE_RECTANGLE, GL_RGBA,
            static_cast<GLsizei> (frameWidth),
            static_cast<GLsizei> (frameHeight),
            GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, surface, 0
        );
        glBindTexture (GL_TEXTURE_RECTANGLE, 0);
        if (bound != kCGLNoError) {
            reportSurfaceUnavailable ("cannot bind IOSurface to a rectangle texture");
            return false;
        }
        return true;
    }

    // CGL binds the surface into the texture outright, so there is nothing
    // holding it once the blit has read it.
    void releaseSurface () { }
#endif
#endif

    void uploadThroughMappedPixels (const MediaVideoFrame& frame) {
        glBindTexture (GL_TEXTURE_2D, texture);
        applyBGRASwizzle ();
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
    }

    // Set on every upload rather than once, because a player that falls back
    // mid-stream changes which of the two applies.
    void applyBGRASwizzle () {
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_R, GL_BLUE);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_G, GL_GREEN);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_B, GL_RED);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, GL_ALPHA);
    }

    void clearSwizzle () {
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_R, GL_RED);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_G, GL_GREEN);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_B, GL_BLUE);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, GL_ALPHA);
    }

    void reportSurfaceUnavailable (const std::string& reason) {
        if (surfaceFailureReported) {
            return;
        }
        surfaceFailureReported = true;
        sLog.error ("Video texture IOSurface upload unavailable: ", reason);
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

    ~Impl () {
#ifdef FRESCO_SCENE_MEDIA_IOSURFACE_BLIT
        // Teardown can reach here after the context has gone, and deleting
        // names without one is undefined rather than a no-op.
#ifdef FRESCO_SCENE_ANGLE_RUNTIME
        const bool contextLive = eglGetCurrentContext () != EGL_NO_CONTEXT;
#else
        const bool contextLive = CGLGetCurrentContext () != nullptr;
#endif
        if (surfaceTexture != 0 && contextLive) {
            releaseSurface ();
            glDeleteFramebuffers (1, &readFramebuffer);
            glDeleteFramebuffers (1, &drawFramebuffer);
            glDeleteTextures (1, &surfaceTexture);
        }
#endif
    }

    Impl (const Impl&) = delete;
    Impl& operator= (const Impl&) = delete;

    GLuint texture;
    GLuint surfaceTexture = 0;
    GLuint readFramebuffer = 0;
    GLuint drawFramebuffer = 0;
#if defined(FRESCO_SCENE_MEDIA_IOSURFACE_BLIT) \
    && defined(FRESCO_SCENE_ANGLE_RUNTIME)
    EGLConfig surfaceConfig = nullptr;
    EGLSurface surfacePbuffer = EGL_NO_SURFACE;
    bool surfaceConfigResolved = false;
#endif
    bool surfaceFailureReported = false;
    std::size_t surfaceBlitUploads = 0;
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
    std::size_t wrapDiscardedFrames = 0;
    std::size_t frameUploads = 0;
    std::size_t seekRequests = 0;
    std::uint64_t uploadedBytes = 0;
    double framePreparationMilliseconds = 0.0;
    double frameUploadMilliseconds = 0.0;
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
    return m_implementation->prepareFrame (
        sample.positionSeconds, sample.wrapped, sample.folded
    );
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
        result.framePreparationMilliseconds
            += implementation.framePreparationMilliseconds;
        result.frameUploadMilliseconds
            += implementation.frameUploadMilliseconds;
        result.decodeMilliseconds += implementation.decodeMilliseconds;
        result.uploadSubmissionMilliseconds
            += implementation.uploadSubmissionMilliseconds;
        result.decodeAttempts += implementation.decodeAttempts;
        result.decodedFrames += implementation.decodedFrames;
        result.frameReadyEvents += implementation.frameReadyEvents;
        result.stalledFrames += implementation.stalledFrames;
        result.wrapDiscardedFrames += implementation.wrapDiscardedFrames;
        result.frameUploads += implementation.frameUploads;
        result.surfaceBlitUploads += implementation.surfaceBlitUploads;
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
