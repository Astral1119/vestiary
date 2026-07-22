#pragma once

#include <string_view>

namespace FrescoScene {

enum class RenderBackend {
    NativeOpenGL,
    AngleMetal,
};

enum class ShaderProfile {
    DesktopCore,
    Embedded,
};

struct ShaderTarget {
    std::string_view language;
    int version = 0;
    ShaderProfile profile = ShaderProfile::DesktopCore;
};

struct BackendIdentity {
    RenderBackend backend = RenderBackend::NativeOpenGL;
    std::string_view id;
    std::string_view renderer;
    std::string_view graphicsAPI;
    ShaderTarget shaderTarget;
};

[[nodiscard]] const BackendIdentity& backendIdentity (RenderBackend backend);
[[nodiscard]] RenderBackend configuredBackend ();
[[nodiscard]] std::string_view shaderProfileName (ShaderProfile profile);

}
