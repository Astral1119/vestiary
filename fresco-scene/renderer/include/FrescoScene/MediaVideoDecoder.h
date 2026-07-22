#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace FrescoScene {

enum class MediaVideoErrorCode {
    none,
    emptyInput,
    unsupportedContainer,
    assetUnavailable,
    missingVideoTrack,
    endOfStream,
    frameDecodeFailed,
};

struct MediaVideoError {
    MediaVideoErrorCode code = MediaVideoErrorCode::none;
    std::string message;
};

enum class MediaVideoPixelFormat {
    bgra8,
};

struct MediaVideoFrame {
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t bytesPerRow = 0;
    double presentationSeconds = 0.0;
    MediaVideoPixelFormat format = MediaVideoPixelFormat::bgra8;
    std::shared_ptr<const std::uint8_t> pixels;
    std::size_t pixelBytes = 0;
};

class MediaVideoDecoder {
public:
    static std::unique_ptr<MediaVideoDecoder> create (
        const void* bytes, std::size_t size, MediaVideoError& error
    );

    ~MediaVideoDecoder ();

    MediaVideoDecoder (const MediaVideoDecoder&) = delete;
    MediaVideoDecoder& operator= (const MediaVideoDecoder&) = delete;

    [[nodiscard]] double durationSeconds () const;
    [[nodiscard]] std::optional<MediaVideoFrame> frameAt (
        double seconds, MediaVideoError& error
    ) const;

private:
    class Impl;

    explicit MediaVideoDecoder (std::unique_ptr<Impl> implementation);

    std::unique_ptr<Impl> m_implementation;
};

[[nodiscard]] const char* mediaVideoErrorName (MediaVideoErrorCode code);

}
