#include "FrescoScene/SceneScriptQuickJS.h"

#include <stdexcept>

namespace FrescoScene {

SceneScriptQuickJS::SceneScriptQuickJS () {
    m_runtime = JS_NewRuntime ();
    if (m_runtime == nullptr) {
        throw std::runtime_error ("cannot create QuickJS runtime");
    }
    m_context = JS_NewContext (m_runtime);
    if (m_context == nullptr) {
        JS_FreeRuntime (m_runtime);
        m_runtime = nullptr;
        throw std::runtime_error ("cannot create QuickJS context");
    }
}

SceneScriptQuickJS::~SceneScriptQuickJS () {
    reset ();
}

JSRuntime *SceneScriptQuickJS::runtime () const {
    return m_runtime;
}

JSContext *SceneScriptQuickJS::context () const {
    return m_context;
}

void SceneScriptQuickJS::reset () {
    if (m_context != nullptr) {
        JS_FreeContext (m_context);
        m_context = nullptr;
    }
    if (m_runtime != nullptr) {
        JS_FreeRuntime (m_runtime);
        m_runtime = nullptr;
    }
}

SceneScriptJSValue::SceneScriptJSValue (JSContext *context, JSValue value)
    : m_context (context), m_value (value) {}

SceneScriptJSValue::~SceneScriptJSValue () {
    JS_FreeValue (m_context, m_value);
}

JSValue SceneScriptJSValue::get () const {
    return m_value;
}

}
