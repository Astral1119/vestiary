#include "FrescoScene/ProceduralEffectCompositing.h"

namespace FrescoScene {

bool requiresCoverageCompositing (
    const std::map<std::string, int>& shaderCombos
) {
    const auto directDraw = shaderCombos.find ("DIRECTDRAW");
    return directDraw != shaderCombos.end () && directDraw->second == 1;
}

bool requiresCoverageCompositing (
    bool passthroughImage,
    const std::map<std::string, int>& passCombos,
    const std::map<std::string, int>& overrideCombos
) {
    return passthroughImage
        || requiresCoverageCompositing (passCombos)
        || requiresCoverageCompositing (overrideCombos);
}

}
