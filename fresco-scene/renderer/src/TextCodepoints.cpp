#include "FrescoScene/TextCodepoints.h"

#include <cstddef>

namespace FrescoScene {
namespace {

constexpr int continuationLength (unsigned char lead) {
    if ((lead & 0x80u) == 0x00u) {
        return 0;
    }
    if ((lead & 0xE0u) == 0xC0u) {
        return 1;
    }
    if ((lead & 0xF0u) == 0xE0u) {
        return 2;
    }
    if ((lead & 0xF8u) == 0xF0u) {
        return 3;
    }
    return -1;
}

constexpr char32_t leadValue (unsigned char lead, int trailing) {
    switch (trailing) {
    case 0:
        return lead;
    case 1:
        return lead & 0x1Fu;
    case 2:
        return lead & 0x0Fu;
    default:
        return lead & 0x07u;
    }
}

constexpr char32_t minimumForLength (int trailing) {
    switch (trailing) {
    case 0:
        return 0x0000;
    case 1:
        return 0x0080;
    case 2:
        return 0x0800;
    default:
        return 0x10000;
    }
}

}

std::vector<char32_t> decodeUtf8 (std::string_view text) {
    std::vector<char32_t> codepoints;
    codepoints.reserve (text.size ());

    std::size_t index = 0;
    while (index < text.size ()) {
        const auto lead = static_cast<unsigned char> (text[index]);
        const int trailing = continuationLength (lead);
        if (trailing < 0) {
            codepoints.push_back (kReplacementCodepoint);
            ++index;
            continue;
        }

        // A sequence running past the end, or interrupted by a byte that is not
        // a continuation, is malformed only up to that point. Consume just the
        // bytes it actually claimed so the remainder still decodes.
        char32_t value = leadValue (lead, trailing);
        int consumed = 1;
        bool valid = true;
        for (int offset = 1; offset <= trailing; ++offset) {
            const std::size_t position = index + static_cast<std::size_t> (offset);
            if (position >= text.size ()) {
                valid = false;
                break;
            }
            const auto continuation = static_cast<unsigned char> (text[position]);
            if ((continuation & 0xC0u) != 0x80u) {
                valid = false;
                break;
            }
            value = (value << 6) | (continuation & 0x3Fu);
            ++consumed;
        }

        const bool overlong = valid && value < minimumForLength (trailing);
        const bool surrogate = value >= 0xD800 && value <= 0xDFFF;
        const bool tooLarge = value > 0x10FFFF;
        if (!valid || overlong || surrogate || tooLarge) {
            codepoints.push_back (kReplacementCodepoint);
            index += static_cast<std::size_t> (consumed);
            continue;
        }

        codepoints.push_back (value);
        index += static_cast<std::size_t> (consumed);
    }

    return codepoints;
}

}
