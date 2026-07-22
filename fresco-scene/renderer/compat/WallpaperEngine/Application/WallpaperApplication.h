#pragma once

#include "WallpaperEngine/Application/ApplicationContext.h"
#include "WallpaperEngine/Data/Model/Project.h"
#include "WallpaperEngine/Data/Model/Wallpaper.h"

#include <GL/glew.h>
#include <map>
#include <memory>
#include <string>

namespace WallpaperEngine::Application {
class WallpaperApplication {
public:
    [[nodiscard]] ApplicationContext& getContext () { return m_context; }
    [[nodiscard]] const ApplicationContext& getContext () const { return m_context; }

    [[nodiscard]] const std::map<std::string, Data::Model::ProjectUniquePtr>& getBackgrounds () const {
        return m_backgrounds;
    }

    Data::Model::Project& addBackground (
        std::string key, Data::Model::ProjectUniquePtr project
    ) {
        auto [entry, inserted] = m_backgrounds.emplace (std::move (key), std::move (project));
        if (!inserted) {
            entry->second = std::move (project);
        }
        return *entry->second;
    }

    void setDestinationFramebuffer (GLuint framebuffer) {
        m_destinationFramebuffer = framebuffer;
    }

    [[nodiscard]] GLuint getDestinationFramebuffer () const {
        return m_destinationFramebuffer;
    }

private:
    ApplicationContext m_context;
    std::map<std::string, Data::Model::ProjectUniquePtr> m_backgrounds;
    GLuint m_destinationFramebuffer = 0;
};
}
