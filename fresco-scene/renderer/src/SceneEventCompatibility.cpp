#include "FrescoScene/SceneEventCompatibility.h"

#include <charconv>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <regex>
#include <string>

namespace FrescoScene {
namespace {

bool contains (std::string_view source, std::string_view token) {
    return source.find (token) != std::string_view::npos;
}

std::optional<std::string> compactSource (std::string_view source) {
    std::string result;
    result.reserve (source.size ());
    char quote = 0;
    bool escaped = false;
    for (std::size_t index = 0; index < source.size (); ++index) {
        const char character = source[index];
        if (quote != 0) {
            result.push_back (character);
            if (escaped) escaped = false;
            else if (character == '\\') escaped = true;
            else if (character == quote) quote = 0;
            continue;
        }
        if (character == '\'' || character == '"') {
            quote = character;
            result.push_back (character);
        } else if (character == '/' && index + 1 < source.size ()
                   && source[index + 1] == '/') {
            index += 2;
            while (index < source.size () && source[index] != '\n') ++index;
        } else if (character == '/' && index + 1 < source.size ()
                   && source[index + 1] == '*') {
            index += 2;
            while (index + 1 < source.size ()
                   && !(source[index] == '*' && source[index + 1] == '/')) ++index;
            if (index + 1 >= source.size ()) return std::nullopt;
            ++index;
        } else if (character != ' ' && character != '\t'
                   && character != '\r' && character != '\n') {
            result.push_back (character);
        }
    }
    return quote == 0 ? std::optional<std::string> (std::move (result))
                      : std::nullopt;
}

bool hasBroadeningSurface (std::string_view source) {
    constexpr std::string_view forbidden[] = {
        "import", "input.", "thisScene.getLayer(",
        "exportfunctioncursor", "exportfunctionmediaTimelineChanged(",
        "exportfunctionmediaPropertiesChanged(", "fetch(", "eval(",
    };
    return std::ranges::any_of (forbidden, [source] (const auto token) {
        return contains (source, token);
    });
}

bool exactPlaybackVisibility (std::string_view key, SceneScriptValueKind kind, std::string_view source) {
    constexpr std::string_view body
        = "exportfunctionmediaPlaybackChanged(event){"
          "thisLayer.visible=event.state!=="
          "MediaPlaybackEvent.PLAYBACK_STOPPED;}";
    return key.starts_with ("visible_")
        && kind == SceneScriptValueKind::boolean
        && (source == body || source == std::string ("'use strict';") + std::string (body))
        && !contains (source, "exportfunctionupdate")
        && !contains (source, "mediaThumbnailChanged")
        && !contains (source, "mediaPropertiesChanged")
        && !contains (source, "mediaTimelineChanged");
}

bool exactThumbnailColor (SceneScriptValueKind kind, std::string_view source) {
    return (kind == SceneScriptValueKind::vector3
            || kind == SceneScriptValueKind::vector4)
        && contains (source, "constDURATION=1;")
        && contains (source, "exportfunctionupdate()")
        && contains (source, "exportfunctionmediaThumbnailChanged(event)")
        && contains (source, "oldColor=newColor;")
        && contains (source, "newColor=event.primaryColor;")
        && contains (source, "timer+=engine.frametime;")
        && !hasBroadeningSurface (source)
        && !contains (source, "thisLayer")
        && !contains (source, "thisObject")
        && !contains (source, "thisScene")
        && !contains (source, "shared.");
}

bool exactOrigin3 (std::string_view key, SceneScriptValueKind kind, std::string_view source) {
    return key.starts_with ("origin_")
        && kind == SceneScriptValueKind::vector3
        && contains (source, "createScriptProperties()")
        && contains (source, "name:'posX'")
        && contains (source, "name:'posY'")
        && contains (source, "name:'posZ'")
        && contains (source, "value.x=scriptProperties.posX;")
        && contains (source, "value.y=scriptProperties.posY;")
        && contains (source, "value.z=scriptProperties.posZ;")
        && !hasBroadeningSurface (source)
        && !contains (source, "engine.")
        && !contains (source, "thisLayer")
        && !contains (source, "thisObject")
        && !contains (source, "thisScene")
        && !contains (source, "shared.")
        && !contains (source, "media");
}

bool exactCommentedInert (std::string_view source) {
    if (!source.starts_with ("//'use strict';")
        || !contains (source, "//export function update(value)")) {
        return false;
    }
    std::size_t start = 0;
    while (start < source.size ()) {
        const auto end = source.find ('\n', start);
        const auto line = source.substr (
            start, end == std::string_view::npos ? source.size () - start : end - start
        );
        const auto first = line.find_first_not_of (" \t\r");
        if (first != std::string_view::npos && !line.substr (first).starts_with ("//")) {
            return false;
        }
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    return true;
}

bool exactTypeMismatchInert (SceneScriptValueKind kind, std::string_view source) {
    std::string residual (source);
    for (std::size_t position = 0;
         (position = residual.find ("shared.shownight", position)) != std::string::npos;) {
        residual.erase (position, std::string_view ("shared.shownight").size ());
    }
    return kind == SceneScriptValueKind::floatingPoint
        && contains (source, "exportfunctionupdate(value)")
        && contains (source, "shared.shownight")
        && contains (source, "value=newVec3(")
        && !hasBroadeningSurface (source)
        && !contains (residual, "shared.")
        && !contains (source, "media");
}

}

SceneEventProfile classifySceneEventProperty (
    std::string_view key, SceneScriptValueKind kind, std::string_view source
) {
    if (exactCommentedInert (source)) {
        return SceneEventProfile::inertCommented;
    }
    const auto compact = compactSource (source);
    if (!compact.has_value ()) {
        return SceneEventProfile::none;
    }
    if (exactPlaybackVisibility (key, kind, *compact)) {
        return SceneEventProfile::playbackVisibility;
    }
    if (exactThumbnailColor (kind, *compact)) {
        return SceneEventProfile::thumbnailPrimaryColor;
    }
    if (exactOrigin3 (key, kind, *compact)) {
        return SceneEventProfile::scriptPropertiesOrigin3;
    }
    if (exactTypeMismatchInert (kind, *compact)) {
        return SceneEventProfile::inertTypeMismatch;
    }
    return SceneEventProfile::none;
}

SceneEventProfile classifySceneCameraZoom (
    SceneScriptValueKind kind, std::string_view source
) {
    return parseSceneCameraZoomCapability (kind, source).has_value ()
        ? SceneEventProfile::booleanSceneCameraZoom
        : SceneEventProfile::none;
}

std::optional<SceneCameraZoomCapability> parseSceneCameraZoomCapability (
    SceneScriptValueKind kind, std::string_view source
) {
    if (kind != SceneScriptValueKind::floatingPoint) {
        return std::nullopt;
    }
    const auto compact = compactSource (source);
    if (!compact.has_value () || hasBroadeningSurface (*compact)) {
        return std::nullopt;
    }
    const std::regex expression (
        R"(^(?:'use strict';)?exportfunctionapplyUserProperties\(changedUserProperties\)\{if\(changedUserProperties\.([A-Za-z_$][A-Za-z0-9_$]*)!={1,2}undefined\)\{(?:let|const)cameraTransforms=thisScene\.getCameraTransforms\(\);cameraTransforms\.zoom=changedUserProperties\.\1\?([+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)):([+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+));thisScene\.setCameraTransforms\(cameraTransforms\);\}\}$)"
    );
    std::smatch match;
    if (!std::regex_match (*compact, match, expression)) {
        return std::nullopt;
    }
    const std::string property = match[1].str ();
    const auto parseZoom = [&match] (std::size_t index) -> std::optional<float> {
        const std::string text = match[index].str ();
        float value = 0.0F;
        const auto parsed = std::from_chars (
            text.data (), text.data () + text.size (), value
        );
        return parsed.ec == std::errc () && parsed.ptr == text.data () + text.size ()
            && std::isfinite (value) && value > 0.0F
            ? std::optional<float> (value) : std::nullopt;
    };
    const auto enabled = parseZoom (2);
    const auto disabled = parseZoom (3);
    if (!enabled.has_value () || !disabled.has_value ()) {
        return std::nullopt;
    }
    return SceneCameraZoomCapability {
        .propertyKey = property,
        .enabledZoom = *enabled,
        .disabledZoom = *disabled,
    };
}

bool hasDistinctiveSceneEventKernel (std::string_view source) {
    return contains (source, "MediaPlaybackEvent.PLAYBACK_STOPPED")
        || (contains (source, "event.primaryColor") && contains (source, "DURATION"))
        || (contains (source, "scriptProperties.posX")
            && contains (source, "scriptProperties.posY")
            && contains (source, "scriptProperties.posZ"));
}

bool hasDistinctiveSceneCameraZoomKernel (std::string_view source) {
    return contains (source, "getCameraTransforms")
        || contains (source, "setCameraTransforms")
        || contains (source, "cameraTransforms.zoom");
}

bool mediaPlaybackVisible (int playbackState) {
    return playbackState != 0;
}

std::optional<std::array<float, 3>> parseThumbnailPrimaryColor (
    std::string_view color
) {
    if (color.size () != 7 || color.front () != '#') {
        return std::nullopt;
    }
    std::array<float, 3> result {};
    for (std::size_t index = 0; index < result.size (); ++index) {
        unsigned component = 0;
        const char* first = color.data () + 1 + index * 2;
        const char* last = first + 2;
        const auto parsed = std::from_chars (first, last, component, 16);
        if (parsed.ec != std::errc () || parsed.ptr != last) {
            return std::nullopt;
        }
        result[index] = static_cast<float> (component) / 255.0f;
    }
    return result;
}

void PrimaryColorTransition::setTarget (std::array<float, 3> color) {
    m_previous = m_current;
    m_current = color;
    m_elapsed = 0.0f;
}

std::array<float, 3> PrimaryColorTransition::advance (float deltaSeconds) {
    if (m_elapsed >= durationSeconds) {
        return m_current;
    }
    const float blend = std::clamp (m_elapsed / durationSeconds, 0.0f, 1.0f);
    std::array<float, 3> result {};
    for (std::size_t index = 0; index < result.size (); ++index) {
        result[index] = m_previous[index]
            + (m_current[index] - m_previous[index]) * blend;
    }
    m_elapsed = std::min (durationSeconds, m_elapsed + std::max (deltaSeconds, 0.0f));
    return result;
}

bool PrimaryColorTransition::active () const {
    return m_elapsed < durationSeconds;
}

}
