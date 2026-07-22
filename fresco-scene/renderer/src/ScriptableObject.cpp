/*
 * Fresco scene scriptable object bridge
 *
 * Derived from linux-wallpaperengine's ScriptableObject.cpp at
 * b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version 3.
 */

#include "WallpaperEngine/Scripting/ScriptableObject.h"

#include "WallpaperEngine/Scripting/ScriptEngine.h"
#include "WallpaperEngine/Data/Model/Object.h"
#include "WallpaperEngine/Logging/Log.h"

using namespace WallpaperEngine::Render;
using namespace WallpaperEngine::Scripting;

ScriptableObject::ScriptableObject (
    Wallpapers::CScene& scene, const Object& object
) : CObject (scene, object) {
    registerProperty ("origin", *object.origin->value);
    if (object.is<Image> ()) {
        const auto* image = object.as<Image> ();
        registerProperty ("scale", *image->scale->value);
        registerProperty ("angles", *image->angles->value);
        registerProperty ("visible", *image->visible->value);
        for (const auto& animationLayer : image->animationLayers) {
            scene.getScriptEngine ().queueAudioFloatScript (
                "animation-rate:" + std::to_string (object.id) + ":"
                    + std::to_string (animationLayer->id),
                *animationLayer->rate->value
            );
        }
    } else if (object.is<Particle> ()) {
        const auto* particle = object.as<Particle> ();
        registerProperty ("scale", *particle->scale->value);
        registerProperty ("angles", *particle->angles->value);
        registerProperty ("visible", *particle->visible->value);
    } else if (object.is<Text> ()) {
        const auto* text = object.as<Text> ();
        registerProperty ("scale", *text->scale->value);
        registerProperty ("angles", *object.groupAngles->value);
        registerProperty ("visible", *text->visible->value);
    } else {
        registerProperty ("scale", *object.groupScale->value);
        registerProperty ("angles", *object.groupAngles->value);
        registerProperty ("visible", *object.groupVisible->value);
    }
}

DynamicValue& ScriptableObject::getProperty (const std::string& name) {
    const auto property = m_properties.find (name);
    if (property == m_properties.end ()) {
        sLog.exception ("Property '", name, "' not found on object '", getObject ().name, "'");
    }
    return property->second.value;
}

const std::map<std::string, ScriptableObject::PropertyEntry>&
ScriptableObject::getProperties () const {
    return m_properties;
}

void ScriptableObject::registerProperty (const std::string& name, DynamicValue& value) {
    auto [property, inserted] = m_properties.emplace (
        name,
        PropertyEntry { .key = name + "_" + std::to_string (getId ()), .value = value }
    );
    if (inserted) {
        getScene ().getScriptEngine ().queueScript (property->second.key, property->second.value, *this);
    }
}
