#include "FrescoScene/SceneScriptQuickJS.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <stdexcept>
#include <string_view>

namespace {

void constructThenFail () {
    FrescoScene::SceneScriptQuickJS quickJS;
    constexpr std::string_view source = "({ value: 42 })";
    FrescoScene::SceneScriptJSValue value (
        quickJS.context (),
        JS_Eval (
            quickJS.context (), source.data (), source.size (),
            "ownership-failure", JS_EVAL_TYPE_GLOBAL
        )
    );
    assert (!JS_IsException (value.get ()));
    throw std::runtime_error ("injected constructor failure");
}

}

int main () {
    try {
        constructThenFail ();
        assert (false);
    } catch (const std::runtime_error &error) {
        assert (std::string_view (error.what ()) == "injected constructor failure");
    }

    FrescoScene::SceneScriptQuickJS recovered;
    constexpr std::string_view source = "21 * 2";
    FrescoScene::SceneScriptJSValue value (
        recovered.context (),
        JS_Eval (
            recovered.context (), source.data (), source.size (),
            "ownership-recovery", JS_EVAL_TYPE_GLOBAL
        )
    );
    assert (!JS_IsException (value.get ()));
    int32_t result = 0;
    assert (JS_ToInt32 (recovered.context (), &result, value.get ()) == 0);
    assert (result == 42);
}
