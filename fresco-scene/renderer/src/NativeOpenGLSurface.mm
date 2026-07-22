#import <AppKit/AppKit.h>
#import <OpenGL/gl3.h>

#include "RenderSurface.h"

#include <algorithm>
#include <cmath>
#include <dlfcn.h>
#include <stdexcept>
#include <string>

namespace FrescoScene {

namespace {

class NativeOpenGLSurface final : public RenderSurface {
public:
    explicit NativeOpenGLSurface (const SurfaceConfiguration& configuration) {
        NSOpenGLPixelFormatAttribute attributes[] = {
            NSOpenGLPFAOpenGLProfile,
            static_cast<NSOpenGLPixelFormatAttribute> (NSOpenGLProfileVersion4_1Core),
            NSOpenGLPFAAccelerated,
            NSOpenGLPFADoubleBuffer,
            NSOpenGLPFAColorSize,
            static_cast<NSOpenGLPixelFormatAttribute> (24),
            NSOpenGLPFAAlphaSize,
            static_cast<NSOpenGLPixelFormatAttribute> (8),
            NSOpenGLPFADepthSize,
            static_cast<NSOpenGLPixelFormatAttribute> (24),
            static_cast<NSOpenGLPixelFormatAttribute> (0),
        };
        m_format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
        if (m_format == nil) {
            throw std::runtime_error ("cannot create an OpenGL 4.1 core pixel format");
        }

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

        m_view = [[NSOpenGLView alloc] initWithFrame:m_window.contentView.bounds
                                        pixelFormat:m_format];
        m_view.wantsBestResolutionOpenGLSurface = YES;
        m_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        m_window.contentView = m_view;
        m_context = m_view.openGLContext;
        if (m_context == nil) {
            throw std::runtime_error ("cannot create an OpenGL 4.1 core context");
        }
        GLint swapInterval = 1;
        [m_context setValues:&swapInterval forParameter:NSOpenGLContextParameterSwapInterval];
        makeCurrent ();
        update ();

        const NSRect backingBounds = [m_view convertRectToBacking:m_view.bounds];
        m_width = std::max (1, static_cast<int> (std::lround (backingBounds.size.width)));
        m_height = std::max (1, static_cast<int> (std::lround (backingBounds.size.height)));
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
    }

    ~NativeOpenGLSurface () override {
        makeCurrent ();
        [m_window orderOut:nil];
        [m_window close];
        [NSOpenGLContext clearCurrentContext];
    }

    [[nodiscard]] const BackendIdentity& identity () const override {
        return backendIdentity (RenderBackend::NativeOpenGL);
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
        return dlsym (RTLD_DEFAULT, name);
    }

    void makeCurrent () override { [m_context makeCurrentContext]; }
    void update () override { [m_context update]; }
    void present () override { [m_context flushBuffer]; }

    void setVisible (bool visible) override {
        if (visible) {
            [m_window orderFrontRegardless];
            update ();
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
                "OpenGL error after rendered frame: " + std::to_string (error)
            );
        }
    }

    [[nodiscard]] std::vector<uint8_t> readFrontRGBA () override {
        makeCurrent ();
        glBindFramebuffer (GL_FRAMEBUFFER, 0);
        glReadBuffer (GL_BACK);
        std::vector<uint8_t> pixels (
            static_cast<std::size_t> (m_width) * m_height * 4
        );
        glReadPixels (
            0, 0, m_width, m_height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data ()
        );
        const GLenum error = glGetError ();
        if (error != GL_NO_ERROR) {
            throw std::runtime_error (
                "OpenGL error during first-frame readback: " + std::to_string (error)
            );
        }
        return pixels;
    }

private:
    int m_width = 0;
    int m_height = 0;
    SurfaceDisplayEvidence m_displayEvidence;
    NSOpenGLPixelFormat* m_format = nil;
    NSWindow* m_window = nil;
    NSOpenGLView* m_view = nil;
    NSOpenGLContext* m_context = nil;
};

}

std::unique_ptr<RenderSurface> createRenderSurface (
    RenderBackend backend,
    const SurfaceConfiguration& configuration
) {
    switch (backend) {
    case RenderBackend::NativeOpenGL:
        return std::make_unique<NativeOpenGLSurface> (configuration);
    case RenderBackend::AngleMetal:
        break;
    }
    throw std::runtime_error ("unsupported render backend");
}

}
