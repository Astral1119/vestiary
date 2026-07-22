#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void appendU32 (std::vector<std::uint8_t>& output, std::uint32_t value) {
    for (int byte = 0; byte < 4; ++byte) {
        output.push_back (static_cast<std::uint8_t> (value >> (8 * byte)));
    }
}

void appendMagic (std::vector<std::uint8_t>& output, const char* value) {
    output.insert (output.end (), value, value + 8);
    output.push_back (0);
}

void require (bool condition, const std::string& message) {
    if (!condition) {
        throw std::runtime_error (message);
    }
}

void writeTexture (
    const std::filesystem::path& outputPath,
    const std::vector<std::uint8_t>& video,
    std::uint32_t width,
    std::uint32_t height
) {
    std::vector<std::uint8_t> texture;
    appendMagic (texture, "TEXV0005");
    appendMagic (texture, "TEXI0001");
    appendU32 (texture, 0);
    appendU32 (texture, 32);
    appendU32 (texture, width);
    appendU32 (texture, height);
    appendU32 (texture, width);
    appendU32 (texture, height);
    appendU32 (texture, 0);
    appendMagic (texture, "TEXB0004");
    appendU32 (texture, 1);
    appendU32 (texture, 35);
    appendU32 (texture, 1);
    appendU32 (texture, 1);
    appendU32 (texture, 0);
    appendU32 (texture, 0);
    texture.push_back (0);
    appendU32 (texture, 0);
    appendU32 (texture, width);
    appendU32 (texture, height);
    appendU32 (texture, 0);
    appendU32 (texture, static_cast<std::uint32_t> (video.size ()));
    appendU32 (texture, static_cast<std::uint32_t> (video.size ()));
    texture.insert (texture.end (), video.begin (), video.end ());

    std::ofstream output (outputPath, std::ios::binary);
    require (output.good (), "cannot open generated texture output");
    output.write (
        reinterpret_cast<const char*> (texture.data ()),
        static_cast<std::streamsize> (texture.size ())
    );
    require (output.good (), "cannot write generated texture output");
}

}

int main (int argc, const char* argv[]) {
    @autoreleasepool {
        try {
            require (argc == 3,
                     "usage: media-fixture-generator PARAMETERS.json OUTPUT.tex");
            NSString* parameterPath = [NSString stringWithUTF8String:argv[1]];
            NSData* parameterData = [NSData dataWithContentsOfFile:parameterPath];
            require (parameterData != nil, "cannot read generator parameters");
            NSError* parameterError = nil;
            id value = [NSJSONSerialization JSONObjectWithData:parameterData
                                                       options:0
                                                         error:&parameterError];
            require ([value isKindOfClass:[NSDictionary class]],
                     "generator parameters must be an object");
            NSDictionary* parameters = value;
            NSSet* expectedKeys = [NSSet setWithArray:@[
                @"schemaVersion", @"container", @"codec", @"width", @"height",
                @"framesPerSecond", @"frameCount", @"durationSeconds",
                @"averageBitRate", @"maximumKeyFrameInterval",
                @"allowFrameReordering", @"pixelFormat", @"colorsBGRA",
                @"byteReproducible",
            ]];
            require ([[NSSet setWithArray:parameters.allKeys]
                        isEqualToSet:expectedKeys],
                     "generator parameters have unknown or missing fields");
            NSData* canonical = [NSJSONSerialization dataWithJSONObject:parameters
                options:(NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes)
                error:&parameterError];
            NSMutableData* canonicalLine = [canonical mutableCopy];
            const char newline = '\n';
            [canonicalLine appendBytes:&newline length:1];
            require (canonical != nil
                && ([canonical isEqualToData:parameterData]
                    || [canonicalLine isEqualToData:parameterData]),
                     "generator parameters must be canonical JSON");
            const auto integer = [&parameters] (NSString* key) {
                id raw = parameters[key];
                require ([raw isKindOfClass:[NSNumber class]]
                    && CFGetTypeID ((__bridge CFTypeRef) raw) != CFBooleanGetTypeID (),
                    std::string ([key UTF8String]) + " must be an integer");
                const long long result = [raw longLongValue];
                require (result > 0, std::string ([key UTF8String]) + " must be positive");
                return result;
            };
            require ([parameters[@"schemaVersion"] integerValue] == 1,
                     "unsupported generator parameter version");
            require ([parameters[@"container"] isEqualToString:@"TEXV0005/TEXB0004"],
                     "unsupported generated texture container");
            require ([parameters[@"codec"] isEqualToString:@"AVVideoCodecTypeH264"],
                     "unsupported generated video codec");
            require ([parameters[@"pixelFormat"] isEqualToString:@"32BGRA"],
                     "unsupported generated pixel format");
            require ([parameters[@"allowFrameReordering"] isEqual:@NO],
                     "generated fixture requires frame reordering disabled");
            require ([parameters[@"byteReproducible"] isEqual:@NO],
                     "generated container bytes must not be declared reproducible");
            const std::uint32_t width = static_cast<std::uint32_t> (integer (@"width"));
            const std::uint32_t height = static_cast<std::uint32_t> (integer (@"height"));
            const std::int32_t fps = static_cast<std::int32_t> (
                integer (@"framesPerSecond")
            );
            const std::size_t frameCount = static_cast<std::size_t> (
                integer (@"frameCount")
            );
            const auto bitRate = integer (@"averageBitRate");
            const auto keyInterval = integer (@"maximumKeyFrameInterval");
            const double duration = [parameters[@"durationSeconds"] doubleValue];
            require (std::isfinite (duration)
                && std::abs (duration - static_cast<double> (frameCount) / fps)
                    < 0.000001,
                "generator duration contradicts frame count and rate");
            NSArray* rawColors = parameters[@"colorsBGRA"];
            require ([rawColors isKindOfClass:[NSArray class]]
                && rawColors.count == frameCount,
                "generator colors must match frame count");
            std::vector<std::array<std::uint8_t, 4>> colors;
            colors.reserve (frameCount);
            for (NSArray* rawColor in rawColors) {
                require ([rawColor isKindOfClass:[NSArray class]]
                    && rawColor.count == 4,
                    "generator color must contain four BGRA bytes");
                std::array<std::uint8_t, 4> color {};
                for (NSUInteger channel = 0; channel < 4; ++channel) {
                    const NSInteger component = [rawColor[channel] integerValue];
                    require (component >= 0 && component <= 255,
                             "generator color component is outside byte range");
                    color[channel] = static_cast<std::uint8_t> (component);
                }
                colors.push_back (color);
            }

            const std::filesystem::path outputPath (argv[2]);
            const std::filesystem::path videoPath
                = outputPath.parent_path () / "generated-media-fixture.mp4";
            [[NSFileManager defaultManager]
                removeItemAtPath:[NSString stringWithUTF8String:videoPath.c_str ()]
                error:nil];

            NSError* error = nil;
            AVAssetWriter* writer = [[AVAssetWriter alloc]
                initWithURL:[NSURL fileURLWithPath:
                    [NSString stringWithUTF8String:videoPath.c_str ()]]
                fileType:AVFileTypeMPEG4 error:&error];
            require (writer != nil, "cannot create AVAssetWriter");
            writer.metadata = @[];
            NSDictionary* settings = @{
                AVVideoCodecKey: AVVideoCodecTypeH264,
                AVVideoWidthKey: @(width),
                AVVideoHeightKey: @(height),
                AVVideoCompressionPropertiesKey: @{
                    AVVideoAverageBitRateKey: @(bitRate),
                    AVVideoExpectedSourceFrameRateKey: @(fps),
                    AVVideoMaxKeyFrameIntervalKey: @(keyInterval),
                    AVVideoAllowFrameReorderingKey:
                        parameters[@"allowFrameReordering"],
                },
            };
            AVAssetWriterInput* input = [AVAssetWriterInput
                assetWriterInputWithMediaType:AVMediaTypeVideo
                outputSettings:settings];
            input.expectsMediaDataInRealTime = NO;
            NSDictionary* attributes = @{
                (NSString*)kCVPixelBufferPixelFormatTypeKey:
                    @(kCVPixelFormatType_32BGRA),
                (NSString*)kCVPixelBufferWidthKey: @(width),
                (NSString*)kCVPixelBufferHeightKey: @(height),
            };
            AVAssetWriterInputPixelBufferAdaptor* adaptor = [
                [AVAssetWriterInputPixelBufferAdaptor alloc]
                    initWithAssetWriterInput:input
                    sourcePixelBufferAttributes:attributes
            ];
            require ([writer canAddInput:input], "cannot add fixture video input");
            [writer addInput:input];
            require ([writer startWriting], "cannot start fixture video writer");
            [writer startSessionAtSourceTime:kCMTimeZero];

            for (std::size_t frame = 0; frame < colors.size (); ++frame) {
                while (!input.readyForMoreMediaData) {
                    [NSThread sleepForTimeInterval:0.001];
                }
                CVPixelBufferRef pixel = nullptr;
                require (CVPixelBufferPoolCreatePixelBuffer (
                    kCFAllocatorDefault, adaptor.pixelBufferPool, &pixel
                ) == kCVReturnSuccess, "cannot allocate fixture pixel buffer");
                CVPixelBufferLockBaseAddress (pixel, 0);
                auto* bytes = static_cast<std::uint8_t*> (
                    CVPixelBufferGetBaseAddress (pixel)
                );
                const std::size_t rowBytes = CVPixelBufferGetBytesPerRow (pixel);
                for (std::size_t y = 0; y < height; ++y) {
                    for (std::size_t x = 0; x < width; ++x) {
                        std::copy (
                            colors[frame].begin (), colors[frame].end (),
                            bytes + y * rowBytes + x * 4
                        );
                    }
                }
                CVPixelBufferUnlockBaseAddress (pixel, 0);
                require ([adaptor appendPixelBuffer:pixel
                    withPresentationTime:CMTimeMake (frame, fps)],
                    "cannot append fixture video frame");
                CVPixelBufferRelease (pixel);
            }
            [input markAsFinished];
            dispatch_semaphore_t completed = dispatch_semaphore_create (0);
            [writer finishWritingWithCompletionHandler:^{
                dispatch_semaphore_signal (completed);
            }];
            dispatch_semaphore_wait (completed, DISPATCH_TIME_FOREVER);
            require (writer.status == AVAssetWriterStatusCompleted,
                     "fixture video writer did not complete");

            NSData* video = [NSData dataWithContentsOfFile:
                [NSString stringWithUTF8String:videoPath.c_str ()]];
            require (video != nil && video.length > 0,
                     "cannot read generated fixture video");
            const auto* begin = static_cast<const std::uint8_t*> (video.bytes);
            writeTexture (
                outputPath, {begin, begin + video.length}, width, height
            );
            [[NSFileManager defaultManager]
                removeItemAtPath:[NSString stringWithUTF8String:videoPath.c_str ()]
                error:nil];
            return 0;
        } catch (const std::exception& exception) {
            std::fprintf (stderr, "%s\n", exception.what ());
            return 1;
        }
    }
}
