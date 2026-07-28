#include "FrescoScene/TextAlignment.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>

int main () {
    using FrescoScene::computeTextHorizontalSpan;
    using FrescoScene::computeTextVerticalSpan;

    // The named edge sits on the origin. Right alignment was verified on the
    // rendered fixture: Persona's credit line ends exactly at its authored
    // origin x, having overrun the scene edge before it.
    const auto right = computeTextHorizontalSpan ("right", 200.0f);
    assert (right.low == -200.0f && right.high == 0.0f);
    assert (right.centre () == -100.0f);

    const auto left = computeTextHorizontalSpan ("left", 200.0f);
    assert (left.low == 0.0f && left.high == 200.0f);
    assert (left.centre () == 100.0f);

    const auto centred = computeTextHorizontalSpan ("center", 200.0f);
    assert (centred.low == -100.0f && centred.high == 100.0f);
    assert (centred.centre () == 0.0f);

    // Screen top is negative y in the quad space, so top alignment hangs the
    // raster below the origin. Measured by forcing it on Persona: object 626
    // moves 18 capture pixels down, half its 107-pixel raster at the 0.336
    // capture scale, and 887 on the direct path moves 6 down.
    const auto top = computeTextVerticalSpan ("top", 100.0f);
    assert (top.low == 0.0f && top.high == 100.0f);
    assert (top.centre () == 50.0f);

    const auto bottom = computeTextVerticalSpan ("bottom", 100.0f);
    assert (bottom.low == -100.0f && bottom.high == 0.0f);
    assert (bottom.centre () == -50.0f);

    const auto middle = computeTextVerticalSpan ("center", 100.0f);
    assert (middle.low == -50.0f && middle.high == 50.0f);
    assert (middle.centre () == 0.0f);

    // Anything unrecognised centres, which is what 204 of the corpus's 213
    // text objects author outright. An unknown value rendering off-origin
    // would be worse than rendering where it always has.
    const auto unknown = computeTextVerticalSpan ("baseline", 100.0f);
    assert (unknown.low == -50.0f && unknown.high == 50.0f);
    const auto empty = computeTextHorizontalSpan ("", 200.0f);
    assert (empty.low == -100.0f && empty.high == 100.0f);

    // A zero raster has no extent to place, whatever it authors.
    const auto degenerate = computeTextVerticalSpan ("top", 0.0f);
    assert (degenerate.low == 0.0f && degenerate.high == 0.0f);
    assert (degenerate.centre () == 0.0f);

    return 0;
}
