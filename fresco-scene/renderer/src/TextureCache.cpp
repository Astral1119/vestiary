/*
 * Fresco scene texture cache
 *
 * Derived from linux-wallpaperengine's TextureCache.cpp at
 * b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version 3.
 */

#include "WallpaperEngine/Render/TextureCache.h"

#include "FrescoScene/MediaArtwork.h"
#include "RuntimeMediaSource.h"
#include "WallpaperEngine/Application/WallpaperApplication.h"
#include "WallpaperEngine/Assets/AssetLoadException.h"
#include "WallpaperEngine/Data/Model/Project.h"
#include "WallpaperEngine/Data/Parsers/TextureParser.h"
#include "WallpaperEngine/Render/CTexture.h"
#include "WallpaperEngine/Render/TextureProvider.h"

#include <filesystem>
#include <ranges>

using namespace WallpaperEngine::Data::Assets;
using namespace WallpaperEngine::Data::Parsers;
using namespace WallpaperEngine::Render;

namespace {

class MediaArtworkTexture final : public TextureProvider {
public:
    MediaArtworkTexture () {
        glGenTextures (1, &m_texture);
        glBindTexture (GL_TEXTURE_2D, m_texture);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        upload (nullptr);
    }

    ~MediaArtworkTexture () override { glDeleteTextures (1, &m_texture); }

    void upload (const std::shared_ptr<const FrescoScene::MediaArtworkImage>& image) {
        static constexpr std::uint8_t transparent[] = { 0, 0, 0, 0 };
        m_ready = image != nullptr;
        m_width = image == nullptr ? 1U : image->width;
        m_height = image == nullptr ? 1U : image->height;
        m_resolution = glm::vec4 (m_width, m_height, m_width, m_height);
        glBindTexture (GL_TEXTURE_2D, m_texture);
        glTexImage2D (
            GL_TEXTURE_2D, 0, GL_RGBA8,
            static_cast<GLsizei> (m_width), static_cast<GLsizei> (m_height),
            0, GL_RGBA, GL_UNSIGNED_BYTE,
            image == nullptr ? transparent : image->rgba.data ()
        );
    }

    [[nodiscard]] GLuint getTextureID (uint32_t) const override {
        return m_texture;
    }
    [[nodiscard]] uint32_t getTextureWidth (uint32_t) const override {
        return m_width;
    }
    [[nodiscard]] uint32_t getTextureHeight (uint32_t) const override {
        return m_height;
    }
    [[nodiscard]] uint32_t getRealWidth () const override { return m_width; }
    [[nodiscard]] uint32_t getRealHeight () const override { return m_height; }
    [[nodiscard]] TextureFormat getFormat () const override {
        return TextureFormat_ARGB8888;
    }
    [[nodiscard]] uint32_t getFlags () const override {
        return TextureFlags_NoFlags;
    }
    [[nodiscard]] const std::vector<FrameSharedPtr>& getFrames () const override {
        return m_frames;
    }
    [[nodiscard]] const glm::vec4* getResolution () const override {
        return &m_resolution;
    }
    [[nodiscard]] bool isAnimated () const override { return false; }
    [[nodiscard]] uint32_t getSpritesheetCols () const override { return 1; }
    [[nodiscard]] uint32_t getSpritesheetRows () const override { return 1; }
    [[nodiscard]] uint32_t getSpritesheetFrames () const override { return 1; }
    [[nodiscard]] float getSpritesheetDuration () const override { return 0.0F; }
    [[nodiscard]] bool isReady () const override { return m_ready; }
    void incrementUsageCount () const override { }
    void decrementUsageCount () const override { }
    void update () const override { }

private:
    GLuint m_texture = 0;
    uint32_t m_width = 1;
    uint32_t m_height = 1;
    glm::vec4 m_resolution = glm::vec4 (1.0F);
    std::vector<FrameSharedPtr> m_frames;
    bool m_ready = false;
};

}

TextureCache::TextureCache (RenderContext& context) : Helpers::ContextAware (context) {
    auto current = std::make_shared<MediaArtworkTexture> ();
    auto previous = std::make_shared<MediaArtworkTexture> ();
    store ("$mediaThumbnail", current);
    store ("$mediaPreviousThumbnail", previous);

    auto* runtime = dynamic_cast<FrescoScene::RuntimeMediaSource*> (
        &context.getMediaSource ()
    );
    if (runtime != nullptr) {
        m_mediaCallback = context.getMediaSource ().addAlbumArtListener (
            [runtime, current, previous] (const auto&) {
                const auto& artwork = runtime->artwork ();
                previous->upload (artwork.previous);
                current->upload (artwork.current);
            }
        );
    }
}

TextureCache::~TextureCache () {
    if (m_mediaCallback) {
        m_mediaCallback ();
    }
}

std::shared_ptr<const TextureProvider> TextureCache::resolve (const std::string& filename) {
    if (const auto found = m_textureCache.find (filename); found != m_textureCache.end ()) {
        return found->second;
    }

    for (const auto& project : getContext ().getApp ().getBackgrounds () | std::views::values) {
        try {
            const auto contents = project->assetLocator->texture (filename);
            auto metadataLoader = [&project] (const std::string& metadataFilename) {
                return project->assetLocator->readString (
                    std::filesystem::path ("materials") / metadataFilename
                );
            };
            auto parsed = TextureParser::parse (
                WallpaperEngine::Data::Utils::BinaryReader (contents),
                filename,
                metadataLoader
            );
            auto texture = std::make_shared<CTexture> (getContext (), std::move (parsed));
            store (filename, texture);
            return texture;
        } catch (const WallpaperEngine::Assets::AssetLoadException&) {
        }
    }

    throw WallpaperEngine::Assets::AssetLoadException (
        "Cannot find file", filename, std::error_code ()
    );
}

void TextureCache::store (
    const std::string& name, std::shared_ptr<const TextureProvider> texture
) {
    m_textureCache.insert_or_assign (name, std::move (texture));
}
