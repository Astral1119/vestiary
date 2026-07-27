#pragma once

namespace FrescoScene {

// Wallpaper Engine rasterizes text at 300 DPI against a 72-point em, so the
// FreeType pixel size for an authored `pointsize` is pointsize * 300/72. The
// layer transform is applied separately by the model matrix and takes no part
// in choosing the raster size.
inline constexpr double kTextRasterPixelsPerPoint = 300.0 / 72.0;

// Upper bound on the raster em, guarding FreeType and the glyph bitmap
// allocation against a malformed pointsize. Exceeds the tallest text a 4K
// scene can display.
inline constexpr unsigned int kTextRasterMaximumPixelSize = 2048u;

[[nodiscard]] unsigned int textRasterPixelSize (float pointSize);

// A rendered string becomes one glyph bitmap uploaded as a single texture, so
// neither extent can exceed the backend's maximum texture size. Rasterizing at
// the authored size makes that reachable: at a 270-pixel em a single-row layer
// crosses a 16384-pixel limit at roughly a hundred characters. Text beyond the
// bound is truncated, since the texture cannot carry it either way.
// A non-positive maximum reports an unknown limit and applies no bound.
[[nodiscard]] int boundedGlyphAtlasExtent (int requestedPixels, int maximumPixels);

}
