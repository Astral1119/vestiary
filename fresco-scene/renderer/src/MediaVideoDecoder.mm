#include "FrescoScene/MediaVideoDecoder.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <utility>

using namespace FrescoScene;

namespace {

void setError (
    MediaVideoError& error, MediaVideoErrorCode code, const std::string& message
) {
    error = { .code = code, .message = message };
}

std::string description (NSError* error) {
    if (error == nil) {
        return "unknown AVFoundation error";
    }
    return std::string ([[error localizedDescription] UTF8String]);
}

bool isISOBaseMedia (const std::uint8_t* bytes, std::size_t size) {
    return size >= 12 && std::memcmp (bytes + 4, "ftyp", 4) == 0;
}

}

class MediaVideoDecoder::Impl {
public:
    bool startReader (double seconds, MediaVideoError& error) const {
        NSError* readerError = nil;
        // Releasing the last reference to a reader still in the reading state
        // does not tear down its decode session: the session's AppleAVD DMA
        // allocation (~27 MB measured) is held until the process exits. Every
        // loop wrap lands here, so an uncancelled reader per wrap is unbounded
        // growth in wired kernel memory that no process RSS reports.
        if (reader != nil) {
            [reader cancelReading];
        }
        reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
        if (reader == nil) {
            setError (
                error, MediaVideoErrorCode::frameDecodeFailed,
                "cannot create video texture reader: " + description (readerError)
            );
            return false;
        }

        NSDictionary* outputSettings = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey:
                @(kCVPixelFormatType_32BGRA),
            (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        output = [[AVAssetReaderTrackOutput alloc]
            initWithTrack:track outputSettings:outputSettings];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) {
            setError (
                error, MediaVideoErrorCode::frameDecodeFailed,
                "cannot attach video texture reader output"
            );
            return false;
        }
        [reader addOutput:output];
        const double remaining = std::max (0.0, duration - seconds);
        reader.timeRange = CMTimeRangeMake (
            CMTimeMakeWithSeconds (seconds, 600),
            CMTimeMakeWithSeconds (remaining, 600)
        );
        if (![reader startReading]) {
            setError (
                error, MediaVideoErrorCode::frameDecodeFailed,
                "cannot start video texture reader: "
                    + description (reader.error)
            );
            return false;
        }
        lastPresentationSeconds = -1.0;
        return true;
    }

    NSURL* url = nil;
    AVURLAsset* asset = nil;
    AVAssetTrack* track = nil;
    mutable AVAssetReader* reader = nil;
    mutable AVAssetReaderTrackOutput* output = nil;
    mutable double lastPresentationSeconds = -1.0;
    double duration = 0.0;
};

MediaVideoDecoder::MediaVideoDecoder (std::unique_ptr<Impl> implementation) :
    m_implementation (std::move (implementation)) { }

MediaVideoDecoder::~MediaVideoDecoder () {
    if (m_implementation && m_implementation->url != nil) {
        [[NSFileManager defaultManager] removeItemAtURL:m_implementation->url error:nil];
    }
}

std::unique_ptr<MediaVideoDecoder> MediaVideoDecoder::create (
    const void* rawBytes, std::size_t size, MediaVideoError& error
) {
    error = {};
    if (rawBytes == nullptr || size == 0) {
        setError (error, MediaVideoErrorCode::emptyInput, "video payload is empty");
        return nullptr;
    }

    const auto* bytes = static_cast<const std::uint8_t*> (rawBytes);
    if (!isISOBaseMedia (bytes, size)) {
        setError (
            error, MediaVideoErrorCode::unsupportedContainer,
            "video texture payload is not an ISO base media container"
        );
        return nullptr;
    }

    auto implementation = std::make_unique<Impl> ();
    NSString* filename = [NSString stringWithFormat:
        @"fresco-scene-video-%@.mp4", [[NSUUID UUID] UUIDString]];
    implementation->url = [NSURL fileURLWithPath:
        [NSTemporaryDirectory () stringByAppendingPathComponent:filename]];

    NSData* data = [NSData dataWithBytes:rawBytes length:size];
    NSError* writeError = nil;
    if (![data writeToURL:implementation->url options:NSDataWritingAtomic error:&writeError]) {
        setError (
            error, MediaVideoErrorCode::assetUnavailable,
            "cannot stage video texture: " + description (writeError)
        );
        return nullptr;
    }

    implementation->asset = [AVURLAsset URLAssetWithURL:implementation->url options:nil];
    NSArray<AVAssetTrack*>* tracks =
        [implementation->asset tracksWithMediaType:AVMediaTypeVideo];
    if ([tracks count] == 0) {
        [[NSFileManager defaultManager] removeItemAtURL:implementation->url error:nil];
        implementation->url = nil;
        setError (
            error, MediaVideoErrorCode::missingVideoTrack,
            "ISO base media payload has no decodable video track"
        );
        return nullptr;
    }

    implementation->track = tracks[0];

    const double duration = CMTimeGetSeconds (implementation->asset.duration);
    implementation->duration = std::isfinite (duration) ? std::max (0.0, duration) : 0.0;
    return std::unique_ptr<MediaVideoDecoder> (
        new MediaVideoDecoder (std::move (implementation))
    );
}

double MediaVideoDecoder::durationSeconds () const {
    return m_implementation->duration;
}

std::optional<MediaVideoFrame> MediaVideoDecoder::frameAt (
    double seconds, MediaVideoError& error
) const {
    error = {};
    const double upperBound = m_implementation->duration > 0.0
        ? std::nextafter (m_implementation->duration, 0.0)
        : 0.0;
    const double requested = std::clamp (
        std::isfinite (seconds) ? seconds : 0.0, 0.0, upperBound
    );
    if (m_implementation->reader == nil
        || requested + 0.001 < m_implementation->lastPresentationSeconds) {
        if (!m_implementation->startReader (requested, error)) {
            return std::nullopt;
        }
    }

    CMSampleBufferRef sample = nullptr;
    double presentationSeconds = 0.0;
    do {
        if (sample != nullptr) {
            CFRelease (sample);
        }
        sample = [m_implementation->output copyNextSampleBuffer];
        if (sample == nullptr) {
            break;
        }
        presentationSeconds = CMTimeGetSeconds (
            CMSampleBufferGetPresentationTimeStamp (sample)
        );
    } while (std::isfinite (presentationSeconds)
        && presentationSeconds + 0.0005 < requested);

    if (sample == nullptr) {
        if (m_implementation->reader.status == AVAssetReaderStatusCompleted) {
            setError (
                error, MediaVideoErrorCode::endOfStream,
                "video texture has no sample at or after the requested time"
            );
            return std::nullopt;
        }
        setError (
            error, MediaVideoErrorCode::frameDecodeFailed,
            "cannot decode video texture frame: "
                + description (m_implementation->reader.error)
        );
        return std::nullopt;
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer (sample);
    if (pixelBuffer == nullptr) {
        CFRelease (sample);
        setError (
            error, MediaVideoErrorCode::frameDecodeFailed,
            "decoded video texture sample has no pixel buffer"
        );
        return std::nullopt;
    }
    CVPixelBufferRetain (pixelBuffer);
    CFRelease (sample);
    const CVReturn lockResult = CVPixelBufferLockBaseAddress (
        pixelBuffer, kCVPixelBufferLock_ReadOnly
    );
    if (lockResult != kCVReturnSuccess) {
        CVPixelBufferRelease (pixelBuffer);
        setError (
            error, MediaVideoErrorCode::frameDecodeFailed,
            "cannot lock decoded video texture pixel buffer"
        );
        return std::nullopt;
    }

    MediaVideoFrame frame;
    frame.width = static_cast<std::uint32_t> (
        CVPixelBufferGetWidth (pixelBuffer)
    );
    frame.height = static_cast<std::uint32_t> (
        CVPixelBufferGetHeight (pixelBuffer)
    );
    frame.bytesPerRow = static_cast<std::uint32_t> (
        CVPixelBufferGetBytesPerRow (pixelBuffer)
    );
    frame.presentationSeconds = presentationSeconds;
    frame.pixelBytes = static_cast<std::size_t> (frame.bytesPerRow) * frame.height;
    // startReader asks for IOSurface-backed buffers, so this is normally set.
    // It stays null for any buffer that arrives without one, and the caller
    // falls back to uploading the mapped pixels.
    frame.surface = CVPixelBufferGetIOSurface (pixelBuffer);
    frame.pixels = std::shared_ptr<const std::uint8_t> (
        static_cast<const std::uint8_t*> (
            CVPixelBufferGetBaseAddress (pixelBuffer)
        ),
        [pixelBuffer] (const std::uint8_t*) {
            CVPixelBufferUnlockBaseAddress (
                pixelBuffer, kCVPixelBufferLock_ReadOnly
            );
            CVPixelBufferRelease (pixelBuffer);
        }
    );
    m_implementation->lastPresentationSeconds = presentationSeconds;
    return frame;
}

const char* FrescoScene::mediaVideoErrorName (MediaVideoErrorCode code) {
    switch (code) {
        case MediaVideoErrorCode::none: return "none";
        case MediaVideoErrorCode::emptyInput: return "empty-input";
        case MediaVideoErrorCode::unsupportedContainer: return "unsupported-container";
        case MediaVideoErrorCode::assetUnavailable: return "asset-unavailable";
        case MediaVideoErrorCode::missingVideoTrack: return "missing-video-track";
        case MediaVideoErrorCode::endOfStream: return "end-of-stream";
        case MediaVideoErrorCode::frameDecodeFailed: return "frame-decode-failed";
    }
    return "unknown";
}
