#include "FrescoScene/MacSystemFontResolver.h"

#include <cassert>
#include <filesystem>

int main () {
    using FrescoScene::resolveMacSystemFont;

    assert (!resolveMacSystemFont ("materials/fonts/embedded.ttf").has_value ());

    const auto consolas = resolveMacSystemFont ("systemfont_consolas");
    assert (consolas.has_value ());
    assert (consolas->requestedFamily == "consolas");
    assert (!consolas->resolvedFamily.empty ());
    assert (std::filesystem::is_regular_file (consolas->path));
    assert (consolas->fixedPitch);

    const auto menlo = resolveMacSystemFont ("systemfont_Menlo");
    assert (menlo.has_value ());
    assert (menlo->resolvedFamily == "Menlo");
    assert (!menlo->substituted);
    assert (menlo->fixedPitch);
    return 0;
}
