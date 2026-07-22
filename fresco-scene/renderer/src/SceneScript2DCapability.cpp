#include "FrescoScene/SceneScript2DCapability.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <initializer_list>
#include <string>

namespace FrescoScene {
namespace {

bool contains (std::string_view source, std::string_view token) {
    return source.find (token) != std::string_view::npos;
}

std::size_t countOccurrences (std::string_view source, std::string_view token) {
    std::size_t count = 0;
    std::size_t position = 0;
    while ((position = source.find (token, position)) != std::string_view::npos) {
        ++count;
        position += token.size ();
    }
    return count;
}

bool hasDormantCursorStorageReset (
    std::string_view key,
    SceneScriptValueKind valueKind,
    std::string_view source
) {
    return key.starts_with ("visible_")
        && valueKind == SceneScriptValueKind::boolean
        && contains (source, "createScriptProperties()")
        && contains (source, ".addCheckbox(")
        && contains (source, "name: 'isMovable'")
        && contains (source, "export function resetPosition()")
        && contains (source, "localStorage.remove(")
        && contains (source, "thisLayer.origin = thisLayer.originalOrigin")
        && contains (source, "export function cursorDown(event)")
        && contains (source, "export function cursorMove(event)")
        && contains (source, "export function cursorUp(event)")
        && contains (source, "export function init()")
        && contains (source, "shared.miDragable")
        && contains (source, "localStorage.get(")
        && contains (source, "localStorage.set(")
        && contains (source, "event.worldPosition")
        && countOccurrences (source, "localStorage.remove(") == 1
        && countOccurrences (source, "thisLayer.originalOrigin") == 1
        && countOccurrences (source, "export function") == 5
        && !contains (source, "export function update")
        && !contains (source, "export function cursorClick")
        && !contains (source, "import ")
        && !contains (source, "thisObject")
        && !contains (source, "thisScene")
        && !contains (source, "engine.")
        && !contains (source, "input.")
        && !contains (source, "media");
}

bool hasOnlyMembers (std::string_view source, std::string_view root,
                     std::initializer_list<std::string_view> allowed) {
    const std::string prefix = std::string (root) + ".";
    std::size_t position = 0;
    while ((position = source.find (prefix, position)) != std::string_view::npos) {
        const std::size_t start = position + prefix.size ();
        std::size_t end = start;
        while (end < source.size () &&
               (std::isalnum (static_cast<unsigned char> (source[end])) ||
                source[end] == '_')) {
            ++end;
        }
        const std::string_view member = source.substr (start, end - start);
        if (std::find (allowed.begin (), allowed.end (), member) == allowed.end ()) {
            return false;
        }
        position = end;
    }
    return true;
}

bool hasOnlyWEMathImport (std::string_view source) {
    std::size_t position = 0;
    while ((position = source.find ("import ", position)) != std::string_view::npos) {
        const std::size_t end = source.find ('\n', position);
        const std::string_view line = source.substr (
            position,
            end == std::string_view::npos ? source.size () - position : end - position);
        if (!contains (line, "from 'WEMath'") && !contains (line, "from \"WEMath\"")) {
            return false;
        }
        position = end == std::string_view::npos ? source.size () : end + 1;
    }
    return true;
}

bool supportedKind (SceneScriptValueKind kind) {
    return kind == SceneScriptValueKind::boolean ||
           kind == SceneScriptValueKind::floatingPoint ||
           kind == SceneScriptValueKind::integer ||
           kind == SceneScriptValueKind::vector2 ||
           kind == SceneScriptValueKind::vector3 ||
           kind == SceneScriptValueKind::vector4;
}

bool touchesBoundedSurface (std::string_view source) {
    constexpr std::array roots = {
        std::string_view ("thisLayer"),
        std::string_view ("thisObject"),
        std::string_view ("thisScene"),
        std::string_view ("scene."),
        std::string_view ("shared."),
        std::string_view ("input."),
        std::string_view ("localStorage."),
        std::string_view ("engine.setTimeout"),
        std::string_view ("mediaPlaybackChanged"),
        std::string_view ("mediaTimelineChanged"),
        std::string_view ("mediaThumbnailChanged"),
        std::string_view ("cursorClick"),
        std::string_view ("cursorDown"),
        std::string_view ("cursorMove"),
        std::string_view ("cursorUp"),
        std::string_view ("cursorEnter"),
        std::string_view ("cursorLeave"),
    };
    return std::ranges::any_of (
        roots, [&source] (const auto root) { return contains (source, root); });
}

} // namespace

SceneScriptCompatibility classifyBounded2DSceneScript (std::string_view key,
                                                       SceneScriptValueKind valueKind,
                                                       std::string_view source) {
    if (!touchesBoundedSurface (source) || contains (source, "registerAudioBuffers") ||
        contains (source, "getVideoTexture")) {
        return {};
    }
    if (!supportedKind (valueKind)) {
        return {.reason = "the 2D object script targets an unsupported value type"};
    }
    constexpr std::array forbidden = {
        std::string_view ("eval("),
        std::string_view ("Function("),
        std::string_view ("fetch("),
        std::string_view ("require("),
        std::string_view ("WebSocket"),
        std::string_view ("XMLHttpRequest"),
        std::string_view ("globalThis"),
        std::string_view ("__fresco"),
        std::string_view ("__proto__"),
        std::string_view (".constructor"),
        std::string_view (".prototype"),
        std::string_view ("thisScene.setCamera"),
        std::string_view ("engine.setCamera"),
        std::string_view ("thisLayer["),
        std::string_view ("thisObject["),
        std::string_view ("thisScene["),
        std::string_view ("scene["),
        std::string_view ("engine["),
        std::string_view ("input["),
        std::string_view ("localStorage["),
        std::string_view ("event["),
    };
    if (std::ranges::any_of (forbidden, [&source] (const auto token) {
            return contains (source, token);
        })) {
        return {.reason = "the 2D object script requests host access outside the "
                          "bounded scene graph"};
    }
    if (!hasOnlyWEMathImport (source)) {
        return {.reason = "the 2D object script imports a module other than WEMath"};
    }
    const bool dormantCursorStorageReset = hasDormantCursorStorageReset (
        key, valueKind, source
    );
    const bool supportedLayerMembers = dormantCursorStorageReset
        ? hasOnlyMembers (
            source, "thisLayer",
            {"visible", "origin", "originalOrigin", "scale", "size", "maxwidth",
             "verticalalign", "horizontalalign", "getParent", "getTransformMatrix",
             "getTextureAnimation", "getAnimationLayer", "getVideoTexture"}
        )
        : hasOnlyMembers (
            source, "thisLayer",
            {"visible", "origin", "scale", "size", "maxwidth", "verticalalign",
             "horizontalalign", "getParent", "getTransformMatrix",
             "getTextureAnimation", "getAnimationLayer", "getVideoTexture"}
        );
    if (!supportedLayerMembers) {
        return {.reason = "the 2D object script requests an unsupported layer "
                          "field or method"};
    }
    if (!hasOnlyMembers (source, "thisObject", {"getAnimation"})) {
        return {.reason = "the 2D object script requests an unsupported "
                          "value-animation method"};
    }
    if (!hasOnlyMembers (source, "thisScene", {"getLayer"}) ||
        !hasOnlyMembers (source, "scene", {"getLayer", "on", "timeVarying"})) {
        return {.reason = "the 2D object script requests an unsupported scene method"};
    }
    if (!hasOnlyMembers (source, "engine", {"canvasSize", "frametime", "setTimeout"})) {
        return {.reason = "the 2D object script requests an unsupported engine method"};
    }
    if (!hasOnlyMembers (source, "input", {"cursorWorldPosition"})) {
        return {.reason = "the 2D object script requests unsupported input state"};
    }
    const bool supportedStorageMembers = dormantCursorStorageReset
        ? hasOnlyMembers (source, "localStorage", {"get", "set", "remove"})
        : hasOnlyMembers (source, "localStorage", {"get", "set"});
    if (!supportedStorageMembers) {
        return {.reason = "the 2D object script requests an unsupported "
                          "local-storage method"};
    }
    if (!hasOnlyMembers (source, "event",
                         {"state", "duration", "position", "primaryColor",
                          "secondaryColor", "tertiaryColor", "textColor",
                          "highContrastColor", "worldPosition"})) {
        return {.reason = "the 2D object script requests an unsupported event field"};
    }

    if (contains (source, "mediaThumbnailChanged") &&
        contains (source, "export function update") &&
        !contains (source, "thisObject.getAnimation")) {
        return {.supported = true, .profile = "generic-media-thumbnail-color-v1"};
    }
    if (contains (source, "mediaTimelineChanged") &&
        contains (source, "mediaPlaybackChanged") &&
        contains (source, "export function update")) {
        return {.supported = true, .profile = "generic-media-playback-timeline-v1"};
    }
    if (contains (source, "mediaPlaybackChanged")) {
        return {.supported = true, .profile = "generic-media-playback-layout-v1"};
    }
    if (contains (source, "cursorClick") || contains (source, "cursorDown") ||
        contains (source, "cursorMove") || contains (source, "cursorUp") ||
        contains (source, "cursorEnter") || contains (source, "cursorLeave")) {
        return {
            .supported = true,
            .profile = dormantCursorStorageReset
                ? "generic-cursor-storage-side-effect-init-v1"
                : "generic-cursor-storage-control-v1",
        };
    }
    if (valueKind == SceneScriptValueKind::vector3 &&
        contains (source, "input.cursorWorldPosition") &&
        contains (source, "export function update")) {
        return {.supported = true, .profile = "generic-cursor-follow-v1"};
    }
    if (contains (source, "scene.on(") && contains (source, "scene.getLayer(")) {
        return {.supported = true, .profile = "generic-legacy-scene-update-v1"};
    }
    if (contains (source, "engine.setTimeout(")
        && contains (source, "export function init")
        && !contains (source, "export function update")
        && !contains (source, "scene.on(")
        && !contains (source, "cursor")
        && !contains (source, "media")) {
        return {.supported = true, .profile = "generic-2d-layer-graph-v1"};
    }
    if ((contains (source, "shared.") || contains (source, "thisLayer") ||
         contains (source, "thisScene")) &&
        (contains (source, "export function update") ||
         contains (source, "export function init"))) {
        return {.supported = true, .profile = "generic-2d-layer-graph-v1"};
    }
    return {.reason = "the 2D object script has no supported lifecycle entry point"};
}

} // namespace FrescoScene
