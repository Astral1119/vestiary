#include "FrescoScene/PassthroughLayerSemantics.h"

namespace FrescoScene {

bool shouldCopyPassthroughBackground (
    bool passthrough,
    bool copyBackground
) {
    return !passthrough || copyBackground;
}

}
