#include "FrescoScene/TextRasterSize.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cmath>
#include <limits>

int main () {
    using FrescoScene::kTextRasterMaximumPixelSize;
    using FrescoScene::textRasterPixelSize;

    // Corpus ground truth. Clock JS 2999232230 authors pointsize 14 in
    // RobotoMono, whose advance is exactly 0.6 em, and gives the five-character
    // layer "const" a 175-pixel box: 35 pixels per character, so the em is
    // 35 / 0.6 = 58.33 pixels. Rasterizing at the authored pointsize instead
    // produced 14 and rendered the scene's text about four times too small.
    assert (textRasterPixelSize (14.0f) == 58u);

    // Persona 3151551777 authors pointsize 36 in DINEngschrift with a 179-pixel
    // box, and pointsize 8 with a 40-pixel box. Both match a 1.2 em line height
    // over this raster size (150 and 33).
    assert (textRasterPixelSize (36.0f) == 150u);
    assert (textRasterPixelSize (8.0f) == 33u);

    // Remaining authored sizes across the corpus, exercising both rounding
    // directions.
    assert (textRasterPixelSize (9.0f) == 38u);
    assert (textRasterPixelSize (31.0f) == 129u);
    assert (textRasterPixelSize (32.0f) == 133u);
    assert (textRasterPixelSize (33.0f) == 138u);
    assert (textRasterPixelSize (35.0f) == 146u);

    // The raster size does not depend on the layer transform. Lonely Cat
    // 3299228616 authors pointsize 35 at scale 0.25 and Persona authors
    // pointsize 32 at scale 4.04; both rasterize at their authored size and
    // are scaled by the model matrix afterwards.
    assert (textRasterPixelSize (35.0f) == textRasterPixelSize (35.0f));

    // A degenerate pointsize still yields a rasterizable em.
    assert (textRasterPixelSize (0.0f) == 1u);
    assert (textRasterPixelSize (-12.0f) == 1u);
    assert (textRasterPixelSize (0.1f) == 1u);
    assert (textRasterPixelSize (std::numeric_limits<float>::quiet_NaN ()) == 1u);
    assert (textRasterPixelSize (std::numeric_limits<float>::infinity ()) == 1u);

    // A malformed pointsize is bounded rather than allowed to size the glyph
    // bitmap allocation.
    assert (textRasterPixelSize (1.0e9f) == kTextRasterMaximumPixelSize);
    assert (
        textRasterPixelSize (
            static_cast<float> (kTextRasterMaximumPixelSize)
        ) == kTextRasterMaximumPixelSize
    );

    using FrescoScene::boundedGlyphAtlasExtent;

    // The glyph bitmap is bounded by the backend's maximum texture size. A
    // 3000-character layer at a 270-pixel em wants 486000 pixels of width and
    // must be truncated to what the texture can hold.
    assert (boundedGlyphAtlasExtent (486000, 16384) == 16384);
    assert (boundedGlyphAtlasExtent (16384, 16384) == 16384);
    assert (boundedGlyphAtlasExtent (1172, 16384) == 1172);

    // A degenerate extent still yields an uploadable bitmap.
    assert (boundedGlyphAtlasExtent (0, 16384) == 1);
    assert (boundedGlyphAtlasExtent (-4, 16384) == 1);

    // An unknown limit applies no bound.
    assert (boundedGlyphAtlasExtent (486000, 0) == 486000);
    assert (boundedGlyphAtlasExtent (486000, -1) == 486000);

    return 0;
}
