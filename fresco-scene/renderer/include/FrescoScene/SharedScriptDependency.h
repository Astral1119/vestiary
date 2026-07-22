#pragma once

#include <array>
#include <map>
#include <string>
#include <string_view>
#include <variant>

namespace FrescoScene {

enum class SharedScriptValueKind {
    boolean,
    number,
    string,
    vector3,
};

using SharedScriptValue = std::variant<
    std::monostate,
    bool,
    double,
    std::string,
    std::array<double, 3>
>;

using SharedScriptState = std::map<std::string, SharedScriptValue>;
using SharedScriptSchema = std::map<std::string, SharedScriptValueKind>;

enum class SharedDependencyStatus {
    applied,
    deferred,
    incompatible,
    unsupported,
};

struct SharedDependencyResult {
    SharedDependencyStatus status;
    SharedScriptValue value;
};

[[nodiscard]] SharedDependencyResult resolveSharedScriptDependency (
    const SharedScriptState& state,
    const SharedScriptSchema& schema,
    std::string_view field,
    const SharedScriptValue& currentValue
);

void mergeSharedScriptDefaults (
    SharedScriptState& state,
    const SharedScriptState& defaults
);

}
