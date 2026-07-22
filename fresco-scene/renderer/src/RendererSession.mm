/*
 * Fresco scene renderer session
 *
 * Copyright (C) 2026 astral (github.com/Astral1119)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version 3.
 */

#import <AppKit/AppKit.h>

#include "FrescoScene/RendererSession.h"
#include "FrescoScene/SceneScriptStoragePool.h"
#include "FrescoScene/RendererClock.h"
#include "FrescoScene/RenderProgramCache.h"
#include "FrescoScene/Camera2DControl.h"
#include "FrescoScene/DynamicValueAnimation.h"
#include "FrescoScene/EffectRenderEvidence.h"
#include "FrescoScene/SceneZoomControl.h"
#include "FrescoScene/SceneSoundCompatibility.h"
#include "FrescoScene/SceneSoundSemanticCapability.h"
#include "FrescoScene/SceneVideoTextureControlProvider.h"
#include "FrescoScene/SessionActivityGate.h"
#include "FrescoScene/TextEffectRegistry.h"
#include "FrescoScene/TextEffectRenderer.h"
#include "RenderSurface.h"
#include "RuntimeMediaSource.h"

#include "WallpaperEngine/Application/WallpaperApplication.h"
#include "WallpaperEngine/Assets/AssetLocator.h"
#include "WallpaperEngine/Data/JSON.h"
#include "WallpaperEngine/Data/Parsers/ProjectParser.h"
#include "WallpaperEngine/FileSystem/Container.h"
#include "WallpaperEngine/Input/MouseInput.h"
#include "WallpaperEngine/Media/MediaSource.h"
#include "WallpaperEngine/Render/Drivers/Output/Output.h"
#include "WallpaperEngine/Render/Drivers/VideoDriver.h"
#include "WallpaperEngine/Render/Objects/CParticle.h"
#include "WallpaperEngine/Render/RenderContext.h"
#include "WallpaperEngine/Render/Wallpapers/CScene.h"
#include "WallpaperEngine/VideoPlayback/MPV/GLPlayer.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

extern float g_Time;
extern float g_TimeLast;

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

template<typename Values>
std::uint64_t floatArrayHash (const Values& values) {
    std::uint64_t hash = 1469598103934665603ULL;
    for (const float value : values) {
        std::uint32_t bits = 0;
        std::memcpy (&bits, &value, sizeof (bits));
        for (unsigned shift = 0; shift < 32; shift += 8) {
            hash ^= static_cast<std::uint8_t> (bits >> shift);
            hash *= 1099511628211ULL;
        }
    }
    return hash;
}

std::uint64_t spectrumHash (const std::array<float, 128>& values) {
    return floatArrayHash (values);
}

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

class WindowOutput final : public Output {
public:
    WindowOutput (
        WallpaperEngine::Application::ApplicationContext& context,
        VideoDriver& driver, int width, int height
    ) : Output (context, driver) {
        m_fullWidth = width;
        m_fullHeight = height;
    }

    void reset () override { }
    [[nodiscard]] bool renderVFlip () const override { return true; }
    [[nodiscard]] bool renderMultiple () const override { return false; }
    [[nodiscard]] bool haveImageBuffer () const override { return false; }
    [[nodiscard]] void* getImageBuffer () const override { return nullptr; }
    [[nodiscard]] uint32_t getImageBufferSize () const override { return 0; }
    void updateRender () const override { }
};

class WindowDriver final : public VideoDriver {
public:
    WindowDriver (
        WallpaperApplication& app, MouseInput& mouse,
        FrescoScene::RenderSurface& surface, int width, int height
    ) : VideoDriver (app, mouse), m_output (app.getContext (), *this, width, height),
        m_surface (surface), m_size (width, height) { }

    [[nodiscard]] Output& getOutput () override { return m_output; }
    [[nodiscard]] float getRenderTime () const override { return g_Time; }
    bool closeRequested () override { return false; }
    void resizeWindow (glm::ivec2 size) override { m_size = size; }
    void resizeWindow (glm::ivec4 bounds) override { m_size = { bounds.z, bounds.w }; }
    void showWindow () override { }
    void hideWindow () override { }
    [[nodiscard]] glm::ivec2 getFramebufferSize () const override { return m_size; }
    [[nodiscard]] uint32_t getFrameCounter () const override { return m_frame; }
    [[nodiscard]] void* getProcAddress (const char* name) const override {
        return m_surface.getProcAddress (name);
    }
    void dispatchEventQueue () override { ++m_frame; }

private:
    WindowOutput m_output;
    FrescoScene::RenderSurface& m_surface;
    glm::ivec2 m_size;
    uint32_t m_frame = 1;
};

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

struct SoundVolumeSetting {
    float fallback = 1.0F;
    std::optional<std::string> userKey;
};

SoundVolumeSetting soundVolume (const JSON& object) {
    const auto volume = object.find ("volume");
    if (volume == object.end ()) {
        return {};
    }
    if (volume->is_number ()) {
        const double value = volume->get<double> ();
        return {
            .fallback = std::isfinite (value) ? static_cast<float> (
                std::clamp (value, 0.0, 1.0)
            ) : 1.0F,
        };
    }
    if (volume->is_object ()) {
        const auto value = volume->find ("value");
        const auto user = volume->find ("user");
        SoundVolumeSetting result;
        if (value != volume->end () && value->is_number ()) {
            const double fallback = value->get<double> ();
            if (std::isfinite (fallback)) {
                result.fallback = static_cast<float> (
                    std::clamp (fallback, 0.0, 1.0)
                );
            }
        }
        if (user != volume->end () && user->is_string ()) {
            result.userKey = user->get<std::string> ();
        }
        return result;
    }
    return {};
}

std::map<std::string, WallpaperEngine::Audio::UserPropertyScalar>
projectUserProperties (const JSON& project) {
    std::map<std::string, WallpaperEngine::Audio::UserPropertyScalar> result;
    const auto general = project.find ("general");
    if (general == project.end () || !general->is_object ()) {
        return result;
    }
    const auto properties = general->find ("properties");
    if (properties == general->end () || !properties->is_object ()) {
        return result;
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
            result.insert_or_assign (key, value->get<bool> ());
        } else if (value->is_string ()) {
            result.insert_or_assign (key, value->get<std::string> ());
        } else if (value->is_number ()) {
            const double numeric = value->get<double> ();
            if (std::isfinite (numeric)) {
                result.insert_or_assign (key, numeric);
            }
        }
    }
    return result;
}

std::vector<WallpaperEngine::Audio::SoundMetadata> soundMetadata (const JSON& scene) {
    std::vector<WallpaperEngine::Audio::SoundMetadata> result;
    const auto objects = scene.find ("objects");
    if (objects == scene.end () || !objects->is_array ()) {
        return result;
    }
    std::vector<FrescoScene::SoundControllerCapability> controllers;
    for (const auto& object : *objects) {
        if (!object.is_object ()) {
            continue;
        }
        const auto visible = object.find ("visible");
        if (visible == object.end () || !visible->is_object ()) {
            continue;
        }
        const auto script = visible->find ("script");
        const auto value = visible->find ("value");
        if (script == visible->end () || !script->is_string ()
            || value == visible->end () || !value->is_boolean ()) {
            continue;
        }
        if (auto capability = FrescoScene::parseSoundControllerCapability (
                script->get<std::string> ()
            )) {
            controllers.push_back (std::move (*capability));
        }
    }
    std::vector<std::string> soundLayerNames;
    for (const auto& object : *objects) {
        const auto sounds = object.find ("sound");
        const auto id = object.find ("id");
        if (sounds != object.end () && sounds->is_array ()
            && id != object.end () && id->is_number_integer ()) {
            soundLayerNames.push_back (object.value ("name", std::string ()));
        }
    }
    std::size_t soundLayerIndex = 0;
    for (std::size_t index = 0; index < objects->size (); ++index) {
        const auto& object = (*objects)[index];
        const auto sounds = object.find ("sound");
        const auto id = object.find ("id");
        if (sounds == object.end () || !sounds->is_array ()
            || id == object.end () || !id->is_number_integer ()) {
            continue;
        }
        const SoundVolumeSetting volume = soundVolume (object);
        const std::string name = object.value ("name", std::string ());
        const bool forceSilent = FrescoScene::forceStartSilent (
            soundLayerIndex++, soundLayerNames, controllers
        );
        result.push_back ({
            .id = id->get<int> (),
            .name = name,
            .startSilent = forceSilent
                || object.value ("startsilent", false),
            .volume = volume.fallback,
            .layerIndex = index,
            .volumeUserKey = volume.userKey,
            .volumeFallback = volume.fallback,
        });
    }
    return result;
}

WallpaperEngine::Audio::UserPropertyBatch audioUserProperties (
    const AudioContext& audio,
    const WallpaperEngine::Audio::UserPropertyBatch& properties
) {
    WallpaperEngine::Audio::UserPropertyBatch result;
    for (const auto& [key, value] : properties.values) {
        if (audio.hasSoundVolumeProperty (key)) {
            result.values.insert_or_assign (key, value);
            ++result.received;
        }
    }
    return result;
}

std::optional<double> normalizedNumber (
    const WallpaperEngine::Audio::UserPropertyScalar& value
) {
    if (const auto* number = std::get_if<double> (&value)) {
        return std::isfinite (*number) ? std::optional<double> (*number) : std::nullopt;
    }
    if (const auto* boolean = std::get_if<bool> (&value)) {
        return *boolean ? 1.0 : 0.0;
    }
    const auto* text = std::get_if<std::string> (&value);
    if (text == nullptr || text->empty ()) {
        return std::nullopt;
    }
    char* end = nullptr;
    const double number = std::strtod (text->c_str (), &end);
    return end != text->c_str () && *end == '\0' && std::isfinite (number)
        ? std::optional<double> (number) : std::nullopt;
}

std::optional<std::string> normalizedScalarString (
    const WallpaperEngine::Audio::UserPropertyScalar& value
) {
    if (const auto* text = std::get_if<std::string> (&value)) {
        return *text;
    }
    if (const auto* boolean = std::get_if<bool> (&value)) {
        return *boolean ? "1" : "0";
    }
    const auto number = normalizedNumber (value);
    if (!number.has_value ()) {
        return std::nullopt;
    }
    std::ostringstream stream;
    stream << *number;
    return stream.str ();
}

bool validColor (std::string_view value) {
    std::istringstream stream { std::string (value) };
    double component = 0.0;
    std::size_t count = 0;
    while (stream >> component) {
        if (!std::isfinite (component) || component < 0.0 || component > 1.0) {
            return false;
        }
        ++count;
    }
    return stream.eof () && (count == 3 || count == 4);
}

WallpaperEngine::Audio::UserPropertyBatch validatedProjectUserProperties (
    const WallpaperEngine::Audio::UserPropertyBatch& input,
    const JSON& definitions
) {
    WallpaperEngine::Audio::UserPropertyBatch result {
        .received = input.received,
        .ignored = input.ignored,
        .diagnostics = input.diagnostics,
    };
    constexpr std::size_t maximumDiagnostics = 16;
    auto reject = [&result] (const std::string& key, std::string_view reason) {
        ++result.ignored;
        if (result.diagnostics.size () < maximumDiagnostics) {
            result.diagnostics.push_back (
                "invalid project user property " + key + ": " + std::string (reason)
            );
        }
    };
    for (const auto& [key, value] : input.values) {
        const auto definition = definitions.find (key);
        if (definition == definitions.end () || !definition->is_object ()) {
            reject (key, "unknown key");
            continue;
        }
        const std::string type = definition->value ("type", std::string ());
        if (type == "bool") {
            if (const auto* boolean = std::get_if<bool> (&value)) {
                result.values.insert_or_assign (key, *boolean);
                continue;
            }
            const auto normalized = normalizedScalarString (value);
            if (normalized == "1" || normalized == "true") {
                result.values.insert_or_assign (key, true);
            } else if (normalized == "0" || normalized == "false") {
                result.values.insert_or_assign (key, false);
            } else {
                reject (key, "expected boolean");
            }
            continue;
        }
        if (type == "slider") {
            const auto number = normalizedNumber (value);
            const double minimum = definition->value ("min", -INFINITY);
            const double maximum = definition->value ("max", INFINITY);
            if (!number.has_value () || *number < minimum || *number > maximum) {
                reject (key, "expected finite in-range slider value");
            } else {
                result.values.insert_or_assign (key, *number);
            }
            continue;
        }
        if (type == "combo") {
            const auto normalized = normalizedScalarString (value);
            bool found = false;
            if (normalized.has_value () && definition->contains ("options")
                && (*definition)["options"].is_array ()) {
                found = std::ranges::any_of (
                    (*definition)["options"], [&normalized] (const auto& option) {
                        return option.is_object ()
                            && option.value ("value", std::string ()) == *normalized;
                    }
                );
            }
            if (!found) {
                reject (key, "unknown combo option");
            } else {
                result.values.insert_or_assign (key, *normalized);
            }
            continue;
        }
        if (type == "color") {
            const auto* color = std::get_if<std::string> (&value);
            if (color == nullptr || !validColor (*color)) {
                reject (key, "expected three or four normalized color components");
            } else {
                result.values.insert_or_assign (key, *color);
            }
            continue;
        }
        if (type == "textinput") {
            constexpr std::size_t maximumTextInputBytes = 4096;
            const auto* text = std::get_if<std::string> (&value);
            if (text == nullptr) {
                reject (key, "expected text");
            } else if (text->find ('\0') != std::string::npos) {
                reject (key, "text contains an embedded NUL");
            } else if (text->size () > maximumTextInputBytes) {
                reject (key, "text exceeds 4096 bytes");
            } else {
                result.values.insert_or_assign (key, *text);
            }
            continue;
        }
        reject (key, "unsupported property type");
    }
    return result;
}

WallpaperEngine::Audio::SoundPropertyEvidence completeUserPropertyEvidence (
    const AudioContext& audio,
    const WallpaperEngine::Scripting::ScriptEngine& scripts,
    const WallpaperEngine::Audio::UserPropertyBatch& properties,
    WallpaperEngine::Audio::SoundPropertyEvidence evidence
) {
    evidence.received = properties.received;
    evidence.ignored += properties.ignored;
    evidence.diagnostics.insert (
        evidence.diagnostics.end (),
        properties.diagnostics.begin (), properties.diagnostics.end ()
    );
    constexpr std::size_t maximumDiagnostics = 16;
    if (evidence.diagnostics.size () > maximumDiagnostics) {
        evidence.diagnostics.resize (maximumDiagnostics);
    }
    for (const auto& [key, value] : properties.values) {
        static_cast<void> (value);
        if (audio.hasSoundVolumeProperty (key)) {
            continue;
        }
        if (scripts.acceptsUserProperty (key)) {
            ++evidence.acceptedScriptProperties;
            evidence.queuedPropertyScripts += scripts.propertyScriptCount ();
            continue;
        }
        ++evidence.ignored;
        if (evidence.diagnostics.size () < maximumDiagnostics) {
            evidence.diagnostics.push_back ("unbound user property: " + key);
        }
    }
    return evidence;
}

std::vector<FrescoScene::SoundControlEvidence> soundControlEvidence (
    const AudioContext& audio
) {
    std::vector<FrescoScene::SoundControlEvidence> result;
    constexpr std::size_t maximumSoundLayers = 64;
    for (const auto& layer : audio.soundLayers ()) {
        if (result.size () == maximumSoundLayers) {
            break;
        }
        result.push_back ({
            .id = layer.definition.id,
            .name = layer.definition.name,
            .playing = layer.playing,
            .requestedPlaying = layer.requestedPlaying,
            .playerConstructed = layer.playerConstructed,
            .activeAsset = layer.activeAssetIndex.has_value ()
                    && *layer.activeAssetIndex < layer.definition.assets.size ()
                ? std::optional<std::string> (
                    layer.definition.assets[*layer.activeAssetIndex]
                )
                : std::nullopt,
            .error = layer.error,
            .playRequests = layer.playRequests,
            .pauseRequests = layer.pauseRequests,
            .stopRequests = layer.stopRequests,
        });
    }
    return result;
}

FrescoScene::ParticleRuntimeEvidence particleRuntimeEvidence (
    const WallpaperEngine::Render::Wallpapers::CScene& scene
) {
    FrescoScene::ParticleRuntimeEvidence result;
    result.stateHash = 1469598103934665603ULL;
    const auto mix = [&result] (std::uint64_t value) {
        result.stateHash ^= value;
        result.stateHash *= 1099511628211ULL;
    };
    for (const auto* object : scene.getObjectsByRenderOrder ()) {
        const auto* particle = dynamic_cast<const
            WallpaperEngine::Render::Objects::CParticle*> (object);
        if (particle == nullptr) {
            continue;
        }
        const auto evidence = particle->runtimeEvidence ();
        ++result.systems;
        if (result.systems == 1) {
            result.minimumSeed = evidence.seed;
            result.maximumSeed = evidence.seed;
        } else {
            result.minimumSeed = std::min (result.minimumSeed, evidence.seed);
            result.maximumSeed = std::max (result.maximumSeed, evidence.seed);
        }
        result.finiteSystems += evidence.finiteLifecycle ? 1 : 0;
        result.unknownSystems += evidence.finiteLifecycle ? 0 : 1;
        result.continuousRequired |= evidence.continuousRequired;
        result.quiescent &= evidence.quiescent;
        result.updates += evidence.updates;
        result.catchUpFrames += evidence.catchUpFrames;
        result.requestedMilliseconds += evidence.requestedMilliseconds;
        result.simulatedMilliseconds += evidence.simulatedMilliseconds;
        result.droppedMilliseconds += evidence.droppedMilliseconds;
        result.maximumRequestedMilliseconds = std::max (
            result.maximumRequestedMilliseconds,
            evidence.maximumRequestedMilliseconds
        );
        result.maximumSimulatedMilliseconds = std::max (
            result.maximumSimulatedMilliseconds,
            evidence.maximumSimulatedMilliseconds
        );
        result.emitted += evidence.emitted;
        result.live += evidence.live;
        result.peakLive += evidence.peakLive;
        result.poolCapacity += evidence.poolCapacity;
        result.poolResizes += evidence.poolResizes;
        result.resourceInitializations += evidence.resourceInitializations;
        mix (static_cast<std::uint32_t> (evidence.objectId));
        mix (evidence.stateHash);
    }
    return result;
}

void dispatchAppEvents () {
    while (NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                               untilDate:[NSDate distantPast]
                                                  inMode:NSDefaultRunLoopMode
                                                 dequeue:YES]) {
        [NSApp sendEvent:event];
    }
}

}

namespace FrescoScene {

std::optional<SceneScriptStoragePool::Lease> leaseScriptStorage (
    const RendererConfiguration &configuration
) {
    if (configuration.scriptStoragePool == nullptr) {
        return std::nullopt;
    }
    auto lease = configuration.scriptStoragePool->leaseCanonical (
        configuration.scriptStorageIdentity
    );
    if (!lease.has_value ()) {
        throw std::runtime_error (
            "renderer SceneScript storage identity is invalid or unavailable"
        );
    }
    return lease;
}

void validatePixelEvidenceRequests (const RendererConfiguration& configuration) {
    if (configuration.pixelProbes.size () > 16) {
        throw std::runtime_error ("renderer pixel probe count must not exceed 16");
    }
    if (configuration.pixelRegions.size () > 8) {
        throw std::runtime_error ("renderer pixel region count must not exceed 8");
    }
    std::unordered_set<std::string> identities;
    const auto validateIdentity = [&identities] (const std::string& identity) {
        if (identity.empty () || identity.size () > 64) {
            throw std::runtime_error (
                "renderer pixel evidence identities must contain 1 to 64 bytes"
            );
        }
        if (!identities.insert (identity).second) {
            throw std::runtime_error (
                "renderer pixel evidence identities must be unique"
            );
        }
    };
    for (const auto& probe : configuration.pixelProbes) {
        validateIdentity (probe.identity);
        if (probe.xMilli > 1000 || probe.yMilli > 1000) {
            throw std::runtime_error (
                "renderer pixel probe coordinates must be between 0 and 1000"
            );
        }
    }
    for (const auto& region : configuration.pixelRegions) {
        validateIdentity (region.identity);
        if (region.rightMilli > 1000 || region.topMilli > 1000
            || region.leftMilli >= region.rightMilli
            || region.bottomMilli >= region.topMilli) {
            throw std::runtime_error (
                "renderer pixel regions must be non-empty and within 0 to 1000"
            );
        }
    }
}

class RendererSession::Impl {
public:
    explicit Impl (const RendererConfiguration& configuration)
        : m_scriptStorageLease (leaseScriptStorage (configuration)),
          m_media (
              m_scriptStorageLease.has_value ()
                  ? &m_scriptStorageLease->storage ()
                  : nullptr
          ) {
        resetPuppetRenderEvidence ();
        if (configuration.width <= 0.0 || configuration.height <= 0.0) {
            throw std::runtime_error ("renderer window dimensions must be positive");
        }
        if (configuration.framesPerSecond < 1.0 || configuration.framesPerSecond > 240.0) {
            throw std::runtime_error ("renderer frame rate must be between 1 and 240 FPS");
        }
        if (configuration.evidenceFrames > 600) {
            throw std::runtime_error ("renderer evidence frame count must not exceed 600");
        }
        validatePixelEvidenceRequests (configuration);
        m_pixelProbeRequests = configuration.pixelProbes;
        m_pixelRegionRequests = configuration.pixelRegions;
        m_targetFPS = configuration.framesPerSecond;
        m_collectRenderDurationSamples = configuration.collectRenderDurationSamples;
        m_muted = true;
        m_audio.setMuted (true);
        m_frameInterval = std::chrono::microseconds (static_cast<int64_t> (
            std::llround (1'000'000.0 / m_targetFPS)
        ));

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        m_surface = createRenderSurface (
            configuration.backend,
            SurfaceConfiguration {
                .x = configuration.x,
                .y = configuration.y,
                .width = configuration.width,
                .height = configuration.height,
            }
        );
        m_width = m_surface->width ();
        m_height = m_surface->height ();
        const auto& backend = m_surface->identity ();
        m_evidence.backend = backend.id;
        m_evidence.graphicsAPI = backend.graphicsAPI;
        m_evidence.shaderTarget = backend.shaderTarget;
        const auto& display = m_surface->displayEvidence ();
        m_evidence.logicalWidth = display.logicalWidth;
        m_evidence.logicalHeight = display.logicalHeight;
        m_evidence.scaleMilli = display.scaleMilli;
        m_evidence.maximumRefreshMilliHertz =
            display.maximumRefreshMilliHertz;
        m_evidence.colorSpace = display.colorSpace;

        auto container = createContainer (configuration.projectRoot, configuration.assetRoot);
        const JSON projectJSON = JSON::parse (container->readString ("project.json"));
        m_projectPropertyDefinitions = projectJSON.value ("general", JSON::object ())
            .value ("properties", JSON::object ());
        const auto validatedInitialProperties = validatedProjectUserProperties (
            configuration.initialUserProperties, m_projectPropertyDefinitions
        );
        const std::string sceneFile = projectJSON.value ("file", "scene.json");
        const JSON sceneJSON = JSON::parse (container->readString (sceneFile));
        auto metadata = soundMetadata (sceneJSON);
        auto effectiveProperties = projectUserProperties (projectJSON);
        for (const auto& [key, value] : validatedInitialProperties.values) {
            effectiveProperties.insert_or_assign (key, value);
        }
        static_cast<void> (
            WallpaperEngine::Audio::resolveSoundMetadataVolumes (
                metadata, effectiveProperties
            )
        );
        m_audio.setSoundMetadata (std::move (metadata));
        auto initialAudioProperties = m_audio.setUserProperties (
            audioUserProperties (m_audio, validatedInitialProperties)
        );
        m_evidence.soundVolumeBindings = m_audio.soundVolumeBindingCount ();
        m_evidence.soundVolumeProperties = m_audio.soundVolumePropertyCount ();
        ScopedRendererClockActivation clockActivation (m_clock);
        m_textEffectRegistry.activate ();
        FrescoScene::clearPendingCamera2DControls ();
        FrescoScene::clearPendingSceneZoom ();
        try {
        auto project = ProjectParser::parse (
            projectJSON,
            std::make_unique<WallpaperEngine::Assets::AssetLocator> (std::move (container))
        );
        auto& loadedProject = m_app.addBackground ("desktop", std::move (project));
        m_app.setDestinationFramebuffer (0);
        m_driver = std::make_unique<WindowDriver> (
            m_app, m_mouse, *m_surface, m_width, m_height
        );
        m_renderContext = std::make_unique<WallpaperEngine::Render::RenderContext> (
            *m_driver, m_app, m_media
        );
        m_resourceGeneration = FrescoScene::registerRenderResourceContext (
            m_renderContext.get ()
        );
        m_mediaTextureHost = std::make_unique<
            WallpaperEngine::VideoPlayback::MPV::MediaTextureHost
        > (*m_renderContext);
        static bool injectedPreSceneConstructionFailure = false;
        const auto* preSceneFailureGeneration = std::getenv (
            "FRESCO_SCENE_TEST_FAIL_BEFORE_SCENE_CONSTRUCTION_ONCE"
        );
        if (preSceneFailureGeneration != nullptr
            && m_resourceGeneration == std::strtoull (
                preSceneFailureGeneration, nullptr, 10
            )
            && !injectedPreSceneConstructionFailure) {
            injectedPreSceneConstructionFailure = true;
            throw std::runtime_error (
                "injected failure before scene construction"
            );
        }
        m_scene = std::make_unique<WallpaperEngine::Render::Wallpapers::CScene> (
            *loadedProject.wallpaper,
            *m_renderContext,
            m_audio,
            WallpaperEngine::Render::WallpaperState::TextureUVsScaling::ZoomFillUVs,
            WallpaperEngine::Data::Assets::TextureFlags_ClampUVs
        );
        m_textEffectRegistry.bindScene (m_scene.get ());
        m_evidence.initialUserProperties = completeUserPropertyEvidence (
            m_audio, m_scene->getScriptEngine (),
            validatedInitialProperties, std::move (initialAudioProperties)
        );
        WallpaperEngine::Audio::UserPropertyBatch initialScriptProperties {
            .values = effectiveProperties,
            .received = effectiveProperties.size (),
        };
        m_scene->getScriptEngine ().setInitialUserProperties (
            initialScriptProperties
        );
        m_scene->setDestinationFramebuffer (0);
        setMuted (configuration.muted);

        const auto& authoredObjects = m_scene->getScene ().objects;
        m_hasParticleSystems = std::ranges::any_of (
            authoredObjects, [] (const auto& object) {
                return object->template is<WallpaperEngine::Data::Model::Particle> ();
            }
        );
        const bool particleOnlyScene = !authoredObjects.empty ()
            && std::ranges::all_of (
                authoredObjects, [] (const auto& object) {
                    return object->template is<WallpaperEngine::Data::Model::Particle> ();
                }
            );
        constexpr int standardEvidenceFrames = 2;
        constexpr int particleEvidenceFrames = 60;
        const uint32_t evidenceFrames = configuration.evidenceFrames != 0
            ? configuration.evidenceFrames
            : particleOnlyScene ? particleEvidenceFrames : standardEvidenceFrames;
        for (uint32_t frame = 1; frame <= evidenceFrames; ++frame) {
            static_cast<void> (renderFrame (frame == evidenceFrames));
        }
        static bool injectedConstructionFailure = false;
        const auto* postTextFailureGeneration = std::getenv (
            "FRESCO_SCENE_TEST_FAIL_AFTER_TEXT_EFFECT_RENDER_ONCE"
        );
        if (postTextFailureGeneration != nullptr
            && m_resourceGeneration == std::strtoull (
                postTextFailureGeneration, nullptr, 10
            )
            && !injectedConstructionFailure) {
            injectedConstructionFailure = true;
            throw std::runtime_error (
                "injected failure after text effect evidence render"
            );
        }
        setVisible (configuration.visible);
        m_evidence.ordered = m_surface->ordered ();
        m_evidence.windowLevel = m_surface->windowLevel ();
        } catch (...) {
            retireResources ();
            throw;
        }
    }

    ~Impl () noexcept {
        try {
            ScopedRendererClockActivation clockActivation (m_clock);
            retireResources ();
        } catch (...) {
            retireResources ();
        }
    }

    void retireResources () noexcept {
        bool completionSucceeded = false;
        if (m_resourceGeneration != 0) {
            try {
                m_surface->makeCurrent ();
                m_surface->completeFrame (true);
                completionSucceeded = true;
            } catch (...) { }
        }
        try { FrescoScene::clearTextEffectRenderers (m_scene.get ()); } catch (...) { }
        try {
            FrescoScene::clearRenderProgramCache (m_resourceGeneration);
        } catch (...) { }
        try { m_scene.reset (); } catch (...) { }
        try { FrescoScene::clearPendingCamera2DControls (); } catch (...) { }
        try { FrescoScene::clearPendingSceneZoom (); } catch (...) { }
        if (m_renderContext != nullptr && m_resourceGeneration != 0) {
            FrescoScene::retireRenderResourceContext (
                m_renderContext.get (), completionSucceeded
            );
            m_resourceGeneration = 0;
        }
        try { m_renderContext.reset (); } catch (...) { }
        try { m_mediaTextureHost.reset (); } catch (...) { }
        try { m_driver.reset (); } catch (...) { }
        try { m_surface.reset (); } catch (...) { }
    }

    FrameRenderResult renderFrame (bool captureEvidence = false) {
        dispatchAppEvents ();
        if (!m_activity.active () || m_scene == nullptr) {
            return FrameRenderResult::suppressedBeforePresentation;
        }
        if (m_trackedMediaLifecycle
            && !m_mediaTextureHost->hasPendingFrames ()) {
            const auto media = m_mediaTextureHost->metrics ();
            return media.players > 0
                    && media.endOfStreamPlayers == media.players
                ? FrameRenderResult::terminallySuppressedBeforePresentation
                : FrameRenderResult::suppressedBeforePresentation;
        }
        const std::size_t mediaUploadsBefore
            = m_mediaTextureHost->metrics ().frameUploads;
        ScopedRendererClockActivation clockActivation (m_clock);
        const auto frameStart = std::chrono::steady_clock::now ();
        if (m_havePreviousFrame) {
            const double interval = std::chrono::duration<double, std::milli> (
                frameStart - m_previousFrameStart
            ).count ();
            m_totalFrameIntervalMilliseconds += interval;
            m_maximumFrameIntervalMilliseconds = std::max (
                m_maximumFrameIntervalMilliseconds, interval
            );
            ++m_measuredFrameIntervals;
            if (interval > 1.5 * std::chrono::duration<double, std::milli> (m_frameInterval).count ()) {
                ++m_missedFrameIntervals;
            }
        }
        m_previousFrameStart = frameStart;
        m_havePreviousFrame = true;
        m_surface->makeCurrent ();
        g_TimeLast = g_Time;
        g_Time += static_cast<float> (1.0 / m_targetFPS);
        m_audio.updatePlayback ();
        m_driver->dispatchEventQueue ();
        FrescoScene::beginEffectRenderFrame ();
        m_scene->render ({ 0, 0, m_width, m_height }, true);
        if (m_hasParticleSystems) {
            ++m_particleSimulationSteps;
        }
        m_surface->completeFrame (!m_evidence.drawComplete);
        m_evidence.drawComplete = true;
        if (captureEvidence) {
            captureFirstFrame ();
        }
        if (m_trackedMediaLifecycle
            && m_mediaTextureHost->metrics ().frameUploads
                == mediaUploadsBefore) {
            const auto media = m_mediaTextureHost->metrics ();
            return media.players > 0
                    && media.endOfStreamPlayers == media.players
                ? FrameRenderResult::terminallySuppressedBeforePresentation
                : FrameRenderResult::suppressedBeforePresentation;
        }
        m_surface->present ();
        const double renderMilliseconds = std::chrono::duration<double, std::milli> (
            std::chrono::steady_clock::now () - frameStart
        ).count ();
        if (m_collectRenderDurationSamples) {
            m_renderDurationSamplesMilliseconds.push_back (renderMilliseconds);
        }
        m_totalRenderMilliseconds += renderMilliseconds;
        m_maximumRenderMilliseconds = std::max (
            m_maximumRenderMilliseconds, renderMilliseconds
        );
        ++m_evidence.frames;
        return FrameRenderResult::presented;
    }

    MediaFramePreparationEvidence prepareMediaFrames () {
        return m_mediaTextureHost->prepareFrames ();
    }

    void setTrackedMediaLifecycle (bool tracked) {
        m_trackedMediaLifecycle = tracked;
    }

    std::size_t seekMediaTextures (double positionSeconds) {
        return m_mediaTextureHost->seek (positionSeconds);
    }

    void setFramesPerSecond (double framesPerSecond) {
        if (!std::isfinite (framesPerSecond)
            || framesPerSecond < 1.0 || framesPerSecond > 240.0) {
            throw std::runtime_error (
                "renderer frame rate must be between 1 and 240 FPS"
            );
        }
        m_targetFPS = framesPerSecond;
        m_frameInterval = std::chrono::microseconds (static_cast<int64_t> (
            std::llround (1'000'000.0 / m_targetFPS)
        ));
        m_havePreviousFrame = false;
    }

    FrameDifferenceEvidence captureFrameDifference () {
        m_lastDifference.presented
            = renderFrame (true) == FrameRenderResult::presented;
        return m_lastDifference;
    }

    void captureFirstFrame () {
        std::vector<uint8_t> pixels = m_surface->readFrontRGBA ();

        uint8_t minimum = 255;
        uint8_t maximum = 0;
        const std::array<uint8_t, 4> firstPixel = {
            pixels[0], pixels[1], pixels[2], pixels[3]
        };
        std::size_t varyingPixels = 0;
        uint64_t pixelRGBTotal = 0;
        uint64_t pixelRGBAHash = 1469598103934665603ULL;
        std::size_t changedPixels = 0;
        uint8_t maximumChannelDelta = 0;
        uint64_t totalChannelDelta = 0;
        for (std::size_t offset = 0; offset < pixels.size (); offset += 4) {
            for (std::size_t channel = 0; channel < 4; ++channel) {
                pixelRGBAHash = (pixelRGBAHash ^ pixels[offset + channel])
                    * 1099511628211ULL;
            }
            pixelRGBTotal += pixels[offset];
            pixelRGBTotal += pixels[offset + 1];
            pixelRGBTotal += pixels[offset + 2];
            minimum = std::min ({
                minimum, pixels[offset], pixels[offset + 1], pixels[offset + 2]
            });
            maximum = std::max ({
                maximum, pixels[offset], pixels[offset + 1], pixels[offset + 2]
            });
            if (!std::equal (
                firstPixel.begin (), firstPixel.end (), pixels.begin () + offset
            )) {
                ++varyingPixels;
            }
            bool pixelChanged = false;
            if (m_lastCapturedPixels.size () == pixels.size ()) {
                for (std::size_t channel = 0; channel < 3; ++channel) {
                    const uint8_t delta = static_cast<uint8_t> (std::abs (
                        static_cast<int> (pixels[offset + channel])
                        - static_cast<int> (m_lastCapturedPixels[offset + channel])
                    ));
                    pixelChanged = pixelChanged || delta != 0;
                    maximumChannelDelta = std::max (maximumChannelDelta, delta);
                    totalChannelDelta += delta;
                }
            }
            if (pixelChanged) {
                ++changedPixels;
            }
        }

        m_evidence.width = m_width;
        m_evidence.height = m_height;
        m_evidence.minimum = minimum;
        m_evidence.maximum = maximum;
        m_evidence.varyingPixels = varyingPixels;
        m_evidence.pixelRGBTotal = pixelRGBTotal;
        m_evidence.pixelRGBAHash = pixelRGBAHash;
        m_evidence.pixelProbes.clear ();
        m_evidence.pixelProbes.reserve (m_pixelProbeRequests.size ());
        for (const auto& request : m_pixelProbeRequests) {
            const int x = std::min (
                m_width - 1,
                static_cast<int> ((static_cast<std::uint64_t> (request.xMilli)
                    * static_cast<std::uint64_t> (m_width - 1) + 500) / 1000)
            );
            const int y = std::min (
                m_height - 1,
                static_cast<int> ((static_cast<std::uint64_t> (request.yMilli)
                    * static_cast<std::uint64_t> (m_height - 1) + 500) / 1000)
            );
            const std::size_t offset = 4 * (
                static_cast<std::size_t> (y) * static_cast<std::size_t> (m_width)
                + static_cast<std::size_t> (x)
            );
            m_evidence.pixelProbes.push_back ({
                .identity = request.identity,
                .xMilli = request.xMilli,
                .yMilli = request.yMilli,
                .x = x,
                .y = y,
                .rgba = { pixels[offset], pixels[offset + 1],
                          pixels[offset + 2], pixels[offset + 3] },
            });
        }
        m_evidence.pixelRegions.clear ();
        m_evidence.pixelRegions.reserve (m_pixelRegionRequests.size ());
        for (const auto& request : m_pixelRegionRequests) {
            const int left = static_cast<int> (
                static_cast<std::uint64_t> (request.leftMilli) * m_width / 1000
            );
            const int bottom = static_cast<int> (
                static_cast<std::uint64_t> (request.bottomMilli) * m_height / 1000
            );
            const int right = std::min (m_width, static_cast<int> (
                (static_cast<std::uint64_t> (request.rightMilli) * m_width + 999)
                    / 1000
            ));
            const int top = std::min (m_height, static_cast<int> (
                (static_cast<std::uint64_t> (request.topMilli) * m_height + 999)
                    / 1000
            ));
            std::uint64_t hash = 1469598103934665603ULL;
            std::uint64_t rgbTotal = 0;
            std::size_t varying = 0;
            std::array<std::uint8_t, 4> first {};
            bool haveFirst = false;
            for (int y = bottom; y < top; ++y) {
                for (int x = left; x < right; ++x) {
                    const std::size_t offset = 4 * (
                        static_cast<std::size_t> (y)
                            * static_cast<std::size_t> (m_width)
                        + static_cast<std::size_t> (x)
                    );
                    const std::array<std::uint8_t, 4> pixel {
                        pixels[offset], pixels[offset + 1],
                        pixels[offset + 2], pixels[offset + 3]
                    };
                    for (const auto channel : pixel) {
                        hash = (hash ^ channel) * 1099511628211ULL;
                    }
                    rgbTotal += pixel[0] + pixel[1] + pixel[2];
                    if (!haveFirst) {
                        first = pixel;
                        haveFirst = true;
                    } else if (pixel != first) {
                        ++varying;
                    }
                }
            }
            m_evidence.pixelRegions.push_back ({
                .identity = request.identity,
                .leftMilli = request.leftMilli,
                .bottomMilli = request.bottomMilli,
                .rightMilli = request.rightMilli,
                .topMilli = request.topMilli,
                .left = left,
                .bottom = bottom,
                .right = right,
                .top = top,
                .pixels = static_cast<std::size_t> (right - left)
                    * static_cast<std::size_t> (top - bottom),
                .varyingPixels = varying,
                .pixelRGBTotal = rgbTotal,
                .pixelRGBAHash = hash,
            });
        }
        m_evidence.effectRender = FrescoScene::effectRenderEvidence ();
        m_evidence.programCacheEntries = FrescoScene::renderProgramCache ().size (
            m_resourceGeneration
        );
        m_evidence.programCacheInsertions =
            FrescoScene::renderProgramCache ().insertions (
                m_resourceGeneration
            );
        m_evidence.resourceGeneration = m_resourceGeneration;
        m_evidence.resourceLifecycle = FrescoScene::renderResourceLifecycleEvidence ();
        m_evidence.textEffectChains = FrescoScene::textEffectChainEvidence (
            m_scene.get ()
        );
        const auto& scriptEngine = m_scene->getScriptEngine ();
        m_evidence.scriptLayers = scriptEngine.layerCount ();
        m_evidence.scriptUpdates = scriptEngine.updateCount ();
        m_evidence.scriptTextChanges = scriptEngine.textChangeCount ();
        m_evidence.mediaPropertyScripts = scriptEngine.mediaPropertyScriptCount ();
        m_evidence.mediaPropertyScriptDispatches
            = scriptEngine.mediaPropertyScriptDispatchCount ();
        m_evidence.mediaPlaybackScriptDispatches
            = scriptEngine.mediaPlaybackScriptDispatchCount ();
        m_evidence.mediaTimelineScriptDispatches
            = scriptEngine.mediaTimelineScriptDispatchCount ();
        m_evidence.mediaThumbnailScriptDispatches
            = scriptEngine.mediaThumbnailScriptDispatchCount ();
        m_evidence.mediaPropertyScriptErrors
            = scriptEngine.mediaPropertyScriptErrorCount ();
        m_evidence.scriptedDynamicFloats.clear ();
        for (const auto& dynamicFloat : scriptEngine.dynamicFloatEvidence ()) {
            m_evidence.scriptedDynamicFloats.push_back ({
                .key = dynamicFloat.key,
                .value = dynamicFloat.value,
                .updates = dynamicFloat.updates,
                .changes = dynamicFloat.changes,
            });
        }
        m_evidence.scriptedDynamicFloatUpdates
            = scriptEngine.dynamicFloatUpdateCount ();
        m_evidence.scriptedDynamicFloatChanges
            = scriptEngine.dynamicFloatChangeCount ();
        m_evidence.scriptErrors = scriptEngine.errorCount ();
        m_evidence.propertyScripts.clear ();
        for (const auto& script : scriptEngine.propertyScriptEvidence ()) {
            m_evidence.propertyScripts.push_back ({
                .key = script.key,
                .profile = script.profile,
                .objectId = script.objectId,
                .property = script.property,
                .value = script.value,
                .initialized = script.initialized,
                .seededDelaySeconds = script.seededDelaySeconds,
                .targetDelaySeconds = script.targetDelaySeconds,
                .propertyApplications = script.propertyApplications,
                .updates = script.updates,
            });
        }
        m_evidence.propertyScriptControllers = m_evidence.propertyScripts.size ();
        m_evidence.propertyScriptInitializations
            = scriptEngine.propertyScriptInitializationCount ();
        m_evidence.propertyScriptPropertyApplications
            = scriptEngine.propertyScriptPropertyApplicationCount ();
        m_evidence.propertyScriptUpdates
            = scriptEngine.propertyScriptUpdateCount ();
        m_evidence.propertyScriptErrors
            = scriptEngine.propertyScriptErrorCount ();
        m_evidence.genericPropertyScripts
            = scriptEngine.genericPropertyScriptCount ();
        m_evidence.continuousGenericPropertyScripts
            = scriptEngine.continuousGenericPropertyScriptCount ();
        m_evidence.genericPropertyScriptUpdates
            = scriptEngine.genericPropertyScriptUpdateCount ();
        m_evidence.genericPropertyScriptChanges
            = scriptEngine.genericPropertyScriptChangeCount ();
        m_evidence.genericPropertyScriptErrors
            = scriptEngine.genericPropertyScriptErrorCount ();
        m_evidence.audioVectorScripts = scriptEngine.audioVectorScriptCount ();
        m_evidence.exactTrackedAudioVectorScripts
            = scriptEngine.exactTrackedAudioVectorScriptCount ();
        m_evidence.audioVectorValueX
            = scriptEngine.audioVectorValueX ().value_or (0.0F);
        m_evidence.audioVectorScriptUpdates
            = scriptEngine.audioVectorScriptUpdateCount ();
        m_evidence.audioVectorScriptChanges
            = scriptEngine.audioVectorScriptChangeCount ();
        m_evidence.namedAnimationTargetPlays
            = scriptEngine.namedAnimationTargetPlayCount ();
        m_evidence.namedAnimationActive
            = scriptEngine.namedAnimationActiveCount ();
        m_evidence.namedAnimationFrameTotal
            = scriptEngine.namedAnimationFrameTotal ();
        const auto camera2D = FrescoScene::camera2DControlEvidence (*m_scene);
        m_evidence.camera2DActive = camera2D.active;
        m_evidence.camera2DCenterX = camera2D.center.x;
        m_evidence.camera2DCenterY = camera2D.center.y;
        m_evidence.camera2DZoom = camera2D.zoom;
        const auto sceneZoom = FrescoScene::sceneZoomEvidence (*m_scene);
        m_evidence.sceneZoomActive = sceneZoom.active;
        m_evidence.sceneZoom = sceneZoom.zoom;
        m_evidence.cursorScripts = scriptEngine.cursorScriptCount ();
        m_evidence.deferredScriptValues = scriptEngine.deferredScriptCount ();
        m_evidence.scriptTimers = scriptEngine.timerEvidence ();
        m_evidence.scriptTimeMilliseconds
            = m_evidence.scriptTimers.currentTimeMilliseconds.value_or (
                m_scene->getTime () * 1000.0
            );
        m_evidence.soundControls = soundControlEvidence (m_audio);
        m_lastDifference = FrameDifferenceEvidence {
            .frame = m_evidence,
            .changedPixels = changedPixels,
            .maximumChannelDelta = maximumChannelDelta,
            .totalChannelDelta = totalChannelDelta,
        };
        m_lastCapturedPixels = std::move (pixels);
    }

    void setVisible (bool visible) {
        ScopedRendererClockActivation clockActivation (m_clock);
        m_surface->setVisible (visible);
        applyActivityUpdate (m_activity.setVisible (visible));
    }

    void setPaused (bool paused) {
        ScopedRendererClockActivation clockActivation (m_clock);
        applyActivityUpdate (m_activity.setPaused (paused));
    }

    void applyActivityUpdate (const SessionActivityUpdate& update) {
        if (update.transition == SessionActivityTransition::unchanged) {
            return;
        }
        m_mediaTextureHost->setVisible (update.active);
        m_mediaTextureHost->setPaused (!update.active);
        if (!update.active) {
            m_audio.pauseAllSounds ();
        } else {
            m_scene->getScriptEngine ().applyPendingUserProperties ();
            m_audio.resumeAllSounds ();
        }
        m_havePreviousFrame = false;
    }

    void setMuted (bool muted) {
        if (m_muted == muted) {
            return;
        }
        m_muted = muted;
        m_audio.setMuted (muted);
    }

    AudioSpectrumApplicationEvidence setAudioSpectrum (
        const std::array<float, 128>& spectrum
    ) {
        ++m_audioSpectrumInputs;
        const std::uint64_t nextHash = spectrumHash (spectrum);
        const bool changed = nextHash != m_audioSpectrumHash;
        auto& recorder = m_audio.getRecorder ();
        if (changed) {
            recorder.setSpectrum (spectrum);
            m_audioSpectrumHash = nextHash;
            ++m_audioSpectrumChanges;
        }
        const std::uint64_t leftHash = floatArrayHash (recorder.audio16Left);
        const std::uint64_t rightHash = floatArrayHash (recorder.audio16Right);
        m_audioVectorHash = leftHash ^ (rightHash * 1099511628211ULL);
        m_audioVectorAverage0 = (
            recorder.audio16Left[0] + recorder.audio16Right[0]
        ) * 0.5;
        return {
            .changed = changed,
            .inputs = m_audioSpectrumInputs,
            .changes = m_audioSpectrumChanges,
            .spectrumHash = m_audioSpectrumHash,
            .vectorHash = m_audioVectorHash,
            .vectorAverage0 = m_audioVectorAverage0,
        };
    }

    void setTrackedAudioLifecycle (bool tracked) {
        m_trackedAudioLifecycle = tracked;
    }

    [[nodiscard]] MediaSessionEvidence setMediaSession (
        const MediaSessionEvent& event
    ) {
        ScopedRendererClockActivation clockActivation (m_clock);
        m_surface->makeCurrent ();
        const MediaSessionChange changes = m_media.apply (event);
        const auto& snapshot = m_media.snapshot ();
        const auto& artwork = m_media.artwork ();
        if (contains (changes, MediaSessionChange::properties)) {
            m_scene->getScriptEngine ().setMediaProperties (
                snapshot.title, snapshot.artist, snapshot.album
            );
        }
        if (contains (changes, MediaSessionChange::playback)) {
            m_scene->getScriptEngine ().mediaPlaybackChanged (
                static_cast<int> (snapshot.playback)
            );
        }
        if (contains (changes, MediaSessionChange::timeline)) {
            m_scene->getScriptEngine ().mediaTimelineChanged (
                snapshot.positionSeconds, snapshot.durationSeconds
            );
        }
        if (contains (changes, MediaSessionChange::thumbnail)) {
            const MediaThumbnail emptyThumbnail;
            const auto& thumbnail = snapshot.thumbnail.has_value ()
                ? *snapshot.thumbnail : emptyThumbnail;
            m_scene->getScriptEngine ().mediaThumbnailChanged (
                thumbnail.primaryColor, thumbnail.secondaryColor,
                thumbnail.tertiaryColor, thumbnail.textColor,
                thumbnail.highContrastColor
            );
        }
        return {
            .events = m_media.evidence ().events,
            .revision = snapshot.revision,
            .available = snapshot.available,
            .playback = snapshot.playback,
            .hasThumbnail = snapshot.thumbnail.has_value (),
            .artworkReady = artwork.current != nullptr,
            .artworkRevision = artwork.revision,
            .artworkRGBAHash = [&artwork] {
                if (artwork.current == nullptr) {
                    return uint64_t {0};
                }
                uint64_t hash = 1469598103934665603ULL;
                for (const uint8_t channel : artwork.current->rgba) {
                    hash = (hash ^ channel) * 1099511628211ULL;
                }
                return hash;
            } (),
            .artworkError = mediaArtworkErrorName (artwork.lastError.code),
        };
    }

    bool cursorClick (
        int objectId, std::optional<double> monotonicMilliseconds
    ) {
        ScopedRendererClockActivation clockActivation (m_clock);
        return m_scene != nullptr
            && m_scene->getScriptEngine ().cursorClick (
                objectId, monotonicMilliseconds
            );
    }

    std::size_t cursorEvent (std::string_view name, float x, float y) {
        ScopedRendererClockActivation clockActivation (m_clock);
        return m_scene == nullptr ? 0
                                  : m_scene->getScriptEngine ().cursorEvent (name, x, y);
    }

    [[nodiscard]] WallpaperEngine::Audio::SoundPropertyEvidence setUserProperties (
        const WallpaperEngine::Audio::UserPropertyBatch& properties
    ) {
        ScopedRendererClockActivation clockActivation (m_clock);
        const auto validated = validatedProjectUserProperties (
            properties, m_projectPropertyDefinitions
        );
        m_scene->getScriptEngine ().setUserProperties (validated);
        if (m_activity.active ()) {
            m_scene->getScriptEngine ().applyPendingUserProperties ();
        }
        return completeUserPropertyEvidence (
            m_audio, m_scene->getScriptEngine (), validated,
            m_audio.setUserProperties (audioUserProperties (m_audio, validated))
        );
    }

    [[nodiscard]] RendererMetrics metrics () const {
        const auto& scriptEngine = m_scene->getScriptEngine ();
        const auto scriptTimers = scriptEngine.timerEvidence ();
        const auto camera2D = FrescoScene::camera2DControlEvidence (*m_scene);
        auto mediaTextures = m_mediaTextureHost->metrics ();
        if (const auto videoControls
                = FrescoScene::sceneVideoTextureControlMetrics (m_scene.get ())) {
            mediaTextures.scriptControlledPlayers = videoControls->videoPlayers;
            mediaTextures.scriptPlayingPlayers
                = videoControls->requestedPlayingPlayers;
            mediaTextures.scriptPausedPlayers
                = videoControls->videoPlayers
                - std::min (
                    videoControls->videoPlayers,
                    videoControls->requestedPlayingPlayers
                );
        }
        return RendererMetrics {
            .backend = m_evidence.backend,
            .graphicsAPI = m_evidence.graphicsAPI,
            .shaderTarget = m_evidence.shaderTarget,
            .programCacheEntries = FrescoScene::renderProgramCache ().size (
                m_resourceGeneration
            ),
            .programCacheInsertions =
                FrescoScene::renderProgramCache ().insertions (
                    m_resourceGeneration
                ),
            .resourceGeneration = m_resourceGeneration,
            .resourceLifecycle = FrescoScene::renderResourceLifecycleEvidence (),
            .frames = m_evidence.frames,
            .targetFPS = m_targetFPS,
            .elapsedMilliseconds = std::chrono::duration<double, std::milli> (
                std::chrono::steady_clock::now () - m_createdAt
            ).count (),
            .averageFrameIntervalMilliseconds = m_measuredFrameIntervals == 0
                ? 0.0
                : m_totalFrameIntervalMilliseconds / m_measuredFrameIntervals,
            .maximumFrameIntervalMilliseconds = m_maximumFrameIntervalMilliseconds,
            .averageRenderMilliseconds = m_evidence.frames == 0
                ? 0.0
                : m_totalRenderMilliseconds / m_evidence.frames,
            .maximumRenderMilliseconds = m_maximumRenderMilliseconds,
            .renderDurationSamplesMilliseconds
                = m_collectRenderDurationSamples
                    ? m_renderDurationSamplesMilliseconds
                    : std::vector<double> {},
            .renderAllocations = FrescoScene::renderAllocationEvidence (),
            .effectRender = FrescoScene::effectRenderEvidence (),
            .missedFrameIntervals = m_missedFrameIntervals,
            .textEffectChains = FrescoScene::textEffectChainEvidence (m_scene.get ()),
            .scriptLayers = scriptEngine.layerCount (),
            .scriptUpdates = scriptEngine.updateCount (),
            .scriptTextChanges = scriptEngine.textChangeCount (),
            .mediaPropertyScripts = scriptEngine.mediaPropertyScriptCount (),
            .mediaPropertyScriptDispatches
                = scriptEngine.mediaPropertyScriptDispatchCount (),
            .mediaPlaybackScriptDispatches
                = scriptEngine.mediaPlaybackScriptDispatchCount (),
            .mediaTimelineScriptDispatches
                = scriptEngine.mediaTimelineScriptDispatchCount (),
            .mediaThumbnailScriptDispatches
                = scriptEngine.mediaThumbnailScriptDispatchCount (),
            .mediaPropertyScriptErrors
                = scriptEngine.mediaPropertyScriptErrorCount (),
            .scriptedDynamicFloats = [&scriptEngine] {
                std::vector<ScriptedDynamicFloatEvidence> result;
                for (const auto& dynamicFloat : scriptEngine.dynamicFloatEvidence ()) {
                    result.push_back ({
                        .key = dynamicFloat.key,
                        .value = dynamicFloat.value,
                        .updates = dynamicFloat.updates,
                        .changes = dynamicFloat.changes,
                    });
                }
                return result;
            } (),
            .scriptedDynamicFloatUpdates = scriptEngine.dynamicFloatUpdateCount (),
            .scriptedDynamicFloatChanges = scriptEngine.dynamicFloatChangeCount (),
            .scriptErrors = scriptEngine.errorCount (),
            .scriptStorageKeys = m_scriptStorageLease.has_value ()
                ? m_scriptStorageLease->storage ().keyCount ()
                : 0,
            .scriptStorageBytes = m_scriptStorageLease.has_value ()
                ? m_scriptStorageLease->storage ().byteSize ()
                : 0,
            .soundVolumeBindings = m_audio.soundVolumeBindingCount (),
            .soundVolumeProperties = m_audio.soundVolumePropertyCount (),
            .propertyScripts = [&scriptEngine] {
                std::vector<PropertyScriptEvidence> result;
                for (const auto& script : scriptEngine.propertyScriptEvidence ()) {
                    result.push_back ({
                        .key = script.key,
                        .profile = script.profile,
                        .objectId = script.objectId,
                        .property = script.property,
                        .value = script.value,
                        .initialized = script.initialized,
                        .seededDelaySeconds = script.seededDelaySeconds,
                        .targetDelaySeconds = script.targetDelaySeconds,
                        .propertyApplications = script.propertyApplications,
                        .updates = script.updates,
                    });
                }
                return result;
            } (),
            .propertyScriptControllers = scriptEngine.propertyScriptEvidence ().size (),
            .propertyScriptInitializations
                = scriptEngine.propertyScriptInitializationCount (),
            .propertyScriptPropertyApplications
                = scriptEngine.propertyScriptPropertyApplicationCount (),
            .propertyScriptUpdates = scriptEngine.propertyScriptUpdateCount (),
            .propertyScriptErrors = scriptEngine.propertyScriptErrorCount (),
            .genericPropertyScripts = scriptEngine.genericPropertyScriptCount (),
            .continuousGenericPropertyScripts
                = scriptEngine.continuousGenericPropertyScriptCount (),
            .genericPropertyScriptUpdates
                = scriptEngine.genericPropertyScriptUpdateCount (),
            .genericPropertyScriptChanges
                = scriptEngine.genericPropertyScriptChangeCount (),
            .genericPropertyScriptErrors
                = scriptEngine.genericPropertyScriptErrorCount (),
            .audioVectorScripts = scriptEngine.audioVectorScriptCount (),
            .exactTrackedAudioVectorScripts
                = scriptEngine.exactTrackedAudioVectorScriptCount (),
            .audioVectorValueX
                = scriptEngine.audioVectorValueX ().value_or (0.0F),
            .audioVectorScriptUpdates
                = scriptEngine.audioVectorScriptUpdateCount (),
            .audioVectorScriptChanges
                = scriptEngine.audioVectorScriptChangeCount (),
            .audioSpectrumInputs = m_audioSpectrumInputs,
            .audioSpectrumChanges = m_audioSpectrumChanges,
            .audioSpectrumHash = m_audioSpectrumHash,
            .audioVectorHash = m_audioVectorHash,
            .audioVectorAverage0 = m_audioVectorAverage0,
            .audioEnvelopeContinuousRequired = m_trackedAudioLifecycle
                && scriptEngine.audioVectorContinuousRequired (),
            .namedAnimationTargetPlays
                = scriptEngine.namedAnimationTargetPlayCount (),
            .namedAnimationActive
                = scriptEngine.namedAnimationActiveCount (),
            .automaticDynamicValueAnimations
                = FrescoScene::automaticDynamicValueAnimationCount (),
            .namedAnimationFrameTotal
                = scriptEngine.namedAnimationFrameTotal (),
            .camera2DActive = camera2D.active,
            .camera2DCenterX = camera2D.center.x,
            .camera2DCenterY = camera2D.center.y,
            .camera2DZoom = camera2D.zoom,
            .sceneZoomActive = FrescoScene::sceneZoomEvidence (*m_scene).active,
            .sceneZoom = FrescoScene::sceneZoomEvidence (*m_scene).zoom,
            .cursorScripts = scriptEngine.cursorScriptCount (),
            .deferredScriptValues = scriptEngine.deferredScriptCount (),
            .scriptTimers = scriptTimers,
            .scriptTimeMilliseconds
                = scriptTimers.currentTimeMilliseconds.value_or (
                    m_scene->getTime () * 1000.0
                ),
            .soundControls = soundControlEvidence (m_audio),
            .mediaTextures = mediaTextures,
            .particleSimulationSteps = m_particleSimulationSteps,
            .particles = particleRuntimeEvidence (*m_scene),
            .active = m_activity.active (),
            .paused = m_activity.paused (),
            .muted = m_muted,
            .visible = m_activity.visible (),
        };
    }

    FrameEvidence m_evidence;
    FrameDifferenceEvidence m_lastDifference;
    std::vector<uint8_t> m_lastCapturedPixels;
    SessionActivityGate m_activity;
    RendererClock m_clock;
    bool m_muted = false;
    bool m_havePreviousFrame = false;
    bool m_hasParticleSystems = false;
    bool m_trackedMediaLifecycle = false;
    bool m_trackedAudioLifecycle = false;
    bool m_collectRenderDurationSamples = false;
    std::size_t m_particleSimulationSteps = 0;
    std::size_t m_audioSpectrumInputs = 0;
    std::size_t m_audioSpectrumChanges = 0;
    std::uint64_t m_audioSpectrumHash = 0;
    std::uint64_t m_audioVectorHash = 0;
    double m_audioVectorAverage0 = 0.0;
    double m_targetFPS = 60.0;
    std::chrono::microseconds m_frameInterval = std::chrono::microseconds (16'667);
    std::chrono::steady_clock::time_point m_createdAt = std::chrono::steady_clock::now ();
    std::chrono::steady_clock::time_point m_previousFrameStart;
    double m_totalFrameIntervalMilliseconds = 0.0;
    double m_maximumFrameIntervalMilliseconds = 0.0;
    double m_totalRenderMilliseconds = 0.0;
    double m_maximumRenderMilliseconds = 0.0;
    std::vector<double> m_renderDurationSamplesMilliseconds;
    std::vector<PixelProbeRequest> m_pixelProbeRequests;
    std::vector<PixelRegionRequest> m_pixelRegionRequests;
    uint32_t m_measuredFrameIntervals = 0;
    uint32_t m_missedFrameIntervals = 0;
    int m_width = 0;
    int m_height = 0;
    std::unique_ptr<RenderSurface> m_surface;
    TextEffectRegistrySession m_textEffectRegistry;
    WallpaperApplication m_app;
    StillMouse m_mouse;
    std::optional<SceneScriptStoragePool::Lease> m_scriptStorageLease;
    RuntimeMediaSource m_media;
    AudioContext m_audio;
    JSON m_projectPropertyDefinitions = JSON::object ();
    std::unique_ptr<WindowDriver> m_driver;
    std::unique_ptr<WallpaperEngine::VideoPlayback::MPV::MediaTextureHost>
        m_mediaTextureHost;
    std::unique_ptr<WallpaperEngine::Render::RenderContext> m_renderContext;
    FrescoScene::RenderResourceGeneration m_resourceGeneration = 0;
    std::unique_ptr<WallpaperEngine::Render::Wallpapers::CScene> m_scene;
};

RendererSession::RendererSession (const RendererConfiguration& configuration)
    : m_impl (std::make_unique<Impl> (configuration)) { }

RendererSession::~RendererSession () = default;

const FrameEvidence& RendererSession::firstFrameEvidence () const {
    return m_impl->m_evidence;
}

bool RendererSession::active () const { return m_impl->m_activity.active (); }

bool RendererSession::paused () const { return m_impl->m_activity.paused (); }

bool RendererSession::muted () const { return m_impl->m_muted; }

void RendererSession::setPaused (bool paused) { m_impl->setPaused (paused); }

void RendererSession::setMuted (bool muted) { m_impl->setMuted (muted); }

void RendererSession::setVisible (bool visible) { m_impl->setVisible (visible); }

void RendererSession::setFramesPerSecond (double framesPerSecond) {
    m_impl->setFramesPerSecond (framesPerSecond);
}

AudioSpectrumApplicationEvidence RendererSession::setAudioSpectrum (
    const std::array<float, 128>& spectrum
) {
    return m_impl->setAudioSpectrum (spectrum);
}

void RendererSession::setTrackedAudioLifecycle (bool tracked) {
    m_impl->setTrackedAudioLifecycle (tracked);
}

MediaSessionEvidence RendererSession::setMediaSession (
    const MediaSessionEvent& event
) {
    return m_impl->setMediaSession (event);
}

bool RendererSession::cursorClick (
    int objectId, std::optional<double> monotonicMilliseconds
) {
    return m_impl->cursorClick (objectId, monotonicMilliseconds);
}

std::size_t RendererSession::cursorEvent (
    std::string_view name, float x, float y
) {
    return m_impl->cursorEvent (name, x, y);
}

WallpaperEngine::Audio::SoundPropertyEvidence RendererSession::setUserProperties (
    const WallpaperEngine::Audio::UserPropertyBatch& properties
) {
    return m_impl->setUserProperties (properties);
}

FrameRenderResult RendererSession::renderFrame () {
    return m_impl->renderFrame ();
}

MediaFramePreparationEvidence RendererSession::prepareMediaFrames () {
    return m_impl->prepareMediaFrames ();
}

MediaTextureGlobalLifecycleEvidence globalMediaTextureLifecycleEvidence () {
    const auto evidence = WallpaperEngine::VideoPlayback::MPV::
        globalMediaTextureLifecycleEvidence ();
    return {
        .livePlayers = evidence.livePlayers,
        .constructions = evidence.constructions,
        .destructions = evidence.destructions,
    };
}

void RendererSession::setTrackedMediaLifecycle (bool tracked) {
    m_impl->setTrackedMediaLifecycle (tracked);
}

std::size_t RendererSession::seekMediaTextures (double positionSeconds) {
    return m_impl->seekMediaTextures (positionSeconds);
}

FrameDifferenceEvidence RendererSession::captureFrameDifference () {
    return m_impl->captureFrameDifference ();
}

std::chrono::microseconds RendererSession::frameInterval () const {
    return m_impl->m_frameInterval;
}

RendererMetrics RendererSession::metrics () const { return m_impl->metrics (); }

PuppetRenderEvidence RendererSession::puppetEvidence () const {
    return puppetRenderEvidence ();
}

}
