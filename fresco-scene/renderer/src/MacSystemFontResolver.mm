#include "FrescoScene/MacSystemFontResolver.h"

#include <algorithm>
#include <cctype>
#include <string>

#include <limits.h>

#include <CoreText/CoreText.h>

namespace FrescoScene {
namespace {

std::string utf8 (CFStringRef value) {
    if (value == nullptr) {
        return {};
    }
    const CFIndex length = CFStringGetLength (value);
    const CFIndex capacity = CFStringGetMaximumSizeForEncoding (
        length, kCFStringEncodingUTF8
    ) + 1;
    std::string result (static_cast<size_t> (capacity), '\0');
    if (!CFStringGetCString (
            value, result.data (), capacity, kCFStringEncodingUTF8
        )) {
        return {};
    }
    result.resize (std::char_traits<char>::length (result.c_str ()));
    return result;
}

std::string normalized (std::string_view value) {
    std::string result;
    for (const unsigned char character : value) {
        if (std::isalnum (character)) {
            result.push_back (static_cast<char> (std::tolower (character)));
        }
    }
    return result;
}

bool requestsFixedPitch (std::string_view family) {
    const std::string name = normalized (family);
    return name.find ("consolas") != std::string::npos
        || name.find ("courier") != std::string::npos
        || name.find ("menlo") != std::string::npos
        || name.find ("mono") != std::string::npos;
}

std::string fontPath (CTFontRef font) {
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor (font);
    CFTypeRef attribute = descriptor == nullptr ? nullptr
        : CTFontDescriptorCopyAttribute (descriptor, kCTFontURLAttribute);
    std::string result;
    if (attribute != nullptr && CFGetTypeID (attribute) == CFURLGetTypeID ()) {
        char path[PATH_MAX] = {};
        if (CFURLGetFileSystemRepresentation (
                static_cast<CFURLRef> (attribute), true,
                reinterpret_cast<UInt8*> (path), sizeof (path)
            )) {
            result = path;
        }
    }
    if (attribute != nullptr) {
        CFRelease (attribute);
    }
    if (descriptor != nullptr) {
        CFRelease (descriptor);
    }
    return result;
}

}

std::optional<MacSystemFontResolution> resolveMacSystemFont (
    std::string_view wallpaperFont
) {
    constexpr std::string_view prefix = "systemfont_";
    if (!wallpaperFont.starts_with (prefix)) {
        return std::nullopt;
    }

    std::string requested (wallpaperFont.substr (prefix.size ()));
    std::replace (requested.begin (), requested.end (), '_', ' ');
    if (requested.empty ()) {
        return std::nullopt;
    }

    CFStringRef requestedName = CFStringCreateWithBytes (
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8*> (requested.data ()),
        static_cast<CFIndex> (requested.size ()), kCFStringEncodingUTF8, false
    );
    CTFontRef font = requestedName == nullptr ? nullptr
        : CTFontCreateWithName (requestedName, 12.0, nullptr);
    if (requestedName != nullptr) {
        CFRelease (requestedName);
    }

    std::string family;
    if (font != nullptr) {
        CFStringRef familyName = CTFontCopyFamilyName (font);
        family = utf8 (familyName);
        if (familyName != nullptr) {
            CFRelease (familyName);
        }
    }
    const bool exact = normalized (family) == normalized (requested);
    if (!exact) {
        if (font != nullptr) {
            CFRelease (font);
        }
        font = CTFontCreateUIFontForLanguage (
            requestsFixedPitch (requested)
                ? kCTFontUIFontUserFixedPitch
                : kCTFontUIFontSystem,
            12.0, nullptr
        );
        if (font != nullptr) {
            CFStringRef familyName = CTFontCopyFamilyName (font);
            family = utf8 (familyName);
            if (familyName != nullptr) {
                CFRelease (familyName);
            }
        }
    }

    if (font == nullptr) {
        return std::nullopt;
    }
    const bool fixedPitch
        = (CTFontGetSymbolicTraits (font) & kCTFontMonoSpaceTrait) != 0;
    const std::string path = fontPath (font);
    CFRelease (font);
    if (path.empty ()) {
        return std::nullopt;
    }
    return MacSystemFontResolution {
        .requestedFamily = std::move (requested),
        .resolvedFamily = std::move (family),
        .path = path,
        .substituted = !exact,
        .fixedPitch = fixedPitch,
    };
}

std::optional<std::string> resolveMacFallbackFontPath (char32_t codepoint) {
    UniChar units[2];
    CFIndex unitCount = 0;
    if (codepoint <= 0xFFFF) {
        if (codepoint >= 0xD800 && codepoint <= 0xDFFF) {
            return std::nullopt;
        }
        units[0] = static_cast<UniChar> (codepoint);
        unitCount = 1;
    } else if (codepoint <= 0x10FFFF) {
        const char32_t offset = codepoint - 0x10000;
        units[0] = static_cast<UniChar> (0xD800 + (offset >> 10));
        units[1] = static_cast<UniChar> (0xDC00 + (offset & 0x3FF));
        unitCount = 2;
    } else {
        return std::nullopt;
    }

    CFStringRef text = CFStringCreateWithCharacters (
        kCFAllocatorDefault, units, unitCount
    );
    if (text == nullptr) {
        return std::nullopt;
    }
    CTFontRef base = CTFontCreateUIFontForLanguage (
        kCTFontUIFontSystem, 12.0, nullptr
    );
    if (base == nullptr) {
        CFRelease (text);
        return std::nullopt;
    }
    // CTFontCreateForString walks the cascade list and returns the base font
    // itself when nothing covers the character, so the coverage check has to be
    // made against the font it hands back.
    CTFontRef covering = CTFontCreateForString (
        base, text, CFRangeMake (0, unitCount)
    );
    CFRelease (text);
    CFRelease (base);
    if (covering == nullptr) {
        return std::nullopt;
    }

    CGGlyph glyphs[2] = {0, 0};
    const bool covered = CTFontGetGlyphsForCharacters (
        covering, units, glyphs, unitCount
    );
    std::string path = covered ? fontPath (covering) : std::string {};
    CFRelease (covering);
    if (path.empty ()) {
        return std::nullopt;
    }
    return path;
}

}
