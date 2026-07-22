#include "FrescoScene/PassthroughLayerSemantics.h"

#include <cassert>

int main () {
    using FrescoScene::shouldCopyPassthroughBackground;

    assert (shouldCopyPassthroughBackground (false, false));
    assert (shouldCopyPassthroughBackground (false, true));
    assert (!shouldCopyPassthroughBackground (true, false));
    assert (shouldCopyPassthroughBackground (true, true));
}
