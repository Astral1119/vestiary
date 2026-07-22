#include "FrescoScene/SceneSoundSemanticCapability.h"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <iterator>
#include <regex>
#include <set>
#include <utility>

namespace FrescoScene {
namespace {

std::optional<std::string> compactSource (std::string_view source) {
    std::string result;
    result.reserve (source.size ());
    char quote = 0;
    bool escaped = false;
    for (std::size_t index = 0; index < source.size (); ++index) {
        const char character = source[index];
        if (quote != 0) {
            result.push_back (character);
            if (escaped) {
                escaped = false;
            } else if (character == '\\') {
                escaped = true;
            } else if (character == quote) {
                quote = 0;
            }
            continue;
        }
        if (character == '\'' || character == '"') {
            quote = character;
            result.push_back (character);
            continue;
        }
        if (character == '/' && index + 1 < source.size ()
            && source[index + 1] == '/') {
            index += 2;
            while (index < source.size () && source[index] != '\n') {
                ++index;
            }
            continue;
        }
        if (character == '/' && index + 1 < source.size ()
            && source[index + 1] == '*') {
            index += 2;
            while (index + 1 < source.size ()
                   && !(source[index] == '*' && source[index + 1] == '/')) {
                ++index;
            }
            if (index + 1 == source.size ()) {
                return std::nullopt;
            }
            ++index;
            continue;
        }
        if (character != ' ' && character != '\t' && character != '\r'
            && character != '\n') {
            result.push_back (character);
        }
    }
    if (quote != 0) {
        return std::nullopt;
    }
    return result;
}

bool contains (std::string_view source, std::string_view token) {
    return source.find (token) != std::string_view::npos;
}

std::size_t count (std::string_view source, std::string_view token) {
    std::size_t result = 0;
    std::size_t position = 0;
    while ((position = source.find (token, position)) != std::string_view::npos) {
        ++result;
        position += token.size ();
    }
    return result;
}

std::set<std::string> exportedFunctions (const std::string& source) {
    const std::regex expression (R"(exportfunction([A-Za-z_$][A-Za-z0-9_$]*)\()") ;
    std::set<std::string> result;
    for (auto match = std::sregex_iterator (source.begin (), source.end (), expression);
         match != std::sregex_iterator (); ++match) {
        result.insert ((*match)[1].str ());
    }
    return result;
}

std::set<std::string> declaredFunctions (const std::string& source) {
    const std::regex expression (
        R"((?:export)?function([A-Za-z_$][A-Za-z0-9_$]*)\()"
    );
    std::set<std::string> result;
    for (auto match = std::sregex_iterator (source.begin (), source.end (), expression);
         match != std::sregex_iterator (); ++match) {
        result.insert ((*match)[1].str ());
    }
    return result;
}

bool hasOnlyKnownArrows (std::string source) {
    constexpr std::string_view allowed[] = {
        "song=>thisScene.getLayer(song)",
        "song=>{if(song&&song.stop)song.stop();}",
        "song=>song.stop()",
    };
    for (const auto expression : allowed) {
        std::size_t position = 0;
        while ((position = source.find (expression, position)) != std::string::npos) {
            source.erase (position, expression.size ());
        }
    }
    return !contains (source, "=>");
}

std::set<std::string> rootAPIs (const std::string& source) {
    const std::regex expression (
        R"((engine|thisScene|thisLayer|thisObject|input|shared|console|Math)\.([A-Za-z_$][A-Za-z0-9_$]*))"
    );
    std::set<std::string> result;
    for (auto match = std::sregex_iterator (source.begin (), source.end (), expression);
         match != std::sregex_iterator (); ++match) {
        result.insert ((*match)[1].str () + "." + (*match)[2].str ());
    }
    return result;
}

bool hasForbiddenSurface (std::string_view source) {
    constexpr std::string_view forbidden[] = {
        "import", "eval(", "Function(", "fetch(", "require(", "WebSocket",
        "XMLHttpRequest", "globalThis", "thisLayer[", "thisScene[", "engine[",
        "input[", "shared[", "while(", "do{", "function(",
    };
    return std::ranges::any_of (forbidden, [source] (const auto token) {
        return contains (source, token);
    });
}

std::optional<std::string> quotedValue (
    std::string_view object,
    std::string_view key
) {
    const std::string marker = std::string (key) + ":";
    const auto markerPosition = object.find (marker);
    if (markerPosition == std::string_view::npos) {
        return std::nullopt;
    }
    const auto opening = markerPosition + marker.size ();
    if (opening >= object.size ()
        || (object[opening] != '\'' && object[opening] != '"')) {
        return std::nullopt;
    }
    const char quote = object[opening];
    bool escaped = false;
    for (auto index = opening + 1; index < object.size (); ++index) {
        const char character = object[index];
        if (escaped) {
            escaped = false;
        } else if (character == '\\') {
            escaped = true;
        } else if (character == quote) {
            return std::string (object.substr (opening + 1, index - opening - 1));
        }
    }
    return std::nullopt;
}

std::optional<std::string_view> balancedBlock (
    std::string_view source,
    std::size_t opening,
    char open,
    char close
) {
    if (opening >= source.size () || source[opening] != open) {
        return std::nullopt;
    }
    int depth = 0;
    char quote = 0;
    bool escaped = false;
    for (std::size_t index = opening; index < source.size (); ++index) {
        const char character = source[index];
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (character == '\\') {
                escaped = true;
            } else if (character == quote) {
                quote = 0;
            }
            continue;
        }
        if (character == '\'' || character == '"') {
            quote = character;
        } else if (character == open) {
            ++depth;
        } else if (character == close && --depth == 0) {
            return source.substr (opening + 1, index - opening - 1);
        }
    }
    return std::nullopt;
}

std::optional<std::vector<std::string>> quotedArray (
    std::string_view source,
    std::string_view variable
) {
    std::size_t opening = std::string_view::npos;
    for (const auto prefix : {"let", "const", "var"}) {
        const std::string marker = std::string (prefix) + std::string (variable) + "=[";
        if (const auto found = source.find (marker); found != std::string_view::npos) {
            if (opening != std::string_view::npos) {
                return std::nullopt;
            }
            opening = found + marker.size () - 1;
        }
    }
    const auto block = balancedBlock (source, opening, '[', ']');
    if (!block.has_value ()) {
        return std::nullopt;
    }
    std::vector<std::string> result;
    std::size_t position = 0;
    while (position < block->size ()) {
        if (block->at (position) != '\'' && block->at (position) != '"') {
            return std::nullopt;
        }
        const char quote = block->at (position++);
        const auto valueStart = position;
        bool escaped = false;
        while (position < block->size ()) {
            const char character = block->at (position);
            if (escaped) {
                escaped = false;
            } else if (character == '\\') {
                escaped = true;
            } else if (character == quote) {
                break;
            }
            ++position;
        }
        if (position == block->size ()) {
            return std::nullopt;
        }
        result.emplace_back (block->substr (valueStart, position - valueStart));
        ++position;
        if (position < block->size () && block->at (position++) != ',') {
            return std::nullopt;
        }
    }
    if (result.empty ()) {
        return std::nullopt;
    }
    return result;
}

std::vector<SoundScriptPropertySchema> propertySchema (std::string_view source) {
    std::vector<SoundScriptPropertySchema> result;
    for (const auto& [method, kind] : {
             std::pair { std::string_view (".addCheckbox("), SoundScriptPropertyKind::checkbox },
             std::pair { std::string_view (".addText("), SoundScriptPropertyKind::text },
         }) {
        std::size_t position = 0;
        while ((position = source.find (method, position)) != std::string_view::npos) {
            const std::size_t opening = position + method.size ();
            const auto block = balancedBlock (source, opening, '{', '}');
            if (!block.has_value ()) {
                return {};
            }
            const auto name = quotedValue (*block, "name");
            if (!name.has_value ()) {
                return {};
            }
            std::string defaultValue;
            if (kind == SoundScriptPropertyKind::text) {
                const auto value = quotedValue (*block, "value");
                if (!value.has_value ()) {
                    return {};
                }
                defaultValue = *value;
            } else if (contains (*block, "value:true")) {
                defaultValue = "true";
            } else if (contains (*block, "value:false")) {
                defaultValue = "false";
            } else {
                return {};
            }
            result.push_back ({
                .name = *name,
                .kind = kind,
                .defaultValue = std::move (defaultValue),
            });
            position = opening + block->size () + 2;
        }
    }
    return result;
}

bool exactPropertySchema (
    const std::vector<SoundScriptPropertySchema>& actual,
    const std::vector<std::pair<std::string_view, SoundScriptPropertyKind>>& expected
) {
    if (actual.size () != expected.size ()) {
        return false;
    }
    return std::ranges::all_of (expected, [&actual] (const auto& item) {
        return std::ranges::count_if (actual, [&item] (const auto& property) {
            return property.name == item.first && property.kind == item.second;
        }) == 1;
    });
}

std::optional<std::string> changedProperty (
    const std::string& source,
    std::string_view suffix
) {
    const std::regex expression (
        std::string (R"(changedUserProperties\.([A-Za-z_$][A-Za-z0-9_$]*))")
        + std::string (suffix)
    );
    std::smatch match;
    if (!std::regex_search (source, match, expression)) {
        return std::nullopt;
    }
    return match[1].str ();
}

bool hasOnlyPlaybackMethods (
    std::string_view source,
    const std::set<std::string_view>& allowed
) {
    const std::regex method (R"(\.([A-Za-z_$][A-Za-z0-9_$]*)\()") ;
    for (auto match = std::cregex_iterator (source.begin (), source.end (), method);
         match != std::cregex_iterator (); ++match) {
        const std::string candidate = (*match)[1].str ();
        if ((candidate == "play" || candidate == "pause" || candidate == "stop"
             || candidate == "isPlaying")
            && !allowed.contains (candidate)) {
            return false;
        }
    }
    return true;
}

std::optional<float> parseFloat (const std::ssub_match& match) {
    float result = 0.0F;
    const std::string value = match.str ();
    const auto parsed = std::from_chars (
        value.data (), value.data () + value.size (), result
    );
    return parsed.ec == std::errc () && parsed.ptr == value.data () + value.size ()
        && std::isfinite (result)
        ? std::optional<float> (result) : std::nullopt;
}

}

std::optional<SoundControllerCapability>
parseDelayedMediaVisibilityCapability (std::string_view source) {
    const auto compact = compactSource (source);
    if (!compact.has_value () || hasForbiddenSurface (*compact)
        || exportedFunctions (*compact)
            != std::set<std::string> ({"applyUserProperties", "init", "update"})
        || declaredFunctions (*compact)
            != std::set<std::string> ({
                "applyUserProperties", "init", "playTargetMusic", "update"
            })
        || !hasOnlyKnownArrows (*compact)
        || rootAPIs (*compact)
            != std::set<std::string> ({"console.warn", "engine.frametime", "thisScene.getLayer"})
        || count (*compact, "thisScene.getLayer(") != 1
        || count (*compact, "for(") != 0
        || count (*compact, "functionplayTargetMusic(") != 1
        || count (*compact, "playTargetMusic(") < 2
        || count (*compact, "playTargetMusic(") > 3
        || count (*compact, "update(") != 1
        || count (*compact, "init(") != 1
        || count (*compact, "applyUserProperties(") != 1
        || !hasOnlyPlaybackMethods (*compact, {"play", "stop", "isPlaying"})
        || !contains (*compact, "musicLayers=songNames.map(song=>thisScene.getLayer(song))")
        || !contains (*compact, "elapsedTime+=engine.frametime")
        || !contains (*compact, "if(elapsedTime>=targetDelay)")
        || !contains (*compact, "parseFloat(scriptProperties.delayTime.trim())")) {
        return std::nullopt;
    }
    const auto layers = quotedArray (*compact, "songNames");
    const auto selection = changedProperty (*compact, R"(===undefined)");
    auto schema = propertySchema (*compact);
    const auto helperStart = compact->find ("functionplayTargetMusic(){");
    const auto helperBody = balancedBlock (
        *compact,
        helperStart == std::string::npos
            ? std::string::npos
            : helperStart + std::string_view ("functionplayTargetMusic()").size (),
        '{', '}'
    );
    if (!layers.has_value () || !selection.has_value ()
        || !helperBody.has_value () || contains (*helperBody, "playTargetMusic(")
        || !exactPropertySchema (schema, {
            {"enableDelay", SoundScriptPropertyKind::checkbox},
            {"delayTime", SoundScriptPropertyKind::text},
        })
        || !contains (*compact, "scriptProperties.enableDelay&&delayValue>0")) {
        return std::nullopt;
    }
    return SoundControllerCapability {
        .kind = SoundControllerCapabilityKind::delayedSelection,
        .selectionProperty = *selection,
        .referencedLayers = *layers,
        .propertySchema = std::move (schema),
        .delayEnabledProperty = "enableDelay",
        .delaySecondsProperty = "delayTime",
    };
}

std::optional<SoundControllerCapability>
parseSoundLayerVisibilityCapability (std::string_view source) {
    const auto compact = compactSource (source);
    if (!compact.has_value () || hasForbiddenSurface (*compact)
        || exportedFunctions (*compact)
            != std::set<std::string> ({"applyUserProperties", "init"})
        || declaredFunctions (*compact)
            != std::set<std::string> ({"applyUserProperties", "init"})
        || !hasOnlyKnownArrows (*compact)
        || rootAPIs (*compact)
            != std::set<std::string> ({"Math.floor", "Math.random", "thisScene.getLayer"})
        || count (*compact, "thisScene.getLayer(") != 1
        || count (*compact, "for(") > 1
        || (count (*compact, "for(") == 1
            && !contains (
                *compact,
                "for(leti=0;i<songNames.length;i++){if(i!==+changedUserProperties."
            ))
        || count (*compact, "update(") != 0
        || count (*compact, "init(") != 1
        || count (*compact, "applyUserProperties(") != 1
        || !hasOnlyPlaybackMethods (*compact, {"play", "stop", "isPlaying"})
        || !contains (*compact, "songNames=songNames.map(song=>thisScene.getLayer(song))")
        || !contains (*compact, "songNames.forEach(song=>song.stop())")
        || !contains (*compact, "Math.floor(Math.random()*songNames.length)")) {
        return std::nullopt;
    }
    const auto layers = quotedArray (*compact, "songNames");
    const auto selection = changedProperty (*compact, R"(!==undefined)");
    if (!layers.has_value () || !selection.has_value ()) {
        return std::nullopt;
    }
    return SoundControllerCapability {
        .kind = SoundControllerCapabilityKind::visibilitySelection,
        .selectionProperty = *selection,
        .referencedLayers = *layers,
    };
}

std::optional<SoundControllerCapability>
parseCursorClickSoundCapability (std::string_view source) {
    const auto compact = compactSource (source);
    if (!compact.has_value () || hasForbiddenSurface (*compact)
        || exportedFunctions (*compact)
            != std::set<std::string> ({"cursorClick", "update"})
        || declaredFunctions (*compact)
            != std::set<std::string> ({"cursorClick", "update"})
        || !hasOnlyKnownArrows (*compact)
        || rootAPIs (*compact)
            != std::set<std::string> ({"engine.frametime", "thisScene.getLayer"})
        || count (*compact, "for(") != 0
        || count (*compact, "cursorClick(") != 1
        || count (*compact, "update(") != 1
        || !hasOnlyPlaybackMethods (*compact, {"play"})) {
        return std::nullopt;
    }
    auto schema = propertySchema (*compact);
    if (!exactPropertySchema (schema, {
            {"count1", SoundScriptPropertyKind::text},
            {"voice1", SoundScriptPropertyKind::text},
            {"count2", SoundScriptPropertyKind::text},
            {"voice2", SoundScriptPropertyKind::text},
            {"waitingtime", SoundScriptPropertyKind::text},
        })) {
        return std::nullopt;
    }
    const std::regex call (
        R"(thisScene\.getLayer\(scriptProperties\.([A-Za-z_$][A-Za-z0-9_$]*)\)\.play\(\))"
    );
    std::vector<std::string> references;
    for (auto match = std::sregex_iterator (compact->begin (), compact->end (), call);
         match != std::sregex_iterator (); ++match) {
        const std::string propertyName = (*match)[1].str ();
        const auto property = std::ranges::find_if (schema, [&propertyName] (const auto& item) {
            return item.name == propertyName && item.kind == SoundScriptPropertyKind::text;
        });
        if (property == schema.end () || property->defaultValue.empty ()) {
            return std::nullopt;
        }
        references.push_back (property->defaultValue);
    }
    if (references.empty () || count (*compact, "thisScene.getLayer(") != references.size ()
        || !contains (*compact, "waitingtime+=engine.frametime")
        || !contains (*compact, "waitingtime>scriptProperties.waitingtime")) {
        return std::nullopt;
    }
    return SoundControllerCapability {
        .kind = SoundControllerCapabilityKind::cursorSingleShot,
        .referencedLayers = std::move (references),
        .propertySchema = std::move (schema),
    };
}

std::optional<SoundControllerCapability>
parseSoundControllerCapability (std::string_view source) {
    if (auto delayed = parseDelayedMediaVisibilityCapability (source)) {
        return delayed;
    }
    if (auto visibility = parseSoundLayerVisibilityCapability (source)) {
        return visibility;
    }
    return parseCursorClickSoundCapability (source);
}

SoundLayerOwnership soundLayerOwnership (
    std::string_view layerName,
    const std::vector<SoundControllerCapability>& controllers
) {
    const bool owned = std::ranges::any_of (controllers, [layerName] (const auto& controller) {
        return std::ranges::find (controller.referencedLayers, layerName)
            != controller.referencedLayers.end ();
    });
    return { .controllerOwned = owned, .startPaused = owned };
}

std::vector<SoundLayerOwnership> soundLayerOwnership (
    const std::vector<std::string>& layerNames,
    const std::vector<SoundControllerCapability>& controllers
) {
    std::vector<SoundLayerOwnership> result (layerNames.size ());
    for (const auto& controller : controllers) {
        for (const auto& reference : controller.referencedLayers) {
            const auto first = std::ranges::find (layerNames, reference);
            if (first == layerNames.end ()
                || std::ranges::find (std::next (first), layerNames.end (), reference)
                    != layerNames.end ()) {
                continue;
            }
            const auto index = static_cast<std::size_t> (
                std::distance (layerNames.begin (), first)
            );
            result[index] = { .controllerOwned = true, .startPaused = true };
        }
    }
    return result;
}

std::optional<MonoAudioAverageTransformCapability>
parseMonoAudioAverageTransformCapability (std::string_view source) {
    const auto compact = compactSource (source);
    if (!compact.has_value () || hasForbiddenSurface (*compact)) {
        return std::nullopt;
    }
    const std::regex expression (
        R"(^'use strict';const([A-Za-z_$][A-Za-z0-9_$]*)=engine\.registerAudioBuffers\((?:engine\.AUDIO_RESOLUTION_)?(16|32|64)\);exportfunctionupdate\(value\)\{value=\(\1\.average\[([0-9]+)\]\|\|([+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))\)\*([+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+));returnvalue;\}$)"
    );
    std::smatch match;
    if (!std::regex_match (*compact, match, expression)) {
        return std::nullopt;
    }
    std::size_t resolution = 0;
    std::size_t bin = 0;
    const std::string resolutionText = match[2].str ();
    const std::string binText = match[3].str ();
    const auto resolutionResult = std::from_chars (
        resolutionText.data (),
        resolutionText.data () + resolutionText.size (),
        resolution
    );
    const auto binResult = std::from_chars (
        binText.data (), binText.data () + binText.size (), bin
    );
    const auto fallback = parseFloat (match[4]);
    const auto gain = parseFloat (match[5]);
    if (resolutionResult.ec != std::errc () || binResult.ec != std::errc ()
        || !fallback.has_value () || !gain.has_value () || bin >= resolution
        || *fallback < 0.0F || *fallback > 1.0F || *gain < 0.0F) {
        return std::nullopt;
    }
    return MonoAudioAverageTransformCapability {
        .resolution = resolution,
        .bin = bin,
        .fallback = *fallback,
        .gain = *gain,
    };
}

}
