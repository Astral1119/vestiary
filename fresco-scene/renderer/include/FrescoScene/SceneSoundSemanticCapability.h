#pragma once

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace FrescoScene {

enum class SoundControllerCapabilityKind {
    delayedSelection,
    visibilitySelection,
    cursorSingleShot,
};

enum class SoundScriptPropertyKind {
    checkbox,
    text,
};

struct SoundScriptPropertySchema {
    std::string name;
    SoundScriptPropertyKind kind = SoundScriptPropertyKind::text;
    std::string defaultValue;
};

struct SoundControllerCapability {
    SoundControllerCapabilityKind kind;
    std::string selectionProperty;
    std::vector<std::string> referencedLayers;
    std::vector<SoundScriptPropertySchema> propertySchema;
    std::optional<std::string> delayEnabledProperty;
    std::optional<std::string> delaySecondsProperty;
};

struct SoundLayerOwnership {
    bool controllerOwned = false;
    bool startPaused = false;
};

struct MonoAudioAverageTransformCapability {
    std::size_t resolution = 0;
    std::size_t bin = 0;
    float fallback = 0.0F;
    float gain = 0.0F;
};

[[nodiscard]] std::optional<SoundControllerCapability>
parseDelayedMediaVisibilityCapability (std::string_view source);

[[nodiscard]] std::optional<SoundControllerCapability>
parseSoundLayerVisibilityCapability (std::string_view source);

[[nodiscard]] std::optional<SoundControllerCapability>
parseCursorClickSoundCapability (std::string_view source);

[[nodiscard]] std::optional<SoundControllerCapability>
parseSoundControllerCapability (std::string_view source);

[[nodiscard]] SoundLayerOwnership soundLayerOwnership (
    std::string_view layerName,
    const std::vector<SoundControllerCapability>& controllers
);

[[nodiscard]] std::vector<SoundLayerOwnership> soundLayerOwnership (
    const std::vector<std::string>& layerNames,
    const std::vector<SoundControllerCapability>& controllers
);

[[nodiscard]] std::optional<MonoAudioAverageTransformCapability>
parseMonoAudioAverageTransformCapability (std::string_view source);

}
