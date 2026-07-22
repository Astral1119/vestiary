#include "WallpaperEngine/Data/Builders/ColorBuilder.h"

#include <cmath>

using WallpaperEngine::Data::Builders::ColorBuilder;

namespace {
bool close (float left, float right) { return std::abs (left - right) < 0.0001f; }
}

int main () {
    const auto normalizedWhite = ColorBuilder::parse ("1 1 1");
    if (!close (normalizedWhite.r, 1.0f) || !close (normalizedWhite.g, 1.0f)
        || !close (normalizedWhite.b, 1.0f) || !close (normalizedWhite.a, 1.0f)) {
        return 1;
    }

    const auto normalizedBlack = ColorBuilder::parse ("0 0 0");
    if (!close (normalizedBlack.r, 0.0f) || !close (normalizedBlack.g, 0.0f)
        || !close (normalizedBlack.b, 0.0f) || !close (normalizedBlack.a, 1.0f)) {
        return 2;
    }

    const auto byteColor = ColorBuilder::parse ("128 64 32 255");
    if (!close (byteColor.r, 128.0f / 255.0f) || !close (byteColor.g, 64.0f / 255.0f)
        || !close (byteColor.b, 32.0f / 255.0f) || !close (byteColor.a, 1.0f)) {
        return 3;
    }
}
