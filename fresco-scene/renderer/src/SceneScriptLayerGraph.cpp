#include "FrescoScene/SceneScriptLayerGraph.h"
#include "FrescoScene/SceneScriptStorage.h"
#include "FrescoScene/SceneScriptQuickJS.h"

#include "WallpaperEngine/Data/Model/DynamicValue.h"
#include "WallpaperEngine/Data/Model/Object.h"
#include "WallpaperEngine/Render/Wallpapers/CScene.h"

#include <glm/glm.hpp>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <map>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <type_traits>
#include <utility>
#include <variant>

using WallpaperEngine::Data::Model::DynamicValue;
using WallpaperEngine::Data::Model::Image;
using WallpaperEngine::Data::Model::Object;
using WallpaperEngine::Data::Model::Particle;
using WallpaperEngine::Data::Model::Text;
using WallpaperEngine::Render::Wallpapers::CScene;

namespace FrescoScene {
namespace {

[[noreturn]] void throwJSException (JSContext *context, std::string_view operation) {
    JSValue exception = JS_GetException (context);
    const char *message = JS_ToCString (context, exception);
    const std::string detail =
        message == nullptr ? "unknown JavaScript exception" : message;
    if (message != nullptr) {
        JS_FreeCString (context, message);
    }
    JS_FreeValue (context, exception);
    throw std::runtime_error (std::string (operation) + ": " + detail);
}

JSValue property (JSContext *context, JSValueConst object, const char *name) {
    return JS_GetPropertyStr (context, object, name);
}

bool finiteNumber (JSContext *context, JSValueConst object, const char *name,
                   float &result) {
    JSValue value = property (context, object, name);
    double number = 0.0;
    const bool valid =
        JS_ToFloat64 (context, &number, value) == 0 && std::isfinite (number);
    JS_FreeValue (context, value);
    if (valid) {
        result = static_cast<float> (number);
    }
    return valid;
}

std::optional<glm::vec3> vector3 (JSContext *context, JSValueConst value) {
    glm::vec3 result{};
    if (!JS_IsObject (value) || !finiteNumber (context, value, "x", result.x) ||
        !finiteNumber (context, value, "y", result.y) ||
        !finiteNumber (context, value, "z", result.z)) {
        return std::nullopt;
    }
    return result;
}

JSValue vector3 (JSContext *context, const glm::vec3 &value) {
    JSValue global = JS_GetGlobalObject (context);
    JSValue constructor = property (context, global, "__frescoVec3");
    JS_FreeValue (context, global);
    JSValue arguments[] = {
        JS_NewFloat64 (context, value.x),
        JS_NewFloat64 (context, value.y),
        JS_NewFloat64 (context, value.z),
    };
    JSValue result = JS_CallConstructor (context, constructor, 3, arguments);
    for (auto &argument : arguments) {
        JS_FreeValue (context, argument);
    }
    JS_FreeValue (context, constructor);
    if (JS_IsException (result)) {
        throwJSException (context, "create SceneScript Vec3");
    }
    return result;
}

void setProperty (JSContext *context, JSValueConst object, const char *name,
                  JSValue value) {
    if (JS_SetPropertyStr (context, object, name, value) < 0) {
        throwJSException (context, "set SceneScript layer property");
    }
}

struct Binding {
    int id = 0;
    std::string name;
    std::optional<int> parent;
    DynamicValue *origin = nullptr;
    DynamicValue *scale = nullptr;
    DynamicValue *angles = nullptr;
    DynamicValue *visible = nullptr;
    DynamicValue *alpha = nullptr;
    DynamicValue *color = nullptr;
    DynamicValue *maxWidth = nullptr;
    glm::vec2 size{};
    std::string *horizontalAlign = nullptr;
    std::string *verticalAlign = nullptr;
};

DynamicValue *
settingValue (const WallpaperEngine::Data::Model::UserSettingUniquePtr &setting) {
    return setting == nullptr ? nullptr : setting->value.get ();
}

Binding bindingFor (Object &object) {
    Binding result{
        .id = object.id,
        .name = object.name,
        .parent = object.parent,
        .origin = settingValue (object.origin),
        .scale = settingValue (object.groupScale),
        .angles = settingValue (object.groupAngles),
        .visible = settingValue (object.groupVisible),
    };
    if (object.is<Image> ()) {
        auto *image = object.as<Image> ();
        result.scale = settingValue (image->scale);
        result.angles = settingValue (image->angles);
        result.visible = settingValue (image->visible);
        result.alpha = settingValue (image->alpha);
        result.color = settingValue (image->color);
        result.size = image->size;
        result.horizontalAlign = &image->alignment;
    } else if (object.is<Text> ()) {
        auto *text = object.as<Text> ();
        result.scale = settingValue (text->scale);
        result.visible = settingValue (text->visible);
        result.alpha = settingValue (text->alpha);
        result.color = settingValue (text->color);
        result.maxWidth = settingValue (text->maxWidth);
        result.size = text->size;
        result.horizontalAlign = &text->alignment;
        result.verticalAlign = &text->verticalalign;
    } else if (object.is<Particle> ()) {
        auto *particle = object.as<Particle> ();
        result.scale = settingValue (particle->scale);
        result.angles = settingValue (particle->angles);
        result.visible = settingValue (particle->visible);
    }
    return result;
}

void updateVector (DynamicValue *value, const glm::vec3 &next) {
    if (value != nullptr && value->getType () == DynamicValue::Vec3 &&
        value->getVec3 () != next) {
        value->update (next, DynamicValue::UpdateSource::Script);
    }
}

void updateFloat (DynamicValue *value, float next) {
    if (value != nullptr && value->getType () == DynamicValue::Float &&
        value->getFloat () != next) {
        value->update (next, DynamicValue::UpdateSource::Script);
    }
}

void updateBoolean (DynamicValue *value, bool next) {
    if (value != nullptr && value->getType () == DynamicValue::Boolean &&
        value->getBool () != next) {
        value->update (next, DynamicValue::UpdateSource::Script);
    }
}

} // namespace

class SceneScriptLayerGraph::Impl {
  public:
    Impl (JSContext *context, CScene &scene, SceneScriptStorage &storage)
        : context (context), scene (scene), storage (storage) {
        constexpr std::string_view bootstrap = R"JS(
(function () {
  class Vec3 {
    constructor(x = 0, y = x, z = x) { this.x = x; this.y = y; this.z = z; }
    add(v) { return new Vec3(this.x + v.x, this.y + v.y, this.z + (v.z || 0)); }
    subtract(v) { return new Vec3(this.x - v.x, this.y - v.y, this.z - (v.z || 0)); }
    multiply(v) {
      return typeof v === 'number'
        ? new Vec3(this.x * v, this.y * v, this.z * v)
        : new Vec3(this.x * v.x, this.y * v.y, this.z * v.z);
    }
    mix(v, t) { return new Vec3(this.x + (v.x - this.x) * t, this.y + (v.y - this.y) * t, this.z + (v.z - this.z) * t); }
    sign() { return new Vec3(Math.sign(this.x), Math.sign(this.y), Math.sign(this.z)); }
    length() { return Math.hypot(this.x, this.y, this.z); }
    normalize() { const n = this.length(); return n ? this.multiply(1 / n) : new Vec3(); }
  }
  const byId = Object.create(null);
  const byName = Object.create(null);
  const commands = [];
  const storageWrites = [];
  function resolved(layer, seen = new Set()) {
    if (!layer || seen.has(layer.id)) throw new Error('cyclic or missing SceneScript parent');
    seen.add(layer.id);
    const local = { origin: layer.origin, scale: layer.scale, angle: layer.angles.z || 0 };
    const parent = layer.parentId == null ? null : byId[layer.parentId];
    if (!parent) return local;
    const outer = resolved(parent, seen);
    const c = Math.cos(outer.angle), s = Math.sin(outer.angle);
    const x = local.origin.x * outer.scale.x;
    const y = local.origin.y * outer.scale.y;
    return {
      origin: new Vec3(outer.origin.x + x * c - y * s, outer.origin.y + x * s + y * c, outer.origin.z + local.origin.z * outer.scale.z),
      scale: local.scale.multiply(outer.scale),
      angle: local.angle + outer.angle,
    };
  }
  function register(seed) {
    const layer = Object.assign(seed, {
      getParent() { return this.parentId == null ? null : byId[this.parentId]; },
      getTransformMatrix() {
        const value = resolved(this);
        const matrix = new Array(16).fill(0);
        matrix[0] = value.scale.x; matrix[5] = value.scale.y; matrix[10] = value.scale.z; matrix[15] = 1;
        matrix[12] = value.origin.x; matrix[13] = value.origin.y; matrix[14] = value.origin.z;
        return { m: matrix };
      },
      getTextureAnimation() {
        const id = this.id;
        return {
          setFrame(frame) { commands.push({ kind: 'textureFrame', id, frame }); },
          stop() { commands.push({ kind: 'textureStop', id }); },
        };
      },
      getAnimationLayer(name) {
        const id = this.id;
        return { play() { commands.push({ kind: 'animationLayerPlay', id, name: String(name) }); } };
      },
      getVideoTexture() {
        const id = this.id;
        return {
          play() { commands.push({ kind: 'videoPlay', id }); },
          pause() { commands.push({ kind: 'videoPause', id }); },
        };
      },
    });
    byId[layer.id] = layer;
    if (layer.name) byName[layer.name] = layer;
    return layer;
  }
  globalThis.__frescoVec3 = Vec3;
  globalThis.__frescoLayerGraph = {
    byId, byName, commands, storageWrites, register,
    layer(id) { const layer = byId[id]; if (!layer) throw new Error('SceneScript layer id not found: ' + id); return layer; },
    named(name) { const layer = byName[name]; if (!layer) throw new Error('SceneScript layer name not found: ' + name); return layer; },
  };
  const sharedState = globalThis.__frescoSharedScriptState
    || (globalThis.__frescoSharedScriptState = {});
  if (!Object.prototype.hasOwnProperty.call(sharedState, 'miTextContainerScale')) {
    sharedState.miTextContainerScale = new Vec3(1);
  }
  globalThis.__frescoInputState = { cursorWorldPosition: new Vec3() };
  globalThis.__frescoTimeVarying = false;
  globalThis.__frescoTimers = [];
  globalThis.__frescoTimerEvidence = {
    scheduled: 0, fired: 0, cancelled: 0, pending: 0,
    nextDueMilliseconds: null, currentTimeMilliseconds: null,
    lastScheduledDelayMilliseconds: null,
    lastFiredDueMilliseconds: null, lastFiredAtMilliseconds: null,
  };
  const values = globalThis.__frescoStorageValues = Object.create(null);
  globalThis.__frescoLocalStorage = {
    get(name) { return values[name]; },
    set(name, value) { values[name] = value; storageWrites.push({ name: String(name), value }); },
  };
})()
)JS";
        SceneScriptJSValue result (
            context,
            JS_Eval (context, bootstrap.data (), bootstrap.size (),
                     "scene-layer-graph", JS_EVAL_TYPE_GLOBAL)
        );
        if (JS_IsException (result.get ())) {
            throwJSException (context, "initialize SceneScript layer graph");
        }
        static bool injectedConstructionFailure = false;
        if (std::getenv (
                "FRESCO_SCENE_TEST_FAIL_DURING_SCRIPT_GRAPH_CONSTRUCTION_ONCE"
            ) != nullptr
            && !injectedConstructionFailure) {
            injectedConstructionFailure = true;
            throw std::runtime_error (
                "injected failure during SceneScript graph construction"
            );
        }

        const auto &objects = scene.getScene ().objects;
        bindings.reserve (objects.size ());
        for (const auto &object : objects) {
            bindings.push_back (bindingFor (*const_cast<Object *> (object.get ())));
        }
        registerLayers ();
        seedStorage ();
        syncFromScene ();
    }

    JSValue graph () const {
        JSValue global = JS_GetGlobalObject (context);
        JSValue result = property (context, global, "__frescoLayerGraph");
        JS_FreeValue (context, global);
        return result;
    }

    JSValue layer (int id) const {
        JSValue graphObject = graph ();
        JSValue byId = property (context, graphObject, "byId");
        JS_FreeValue (context, graphObject);
        const std::string key = std::to_string (id);
        JSValue result = property (context, byId, key.c_str ());
        JS_FreeValue (context, byId);
        return result;
    }

    void registerLayers () {
        JSValue graphObject = graph ();
        JSValue function = property (context, graphObject, "register");
        for (const auto &binding : bindings) {
            JSValue seed = JS_NewObject (context);
            setProperty (context, seed, "id", JS_NewInt32 (context, binding.id));
            setProperty (context, seed, "name",
                         JS_NewString (context, binding.name.c_str ()));
            setProperty (context, seed, "parentId",
                         binding.parent.has_value ()
                             ? JS_NewInt32 (context, *binding.parent)
                             : JS_NULL);
            JSValue result = JS_Call (context, function, graphObject, 1, &seed);
            JS_FreeValue (context, seed);
            if (JS_IsException (result)) {
                JS_FreeValue (context, function);
                JS_FreeValue (context, graphObject);
                throwJSException (context, "register SceneScript layer");
            }
            JS_FreeValue (context, result);
        }
        JS_FreeValue (context, function);
        JS_FreeValue (context, graphObject);
    }

    void seedStorage () {
        JSValue global = JS_GetGlobalObject (context);
        JSValue values = property (context, global, "__frescoStorageValues");
        JS_FreeValue (context, global);
        for (const auto &[name, value] : storage.snapshot ()) {
            setStorageMirror (values, name, encodeStorageValue (value));
        }
        JS_FreeValue (context, values);
    }

    JSValue encodeStorageValue (const SceneScriptStorageValue &value) const {
        return std::visit (
            [this] (const auto &scalar) -> JSValue {
                using Scalar = std::decay_t<decltype (scalar)>;
                if constexpr (std::is_same_v<Scalar, bool>) {
                    return JS_NewBool (context, scalar);
                } else if constexpr (std::is_same_v<Scalar, double>) {
                    return JS_NewFloat64 (context, scalar);
                } else if constexpr (std::is_same_v<Scalar, std::string>) {
                    return JS_NewStringLen (
                        context, scalar.data (), scalar.size ()
                    );
                } else {
                    return vector3 (
                        context,
                        glm::vec3 (scalar.x, scalar.y, scalar.z)
                    );
                }
            },
            value
        );
    }

    void setStorageMirror (
        JSValueConst values,
        std::string_view name,
        JSValue value
    ) const {
        const JSAtom atom = JS_NewAtomLen (context, name.data (), name.size ());
        if (JS_SetProperty (context, values, atom, value) < 0) {
            JS_FreeAtom (context, atom);
            throwJSException (context, "synchronize SceneScript local storage");
        }
        JS_FreeAtom (context, atom);
    }

    void syncBinding (const Binding &binding) {
        JSValue object = layer (binding.id);
        if (binding.origin != nullptr) {
            setProperty (context, object, "origin",
                         vector3 (context, binding.origin->getVec3 ()));
        }
        if (binding.scale != nullptr) {
            setProperty (context, object, "scale",
                         vector3 (context, binding.scale->getVec3 ()));
        }
        if (binding.angles != nullptr) {
            setProperty (context, object, "angles",
                         vector3 (context, binding.angles->getVec3 ()));
        } else {
            setProperty (
                context, object, "angles", vector3 (context, glm::vec3 {})
            );
        }
        if (binding.visible != nullptr) {
            setProperty (context, object, "visible",
                         JS_NewBool (context, binding.visible->getBool ()));
        }
        if (binding.alpha != nullptr) {
            setProperty (context, object, "alpha",
                         JS_NewFloat64 (context, binding.alpha->getFloat ()));
        }
        if (binding.color != nullptr) {
            setProperty (context, object, "color",
                         vector3 (context, binding.color->getVec3 ()));
        }
        if (binding.maxWidth != nullptr) {
            setProperty (context, object, "maxwidth",
                         JS_NewFloat64 (context, binding.maxWidth->getFloat ()));
        }
        setProperty (context, object, "size",
                     vector3 (context, {binding.size.x, binding.size.y, 0.0f}));
        if (binding.horizontalAlign != nullptr) {
            setProperty (context, object, "horizontalalign",
                         JS_NewString (context, binding.horizontalAlign->c_str ()));
        }
        if (binding.verticalAlign != nullptr) {
            setProperty (context, object, "verticalalign",
                         JS_NewString (context, binding.verticalAlign->c_str ()));
        }
        JS_FreeValue (context, object);
    }

    void syncFromScene () {
        for (const auto &binding : bindings) {
            syncBinding (binding);
        }
    }

    void syncObjectFromScene (int objectId) {
        const auto binding = std::ranges::find_if (
            bindings, [objectId] (const auto &candidate) {
                return candidate.id == objectId;
            });
        if (binding != bindings.end ()) {
            syncBinding (*binding);
        }
    }

    void syncPropertyFromScene (int objectId, std::string_view propertyName) {
        const auto binding = std::ranges::find_if (
            bindings, [objectId] (const auto &candidate) {
                return candidate.id == objectId;
            });
        if (binding == bindings.end ()) {
            return;
        }
        JSValue object = layer (binding->id);
        if (propertyName == "origin" && binding->origin != nullptr) {
            setProperty (context, object, "origin",
                         vector3 (context, binding->origin->getVec3 ()));
        } else if (propertyName == "scale" && binding->scale != nullptr) {
            setProperty (context, object, "scale",
                         vector3 (context, binding->scale->getVec3 ()));
        } else if (propertyName == "angles" && binding->angles != nullptr) {
            setProperty (context, object, "angles",
                         vector3 (context, binding->angles->getVec3 ()));
        } else if (propertyName == "visible" && binding->visible != nullptr) {
            setProperty (context, object, "visible",
                         JS_NewBool (context, binding->visible->getBool ()));
        } else if (propertyName == "alpha" && binding->alpha != nullptr) {
            setProperty (context, object, "alpha",
                         JS_NewFloat64 (context, binding->alpha->getFloat ()));
        } else if (propertyName == "color" && binding->color != nullptr) {
            setProperty (context, object, "color",
                         vector3 (context, binding->color->getVec3 ()));
        } else if (propertyName == "maxwidth" && binding->maxWidth != nullptr) {
            setProperty (context, object, "maxwidth",
                         JS_NewFloat64 (context, binding->maxWidth->getFloat ()));
        }
        JS_FreeValue (context, object);
    }

    std::size_t applyToScene () {
        std::size_t changes = 0;
        for (const auto &binding : bindings) {
            JSValue object = layer (binding.id);
            const auto applyVector = [&] (const char *name, DynamicValue *target) {
                if (target == nullptr) {
                    return;
                }
                JSValue value = property (context, object, name);
                const auto next = vector3 (context, value);
                JS_FreeValue (context, value);
                if (next.has_value () && target->getVec3 () != *next) {
                    updateVector (target, *next);
                    ++changes;
                }
            };
            applyVector ("origin", binding.origin);
            applyVector ("scale", binding.scale);
            applyVector ("angles", binding.angles);
            applyVector ("color", binding.color);
            if (binding.visible != nullptr) {
                JSValue value = property (context, object, "visible");
                const bool next = JS_ToBool (context, value) != 0;
                JS_FreeValue (context, value);
                if (binding.visible->getBool () != next) {
                    updateBoolean (binding.visible, next);
                    ++changes;
                }
            }
            if (binding.alpha != nullptr) {
                JSValue value = property (context, object, "alpha");
                double next = 0.0;
                const bool valid =
                    JS_ToFloat64 (context, &next, value) == 0 && std::isfinite (next);
                JS_FreeValue (context, value);
                if (valid && binding.alpha->getFloat () != static_cast<float> (next)) {
                    updateFloat (binding.alpha, static_cast<float> (next));
                    ++changes;
                }
            }
            if (binding.maxWidth != nullptr) {
                JSValue value = property (context, object, "maxwidth");
                double next = 0.0;
                const bool valid = JS_ToFloat64 (context, &next, value) == 0 &&
                                   std::isfinite (next) && next >= 0.0;
                JS_FreeValue (context, value);
                if (valid && binding.maxWidth->getFloat () !=
                                 static_cast<float> (next)) {
                    updateFloat (binding.maxWidth, static_cast<float> (next));
                    ++changes;
                }
            }
            changes += applyString (object, "horizontalalign", binding.horizontalAlign);
            changes += applyString (object, "verticalalign", binding.verticalAlign);
            JS_FreeValue (context, object);
        }
        flushStorage ();
        return changes;
    }

    std::size_t applyString (JSValueConst object, const char *name,
                             std::string *target) {
        if (target == nullptr) {
            return 0;
        }
        JSValue value = property (context, object, name);
        const char *string = JS_ToCString (context, value);
        JS_FreeValue (context, value);
        if (string == nullptr) {
            return 0;
        }
        const std::string next = string;
        JS_FreeCString (context, string);
        if (*target == next) {
            return 0;
        }
        *target = next;
        return 1;
    }

    void flushStorage () {
        JSValue graphObject = graph ();
        JSValue writes = property (context, graphObject, "storageWrites");
        JS_FreeValue (context, graphObject);
        JSValue global = JS_GetGlobalObject (context);
        JSValue values = property (context, global, "__frescoStorageValues");
        JS_FreeValue (context, global);
        uint32_t length = 0;
        JSValue lengthValue = property (context, writes, "length");
        JS_ToUint32 (context, &length, lengthValue);
        JS_FreeValue (context, lengthValue);
        for (uint32_t index = 0; index < length; ++index) {
            JSValue write = JS_GetPropertyUint32 (context, writes, index);
            JSValue nameValue = property (context, write, "name");
            JSValue value = property (context, write, "value");
            std::size_t nameLength = 0;
            const char *nameString = JS_ToCStringLen (
                context, &nameLength, nameValue
            );
            if (nameString != nullptr) {
                const std::string name (nameString, nameLength);
                SceneScriptStorageSetResult result
                    = SceneScriptStorageSetResult::nonFinite;
                if (JS_IsBool (value)) {
                    result = storage.set (name, JS_ToBool (context, value) != 0);
                } else if (JS_IsNumber (value)) {
                    double number = 0.0;
                    if (JS_ToFloat64 (context, &number, value) == 0 &&
                        std::isfinite (number)) {
                        result = storage.set (name, number);
                    }
                } else if (const auto next = vector3 (context, value);
                           next.has_value ()) {
                    result = storage.set (
                        name,
                        SceneScriptStorageVec3 {next->x, next->y, next->z}
                    );
                } else if (JS_IsString (value)) {
                    std::size_t textLength = 0;
                    const char *text = JS_ToCStringLen (
                        context, &textLength, value
                    );
                    if (text != nullptr) {
                        result = storage.set (
                            name, std::string (text, textLength)
                        );
                        JS_FreeCString (context, text);
                    }
                }
                if (result != SceneScriptStorageSetResult::stored) {
                    storageRejected = true;
                }
                const auto retained = storage.get (name);
                setStorageMirror (
                    values,
                    name,
                    retained.has_value ()
                        ? encodeStorageValue (*retained)
                        : JS_UNDEFINED
                );
                JS_FreeCString (context, nameString);
            }
            JS_FreeValue (context, value);
            JS_FreeValue (context, nameValue);
            JS_FreeValue (context, write);
        }
        JS_SetPropertyStr (context, writes, "length", JS_NewInt32 (context, 0));
        JS_FreeValue (context, values);
        JS_FreeValue (context, writes);
    }

    JSContext *context;
    CScene &scene;
    SceneScriptStorage &storage;
    std::vector<Binding> bindings;
    bool storageRejected = false;
};

SceneScriptLayerGraph::SceneScriptLayerGraph (
    JSContext *context,
    CScene &scene,
    SceneScriptStorage &storage
) : m_impl (std::make_unique<Impl> (context, scene, storage)) {}

SceneScriptLayerGraph::~SceneScriptLayerGraph () = default;

void SceneScriptLayerGraph::syncFromScene () {
    m_impl->syncFromScene ();
}

void SceneScriptLayerGraph::syncObjectFromScene (int objectId) {
    m_impl->syncObjectFromScene (objectId);
}

void SceneScriptLayerGraph::syncPropertyFromScene (
    int objectId, std::string_view propertyName) {
    m_impl->syncPropertyFromScene (objectId, propertyName);
}

std::size_t SceneScriptLayerGraph::applyToScene () {
    return m_impl->applyToScene ();
}

void SceneScriptLayerGraph::setCursor (float x, float y) {
    JSValue global = JS_GetGlobalObject (m_impl->context);
    JSValue input = property (m_impl->context, global, "__frescoInputState");
    JS_FreeValue (m_impl->context, global);
    setProperty (m_impl->context, input, "cursorWorldPosition",
                 vector3 (m_impl->context, {x, y, 0.0f}));
    JS_FreeValue (m_impl->context, input);
}

void SceneScriptLayerGraph::setTimeVarying (bool enabled) {
    JSValue global = JS_GetGlobalObject (m_impl->context);
    setProperty (m_impl->context, global, "__frescoTimeVarying",
                 JS_NewBool (m_impl->context, enabled));
    JS_FreeValue (m_impl->context, global);
}

std::vector<SceneScriptLayerCommand> SceneScriptLayerGraph::takeCommands () {
    std::vector<SceneScriptLayerCommand> result;
    JSValue graphObject = m_impl->graph ();
    JSValue commands = property (m_impl->context, graphObject, "commands");
    JS_FreeValue (m_impl->context, graphObject);
    uint32_t length = 0;
    JSValue lengthValue = property (m_impl->context, commands, "length");
    JS_ToUint32 (m_impl->context, &length, lengthValue);
    JS_FreeValue (m_impl->context, lengthValue);
    result.reserve (length);
    for (uint32_t index = 0; index < length; ++index) {
        JSValue command = JS_GetPropertyUint32 (m_impl->context, commands, index);
        JSValue kindValue = property (m_impl->context, command, "kind");
        JSValue idValue = property (m_impl->context, command, "id");
        const char *kindString = JS_ToCString (m_impl->context, kindValue);
        int32_t objectId = 0;
        JS_ToInt32 (m_impl->context, &objectId, idValue);
        SceneScriptLayerCommand next{.objectId = objectId};
        if (kindString != nullptr && std::string_view (kindString) == "textureFrame") {
            next.kind = SceneScriptLayerCommand::Kind::textureFrame;
            JSValue frameValue = property (m_impl->context, command, "frame");
            int32_t frame = 0;
            JS_ToInt32 (m_impl->context, &frame, frameValue);
            JS_FreeValue (m_impl->context, frameValue);
            next.frame = frame;
        } else if (kindString != nullptr &&
                   std::string_view (kindString) == "textureStop") {
            next.kind = SceneScriptLayerCommand::Kind::textureStop;
        } else if (kindString != nullptr &&
                   std::string_view (kindString) == "animationLayerPlay") {
            next.kind = SceneScriptLayerCommand::Kind::animationLayerPlay;
            JSValue nameValue = property (m_impl->context, command, "name");
            const char *name = JS_ToCString (m_impl->context, nameValue);
            if (name != nullptr) {
                next.name = name;
                JS_FreeCString (m_impl->context, name);
            }
            JS_FreeValue (m_impl->context, nameValue);
        } else if (kindString != nullptr &&
                   std::string_view (kindString) == "videoPlay") {
            next.kind = SceneScriptLayerCommand::Kind::videoPlay;
        } else if (kindString != nullptr &&
                   std::string_view (kindString) == "videoPause") {
            next.kind = SceneScriptLayerCommand::Kind::videoPause;
        } else {
            const std::string invalidKind =
                kindString == nullptr ? "<non-string>" : kindString;
            if (kindString != nullptr) {
                JS_FreeCString (m_impl->context, kindString);
            }
            JS_FreeValue (m_impl->context, idValue);
            JS_FreeValue (m_impl->context, kindValue);
            JS_FreeValue (m_impl->context, command);
            JS_FreeValue (m_impl->context, commands);
            throw std::runtime_error ("unsupported SceneScript layer command: " +
                                      invalidKind);
        }
        if (kindString != nullptr) {
            JS_FreeCString (m_impl->context, kindString);
        }
        JS_FreeValue (m_impl->context, idValue);
        JS_FreeValue (m_impl->context, kindValue);
        JS_FreeValue (m_impl->context, command);
        result.push_back (std::move (next));
    }
    JS_SetPropertyStr (m_impl->context, commands, "length",
                       JS_NewInt32 (m_impl->context, 0));
    JS_FreeValue (m_impl->context, commands);
    return result;
}

bool SceneScriptLayerGraph::takeStorageRejection () {
    return std::exchange (m_impl->storageRejected, false);
}

SceneScriptTimerEvidence SceneScriptLayerGraph::timerEvidence () const {
    JSValue global = JS_GetGlobalObject (m_impl->context);
    JSValue value = property (
        m_impl->context, global, "__frescoTimerEvidence"
    );
    JS_FreeValue (m_impl->context, global);
    if (!JS_IsObject (value)) {
        JS_FreeValue (m_impl->context, value);
        return {};
    }
    const auto number = [this, value] (const char* name) -> std::optional<double> {
        JSValue field = property (m_impl->context, value, name);
        double result = 0.0;
        const bool valid = !JS_IsNull (field) && !JS_IsUndefined (field)
            && JS_ToFloat64 (m_impl->context, &result, field) == 0
            && std::isfinite (result) && result >= 0.0;
        JS_FreeValue (m_impl->context, field);
        return valid ? std::optional<double> (result) : std::nullopt;
    };
    const auto count = [&number] (const char* name) {
        return static_cast<std::size_t> (number (name).value_or (0.0));
    };
    SceneScriptTimerEvidence result {
        .scheduled = count ("scheduled"),
        .fired = count ("fired"),
        .cancelled = count ("cancelled"),
        .pending = count ("pending"),
        .nextDueMilliseconds = number ("nextDueMilliseconds"),
        .currentTimeMilliseconds = number ("currentTimeMilliseconds"),
        .lastScheduledDelayMilliseconds
            = number ("lastScheduledDelayMilliseconds"),
        .lastFiredDueMilliseconds = number ("lastFiredDueMilliseconds"),
        .lastFiredAtMilliseconds = number ("lastFiredAtMilliseconds"),
    };
    JS_FreeValue (m_impl->context, value);
    return result;
}

std::string SceneScriptLayerGraph::wrapperPrelude (int objectId, int canvasWidth,
                                                   int canvasHeight, int clockHour) {
    std::ostringstream source;
    source << "  const Vec3 = globalThis.__frescoVec3;\n"
           << "  let thisLayer = globalThis.__frescoLayerGraph.layer(" << objectId
           << ");\n"
           << "  const thisScene = { getLayer(name) { return "
              "globalThis.__frescoLayerGraph.named(String(name)); } };\n"
           << "  const shared = globalThis.__frescoSharedScriptState;\n"
           << "  const input = globalThis.__frescoInputState;\n"
           << "  const localStorage = globalThis.__frescoLocalStorage;\n"
           << "  let __frescoValueAnimationCommand = '';\n"
           << "  const thisObject = { getAnimation() { return { play() { "
              "__frescoValueAnimationCommand = 'play'; }, restart() { "
              "__frescoValueAnimationCommand = 'restart'; }, pause() { "
              "__frescoValueAnimationCommand = 'pause'; } }; } };\n"
           << "  function __frescoTakeValueAnimationCommand() { const command = "
              "__frescoValueAnimationCommand; __frescoValueAnimationCommand = ''; "
              "return command; }\n"
           << "  const __frescoSceneCallbacks = [];\n"
           << "  const scene = { getLayer(name) { return thisScene.getLayer(name); "
              "}, on(name, callback) { if (name !== 'update' || typeof callback !== "
              "'function') throw new RangeError('unsupported scene event'); "
              "__frescoSceneCallbacks.push(callback); }, get timeVarying() { return "
              "!!globalThis.__frescoTimeVarying; } };\n"
           << "  const WEMath = { mix(a, b, t) { return a + (b - a) * t; } };\n"
           << "  const MediaPlaybackEvent = { PLAYBACK_STOPPED: 0, "
              "PLAYBACK_PLAYING: 1, PLAYBACK_PAUSED: 2 };\n"
           << "  const __frescoClockHour = " << clockHour << ";\n"
           << "  class Date { constructor() {} static now() { const c = "
              "globalThis.__frescoScene; return c ? c.time * 1000 : 0; } getHours() "
              "{ return __frescoClockHour; } }\n"
           << "  const __frescoTimers = globalThis.__frescoTimers;\n"
           << "  const __frescoTimerEvidence = globalThis.__frescoTimerEvidence;\n"
           << "  const engine = { canvasSize: { x: " << canvasWidth
           << ", y: " << canvasHeight
           << " }, get frametime() { const c = globalThis.__frescoScene; return c ? "
              "c.dt : 0; }, setTimeout(callback, milliseconds) { if (typeof "
              "callback !== 'function' || !Number.isFinite(milliseconds) || "
              "milliseconds < 0) throw new RangeError('invalid timeout'); const "
              "timer = { callback, due: Date.now() + milliseconds, active: true }; "
              "__frescoTimers.push(timer); __frescoTimerEvidence.scheduled++; "
              "__frescoTimerEvidence.pending++; "
              "__frescoTimerEvidence.lastScheduledDelayMilliseconds = milliseconds; "
              "__frescoTimerEvidence.nextDueMilliseconds = "
              "__frescoTimerEvidence.nextDueMilliseconds === null ? timer.due : "
              "Math.min(__frescoTimerEvidence.nextDueMilliseconds, timer.due); "
              "return () => { if (timer.active) { timer.active = false; "
              "__frescoTimerEvidence.cancelled++; __frescoTimerEvidence.pending--; } }; "
              "} };\n"
           << "  const console = { log() {}, warn() {}, error() {} };\n"
           << "  function __frescoAdvanceHostObjects() { const now = Date.now(); "
              "__frescoTimerEvidence.currentTimeMilliseconds = now; "
              "for (const timer of __frescoTimers) { if (timer.active && timer.due "
              "<= now) { timer.active = false; __frescoTimerEvidence.fired++; "
              "__frescoTimerEvidence.pending--; "
              "__frescoTimerEvidence.lastFiredDueMilliseconds = timer.due; "
              "__frescoTimerEvidence.lastFiredAtMilliseconds = now; timer.callback(); } } "
              "for (const callback of __frescoSceneCallbacks) callback(); for (let i = "
              "__frescoTimers.length - 1; i >= 0; --i) { if "
              "(!__frescoTimers[i].active) __frescoTimers.splice(i, 1); } "
              "__frescoTimerEvidence.nextDueMilliseconds = null; "
              "for (const timer of __frescoTimers) { if (timer.active) "
              "__frescoTimerEvidence.nextDueMilliseconds = "
              "__frescoTimerEvidence.nextDueMilliseconds === null ? timer.due : "
              "Math.min(__frescoTimerEvidence.nextDueMilliseconds, timer.due); } }\n"
           << "  function createScriptProperties() { const builder = { addSlider(o) "
              "{ if (!(o.name in __properties)) __properties[o.name] = o.value; "
              "return builder; }, addCheckbox(o) { if (!(o.name in __properties)) "
              "__properties[o.name] = o.value; return builder; }, addCombo(o) { if "
              "(!(o.name in __properties)) __properties[o.name] = o.value ?? "
              "(o.options && o.options[0] ? o.options[0].value : undefined); return "
              "builder; }, addColor(o) { if (!(o.name in __properties)) "
              "__properties[o.name] = o.value; return builder; }, addText(o) { if "
              "(!(o.name in __properties)) __properties[o.name] = o.value; return "
              "builder; }, finish() { return __properties; } }; return builder; }\n";
    return source.str ();
}

} // namespace FrescoScene
