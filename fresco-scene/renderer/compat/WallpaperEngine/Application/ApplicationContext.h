#pragma once

#include <optional>
#include <vector>

namespace WallpaperEngine::Application {
class ApplicationContext {
public:
    struct Settings {
        struct General {
            bool disableParticles = false;
        } general;
        struct Mouse {
            bool disableparallax = false;
        } mouse;
        struct Render {
            struct Debug {
                std::optional<int> objectFilter;
                std::vector<int> skipObjects;
                std::vector<int> skipEffects;
                bool baseOnly = false;
                bool noSolidFinal = false;
                bool passLog = false;
            } debug;
        } render;
    } settings;
};
}
