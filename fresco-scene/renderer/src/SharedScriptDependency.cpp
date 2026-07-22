#include "FrescoScene/SharedScriptDependency.h"

#include <utility>

namespace FrescoScene {
namespace {

bool matches (
    const SharedScriptValue& value,
    SharedScriptValueKind expected
) {
    switch (expected) {
        case SharedScriptValueKind::boolean:
            return std::holds_alternative<bool> (value);
        case SharedScriptValueKind::number:
            return std::holds_alternative<double> (value);
        case SharedScriptValueKind::string:
            return std::holds_alternative<std::string> (value);
        case SharedScriptValueKind::vector3:
            return std::holds_alternative<std::array<double, 3>> (value);
    }
    return false;
}

}

SharedDependencyResult resolveSharedScriptDependency (
    const SharedScriptState& state,
    const SharedScriptSchema& schema,
    std::string_view field,
    const SharedScriptValue& currentValue
) {
    const auto expected = schema.find (std::string (field));
    if (expected == schema.end ()) {
        return { SharedDependencyStatus::unsupported, currentValue };
    }
    const auto candidate = state.find (std::string (field));
    if (candidate == state.end ()) {
        return { SharedDependencyStatus::deferred, currentValue };
    }
    if (!matches (candidate->second, expected->second)) {
        return { SharedDependencyStatus::incompatible, currentValue };
    }
    return { SharedDependencyStatus::applied, candidate->second };
}

void mergeSharedScriptDefaults (
    SharedScriptState& state,
    const SharedScriptState& defaults
) {
    for (const auto& [name, value] : defaults) {
        state.try_emplace (name, value);
    }
}

}
