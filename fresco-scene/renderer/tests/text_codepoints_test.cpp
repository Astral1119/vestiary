#include "FrescoScene/TextCodepoints.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <string_view>

int main () {
    using FrescoScene::decodeUtf8;
    using FrescoScene::kReplacementCodepoint;

    // ASCII is unchanged.
    {
        const auto result = decodeUtf8 ("const clock = {");
        assert (result.size () == 15);
        assert (result[0] == U'c');
        assert (result[14] == U'{');
    }

    // GBC Subaru 3448290956 authors this run; iterating bytes rendered its
    // eighteen characters as fifty-four Latin-1 ones.
    {
        const auto result = decodeUtf8 ("功能提示：视线跟随、音频感应、自定义布局");
        assert (result.size () == 20);
        assert (result[0] == U'功');
        assert (result[19] == U'局');
    }

    // Each sequence length decodes to its own codepoint.
    {
        const auto result = decodeUtf8 ("aé中\U0001F600");
        assert (result.size () == 4);
        assert (result[0] == U'a');
        assert (result[1] == 0x00E9);
        assert (result[2] == 0x4E2D);
        assert (result[3] == 0x1F600);
    }

    // An empty string decodes to nothing rather than a replacement.
    assert (decodeUtf8 ("").empty ());

    // A stray continuation byte is one replacement, and decoding continues.
    {
        const auto result = decodeUtf8 ("a\x80z");
        assert (result.size () == 3);
        assert (result[0] == U'a');
        assert (result[1] == kReplacementCodepoint);
        assert (result[2] == U'z');
    }

    // A truncated sequence consumes only what it claimed, so the tail survives.
    {
        const auto result = decodeUtf8 ("\xE4\xB8z");
        assert (result.size () == 2);
        assert (result[0] == kReplacementCodepoint);
        assert (result[1] == U'z');
    }

    // A sequence running off the end yields one replacement.
    {
        const auto result = decodeUtf8 ("\xE4\xB8");
        assert (result.size () == 1);
        assert (result[0] == kReplacementCodepoint);
    }

    // Overlong encodings, surrogates, and out-of-range values are malformed.
    {
        // U+002F encoded in two bytes.
        const auto overlong = decodeUtf8 ("\xC0\xAF");
        assert (overlong.size () == 1 && overlong[0] == kReplacementCodepoint);

        // U+D800 encoded directly.
        const auto surrogate = decodeUtf8 ("\xED\xA0\x80");
        assert (surrogate.size () == 1 && surrogate[0] == kReplacementCodepoint);

        // Above U+10FFFF.
        const auto tooLarge = decodeUtf8 ("\xF7\xBF\xBF\xBF");
        assert (tooLarge.size () == 1 && tooLarge[0] == kReplacementCodepoint);
    }

    // A five-byte lead is not a valid UTF-8 lead at all.
    {
        const auto result = decodeUtf8 ("\xF8");
        assert (result.size () == 1 && result[0] == kReplacementCodepoint);
    }

    return 0;
}
