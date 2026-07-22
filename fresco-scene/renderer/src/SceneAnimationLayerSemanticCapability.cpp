#include "FrescoScene/SceneAnimationLayerSemanticCapability.h"

#include <regex>
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
            } else if (character == '\n' || character == '\r') {
                return std::nullopt;
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
            if (index + 1 >= source.size ()) {
                return std::nullopt;
            }
            ++index;
            continue;
        }
        if (character != ' ' && character != '\t' && character != '\n'
            && character != '\r') {
            result.push_back (character);
        }
    }
    return quote == 0 ? std::optional<std::string> (std::move (result))
                      : std::nullopt;
}

}

std::optional<LocalAnimationLayerPlayClickCapability>
parseLocalAnimationLayerPlayClickCapability (std::string_view source) {
    const auto compact = compactSource (source);
    if (!compact.has_value ()) {
        return std::nullopt;
    }
    const std::regex expression (
        R"REGEX(^(?:'use strict';|"use strict";)?exportfunctioncursorClick\([A-Za-z_$][A-Za-z0-9_$]*\)\{thisLayer\.getAnimationLayer\((?:"([^"\\\r\n]+)"|'([^'\\\r\n]+)')\)\.play\(\);\};?$)REGEX"
    );
    std::smatch match;
    if (!std::regex_match (*compact, match, expression)) {
        return std::nullopt;
    }
    const std::string target = match[1].matched ? match[1].str () : match[2].str ();
    if (target.empty ()) {
        return std::nullopt;
    }
    return LocalAnimationLayerPlayClickCapability { .targetName = target };
}

bool isTopologyProvenInert (
    const LocalAnimationLayerPlayClickCapability& capability,
    const LocalAnimationLayerTopology& topology
) {
    return !capability.targetName.empty ()
        && topology.imageObject
        && topology.serializedAnimationLayerCount == 0
        && topology.effectCount == 0
        && topology.modelPresent
        && topology.modelAutosize
        && !topology.puppetModel
        && topology.materialPassCount == 1
        && topology.materialShader == "genericimage4"
        && topology.textureImageCount == 1
        && !topology.textureAnimated
        && !topology.requestedNamedAnimationPresent;
}

}
