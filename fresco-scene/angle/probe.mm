/*
 * Fresco ANGLE/Metal window probe
 *
 * This file deliberately loads EGL and GLES at runtime. The feasibility probe
 * can therefore test a candidate ANGLE distribution without linking Fresco to
 * an unrelated system or application copy.
 */

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <dlfcn.h>
#include <stdint.h>

#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>

using EGLBoolean = unsigned int;
using EGLenum = unsigned int;
using EGLint = int;
using EGLAttrib = intptr_t;
using EGLDisplay = void*;
using EGLConfig = void*;
using EGLContext = void*;
using EGLSurface = void*;

constexpr EGLBoolean EGL_FALSE = 0;
constexpr EGLint EGL_NONE = 0x3038;
constexpr EGLint EGL_RED_SIZE = 0x3024;
constexpr EGLint EGL_GREEN_SIZE = 0x3023;
constexpr EGLint EGL_BLUE_SIZE = 0x3022;
constexpr EGLint EGL_ALPHA_SIZE = 0x3021;
constexpr EGLint EGL_SURFACE_TYPE = 0x3033;
constexpr EGLint EGL_WINDOW_BIT = 0x0004;
constexpr EGLint EGL_RENDERABLE_TYPE = 0x3040;
constexpr EGLint EGL_OPENGL_ES3_BIT = 0x0040;
constexpr EGLenum EGL_OPENGL_ES_API = 0x30A0;
constexpr EGLint EGL_CONTEXT_MAJOR_VERSION = 0x3098;
constexpr EGLint EGL_CONTEXT_MINOR_VERSION = 0x30FB;
constexpr EGLenum EGL_PLATFORM_ANGLE_ANGLE = 0x3202;
constexpr EGLAttrib EGL_PLATFORM_ANGLE_TYPE_ANGLE = 0x3203;
constexpr EGLAttrib EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE = 0x3489;

constexpr unsigned int GL_COLOR_BUFFER_BIT = 0x00004000;
constexpr unsigned int GL_RENDERER = 0x1F01;
constexpr unsigned int GL_VERSION = 0x1F02;
constexpr unsigned int GL_RGBA = 0x1908;
constexpr unsigned int GL_UNSIGNED_BYTE = 0x1401;
constexpr unsigned int GL_NO_ERROR = 0;

template <typename Function>
Function load (void* library, const char* name) {
    auto symbol = reinterpret_cast<Function> (dlsym (library, name));
    if (symbol == nullptr) {
        throw std::runtime_error (std::string ("missing symbol ") + name);
    }
    return symbol;
}

std::string jsonEscape (const char* input) {
    std::string output;
    for (const char* cursor = input; cursor != nullptr && *cursor != '\0'; ++cursor) {
        if (*cursor == '\\' || *cursor == '"') {
            output += '\\';
        }
        output += *cursor;
    }
    return output;
}

int main (int argc, char** argv) {
    @autoreleasepool {
        if (argc != 2) {
            std::fprintf (stderr, "usage: fresco-angle-probe ANGLE_LIBRARY_DIRECTORY\n");
            return 64;
        }

        try {
            const std::string directory = argv[1];
            void* gles = dlopen ((directory + "/libGLESv2.dylib").c_str (), RTLD_NOW | RTLD_GLOBAL);
            if (gles == nullptr) {
                throw std::runtime_error (std::string ("cannot load libGLESv2: ") + dlerror ());
            }
            void* egl = dlopen ((directory + "/libEGL.dylib").c_str (), RTLD_NOW | RTLD_LOCAL);
            if (egl == nullptr) {
                throw std::runtime_error (std::string ("cannot load libEGL: ") + dlerror ());
            }

            const auto eglGetPlatformDisplay = load<EGLDisplay (*) (EGLenum, void*, const EGLAttrib*)> (
                egl, "eglGetPlatformDisplay"
            );
            const auto eglInitialize = load<EGLBoolean (*) (EGLDisplay, EGLint*, EGLint*)> (
                egl, "eglInitialize"
            );
            const auto eglChooseConfig = load<EGLBoolean (*) (EGLDisplay, const EGLint*, EGLConfig*, EGLint, EGLint*)> (
                egl, "eglChooseConfig"
            );
            const auto eglBindAPI = load<EGLBoolean (*) (EGLenum)> (egl, "eglBindAPI");
            const auto eglCreateContext = load<EGLContext (*) (EGLDisplay, EGLConfig, EGLContext, const EGLint*)> (
                egl, "eglCreateContext"
            );
            const auto eglCreateWindowSurface = load<EGLSurface (*) (EGLDisplay, EGLConfig, void*, const EGLint*)> (
                egl, "eglCreateWindowSurface"
            );
            const auto eglMakeCurrent = load<EGLBoolean (*) (EGLDisplay, EGLSurface, EGLSurface, EGLContext)> (
                egl, "eglMakeCurrent"
            );
            const auto eglSwapBuffers = load<EGLBoolean (*) (EGLDisplay, EGLSurface)> (egl, "eglSwapBuffers");
            const auto eglDestroySurface = load<EGLBoolean (*) (EGLDisplay, EGLSurface)> (egl, "eglDestroySurface");
            const auto eglDestroyContext = load<EGLBoolean (*) (EGLDisplay, EGLContext)> (egl, "eglDestroyContext");
            const auto eglTerminate = load<EGLBoolean (*) (EGLDisplay)> (egl, "eglTerminate");
            const auto eglGetError = load<EGLint (*) ()> (egl, "eglGetError");

            const auto glGetString = load<const unsigned char* (*) (unsigned int)> (gles, "glGetString");
            const auto glClearColor = load<void (*) (float, float, float, float)> (gles, "glClearColor");
            const auto glClear = load<void (*) (unsigned int)> (gles, "glClear");
            const auto glFinish = load<void (*) ()> (gles, "glFinish");
            const auto glReadPixels = load<void (*) (int, int, int, int, unsigned int, unsigned int, void*)> (
                gles, "glReadPixels"
            );
            const auto glGetError = load<unsigned int (*) ()> (gles, "glGetError");

            [NSApplication sharedApplication];
            NSRect frame = NSMakeRect (0, 0, 64, 64);
            NSWindow* window = [[NSWindow alloc]
                initWithContentRect:frame
                          styleMask:NSWindowStyleMaskBorderless
                            backing:NSBackingStoreBuffered
                              defer:NO];
            NSView* view = [[NSView alloc] initWithFrame:frame];
            view.wantsLayer = YES;
            view.layer.contentsScale = 1.0;
            [window setContentView:view];
            [window orderOut:nil];

            const EGLAttrib displayAttributes[] = {
                EGL_PLATFORM_ANGLE_TYPE_ANGLE,
                EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
                EGL_NONE,
            };
            EGLDisplay display = eglGetPlatformDisplay (
                EGL_PLATFORM_ANGLE_ANGLE, nullptr, displayAttributes
            );
            if (display == nullptr) {
                throw std::runtime_error ("eglGetPlatformDisplay(Metal) failed: " + std::to_string (eglGetError ()));
            }

            EGLint eglMajor = 0;
            EGLint eglMinor = 0;
            if (eglInitialize (display, &eglMajor, &eglMinor) == EGL_FALSE) {
                throw std::runtime_error ("eglInitialize failed: " + std::to_string (eglGetError ()));
            }

            const EGLint configAttributes[] = {
                EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                EGL_RED_SIZE, 8,
                EGL_GREEN_SIZE, 8,
                EGL_BLUE_SIZE, 8,
                EGL_ALPHA_SIZE, 8,
                EGL_NONE,
            };
            EGLConfig config = nullptr;
            EGLint configCount = 0;
            if (eglChooseConfig (display, configAttributes, &config, 1, &configCount) == EGL_FALSE || configCount != 1) {
                throw std::runtime_error ("no ES 3 window config: " + std::to_string (eglGetError ()));
            }
            if (eglBindAPI (EGL_OPENGL_ES_API) == EGL_FALSE) {
                throw std::runtime_error ("eglBindAPI failed: " + std::to_string (eglGetError ()));
            }

            const EGLint contextAttributes[] = {
                EGL_CONTEXT_MAJOR_VERSION, 3,
                EGL_CONTEXT_MINOR_VERSION, 0,
                EGL_NONE,
            };
            EGLContext context = eglCreateContext (display, config, nullptr, contextAttributes);
            if (context == nullptr) {
                throw std::runtime_error ("ES 3 context creation failed: " + std::to_string (eglGetError ()));
            }
            EGLSurface surface = eglCreateWindowSurface (
                display, config, (__bridge void*) view.layer, nullptr
            );
            if (surface == nullptr) {
                throw std::runtime_error ("CALayer window surface creation failed: " + std::to_string (eglGetError ()));
            }
            if (eglMakeCurrent (display, surface, surface, context) == EGL_FALSE) {
                throw std::runtime_error ("eglMakeCurrent failed: " + std::to_string (eglGetError ()));
            }

            glClearColor (0.125F, 0.25F, 0.5F, 1.0F);
            glClear (GL_COLOR_BUFFER_BIT);
            glFinish ();
            unsigned char pixel[4] = {};
            glReadPixels (0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
            const unsigned int glError = glGetError ();
            const bool pixelMatches =
                pixel[0] >= 31 && pixel[0] <= 33 && pixel[1] >= 63 && pixel[1] <= 65
                && pixel[2] >= 127 && pixel[2] <= 129 && pixel[3] == 255;
            if (glError != GL_NO_ERROR || !pixelMatches || eglSwapBuffers (display, surface) == EGL_FALSE) {
                throw std::runtime_error ("draw/read/swap validation failed");
            }

            const char* renderer = reinterpret_cast<const char*> (glGetString (GL_RENDERER));
            const char* version = reinterpret_cast<const char*> (glGetString (GL_VERSION));
            const bool isMetal = renderer != nullptr && std::string (renderer).find ("Metal") != std::string::npos;
            std::printf (
                "{\"result\":\"%s\",\"egl\":\"%d.%d\",\"renderer\":\"%s\","
                "\"glVersion\":\"%s\",\"pixel\":[%u,%u,%u,%u],\"windowOwner\":\"AppKit\"}\n",
                isMetal ? "pass" : "fail", eglMajor, eglMinor, jsonEscape (renderer).c_str (),
                jsonEscape (version).c_str (), pixel[0], pixel[1], pixel[2], pixel[3]
            );

            eglMakeCurrent (display, nullptr, nullptr, nullptr);
            eglDestroySurface (display, surface);
            eglDestroyContext (display, context);
            eglTerminate (display);
            return isMetal ? 0 : 1;
        } catch (const std::exception& error) {
            std::fprintf (stderr, "fresco-angle-probe: %s\n", error.what ());
            return 1;
        }
    }
}
