#include "FrescoScene/TextRasterSize.h"

#include <algorithm>
#include <cmath>

namespace FrescoScene {

unsigned int textRasterPixelSize (float pointSize) {
    if (!std::isfinite (pointSize) || pointSize <= 0.0f) {
        return 1u;
    }

    const double pixels = std::lround (
        static_cast<double> (pointSize) * kTextRasterPixelsPerPoint
    );
    if (pixels >= static_cast<double> (kTextRasterMaximumPixelSize)) {
        return kTextRasterMaximumPixelSize;
    }
    return std::max (1u, static_cast<unsigned int> (pixels));
}

int boundedGlyphAtlasExtent (int requestedPixels, int maximumPixels) {
    const int requested = std::max (1, requestedPixels);
    if (maximumPixels <= 0) {
        return requested;
    }
    return std::min (requested, maximumPixels);
}

}
