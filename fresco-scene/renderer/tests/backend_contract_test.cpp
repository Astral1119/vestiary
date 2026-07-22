#include "FrescoScene/RenderBackend.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>

int main () {
    const auto& backend = FrescoScene::backendIdentity (
        FrescoScene::RenderBackend::NativeOpenGL
    );
    assert (backend.id == "native-opengl");
    assert (backend.renderer == "opengl-4.1-2d");
    assert (backend.graphicsAPI == "OpenGL 4.1 core");
    assert (backend.shaderTarget.language == "GLSL");
    assert (backend.shaderTarget.version == 410);
    assert (
        FrescoScene::shaderProfileName (backend.shaderTarget.profile)
        == "desktop-core"
    );
}
