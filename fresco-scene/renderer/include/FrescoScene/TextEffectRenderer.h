#pragma once

#include "FrescoScene/TextEffectChainDecision.h"
#include "WallpaperEngine/Render/Objects/CRenderable.h"

#include <functional>
#include <memory>
#include <vector>

#include <glm/mat4x4.hpp>
#include <glm/vec2.hpp>

namespace WallpaperEngine::Data::Model {
struct ImageEffect;
class Text;
}

namespace WallpaperEngine::Render {
class CFBO;
}

namespace WallpaperEngine::Render::Objects::Effects {
class CPass;
}

namespace FrescoScene {

using TextEffectSourceRenderer = std::function<void (
    const std::shared_ptr<const WallpaperEngine::Render::CFBO>&,
    const glm::mat4&
)>;

class TextEffectRenderer final :
    public WallpaperEngine::Render::Objects::CRenderable {
public:
    TextEffectRenderer (
        WallpaperEngine::Render::Wallpapers::CScene& scene,
        const WallpaperEngine::Data::Model::Text& text,
        const std::vector<std::unique_ptr<WallpaperEngine::Data::Model::ImageEffect>>& effects
    );
    ~TextEffectRenderer () override;

    [[nodiscard]] TextEffectChainDecision chainDecision () const;
    void recordDecision (const TextEffectChainDecision& decision);
    [[nodiscard]] std::optional<TextEffectChainEvidence> decisionEvidence () const;
    void renderEffects (
        glm::ivec2 textureSize,
        const TextEffectChainDecision& decision,
        const TextEffectSourceRenderer& renderSource
    );

    [[nodiscard]] const float& getBrightness () const override;
    [[nodiscard]] const float& getUserAlpha () const override;
    [[nodiscard]] const float& getAlpha () const override;
    [[nodiscard]] const glm::vec3& getColor () const override;
    [[nodiscard]] const glm::vec4& getColor4 () const override;
    [[nodiscard]] const glm::vec3& getCompositeColor () const override;

private:
    [[nodiscard]] TextEffectChainMember chainMember (
        const WallpaperEngine::Data::Model::ImageEffect& effect
    ) const;
    void clearPasses ();
    void rebuild (glm::ivec2 textureSize);
    void createGeometry ();
    void configurePasses ();
    void updateScreenMVP ();

    const WallpaperEngine::Data::Model::Text& m_text;
    const std::vector<std::unique_ptr<WallpaperEngine::Data::Model::ImageEffect>>& m_effects;
    std::vector<int> m_activeEffects;
    std::optional<TextEffectChainDecision> m_latestDecision;
    std::vector<WallpaperEngine::Render::Objects::Effects::CPass*> m_passes;
    std::vector<std::shared_ptr<WallpaperEngine::Render::FBOProvider>> m_effectProviders;

    std::shared_ptr<const WallpaperEngine::Render::CFBO> m_sourceFBO;
    std::shared_ptr<const WallpaperEngine::Render::CFBO> m_mainFBO;
    std::shared_ptr<const WallpaperEngine::Render::CFBO> m_subFBO;
    glm::ivec2 m_textureSize = { 0, 0 };

    GLuint m_scenePosition = GL_NONE;
    GLuint m_passPosition = GL_NONE;
    GLuint m_passTexCoord = GL_NONE;

    glm::mat4 m_screenMVP = { 1.0f };
    glm::mat4 m_screenMVPInverse = { 1.0f };
    glm::mat4 m_passMVP = { 1.0f };
    glm::mat4 m_passMVPInverse = { 1.0f };
    glm::mat4 m_modelMatrix = { 1.0f };
    glm::mat4 m_viewProjectionMatrix = { 1.0f };
};

[[nodiscard]] bool renderTextEffects (
    WallpaperEngine::Render::Wallpapers::CScene& scene,
    const WallpaperEngine::Data::Model::Text& text,
    glm::ivec2 textureSize,
    const TextEffectSourceRenderer& renderSource
);

void clearTextEffectRenderers (
    const WallpaperEngine::Render::Wallpapers::CScene* scene
);

[[nodiscard]] std::vector<TextEffectChainEvidence> textEffectChainEvidence (
    const WallpaperEngine::Render::Wallpapers::CScene* scene
);

}
