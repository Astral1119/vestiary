#include "FrescoScene/MediaArtwork.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <limits>

using namespace FrescoScene;

namespace {

constexpr std::size_t maximumEncodedBytes = 32U * 1024U * 1024U;
constexpr std::uint32_t maximumDimension = 8192U;
constexpr std::uint64_t maximumPixels = 64U * 1024U * 1024U;

void setError (
    MediaArtworkError& error, MediaArtworkErrorCode code, std::string message
) {
    error = { .code = code, .message = std::move (message) };
}

}

std::shared_ptr<const MediaArtworkImage> FrescoScene::decodeMediaArtwork (
    std::string_view dataURI, MediaArtworkError& error
) {
    error = {};
    constexpr std::string_view prefix = "data:image/";
    if (!dataURI.starts_with (prefix)) {
        setError (
            error, MediaArtworkErrorCode::invalidDataURI,
            "media artwork must be an image data URI"
        );
        return nullptr;
    }
    const auto separator = dataURI.find (',');
    if (separator == std::string_view::npos
        || !dataURI.substr (0, separator).ends_with (";base64")) {
        setError (
            error, MediaArtworkErrorCode::unsupportedEncoding,
            "media artwork data URI must use base64 encoding"
        );
        return nullptr;
    }
    const std::string_view encoded = dataURI.substr (separator + 1);
    if (encoded.empty ()) {
        setError (
            error, MediaArtworkErrorCode::invalidBase64,
            "media artwork base64 payload is empty"
        );
        return nullptr;
    }
    if (encoded.size () > maximumEncodedBytes) {
        setError (
            error, MediaArtworkErrorCode::payloadTooLarge,
            "media artwork base64 payload exceeds 32 MiB"
        );
        return nullptr;
    }

    NSString* encodedString = [[NSString alloc]
        initWithBytes:encoded.data ()
        length:encoded.size ()
        encoding:NSASCIIStringEncoding];
    NSData* bytes = encodedString == nil ? nil : [[NSData alloc]
        initWithBase64EncodedString:encodedString options:0];
    if (bytes == nil) {
        setError (
            error, MediaArtworkErrorCode::invalidBase64,
            "media artwork payload is not valid base64"
        );
        return nullptr;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData (
        (__bridge CFDataRef) bytes, nullptr
    );
    if (source == nullptr || CGImageSourceGetCount (source) == 0) {
        if (source != nullptr) {
            CFRelease (source);
        }
        setError (
            error, MediaArtworkErrorCode::decodeFailed,
            "media artwork payload is not a supported image"
        );
        return nullptr;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex (source, 0, nullptr);
    CFRelease (source);
    if (image == nullptr) {
        setError (
            error, MediaArtworkErrorCode::decodeFailed,
            "media artwork image could not be decoded"
        );
        return nullptr;
    }

    const std::size_t width = CGImageGetWidth (image);
    const std::size_t height = CGImageGetHeight (image);
    const std::uint64_t pixels = static_cast<std::uint64_t> (width) * height;
    if (width == 0 || height == 0 || width > maximumDimension
        || height > maximumDimension || pixels > maximumPixels) {
        CGImageRelease (image);
        setError (
            error, MediaArtworkErrorCode::dimensionsTooLarge,
            "media artwork dimensions are empty or exceed the 8192 pixel limit"
        );
        return nullptr;
    }

    auto result = std::make_shared<MediaArtworkImage> ();
    result->width = static_cast<std::uint32_t> (width);
    result->height = static_cast<std::uint32_t> (height);
    result->rgba.resize (static_cast<std::size_t> (pixels) * 4U);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB ();
    CGContextRef context = CGBitmapContextCreate (
        result->rgba.data (), width, height, 8, width * 4U, colorSpace,
        static_cast<CGBitmapInfo> (
            static_cast<unsigned> (kCGImageAlphaPremultipliedLast)
            | static_cast<unsigned> (kCGBitmapByteOrder32Big)
        )
    );
    CGColorSpaceRelease (colorSpace);
    if (context == nullptr) {
        CGImageRelease (image);
        setError (
            error, MediaArtworkErrorCode::decodeFailed,
            "media artwork RGBA buffer could not be created"
        );
        return nullptr;
    }
    CGContextTranslateCTM (context, 0.0, static_cast<CGFloat> (height));
    CGContextScaleCTM (context, 1.0, -1.0);
    CGContextDrawImage (
        context, CGRectMake (0.0, 0.0, width, height), image
    );
    CGContextRelease (context);
    CGImageRelease (image);
    return result;
}

MediaArtworkUpdate MediaArtworkState::apply (
    const std::optional<std::string>& dataURI
) {
    if (!dataURI.has_value () || dataURI->empty ()) {
        if (m_snapshot.current == nullptr && m_snapshot.uri.empty ()) {
            return MediaArtworkUpdate::unchanged;
        }
        m_snapshot.current.reset ();
        m_snapshot.previous.reset ();
        m_snapshot.uri.clear ();
        m_snapshot.lastError = {};
        ++m_snapshot.revision;
        return MediaArtworkUpdate::cleared;
    }
    if (*dataURI == m_snapshot.uri && m_snapshot.current != nullptr) {
        return MediaArtworkUpdate::unchanged;
    }

    MediaArtworkError error;
    auto decoded = decodeMediaArtwork (*dataURI, error);
    if (decoded == nullptr) {
        m_snapshot.lastError = std::move (error);
        return MediaArtworkUpdate::rejected;
    }
    m_snapshot.previous = m_snapshot.current;
    m_snapshot.current = std::move (decoded);
    m_snapshot.uri = *dataURI;
    m_snapshot.lastError = {};
    ++m_snapshot.revision;
    return MediaArtworkUpdate::updated;
}

const MediaArtworkSnapshot& MediaArtworkState::snapshot () const {
    return m_snapshot;
}

const char* FrescoScene::mediaArtworkErrorName (MediaArtworkErrorCode code) {
    switch (code) {
        case MediaArtworkErrorCode::none: return "none";
        case MediaArtworkErrorCode::invalidDataURI: return "invalid-data-uri";
        case MediaArtworkErrorCode::unsupportedEncoding:
            return "unsupported-encoding";
        case MediaArtworkErrorCode::payloadTooLarge: return "payload-too-large";
        case MediaArtworkErrorCode::invalidBase64: return "invalid-base64";
        case MediaArtworkErrorCode::decodeFailed: return "decode-failed";
        case MediaArtworkErrorCode::dimensionsTooLarge:
            return "dimensions-too-large";
    }
    return "unknown";
}
