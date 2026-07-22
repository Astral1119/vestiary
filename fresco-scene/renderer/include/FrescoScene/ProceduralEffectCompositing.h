#pragma once

#include <map>
#include <string>

namespace FrescoScene {

// DIRECTDRAW effect shaders synthesize color from a transparent source. Their
// alpha channel is coverage and must participate in final scene compositing.
[[nodiscard]] bool requiresCoverageCompositing (
    const std::map<std::string, int>& shaderCombos
);

// Passthrough images sample the existing scene and may replace their source
// alpha with effect coverage. The final scene pass must honor that alpha.
[[nodiscard]] bool requiresCoverageCompositing (
    bool passthroughImage,
    const std::map<std::string, int>& passCombos,
    const std::map<std::string, int>& overrideCombos
);

}
