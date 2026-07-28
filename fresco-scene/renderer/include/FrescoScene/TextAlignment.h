#pragma once

#include <string_view>

namespace FrescoScene {

// Where a text raster sits relative to its authored origin, in the quad space
// CText builds its vertices in: +x is screen right, +y is screen bottom.
//
// The named edge sits on the origin. `right` puts the raster's right edge
// there, so the glyphs run left into negative x; `top` puts its top edge there,
// so they run down into positive y. Anything else centres, which is what all
// but nine objects in the corpus author.
struct TextQuadSpan {
    float low = 0.0f;
    float high = 0.0f;

    // The composited path renders the raster centred in its FBO and places
    // that FBO with an origin offset, so it needs the span's centre rather
    // than its ends.
    [[nodiscard]] constexpr float centre () const { return (low + high) * 0.5f; }
};

[[nodiscard]] TextQuadSpan computeTextHorizontalSpan (
    std::string_view alignment, float widthPixels
);
[[nodiscard]] TextQuadSpan computeTextVerticalSpan (
    std::string_view alignment, float heightPixels
);

}
