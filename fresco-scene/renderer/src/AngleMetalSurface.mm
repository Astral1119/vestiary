#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include "RenderSurface.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <stdexcept>
#include <string>

namespace FrescoScene {

namespace {

std::size_t angleDisplayUsers = 0;

[[noreturn]] void throwEGLError (const char* operation) {
    throw std::runtime_error (
        std::string (operation) + " failed with EGL error "
        + std::to_string (eglGetError ())
    );
}

class AngleMetalSurface final : public RenderSurface {
public:
    explicit AngleMetalSurface (const SurfaceConfiguration& configuration) {
        assert ([NSThread isMainThread]
            && "ANGLE display ownership is confined to the AppKit main thread");
        const NSRect frame = NSMakeRect (
            configuration.x, configuration.y,
            configuration.width, configuration.height
        );
        m_window = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
        m_window.level = static_cast<NSWindowLevel> (
            CGWindowLevelForKey (kCGDesktopIconWindowLevelKey) - 1
        );
        m_window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorIgnoresCycle;
        m_window.ignoresMouseEvents = YES;
        m_window.opaque = YES;
        m_window.backgroundColor = NSColor.blackColor;
        m_window.releasedWhenClosed = NO;

        m_view = [[NSView alloc] initWithFrame:m_window.contentView.bounds];
        m_view.wantsLayer = YES;
        m_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        m_view.layer.contentsScale = m_window.backingScaleFactor;
        m_window.contentView = m_view;

        const EGLAttrib displayAttributes[] = {
            EGL_PLATFORM_ANGLE_TYPE_ANGLE,
            EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
            EGL_NONE,
        };
        m_display = eglGetPlatformDisplay (
            EGL_PLATFORM_ANGLE_ANGLE, nullptr, displayAttributes
        );
        if (m_display == EGL_NO_DISPLAY) {
            throwEGLError ("eglGetPlatformDisplay(Metal)");
        }
        EGLint major = 0;
        EGLint minor = 0;
        if (eglInitialize (m_display, &major, &minor) == EGL_FALSE) {
            throwEGLError ("eglInitialize");
        }
        ++angleDisplayUsers;
        m_displayRegistered = true;

        try {

        const EGLint configAttributes[] = {
            EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE, 8,
            EGL_GREEN_SIZE, 8,
            EGL_BLUE_SIZE, 8,
            EGL_ALPHA_SIZE, 8,
            EGL_DEPTH_SIZE, 24,
            EGL_NONE,
        };
        EGLConfig config = nullptr;
        EGLint configCount = 0;
        if (eglChooseConfig (
                m_display, configAttributes, &config, 1, &configCount
            ) == EGL_FALSE || configCount != 1) {
            throwEGLError ("eglChooseConfig");
        }
        if (eglBindAPI (EGL_OPENGL_ES_API) == EGL_FALSE) {
            throwEGLError ("eglBindAPI");
        }

        const EGLint contextAttributes[] = {
            EGL_CONTEXT_MAJOR_VERSION, 3,
            EGL_CONTEXT_MINOR_VERSION, 0,
            EGL_NONE,
        };
        m_context = eglCreateContext (
            m_display, config, EGL_NO_CONTEXT, contextAttributes
        );
        if (m_context == EGL_NO_CONTEXT) {
            throwEGLError ("eglCreateContext");
        }
        m_surface = eglCreateWindowSurface (
            m_display, config, (__bridge void*) m_view.layer, nullptr
        );
        if (m_surface == EGL_NO_SURFACE) {
            throwEGLError ("eglCreateWindowSurface");
        }
        makeCurrent ();
        if (eglSwapInterval (m_display, 1) == EGL_FALSE) {
            throwEGLError ("eglSwapInterval");
        }

        EGLint width = 0;
        EGLint height = 0;
        if (eglQuerySurface (m_display, m_surface, EGL_WIDTH, &width) == EGL_FALSE
            || eglQuerySurface (m_display, m_surface, EGL_HEIGHT, &height) == EGL_FALSE) {
            throwEGLError ("eglQuerySurface");
        }
        m_width = std::max (1, width);
        m_height = std::max (1, height);
        NSScreen* screen = m_window.screen ?: NSScreen.mainScreen;
        NSString* colorSpace = screen.colorSpace.localizedName;
        if (screen == nil || screen.maximumFramesPerSecond <= 0
            || colorSpace.length == 0) {
            throw std::runtime_error ("cannot determine surface display evidence");
        }
        m_displayEvidence = {
            .logicalWidth = std::max (
                1, static_cast<int> (std::lround (m_view.bounds.size.width))
            ),
            .logicalHeight = std::max (
                1, static_cast<int> (std::lround (m_view.bounds.size.height))
            ),
            .pixelWidth = m_width,
            .pixelHeight = m_height,
            .scaleMilli = std::max (
                1, static_cast<int> (std::lround (m_window.backingScaleFactor * 1000.0))
            ),
            .maximumRefreshMilliHertz = static_cast<int> (
                screen.maximumFramesPerSecond * 1000
            ),
            .colorSpace = colorSpace.UTF8String,
        };
        } catch (...) {
            releaseEGL ();
            throw;
        }
    }

    ~AngleMetalSurface () override {
        releaseEGL ();
        [m_window orderOut:nil];
        [m_window close];
    }

    void releaseEGL () noexcept {
        assert ([NSThread isMainThread]
            && "ANGLE display ownership is confined to the AppKit main thread");
        if (m_displayRegistered && m_display != EGL_NO_DISPLAY) {
            assert (angleDisplayUsers > 0);
            eglMakeCurrent (
                m_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT
            );
            if (m_surface != EGL_NO_SURFACE) {
                eglDestroySurface (m_display, m_surface);
            }
            if (m_context != EGL_NO_CONTEXT) {
                eglDestroyContext (m_display, m_context);
            }
            if (--angleDisplayUsers == 0) {
                eglTerminate (m_display);
            }
        }
        m_surface = EGL_NO_SURFACE;
        m_context = EGL_NO_CONTEXT;
        m_display = EGL_NO_DISPLAY;
        m_displayRegistered = false;
    }

    [[nodiscard]] const BackendIdentity& identity () const override {
        return backendIdentity (RenderBackend::AngleMetal);
    }
    [[nodiscard]] int width () const override { return m_width; }
    [[nodiscard]] int height () const override { return m_height; }
    [[nodiscard]] const SurfaceDisplayEvidence& displayEvidence () const override {
        return m_displayEvidence;
    }
    [[nodiscard]] bool ordered () const override { return m_window.isVisible; }
    [[nodiscard]] int windowLevel () const override {
        return static_cast<int> (m_window.level);
    }
    [[nodiscard]] void* getProcAddress (const char* name) const override {
        return reinterpret_cast<void*> (eglGetProcAddress (name));
    }

    void makeCurrent () override {
        if (eglMakeCurrent (
                m_display, m_surface, m_surface, m_context
            ) == EGL_FALSE) {
            throwEGLError ("eglMakeCurrent");
        }
    }
    void update () override { }
    void present () override {
        if (eglSwapBuffers (m_display, m_surface) == EGL_FALSE) {
            throwEGLError ("eglSwapBuffers");
        }
    }
    void setVisible (bool visible) override {
        if (visible) {
            [m_window orderFrontRegardless];
        } else {
            [m_window orderOut:nil];
        }
    }
    void completeFrame (bool wait) override {
        if (wait) {
            glFinish ();
        }
        const GLenum error = glGetError ();
        if (error != GL_NO_ERROR) {
            throw std::runtime_error (
                "OpenGL ES error after rendered frame: " + std::to_string (error)
            );
        }
    }
    [[nodiscard]] std::vector<uint8_t> readFrontRGBA () override {
        makeCurrent ();
        glBindFramebuffer (GL_FRAMEBUFFER, 0);
        std::vector<uint8_t> pixels (
            static_cast<std::size_t> (m_width) * m_height * 4
        );
        glReadPixels (
            0, 0, m_width, m_height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data ()
        );
        const GLenum error = glGetError ();
        if (error != GL_NO_ERROR) {
            throw std::runtime_error (
                "OpenGL ES error during first-frame readback: "
                + std::to_string (error)
            );
        }
        return pixels;
    }

private:
    int m_width = 0;
    int m_height = 0;
    SurfaceDisplayEvidence m_displayEvidence;
    NSWindow* m_window = nil;
    NSView* m_view = nil;
    EGLDisplay m_display = EGL_NO_DISPLAY;
    EGLContext m_context = EGL_NO_CONTEXT;
    EGLSurface m_surface = EGL_NO_SURFACE;
    bool m_displayRegistered = false;
};

}

std::unique_ptr<RenderSurface> createRenderSurface (
    RenderBackend backend,
    const SurfaceConfiguration& configuration
) {
    if (backend == RenderBackend::AngleMetal) {
        return std::make_unique<AngleMetalSurface> (configuration);
    }
    throw std::runtime_error ("unsupported render backend");
}

}
