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
#include "FrescoScene/SceneObjectModelTransform.h"
#include "FrescoScene/TextEffectRegistry.h"
#include "FrescoScene/TextEffectRenderer.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <variant>
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

// Media-driven layers stay inert unless something fires metadata and album-art
// listeners, so scenes with a media widget rendered clean here while breaking on
// a live desktop. Setting FRESCO_SCENE_SMOKE_MEDIA publishes one synthetic
// now-playing track on the first update, which is what those layers wait for.
class EmptyMediaSource final : public MediaSource {
public:
    EmptyMediaSource () : MediaSource (std::chrono::hours (24)) {
        const char* title = std::getenv ("FRESCO_SCENE_SMOKE_MEDIA");
        if (title == nullptr) {
            return;
        }
        m_publish = true;
        m_mediaInfo.playbackState = PlaybackState::Playing;
        m_mediaInfo.title = *title != '\0' ? title : "Smoke Track";
        m_mediaInfo.artist = "Smoke Artist";
        m_mediaInfo.album = "Smoke Album";
        m_mediaInfo.duration = 240.0;
        m_mediaInfo.position = 30.0;
        m_mediaInfo.available = true;
    }

protected:
    void performUpdate () override {
        if (!m_publish || m_published) {
            return;
        }
        m_published = true;
        this->fireMetadataListeners ();
        this->fireAlbumArtListeners ();
    }

private:
    bool m_publish = false;
    bool m_published = false;
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

// Composited text renderers are cached in a process-global map keyed by scene,
// and each one owns passes that release GL programs on destruction. Left in the
// map they are destroyed at `exit`, by which point the program cache's mutex has
// already been destroyed by static teardown and the process aborts. So the cache
// is dropped here while the context is still current, which is what
// `RendererSession::retireResources` does.
class TextEffectRendererLease final {
public:
    explicit TextEffectRendererLease (
        const WallpaperEngine::Render::Wallpapers::CScene* scene
    ) : m_scene (scene) { }

    ~TextEffectRendererLease () noexcept {
        try {
            FrescoScene::clearTextEffectRenderers (m_scene);
        } catch (...) { }
    }

    TextEffectRendererLease (const TextEffectRendererLease&) = delete;
    TextEffectRendererLease& operator= (const TextEffectRendererLease&) = delete;

private:
    const WallpaperEngine::Render::Wallpapers::CScene* m_scene;
};

int environmentDimension (const char* name, int fallback) {
    const char* raw = std::getenv (name);
    if (raw == nullptr) {
        return fallback;
    }
    const int parsed = std::atoi (raw);
    if (parsed < 1 || parsed > 16384) {
        throw std::runtime_error (
            std::string (name) + " must be between 1 and 16384"
        );
    }
    return parsed;
}

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

int g_traceFrame = -1;

// Watches one object's visible value and reports every write with its source,
// which attributes a value that a script sets but something later overwrites.
void watchObjectVisibility (
    const WallpaperEngine::Render::Wallpapers::CScene& scene
) {
    using namespace WallpaperEngine::Data::Model;

    const char* watched = std::getenv ("FRESCO_SCENE_VISIBILITY_WATCH");
    if (watched == nullptr) {
        return;
    }
    const int watchedId = std::atoi (watched);
    for (const auto* object : scene.getObjectsByRenderOrder ()) {
        if (object == nullptr || object->getObject ().id != watchedId) {
            continue;
        }
        const auto& model = object->getObject ();
        if (!model.is<Image> ()) {
            continue;
        }
        auto* value = model.as<Image> ()->visible->value.get ();
        static_cast<void> (value->listen (
            [watchedId] (const DynamicValue& updated, DynamicValue::UpdateSource source) {
                std::cout << "visibilityWatch frame=" << g_traceFrame
                          << " id=" << watchedId
                          << " bool=" << (updated.getBool () ? 1 : 0)
                          << " type=" << static_cast<int> (updated.getType ())
                          << " source=" << static_cast<int> (source) << '\n';
            }
        ));
    }
}

bool visibilityTraceEnabled () {
    return std::getenv ("FRESCO_SCENE_VISIBILITY_TRACE") != nullptr;
}

// Reports every frame in which an object's own visibility differs from the
// previous frame, which separates a value that settles from one that flips.
void traceVisibilityFlips (
    const WallpaperEngine::Render::Wallpapers::CScene& scene,
    int frame,
    const char* phase,
    std::map<int, bool>& previous
) {
    if (!visibilityTraceEnabled ()) {
        return;
    }
    for (const auto* object : scene.getObjectsByRenderOrder ()) {
        if (object == nullptr) {
            continue;
        }
        const auto& model = object->getObject ();
        const bool visible = FrescoScene::sceneObjectVisible (model);
        const auto prior = previous.find (model.id);
        if (prior != previous.end () && prior->second == visible) {
            continue;
        }
        if (prior != previous.end ()) {
            std::cout << "visibilityFlip frame=" << frame << " phase=" << phase
                      << " id=" << model.id << " own=" << (visible ? 1 : 0)
                      << " name=" << model.name << '\n';
        }
        previous.insert_or_assign (model.id, visible);
    }
}

// Reports what each text object's effect chain decided: whether it composited
// through TextEffectRenderer, fell back to direct glyphs, or was rejected, and
// which effect blocked it. The composited path is otherwise unobservable from a
// capture alone — a chain that silently falls back renders plausible text — so
// a test that means to cover compositing asserts on these lines rather than on
// pixels only. Off unless FRESCO_SCENE_TEXT_EFFECT_TRACE is set.
void traceTextEffectChains (
    const WallpaperEngine::Render::Wallpapers::CScene& scene
) {
    if (std::getenv ("FRESCO_SCENE_TEXT_EFFECT_TRACE") == nullptr) {
        return;
    }
    for (const auto& evidence : FrescoScene::textEffectChainEvidence (&scene)) {
        std::cout << "textEffectChain id=" << evidence.objectId
                  << " mode=" << FrescoScene::textEffectChainModeName (evidence.mode)
                  << " active=" << evidence.activeEffectIds.size ()
                  << " supported=" << evidence.supportedActiveEffects
                  << " blocking=" << evidence.blockingEffectIds.size ()
                  << " stage="
                  << FrescoScene::textEffectBlockerStageName (
                         evidence.firstBlockingStage
                     )
                  << " reason=" << evidence.reason << '\n';
    }
}

std::size_t compositedTextEffectChains (
    const WallpaperEngine::Render::Wallpapers::CScene& scene
) {
    const auto evidence = FrescoScene::textEffectChainEvidence (&scene);
    return static_cast<std::size_t> (std::count_if (
        evidence.begin (), evidence.end (), [] (const auto& entry) {
            return entry.mode == FrescoScene::TextEffectChainMode::composited;
        }
    ));
}

// Reports each rendered object's own and parent-resolved visibility, so a
// missing subject can be attributed to its own property, an ancestor, or
// neither. Off unless FRESCO_SCENE_VISIBILITY_TRACE is set.
void traceVisibility (const WallpaperEngine::Render::Wallpapers::CScene& scene) {
    using namespace WallpaperEngine::Data::Model;

    if (!visibilityTraceEnabled ()) {
        return;
    }
    for (const auto* object : scene.getObjectsByRenderOrder ()) {
        if (object == nullptr) {
            continue;
        }
        const auto& model = object->getObject ();
        const char* kind = model.is<Image> () ? "image"
            : model.is<Particle> ()           ? "particle"
            : model.is<Text> ()               ? "text"
            : model.is<Sound> ()              ? "sound"
                                              : "group";
        std::cout << "visibility id=" << model.id << " parent="
                  << (model.parent.has_value () ? std::to_string (*model.parent) : "-")
                  << " kind=" << kind
                  << " own=" << (FrescoScene::sceneObjectVisible (model) ? 1 : 0)
                  << " resolved="
                  << (FrescoScene::sceneObjectVisibleWithParents (scene, model) ? 1 : 0)
                  << " name=" << model.name;
        if (model.is<Image> ()) {
            std::cout << " value="
                      << static_cast<const void*> (
                             model.as<Image> ()->visible->value.get ()
                         );
        }
        std::cout << '\n';
    }
    const auto& scriptEngine = scene.getScriptEngine ();
    std::cout << "scriptCounts generic=" << scriptEngine.genericPropertyScriptCount ()
              << " property=" << scriptEngine.propertyScriptCount ()
              << " deferred=" << scriptEngine.deferredScriptCount ()
              << " genericUpdates=" << scriptEngine.genericPropertyScriptUpdateCount ()
              << " genericChanges=" << scriptEngine.genericPropertyScriptChangeCount ()
              << " genericErrors=" << scriptEngine.genericPropertyScriptErrorCount () << '\n';
    for (const auto& evidence : scriptEngine.genericPropertyScriptEvidence ()) {
        std::cout << "genericScript key=" << evidence.key
                  << " profile=" << evidence.profile
                  << " object=" << evidence.objectId
                  << " property=" << evidence.property
                  << " updates=" << evidence.updates
                  << " changes=" << evidence.changes << '\n';
    }
    for (const auto& evidence : scriptEngine.propertyScriptEvidence ()) {
        std::cout << "propertyScript key=" << evidence.key
                  << " profile=" << evidence.profile
                  << " object=" << evidence.objectId
                  << " property=" << evidence.property
                  << " value=" << (evidence.value ? 1 : 0)
                  << " initialized=" << (evidence.initialized ? 1 : 0)
                  << " updates=" << evidence.updates << '\n';
    }
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

    // Defaults match the scene's own 16:9. Override to reproduce defects that
    // only appear at a display aspect the scene has to be fitted into.
    const int width = environmentDimension ("FRESCO_SCENE_SMOKE_WIDTH", 1280);
    const int height = environmentDimension ("FRESCO_SCENE_SMOKE_HEIGHT", 720);
    Framebuffer output (width, height);
    glBindFramebuffer (GL_FRAMEBUFFER, output.framebuffer);
    glViewport (0, 0, width, height);
    glClearColor (1.0f, 0.0f, 1.0f, 1.0f);
    glClear (GL_COLOR_BUFFER_BIT);

    auto container = createContainer (projectRoot, assetRoot);
    const JSON projectJSON = JSON::parse (container->readString ("project.json"));

    // Text objects hand their effect chains to the registry while the project
    // parses, and `renderTextEffects` composites only for a scene the registry
    // owns. Without a session here the parse discards every chain and the
    // composited path is unreachable, which is how three defects lived in it
    // untested. Constructed before the parse and bound after the scene exists,
    // matching RendererSession.
    FrescoScene::TextEffectRegistrySession textEffectRegistry;
    textEffectRegistry.activate ();

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
    if (const char* filter = std::getenv ("FRESCO_SCENE_OBJECT_FILTER");
        filter != nullptr) {
        app.getContext ().settings.render.debug.objectFilter = std::atoi (filter);
    }
    if (const char* skipped = std::getenv ("FRESCO_SCENE_SKIP_OBJECTS");
        skipped != nullptr) {
        std::string list (skipped);
        std::size_t start = 0;
        while (start < list.size ()) {
            const auto end = list.find (',', start);
            app.getContext ().settings.render.debug.skipObjects.push_back (
                std::atoi (list.substr (start, end - start).c_str ())
            );
            if (end == std::string::npos) {
                break;
            }
            start = end + 1;
        }
    }
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
    textEffectRegistry.bindScene (scene.get ());
    TextEffectRendererLease textEffectRendererLease (scene.get ());
    const auto seededProperties = projectUserProperties (projectJSON);
    if (visibilityTraceEnabled ()) {
        std::cout << "seededUserProperties count=" << seededProperties.values.size ();
        const auto character = seededProperties.values.find ("character");
        if (character != seededProperties.values.end ()) {
            const auto* text = std::get_if<std::string> (&character->second);
            std::cout << " character=" << (text != nullptr ? *text : "(non-string)");
        }
        std::cout << '\n';
    }
    watchObjectVisibility (*scene);
    scene->getScriptEngine ().setInitialUserProperties (seededProperties);
    scene->setDestinationFramebuffer (output.framebuffer);
    if (frameCount < 1 || frameCount > 3600) {
        throw std::runtime_error ("frame count must be between 1 and 3600");
    }
    std::map<int, bool> visibilityHistory;
    for (int frame = 0; frame < frameCount; ++frame) {
        g_TimeLast = g_Time;
        g_Time += 1.0f / 60.0f;
        media.update ();
        driver.dispatchEventQueue ();
        g_traceFrame = frame;
        traceVisibilityFlips (*scene, frame, "pre", visibilityHistory);
        try {
            scene->render ({ 0, 0, width, height }, true);
            traceVisibilityFlips (*scene, frame, "post", visibilityHistory);
        } catch (const std::exception& error) {
            throw std::runtime_error (
                "frame " + std::to_string (frame) + " failed: " + error.what ()
            );
        }
    }

    traceVisibility (*scene);
    traceTextEffectChains (*scene);

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
              << " scriptErrors=" << scriptEngine.errorCount ()
              << " textEffectChains=" << compositedTextEffectChains (*scene) << '\n';
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
