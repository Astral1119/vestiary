/*
 * Fresco scene renderer proof
 *
 * Copyright (C) 2026 astral (github.com/Astral1119)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version 3.
 */

#import <AppKit/AppKit.h>

#include "WallpaperEngine/Application/WallpaperApplication.h"
#include "WallpaperEngine/Assets/AssetLocator.h"
#include "WallpaperEngine/Data/JSON.h"
#include "WallpaperEngine/Data/Parsers/ProjectParser.h"
#include "WallpaperEngine/FileSystem/Container.h"
#include "WallpaperEngine/Input/MouseInput.h"
#include "WallpaperEngine/Logging/Log.h"
#include "WallpaperEngine/Media/MediaSource.h"
#include "WallpaperEngine/Render/Drivers/Output/Output.h"
#include "WallpaperEngine/Render/Drivers/VideoDriver.h"
#include "WallpaperEngine/Render/RenderContext.h"
#include "WallpaperEngine/Render/Wallpapers/CScene.h"

#include "FrescoScene/RenderProgramCache.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

float g_Time = 1.0f;
float g_TimeLast = 1.0f - (1.0f / 60.0f);
float g_Daytime = 0.5f;

namespace {

using WallpaperEngine::Application::WallpaperApplication;
using WallpaperEngine::Audio::AudioContext;
using WallpaperEngine::Data::JSON::JSON;
using WallpaperEngine::Data::Parsers::ProjectParser;
using WallpaperEngine::FileSystem::Container;
using WallpaperEngine::Input::MouseClickStatus;
using WallpaperEngine::Input::MouseInput;
using WallpaperEngine::Media::MediaSource;
using WallpaperEngine::Render::Drivers::Output::Output;
using WallpaperEngine::Render::Drivers::VideoDriver;

class StillMouse final : public MouseInput {
public:
    void update () override { }
    [[nodiscard]] glm::dvec2 position () const override { return { 0.0, 0.0 }; }
    [[nodiscard]] MouseClickStatus leftClick () const override {
        return WallpaperEngine::Input::Released;
    }
    [[nodiscard]] MouseClickStatus rightClick () const override {
        return WallpaperEngine::Input::Released;
    }
};

class SmokeOutput final : public Output {
public:
    SmokeOutput (
        WallpaperEngine::Application::ApplicationContext& context,
        VideoDriver& driver, int width, int height
    ) : Output (context, driver) {
        m_fullWidth = width;
        m_fullHeight = height;
    }

    void reset () override { }
    [[nodiscard]] bool renderVFlip () const override { return false; }
    [[nodiscard]] bool renderMultiple () const override { return false; }
    [[nodiscard]] bool haveImageBuffer () const override { return false; }
    [[nodiscard]] void* getImageBuffer () const override { return nullptr; }
    [[nodiscard]] uint32_t getImageBufferSize () const override { return 0; }
    void updateRender () const override { }
};

class SmokeDriver final : public VideoDriver {
public:
    SmokeDriver (
        WallpaperApplication& app, MouseInput& mouse, int width, int height
    ) : VideoDriver (app, mouse), m_output (app.getContext (), *this, width, height),
        m_size (width, height) { }

    [[nodiscard]] Output& getOutput () override { return m_output; }
    [[nodiscard]] float getRenderTime () const override { return g_Time; }
    bool closeRequested () override { return false; }
    void resizeWindow (glm::ivec2 size) override { m_size = size; }
    void resizeWindow (glm::ivec4 bounds) override { m_size = { bounds.z, bounds.w }; }
    void showWindow () override { }
    void hideWindow () override { }
    [[nodiscard]] glm::ivec2 getFramebufferSize () const override { return m_size; }
    [[nodiscard]] uint32_t getFrameCounter () const override { return m_frame; }
    [[nodiscard]] void* getProcAddress (const char*) const override { return nullptr; }
    void dispatchEventQueue () override { ++m_frame; }

private:
    SmokeOutput m_output;
    glm::ivec2 m_size;
    uint32_t m_frame = 1;
};

class EmptyMediaSource final : public MediaSource {
public:
    EmptyMediaSource () : MediaSource (std::chrono::hours (24)) { }

protected:
    void performUpdate () override { }
};

class RenderResourceContextLease final {
public:
    explicit RenderResourceContextLease (const void* context)
        : m_context (context),
          m_generation (FrescoScene::registerRenderResourceContext (context)) { }

    ~RenderResourceContextLease () noexcept {
        glFinish ();
        bool completionSucceeded = glGetError () == GL_NO_ERROR;
        try {
            FrescoScene::clearRenderProgramCache (m_generation);
        } catch (...) {
            completionSucceeded = false;
        }
        FrescoScene::retireRenderResourceContext (
            m_context, completionSucceeded
        );
    }

    RenderResourceContextLease (const RenderResourceContextLease&) = delete;
    RenderResourceContextLease& operator= (
        const RenderResourceContextLease&
    ) = delete;

private:
    const void* m_context;
    FrescoScene::RenderResourceGeneration m_generation;
};

struct Framebuffer {
    GLuint framebuffer = 0;
    GLuint texture = 0;

    Framebuffer (int width, int height) {
        glGenFramebuffers (1, &framebuffer);
        glBindFramebuffer (GL_FRAMEBUFFER, framebuffer);
        glGenTextures (1, &texture);
        glBindTexture (GL_TEXTURE_2D, texture);
        glTexImage2D (
            GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0,
            GL_RGBA, GL_UNSIGNED_BYTE, nullptr
        );
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glFramebufferTexture2D (
            GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0
        );
        if (glCheckFramebufferStatus (GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            throw std::runtime_error ("output framebuffer is incomplete");
        }
    }

    ~Framebuffer () {
        glDeleteTextures (1, &texture);
        glDeleteFramebuffers (1, &framebuffer);
    }
};

void writePNG (
    const std::filesystem::path& path, const std::vector<uint8_t>& pixels,
    int width, int height
) {
    NSBitmapImageRep* image = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:nil
        pixelsWide:width
        pixelsHigh:height
        bitsPerSample:8
        samplesPerPixel:4
        hasAlpha:YES
        isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace
        bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
        bytesPerRow:width * 4
        bitsPerPixel:32];
    if (image == nil) {
        throw std::runtime_error ("cannot allocate PNG image");
    }

    uint8_t* destination = image.bitmapData;
    for (int y = 0; y < height; ++y) {
        const auto sourceOffset = static_cast<std::size_t> (height - y - 1) * width * 4;
        const auto destinationOffset = static_cast<std::size_t> (y) * width * 4;
        std::copy_n (
            pixels.data () + sourceOffset, static_cast<std::size_t> (width) * 4,
            destination + destinationOffset
        );
    }

    NSData* data = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (data == nil || ![data writeToFile:@(path.c_str ()) atomically:YES]) {
        throw std::runtime_error ("cannot write PNG image");
    }
}

std::unique_ptr<Container> createContainer (
    const std::filesystem::path& projectRoot,
    const std::filesystem::path& assetRoot
) {
    auto container = std::make_unique<Container> ();
    container->mount (projectRoot, "/");
    container->mount (projectRoot / "scene.pkg", "/");
    container->mount (assetRoot, "/");

    auto& virtualFiles = container->getVFS ();
    virtualFiles.add (
        "effects/wpenginelinux/bloomeffect.json",
        JSON {
            { "name", "camerabloom_wpengine_linux" },
            { "group", "wpengine_linux_camera" },
            { "dependencies", JSON::array () },
            { "passes", JSON::array ({
                {
                    { "material", "materials/util/downsample_quarter_bloom.json" },
                    { "target", "_rt_4FrameBuffer" },
                    { "bind", JSON::array ({ {
                        { "name", "_rt_FullFrameBuffer" }, { "index", 0 }
                    } }) }
                },
                {
                    { "material", "materials/util/downsample_eighth_blur_v.json" },
                    { "target", "_rt_8FrameBuffer" },
                    { "bind", JSON::array ({ {
                        { "name", "_rt_4FrameBuffer" }, { "index", 0 }
                    } }) }
                },
                {
                    { "material", "materials/util/blur_h_bloom.json" },
                    { "target", "_rt_Bloom" },
                    { "bind", JSON::array ({ {
                        { "name", "_rt_8FrameBuffer" }, { "index", 0 }
                    } }) }
                },
                {
                    { "material", "materials/util/combine.json" },
                    { "target", "_rt_FullFrameBuffer" },
                    { "bind", JSON::array ({
                        { { "name", "_rt_imageLayerComposite_-1_a" }, { "index", 0 } },
                        { { "name", "_rt_Bloom" }, { "index", 1 } }
                    }) }
                }
            }) }
        }
    );
    virtualFiles.add (
        "models/wpenginelinux.json",
        JSON { { "material", "materials/wpenginelinux.json" } }
    );
    virtualFiles.add (
        "materials/wpenginelinux.json",
        JSON {
            { "passes", JSON::array ({ {
                { "blending", "normal" },
                { "cullmode", "nocull" },
                { "depthtest", "disabled" },
                { "depthwrite", "disabled" },
                { "shader", "genericimage2" },
                { "textures", JSON::array ({ "_rt_FullFrameBuffer" }) }
            } }) }
        }
    );
    virtualFiles.add (
        "models/fresco_procedural_quad.json",
        JSON { { "material", "materials/fresco_procedural_quad.json" } }
    );
    virtualFiles.add (
        "materials/fresco_procedural_quad.json",
        JSON { { "passes", JSON::array () } }
    );
    virtualFiles.add (
        "shaders/commands/copy.frag",
        "uniform sampler2D g_Texture0;\n"
        "in vec2 v_TexCoord;\n"
        "void main () {\n"
        "out_FragColor = texture (g_Texture0, v_TexCoord);\n"
        "}\n"
    );
    virtualFiles.add (
        "shaders/commands/copy.vert",
        "in vec3 a_Position;\n"
        "in vec2 a_TexCoord;\n"
        "out vec2 v_TexCoord;\n"
        "void main () {\n"
        "gl_Position = vec4 (a_Position, 1.0);\n"
        "v_TexCoord = a_TexCoord;\n"
        "}\n"
    );

    Container assetFiles;
    assetFiles.mount (assetRoot, "/");
    std::string particleHelpers = assetFiles.readString ("shaders/common_particles.h");
    particleHelpers +=
        "\nvoid ComputeParticleTangents(in vec3 rotation, out mat3 rotationMatrix, "
        "out vec3 right, out vec3 up)\n"
        "{\n"
        "    ComputeParticleTangents(rotation, right, up);\n"
        "    rotationMatrix = mat3(right, up, cross(right, up));\n"
        "}\n"
        "void ComputeScreenRefractionTangents(in vec3 projectedPositionXYW, "
        "in mat3 rotationMatrix, out vec3 screenCoord, out vec4 screenTangents)\n"
        "{\n"
        "    ComputeScreenRefractionTangents(projectedPositionXYW, rotationMatrix[0], "
        "rotationMatrix[1], screenCoord, screenTangents);\n"
        "}\n";
    virtualFiles.add ("shaders/common_particles.h", particleHelpers);
    return container;
}

// The authored defaults from project.json, seeded the way RendererSession
// seeds them. Without these `engine.userProperties` is empty and every script
// comparing against one resolves its fallback branch.
WallpaperEngine::Audio::UserPropertyBatch projectUserProperties (const JSON& project) {
    WallpaperEngine::Audio::UserPropertyBatch batch;
    const auto general = project.find ("general");
    if (general == project.end () || !general->is_object ()) {
        return batch;
    }
    const auto properties = general->find ("properties");
    if (properties == general->end () || !properties->is_object ()) {
        return batch;
    }
    for (const auto& [key, property] : properties->items ()) {
        if (!property.is_object ()) {
            continue;
        }
        const auto value = property.find ("value");
        if (value == property.end ()) {
            continue;
        }
        if (value->is_boolean ()) {
            batch.values.insert_or_assign (key, value->get<bool> ());
        } else if (value->is_string ()) {
            batch.values.insert_or_assign (key, value->get<std::string> ());
        } else if (value->is_number ()) {
            const double numeric = value->get<double> ();
            if (std::isfinite (numeric)) {
                batch.values.insert_or_assign (key, numeric);
            }
        }
    }
    batch.received = batch.values.size ();
    return batch;
}

void render (
    const std::filesystem::path& projectRoot,
    const std::filesystem::path& assetRoot,
    const std::filesystem::path& outputPath,
    int frameCount,
    float spectrumValue
) {
    WallpaperEngine::Logging::Log::get ().addOutput (&std::cerr);
    WallpaperEngine::Logging::Log::get ().addError (&std::cerr);
    [NSApplication sharedApplication];
    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAOpenGLProfile,
        static_cast<NSOpenGLPixelFormatAttribute> (NSOpenGLProfileVersion4_1Core),
        NSOpenGLPFAAccelerated,
        NSOpenGLPFAColorSize,
        static_cast<NSOpenGLPixelFormatAttribute> (24),
        NSOpenGLPFAAlphaSize,
        static_cast<NSOpenGLPixelFormatAttribute> (8),
        static_cast<NSOpenGLPixelFormatAttribute> (0),
    };
    NSOpenGLPixelFormat* format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    NSOpenGLContext* glContext = [[NSOpenGLContext alloc] initWithFormat:format shareContext:nil];
    if (format == nil || glContext == nil) {
        throw std::runtime_error ("cannot create OpenGL 4.1 context");
    }
    [glContext makeCurrentContext];

    constexpr int width = 1280;
    constexpr int height = 720;
    Framebuffer output (width, height);
    glBindFramebuffer (GL_FRAMEBUFFER, output.framebuffer);
    glViewport (0, 0, width, height);
    glClearColor (1.0f, 0.0f, 1.0f, 1.0f);
    glClear (GL_COLOR_BUFFER_BIT);

    auto container = createContainer (projectRoot, assetRoot);
    const JSON projectJSON = JSON::parse (container->readString ("project.json"));
    WallpaperEngine::Data::Model::ProjectUniquePtr project;
    try {
        project = ProjectParser::parse (
            projectJSON,
            std::make_unique<WallpaperEngine::Assets::AssetLocator> (std::move (container))
        );
    } catch (const std::exception& error) {
        throw std::runtime_error ("project parsing failed: " + std::string (error.what ()));
    }

    WallpaperApplication app;
    auto& loadedProject = app.addBackground ("proof", std::move (project));
    app.setDestinationFramebuffer (output.framebuffer);

    StillMouse mouse;
    SmokeDriver driver (app, mouse, width, height);
    EmptyMediaSource media;
    auto renderContext = std::make_unique<WallpaperEngine::Render::RenderContext> (
        driver, app, media
    );
    RenderResourceContextLease resourceContextLease (renderContext.get ());
    AudioContext audio;
    std::array<float, 128> spectrum;
    spectrum.fill (spectrumValue);
    audio.getRecorder ().setSpectrum (spectrum);

    std::unique_ptr<WallpaperEngine::Render::Wallpapers::CScene> scene;
    try {
        scene = std::make_unique<WallpaperEngine::Render::Wallpapers::CScene> (
            *loadedProject.wallpaper,
            *renderContext,
            audio,
            WallpaperEngine::Render::WallpaperState::TextureUVsScaling::ZoomFillUVs,
            WallpaperEngine::Data::Assets::TextureFlags_ClampUVs
        );
    } catch (const std::exception& error) {
        throw std::runtime_error ("scene construction failed: " + std::string (error.what ()));
    }
    scene->getScriptEngine ().setInitialUserProperties (
        projectUserProperties (projectJSON)
    );
    scene->setDestinationFramebuffer (output.framebuffer);
    if (frameCount < 1 || frameCount > 3600) {
        throw std::runtime_error ("frame count must be between 1 and 3600");
    }
    for (int frame = 0; frame < frameCount; ++frame) {
        g_TimeLast = g_Time;
        g_Time += 1.0f / 60.0f;
        driver.dispatchEventQueue ();
        try {
            scene->render ({ 0, 0, width, height }, true);
        } catch (const std::exception& error) {
            throw std::runtime_error (
                "frame " + std::to_string (frame) + " failed: " + error.what ()
            );
        }
    }

    glBindFramebuffer (GL_FRAMEBUFFER, output.framebuffer);
    std::vector<uint8_t> pixels (static_cast<std::size_t> (width) * height * 4);
    glReadPixels (0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data ());
    const GLenum error = glGetError ();
    if (error != GL_NO_ERROR) {
        throw std::runtime_error ("OpenGL error after rendered frame: " + std::to_string (error));
    }

    uint8_t minimum = 255;
    uint8_t maximum = 0;
    const std::array<uint8_t, 4> firstPixel = {
        pixels[0], pixels[1], pixels[2], pixels[3]
    };
    std::size_t varyingPixels = 0;
    for (std::size_t offset = 0; offset < pixels.size (); offset += 4) {
        minimum = std::min ({ minimum, pixels[offset], pixels[offset + 1], pixels[offset + 2] });
        maximum = std::max ({ maximum, pixels[offset], pixels[offset + 1], pixels[offset + 2] });
        if (!std::equal (firstPixel.begin (), firstPixel.end (), pixels.begin () + offset)) {
            ++varyingPixels;
        }
    }
    writePNG (outputPath, pixels, width, height);
    if (minimum == maximum || varyingPixels == 0) {
        throw std::runtime_error (
            "renderer produced a uniform frame: range="
            + std::to_string (minimum) + '-' + std::to_string (maximum)
            + " varyingPixels=" + std::to_string (varyingPixels)
        );
    }

    const auto& scriptEngine = scene->getScriptEngine ();
    std::cout << "rendered=" << outputPath << " width=" << width << " height=" << height
              << " frames=" << frameCount << " range=" << static_cast<int> (minimum) << '-'
              << static_cast<int> (maximum) << " varyingPixels=" << varyingPixels
              << " scriptLayers=" << scriptEngine.layerCount ()
              << " scriptUpdates=" << scriptEngine.updateCount ()
              << " scriptTextChanges=" << scriptEngine.textChangeCount ()
              << " scriptErrors=" << scriptEngine.errorCount () << '\n';
}

}

int main (int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc < 4 || argc > 6) {
            std::cerr
                << "usage: fresco-scene-render-smoke PROJECT_ROOT ASSET_ROOT "
                   "OUTPUT.png [FRAMES] [SPECTRUM]\n";
            return 2;
        }
        try {
            const int frameCount = argc >= 5 ? std::stoi (argv[4]) : 120;
            const float spectrumValue = argc == 6 ? std::stof (argv[5]) : 0.0F;
            render (argv[1], argv[2], argv[3], frameCount, spectrumValue);
            return 0;
        } catch (const std::exception& error) {
            std::cerr << error.what () << '\n';
            return 1;
        }
    }
}
