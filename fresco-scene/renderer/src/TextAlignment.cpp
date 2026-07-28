#include "FrescoScene/TextAlignment.h"

namespace FrescoScene {

TextQuadSpan computeTextHorizontalSpan (
    std::string_view alignment, float widthPixels
) {
    if (alignment == "right") {
        return { .low = -widthPixels, .high = 0.0f };
    }
    if (alignment == "left") {
        return { .low = 0.0f, .high = widthPixels };
    }
    return { .low = -widthPixels * 0.5f, .high = widthPixels * 0.5f };
}

TextQuadSpan computeTextVerticalSpan (
    std::string_view alignment, float heightPixels
) {
    // Screen top is negative y in this space, so a top-aligned raster hangs
    // below its origin and a bottom-aligned one sits above it. The comment in
    // CText::uploadQuadVertices is the reference for that direction: the quad
    // vertex at -hy carries texcoord v=0, which is the FreeType glyph top.
    if (alignment == "top") {
        return { .low = 0.0f, .high = heightPixels };
    }
    if (alignment == "bottom") {
        return { .low = -heightPixels, .high = 0.0f };
    }
    return { .low = -heightPixels * 0.5f, .high = heightPixels * 0.5f };
}

}
