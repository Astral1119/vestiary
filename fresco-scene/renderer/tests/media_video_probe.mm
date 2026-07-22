#include "FrescoScene/MediaVideoDecoder.h"

#import <Foundation/Foundation.h>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

using namespace FrescoScene;

namespace {

void require (bool condition) {
    if (!condition) {
        std::abort ();
    }
}

}

int main (int argc, const char* argv[]) {
    const std::uint8_t invalid[] = { 0, 1, 2, 3 };
    MediaVideoError error;
    require (MediaVideoDecoder::create (invalid, sizeof (invalid), error) == nullptr);
    require (error.code == MediaVideoErrorCode::unsupportedContainer);
    require (std::string (mediaVideoErrorName (error.code)) == "unsupported-container");

    for (int index = 1; index < argc; ++index) {
        NSData* data = [NSData dataWithContentsOfFile:
            [NSString stringWithUTF8String:argv[index]]];
        require (data != nil);
        auto decoder = MediaVideoDecoder::create ([data bytes], [data length], error);
        if (!decoder) {
            std::cerr << argv[index] << ": " << mediaVideoErrorName (error.code)
                      << ": " << error.message << '\n';
            return 1;
        }
        require (decoder->durationSeconds () > 0.0);
        const auto first = decoder->frameAt (0.0, error);
        if (!first) {
            std::cerr << argv[index] << ": " << mediaVideoErrorName (error.code)
                      << ": " << error.message << '\n';
            return 1;
        }
        require (first->width > 0);
        require (first->height > 0);
        require (first->bytesPerRow >= first->width * 4);
        require (first->pixels != nullptr);
        require (first->format == MediaVideoPixelFormat::bgra8);
        require (first->pixelBytes ==
            static_cast<std::size_t> (first->bytesPerRow) * first->height);
        require (std::isfinite (first->presentationSeconds));
        std::cout << argv[index] << ' ' << first->width << 'x' << first->height
                  << ' ' << decoder->durationSeconds () << '\n';
    }
}
