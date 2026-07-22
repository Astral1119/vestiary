#include "FrescoScene/ProceduralEffectCompositing.h"

#include <cassert>
#include <map>
#include <string>

int main () {
    using FrescoScene::requiresCoverageCompositing;

    assert (!requiresCoverageCompositing ({}));
    assert (!requiresCoverageCompositing ({ { "DIRECTDRAW", 0 } }));
    assert (requiresCoverageCompositing ({ { "DIRECTDRAW", 1 } }));
    assert (requiresCoverageCompositing ({
        { "DIRECTDRAW", 1 },
        { "RENDERING", 1 },
    }));
    assert (!requiresCoverageCompositing (false, {}, {}));
    assert (requiresCoverageCompositing (true, {}, {}));
    assert (requiresCoverageCompositing (
        false, { { "DIRECTDRAW", 1 } }, {}
    ));
    assert (requiresCoverageCompositing (
        false, {}, { { "DIRECTDRAW", 1 } }
    ));
    return 0;
}
