#include "FrescoScene/SceneScriptCompatibility.h"
#include "FrescoScene/SharedScriptDependency.h"

#include <array>
#include <cassert>
#include <string>
#include <string_view>

namespace {

constexpr auto nightWriter = R"JS('use strict';

import * as WEMath from 'WEMath';

const START_HOUR = 20;
const END_HOUR = 5;
const BLEND_DURATION = 0.004;

export function update(value) {
    if (engine.userProperties.timeofday == 2) {
        value = 1;
    } else if (engine.userProperties.timeofday == 99) {
        value = Math.max(
            WEMath.smoothStep((START_HOUR - BLEND_DURATION) / 24, START_HOUR / 24, engine.timeOfDay),
            WEMath.smoothStep(END_HOUR / 24, (END_HOUR - BLEND_DURATION) / 24, engine.timeOfDay));
    }else {
        value = 0;
    }

    shared.night = value;
    shared.shownight = value > 0;

    return value;
})JS";

constexpr auto sunsetWriter = R"JS('use strict';

import * as WEMath from 'WEMath';

const START_HOUR = 17;
const END_HOUR = 20;
const BLEND_DURATION = 0.004;

export function update(value) {
    if (engine.userProperties.timeofday == 1) {
        value = 1;
    } else if (engine.userProperties.timeofday == 99) {
        value = Math.max(
            WEMath.smoothStep((START_HOUR - BLEND_DURATION) / 24, START_HOUR / 24, engine.timeOfDay) *
            WEMath.smoothStep(END_HOUR / 24, (END_HOUR - BLEND_DURATION) / 24, engine.timeOfDay));
    }else {
        value = 0;
    }

    shared.sunset = value;
    shared.showsunset = value > 0;

return value;
})JS";

constexpr auto nightReader = R"JS('use strict';

export function update(value) {
	value = shared.shownight;
	return value;
}
)JS";

constexpr auto sunsetReader = R"JS('use strict';

export function update(value) {
	value = shared.showsunset;
	return value;
}
)JS";

void requireResult (
    const FrescoScene::SharedDependencyResult& result,
    FrescoScene::SharedDependencyStatus status,
    const FrescoScene::SharedScriptValue& value
) {
    assert (result.status == status);
    assert (result.value == value);
}

}

int main () {
    using namespace FrescoScene;

    const auto classifiedNightWriter = classifyScenePropertyScript (
        "effect_multiply", SceneScriptValueKind::integer, nightWriter
    );
    assert (classifiedNightWriter.supported);
    assert (classifiedNightWriter.profile == "generic-time-shared-state-v1");
    const auto classifiedSunsetWriter = classifyScenePropertyScript (
        "effect_multiply", SceneScriptValueKind::integer, sunsetWriter
    );
    assert (classifiedSunsetWriter.supported);
    assert (classifiedSunsetWriter.profile == "generic-time-shared-state-v1");

    const auto classifiedNightReader = classifyScenePropertyScript (
        "effect_visible", SceneScriptValueKind::boolean, nightReader
    );
    assert (classifiedNightReader.supported);
    assert (classifiedNightReader.profile == "generic-shared-state-value-v1");
    const auto classifiedSunsetReader = classifyScenePropertyScript (
        "effect_visible", SceneScriptValueKind::boolean, sunsetReader
    );
    assert (classifiedSunsetReader.supported);
    assert (classifiedSunsetReader.profile == "generic-shared-state-value-v1");

    const SharedScriptSchema schema {
        {"night", SharedScriptValueKind::number},
        {"shownight", SharedScriptValueKind::boolean},
        {"sunset", SharedScriptValueKind::number},
        {"showsunset", SharedScriptValueKind::boolean},
        {"miTextContainerScale", SharedScriptValueKind::vector3},
    };
    SharedScriptState state;

    requireResult (
        resolveSharedScriptDependency (state, schema, "shownight", false),
        SharedDependencyStatus::deferred,
        false
    );
    requireResult (
        resolveSharedScriptDependency (state, schema, "showsunset", false),
        SharedDependencyStatus::deferred,
        false
    );

    state.insert_or_assign ("shownight", true);
    requireResult (
        resolveSharedScriptDependency (state, schema, "shownight", false),
        SharedDependencyStatus::applied,
        true
    );
    state.insert_or_assign ("showsunset", false);
    requireResult (
        resolveSharedScriptDependency (state, schema, "showsunset", true),
        SharedDependencyStatus::applied,
        false
    );

    for (const SharedScriptValue& wrong : {
             SharedScriptValue {std::monostate {}},
             SharedScriptValue {1.0},
             SharedScriptValue {std::string ("true")},
             SharedScriptValue {std::array<double, 3> {1.0, 1.0, 1.0}},
         }) {
        state.insert_or_assign ("shownight", wrong);
        requireResult (
            resolveSharedScriptDependency (state, schema, "shownight", false),
            SharedDependencyStatus::incompatible,
            false
        );
    }

    state.insert_or_assign ("unmodeled", true);
    requireResult (
        resolveSharedScriptDependency (state, schema, "unmodeled", false),
        SharedDependencyStatus::unsupported,
        false
    );
    requireResult (
        resolveSharedScriptDependency (
            state, schema, "shownight", SharedScriptValue {1.0}
        ),
        SharedDependencyStatus::incompatible,
        SharedScriptValue {1.0}
    );
    state.insert_or_assign ("shownight", true);
    requireResult (
        resolveSharedScriptDependency (
            state, schema, "shownight",
            SharedScriptValue {std::array<double, 3> {1.0, 1.0, 1.0}}
        ),
        SharedDependencyStatus::applied,
        true
    );

    SharedScriptState readerFirst;
    requireResult (
        resolveSharedScriptDependency (readerFirst, schema, "shownight", false),
        SharedDependencyStatus::deferred,
        false
    );
    readerFirst.insert_or_assign ("shownight", true);
    requireResult (
        resolveSharedScriptDependency (readerFirst, schema, "shownight", false),
        SharedDependencyStatus::applied,
        true
    );

    SharedScriptState writerFirst {{"shownight", true}};
    requireResult (
        resolveSharedScriptDependency (writerFirst, schema, "shownight", false),
        SharedDependencyStatus::applied,
        true
    );

    SharedScriptState graphState {
        {"shownight", true},
        {"night", 1.0},
    };
    mergeSharedScriptDefaults (graphState, {
        {"shownight", false},
        {"miTextContainerScale", std::array<double, 3> {1.0, 1.0, 1.0}},
    });
    assert (graphState.at ("shownight") == SharedScriptValue (true));
    assert (graphState.at ("night") == SharedScriptValue (1.0));
    assert (graphState.at ("miTextContainerScale") == SharedScriptValue (
        std::array<double, 3> {1.0, 1.0, 1.0}
    ));
}
