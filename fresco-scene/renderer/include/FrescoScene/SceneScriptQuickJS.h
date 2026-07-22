#pragma once

#include <quickjs.h>

namespace FrescoScene {

class SceneScriptQuickJS {
public:
    SceneScriptQuickJS ();
    ~SceneScriptQuickJS ();

    SceneScriptQuickJS (const SceneScriptQuickJS &) = delete;
    SceneScriptQuickJS &operator= (const SceneScriptQuickJS &) = delete;

    [[nodiscard]] JSRuntime *runtime () const;
    [[nodiscard]] JSContext *context () const;
    void reset ();

private:
    JSRuntime *m_runtime = nullptr;
    JSContext *m_context = nullptr;
};

class SceneScriptJSValue {
public:
    SceneScriptJSValue (JSContext *context, JSValue value);
    ~SceneScriptJSValue ();

    SceneScriptJSValue (const SceneScriptJSValue &) = delete;
    SceneScriptJSValue &operator= (const SceneScriptJSValue &) = delete;

    [[nodiscard]] JSValue get () const;

private:
    JSContext *m_context;
    JSValue m_value;
};

}
