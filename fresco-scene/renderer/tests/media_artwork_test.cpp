#include "FrescoScene/MediaArtwork.h"

#include <cstdlib>
#include <optional>
#include <string>

using namespace FrescoScene;

namespace {

void require (bool condition) {
    if (!condition) {
        std::abort ();
    }
}

constexpr const char* image =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY"
    "42YAAAAASUVORK5CYII=";

}

int main () {
    MediaArtworkError error;
    require (decodeMediaArtwork ("https://example.com/cover.png", error) == nullptr);
    require (error.code == MediaArtworkErrorCode::invalidDataURI);

    const std::string first = std::string ("data:image/png;base64,") + image;
    auto decoded = decodeMediaArtwork (first, error);
    require (decoded != nullptr);
    require (decoded->width == 1 && decoded->height == 1);
    require (decoded->rgba.size () == 4);
    require (error.code == MediaArtworkErrorCode::none);

    MediaArtworkState state;
    require (state.apply (first) == MediaArtworkUpdate::updated);
    require (state.snapshot ().revision == 1);
    require (state.snapshot ().current != nullptr);
    require (state.snapshot ().previous == nullptr);
    require (state.apply (first) == MediaArtworkUpdate::unchanged);
    require (state.snapshot ().revision == 1);

    const std::string second = std::string ("data:image/x-png;base64,") + image;
    require (state.apply (second) == MediaArtworkUpdate::updated);
    require (state.snapshot ().revision == 2);
    require (state.snapshot ().current != nullptr);
    require (state.snapshot ().previous != nullptr);

    const auto current = state.snapshot ().current;
    require (state.apply (std::string ("data:image/png;base64,AAAA"))
        == MediaArtworkUpdate::rejected);
    require (state.snapshot ().revision == 2);
    require (state.snapshot ().current == current);
    require (state.snapshot ().lastError.code == MediaArtworkErrorCode::decodeFailed);

    require (state.apply (std::nullopt) == MediaArtworkUpdate::cleared);
    require (state.snapshot ().revision == 3);
    require (state.snapshot ().current == nullptr);
    require (state.snapshot ().previous == nullptr);
    require (state.apply (std::nullopt) == MediaArtworkUpdate::unchanged);
}
