#pragma once

#include "FrescoScene/SceneObjectOpacity.h"
#include "FrescoScene/SceneObjectTransform.h"
#include "FrescoScene/SceneObjectVisibility.h"

#include "WallpaperEngine/Data/Model/Object.h"
#include "WallpaperEngine/Render/CObject.h"
#include "WallpaperEngine/Render/Wallpapers/CScene.h"

namespace FrescoScene {

inline SceneObjectTransform2D sceneObjectLocalTransform (
    const WallpaperEngine::Data::Model::Object& object
) {
    using namespace WallpaperEngine::Data::Model;

    SceneObjectTransform2D transform {
        .origin = object.origin->value->getVec3 (),
        .scale = object.groupScale->value->getVec3 (),
        .angle = object.groupAngles->value->getVec3 ().z,
    };
    if (object.is<Image> ()) {
        const auto* image = object.as<Image> ();
        transform.scale = image->scale->value->getVec3 ();
        transform.angle = image->angles->value->getVec3 ().z;
    } else if (object.is<Particle> ()) {
        const auto* particle = object.as<Particle> ();
        transform.scale = particle->scale->value->getVec3 ();
        transform.angle = particle->angles->value->getVec3 ().z;
    } else if (object.is<Text> ()) {
        transform.scale = object.as<Text> ()->scale->value->getVec3 ();
    }
    return transform;
}

inline SceneObjectTransform2D resolveSceneObjectTransform (
    const WallpaperEngine::Render::Wallpapers::CScene& scene,
    const WallpaperEngine::Data::Model::Object& object
) {
    return resolveSceneObjectTransform (
        {
            .parent = object.parent,
            .local = sceneObjectLocalTransform (object),
        },
        [&scene] (int id) -> std::optional<SceneObjectTransformNode> {
            const auto* parent = scene.getObject (id);
            if (parent == nullptr) {
                return std::nullopt;
            }
            const auto& model = parent->getObject ();
            return SceneObjectTransformNode {
                .parent = model.parent,
                .local = sceneObjectLocalTransform (model),
            };
        }
    );
}

inline bool sceneObjectVisible (
    const WallpaperEngine::Data::Model::Object& object
) {
    using namespace WallpaperEngine::Data::Model;

    if (object.is<Image> ()) {
        return object.as<Image> ()->visible->value->getBool ();
    }
    if (object.is<Particle> ()) {
        return object.as<Particle> ()->visible->value->getBool ();
    }
    if (object.is<Text> ()) {
        return object.as<Text> ()->visible->value->getBool ();
    }
    return object.groupVisible->value->getBool ();
}

inline bool sceneObjectVisibleWithParents (
    const WallpaperEngine::Render::Wallpapers::CScene& scene,
    const WallpaperEngine::Data::Model::Object& object
) {
    using namespace WallpaperEngine::Data::Model;

    if (!sceneObjectVisible (object)) {
        return false;
    }
    return sceneObjectVisibleWithAncestors (
        object.parent,
        [&scene] (int id) -> std::optional<SceneObjectVisibilityNode> {
            const auto* parent = scene.getObject (id);
            if (parent == nullptr) {
                return std::nullopt;
            }
            const auto& model = parent->getObject ();
            return SceneObjectVisibilityNode {
                .parent = model.parent,
                .visible = sceneObjectVisible (model),
                .propagatesVisibility = sceneObjectTypePropagatesVisibility (
                    model.is<Particle> (), model.is<Text> (), model.is<Sound> ()
                ),
            };
        }
    );
}

// The `alpha` material constant is the opacity control: `shaders/effects/
// opacity.frag` declares `uniform float g_UserAlpha; // {"material":"alpha"}`
// and multiplies the sample's alpha by it. Hyuga animates that constant on
// object 367's second opacity effect to fade the opening overlay.
inline float sceneObjectChainOpacity (
    const WallpaperEngine::Data::Model::Object& object
) {
    using namespace WallpaperEngine::Data::Model;

    if (!object.is<Image> ()) {
        return 1.0f;
    }
    float opacity = 1.0f;
    for (const auto& effect : object.as<Image> ()->effects) {
        if (!effect->visible->value->getBool ()) {
            continue;
        }
        for (const auto& passOverride : effect->passOverrides) {
            const auto alpha = passOverride->constants.find ("alpha");
            if (alpha != passOverride->constants.end ()) {
                opacity *= alpha->second->value->getFloat ();
            }
        }
    }
    return opacity;
}

// Only a passthrough composition layer propagates. It exists to group, so its
// chain opacity is the group's; an ordinary image's effect alpha describes that
// image's own rendering. SceneObjectOpacity.h carries the corpus survey behind
// that restriction.
inline bool sceneObjectPropagatesOpacity (
    const WallpaperEngine::Data::Model::Object& object
) {
    using namespace WallpaperEngine::Data::Model;

    if (!object.is<Image> ()) {
        return false;
    }
    const auto* image = object.as<Image> ();
    return image->model != nullptr && image->model->passthrough;
}

inline float sceneObjectOpacityFromParents (
    const WallpaperEngine::Render::Wallpapers::CScene& scene,
    const WallpaperEngine::Data::Model::Object& object
) {
    return sceneObjectInheritedOpacity (
        object.parent,
        [&scene] (int id) -> std::optional<SceneObjectOpacityNode> {
            const auto* parent = scene.getObject (id);
            if (parent == nullptr) {
                return std::nullopt;
            }
            const auto& model = parent->getObject ();
            const bool propagates = sceneObjectPropagatesOpacity (model);
            return SceneObjectOpacityNode {
                .parent = model.parent,
                .propagatesOpacity = propagates,
                .opacity = propagates ? sceneObjectChainOpacity (model) : 1.0f,
            };
        }
    );
}

} // namespace FrescoScene
