#include "FrescoScene/RenderBackend.h"
#include "RenderBackendConfiguration.h"

#include <stdexcept>

namespace FrescoScene {

const BackendIdentity& backendIdentity (RenderBackend backend) {
    static constexpr BackendIdentity configured {
#ifdef FRESCO_SCENE_ANGLE_RUNTIME
        .backend = RenderBackend::AngleMetal,
#else
        .backend = RenderBackend::NativeOpenGL,
#endif
        .id = FRESCO_SCENE_BACKEND_ID,
        .renderer = FRESCO_SCENE_RENDERER_ID,
        .graphicsAPI = FRESCO_SCENE_GRAPHICS_API,
        .shaderTarget = {
            .language = FRESCO_SCENE_SHADER_LANGUAGE,
            .version = FRESCO_SCENE_SHADER_VERSION,
#ifdef FRESCO_SCENE_ANGLE_RUNTIME
            .profile = ShaderProfile::Embedded,
#else
            .profile = ShaderProfile::DesktopCore,
#endif
        },
    };

    switch (backend) {
    case RenderBackend::NativeOpenGL:
    case RenderBackend::AngleMetal:
        if (backend == configured.backend) {
            return configured;
        }
        break;
    }
    throw std::runtime_error ("unsupported render backend");
}

RenderBackend configuredBackend () {
#ifdef FRESCO_SCENE_ANGLE_RUNTIME
    return RenderBackend::AngleMetal;
#else
    return RenderBackend::NativeOpenGL;
#endif
}

std::string_view shaderProfileName (ShaderProfile profile) {
    switch (profile) {
    case ShaderProfile::DesktopCore:
        return "desktop-core";
    case ShaderProfile::Embedded:
        return "embedded";
    }
    throw std::runtime_error ("unsupported shader profile");
}

}
