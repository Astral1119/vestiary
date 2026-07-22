#include "FrescoScene/OpenGLStencilStateAPI.h"

#include <concepts>
#include <type_traits>

static_assert (std::derived_from<
    FrescoScene::OpenGLStencilStateAPI, FrescoScene::StencilStateAPI
>);
static_assert (std::is_final_v<FrescoScene::OpenGLStencilStateAPI>);
static_assert (std::is_default_constructible_v<
    FrescoScene::OpenGLStencilStateAPI
>);

int main () {
    FrescoScene::OpenGLStencilStateAPI api;
    return static_cast<FrescoScene::StencilStateAPI*> (&api) == nullptr;
}
