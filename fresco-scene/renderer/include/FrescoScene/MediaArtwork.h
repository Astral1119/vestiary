#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace FrescoScene {

enum class MediaArtworkErrorCode {
    none,
    invalidDataURI,
    unsupportedEncoding,
    payloadTooLarge,
    invalidBase64,
    decodeFailed,
    dimensionsTooLarge,
};

struct MediaArtworkError {
    MediaArtworkErrorCode code = MediaArtworkErrorCode::none;
    std::string message;
};

struct MediaArtworkImage {
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::vector<std::uint8_t> rgba;
};

[[nodiscard]] std::shared_ptr<const MediaArtworkImage> decodeMediaArtwork (
    std::string_view dataURI, MediaArtworkError& error
);

enum class MediaArtworkUpdate {
    unchanged,
    updated,
    cleared,
    rejected,
};

struct MediaArtworkSnapshot {
    std::shared_ptr<const MediaArtworkImage> current;
    std::shared_ptr<const MediaArtworkImage> previous;
    std::string uri;
    MediaArtworkError lastError;
    std::size_t revision = 0;
};

class MediaArtworkState {
public:
    [[nodiscard]] MediaArtworkUpdate apply (
        const std::optional<std::string>& dataURI
    );
    [[nodiscard]] const MediaArtworkSnapshot& snapshot () const;

private:
    MediaArtworkSnapshot m_snapshot;
};

[[nodiscard]] const char* mediaArtworkErrorName (MediaArtworkErrorCode code);

}
