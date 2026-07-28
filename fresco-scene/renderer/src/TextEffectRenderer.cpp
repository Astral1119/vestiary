#include "FrescoScene/TextEffectRenderer.h"
#include "FrescoScene/Camera2DControl.h"
#include "FrescoScene/SceneObjectModelTransform.h"
#include "FrescoScene/TextEffectRegistry.h"

#include "WallpaperEngine/Data/Assets/Texture.h"
#include "WallpaperEngine/Data/Model/Effect.h"
#include "WallpaperEngine/Data/Model/Material.h"
#include "WallpaperEngine/Data/Model/Object.h"
#include "WallpaperEngine/Logging/Log.h"
#include "WallpaperEngine/Render/Camera.h"
#include "WallpaperEngine/Render/CFBO.h"
#include "WallpaperEngine/Render/Objects/Effects/CPass.h"
#include "WallpaperEngine/Render/Wallpapers/CScene.h"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <iterator>
#include <map>
#include <optional>
#include <set>
#include <string_view>
#include <vector>

#include <glm/common.hpp>
#include <glm/gtc/matrix_inverse.hpp>
#include <glm/gtc/matrix_transform.hpp>

using namespace WallpaperEngine::Data::Model;
using namespace WallpaperEngine::Data::Assets;
using namespace WallpaperEngine::Render;
using namespace WallpaperEngine::Render::Objects;
using namespace WallpaperEngine::Render::Objects::Effects;
using namespace WallpaperEngine::Render::Wallpapers;

namespace FrescoScene {
namespace {

using RendererKey = std::pair<const CScene*, int>;
std::map<RendererKey, std::unique_ptr<TextEffectRenderer>> renderers;

// Reports how much of a stage's framebuffer is actually covered, and the extent
// the covered pixels span. Geometry alone cannot distinguish a chain that draws
// from one that does not — FRESCO_SCENE_TEXT_EFFECT_TRACE reported a correct
// quad for a chain whose first pass rasterised nothing — and a scene capture
// cannot say which stage lost the glyphs. Coverage per stage can: source empty
// means renderSource failed, source full and a later stage empty names the pass
// that dropped them, and a bounds box narrower than the source is the raster
// clipping the glyphs rather than the quad misplacing them.
void probeStage (int id, const char* label, const std::shared_ptr<const CFBO>& fbo) {
    if (std::getenv ("FRESCO_SCENE_TEXT_EFFECT_PROBE") == nullptr) {
        return;
    }
    if (fbo != nullptr) {
        glBindFramebuffer (GL_FRAMEBUFFER, fbo->getFramebuffer ());
        glViewport (0, 0, fbo->getRealWidth (), fbo->getRealHeight ());
    }
    GLint viewport[4] = { 0, 0, 0, 0 };
    glGetIntegerv (GL_VIEWPORT, viewport);
    const int width = viewport[2];
    const int height = viewport[3];
    if (width <= 0 || height <= 0) {
        return;
    }
    std::vector<unsigned char> pixels (
        static_cast<size_t> (width) * static_cast<size_t> (height) * 4
    );
    glPixelStorei (GL_PACK_ALIGNMENT, 1);
    glReadPixels (0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data ());
    size_t covered = 0;
    int minX = width;
    int minY = height;
    int maxX = -1;
    int maxY = -1;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const size_t offset = (static_cast<size_t> (y) * width + x) * 4;
            if (pixels[offset + 3] == 0) {
                continue;
            }
            ++covered;
            minX = std::min (minX, x);
            minY = std::min (minY, y);
            maxX = std::max (maxX, x);
            maxY = std::max (maxY, y);
        }
    }
    sLog.out (
        "textEffectProbe id=", id, " stage=", label,
        " size=", width, 'x', height, " covered=", covered,
        " bounds=", minX, ',', minY, ',', maxX, ',', maxY
    );
}

const Material& textSourceMaterial () {
    static const Material material { .filename = "fresco/text-source", .passes = {} };
    return material;
}

bool supportedMaterial (std::string_view filename) {
    static constexpr std::array names {
        std::string_view { "materials/effects/opacity.json" },
        std::string_view { "materials/effects/transform.json" },
        std::string_view { "materials/effects/blur_precise_gaussian_x.json" },
        std::string_view { "materials/effects/blur_precise_gaussian_y.json" },
    };
    return std::find (names.begin (), names.end (), filename) != names.end ();
}

}

TextEffectRenderer::TextEffectRenderer (
    CScene& scene, const Text& text,
    const std::vector<ImageEffectUniquePtr>& effects
) :
    CObject (scene, text), CRenderable (scene, text, textSourceMaterial ()),
    m_text (text), m_effects (effects) { }

TextEffectRenderer::~TextEffectRenderer () {
    clearPasses ();
    const std::array buffers {
        m_scenePosition, m_passPosition, m_passTexCoord,
    };
    for (const GLuint buffer : buffers) {
        if (buffer != GL_NONE) {
            glDeleteBuffers (1, &buffer);
        }
    }
}

TextEffectChainMember TextEffectRenderer::chainMember (const ImageEffect& effect) const {
    const bool visibilityValid = effect.visible != nullptr
        && effect.visible->value != nullptr;
    TextEffectChainMember member {
        .effectId = effect.id,
        .active = !visibilityValid || effect.visible->value->getBool (),
        .effectSupported = visibilityValid && effect.effect != nullptr,
    };
    if (!member.effectSupported) {
        return member;
    }

    const auto& definition = *effect.effect;
    const bool fbosSupported = std::all_of (
        definition.fbos.begin (), definition.fbos.end (),
        [] (const auto& fbo) { return fbo != nullptr; }
    );
    std::set<std::string_view> fboNames;
    if (fbosSupported) {
        for (const auto& fbo : definition.fbos) {
            fboNames.insert (fbo->name);
        }
    }
    const auto resolvableBind = [&fboNames] (const std::string& name) {
        return name == "previous" || fboNames.contains (name);
    };
    const auto constantsSupported = [] (const auto& constants) {
        return std::all_of (
            constants.begin (), constants.end (), [] (const auto& entry) {
                return entry.second != nullptr && entry.second->value != nullptr;
            }
        );
    };
    member.passSupported = fbosSupported && !definition.passes.empty ()
        && std::all_of (
            effect.passOverrides.begin (), effect.passOverrides.end (),
            [&constantsSupported] (const auto& passOverride) {
                return passOverride != nullptr
                    && constantsSupported (passOverride->constants);
            }
        )
        && std::all_of (
            definition.passes.begin (), definition.passes.end (),
            [&fboNames, &resolvableBind] (const auto& pass) {
                if (pass == nullptr || pass->source.has_value ()
                    || pass->command.has_value ()) {
                    return false;
                }
                if (pass->target.has_value ()
                    && !fboNames.contains (*pass->target)) {
                    return false;
                }
                return std::all_of (
                    pass->binds.begin (), pass->binds.end (),
                    [&resolvableBind] (const auto& bind) {
                        return resolvableBind (bind.second);
                    }
                );
            }
        );
    member.materialSupported = member.passSupported
        && std::all_of (
            definition.passes.begin (), definition.passes.end (),
            [&constantsSupported] (const auto& pass) {
                if (!pass->material.has_value () || pass->material.value () == nullptr
                    || !supportedMaterial (pass->material.value ()->filename)
                    || pass->material.value ()->passes.empty ()) {
                    return false;
                }
                return std::all_of (
                    pass->material.value ()->passes.begin (),
                    pass->material.value ()->passes.end (),
                    [&constantsSupported] (const auto& materialPass) {
                        return materialPass != nullptr
                            && constantsSupported (materialPass->constants);
                    }
                );
            }
        );
    return member;
}

TextEffectChainDecision TextEffectRenderer::chainDecision () const {
    TextEffectChainRequest request { .directFallbackAvailable = true };
    request.effects.reserve (m_effects.size ());
    for (const auto& effect : m_effects) {
        request.effects.push_back (
            effect != nullptr
                ? chainMember (*effect)
                : TextEffectChainMember {
                    .effectId = -1,
                    .active = true,
                    .effectSupported = false,
                }
        );
    }

    const auto lastActive = std::find_if (
        request.effects.rbegin (), request.effects.rend (),
        [] (const auto& effect) { return effect.active; }
    );
    if (lastActive != request.effects.rend ()) {
        const auto index = static_cast<std::size_t> (
            std::distance (lastActive, request.effects.rend ()) - 1
        );
        const auto& effect = m_effects[index];
        if (effect != nullptr && effect->effect != nullptr
            && !effect->effect->passes.empty ()) {
            const auto& finalPass = effect->effect->passes.back ();
            if (finalPass != nullptr && finalPass->target.has_value ()) {
                request.effects[index].passSupported = false;
            }
        }
    }
    return decideTextEffectChain (request);
}

void TextEffectRenderer::recordDecision (const TextEffectChainDecision& decision) {
    const bool changed = !m_latestDecision.has_value ()
        || m_latestDecision->mode != decision.mode
        || m_latestDecision->activeEffectIds != decision.activeEffectIds
        || m_latestDecision->blockingEffectIds != decision.blockingEffectIds
        || m_latestDecision->firstBlockingStage != decision.firstBlockingStage;
    m_latestDecision = decision;
    if (changed && decision.mode != TextEffectChainMode::composited) {
        sLog.error (
            "CText: effect chain on object ", m_text.id, " uses ",
            textEffectChainModeName (decision.mode), " because ", decision.reason,
            " at ", textEffectBlockerStageName (decision.firstBlockingStage)
        );
    }
}

std::optional<TextEffectChainEvidence> TextEffectRenderer::decisionEvidence () const {
    if (!m_latestDecision.has_value ()) {
        return std::nullopt;
    }
    return TextEffectChainEvidence {
        .objectId = m_text.id,
        .mode = m_latestDecision->mode,
        .activeEffectIds = m_latestDecision->activeEffectIds,
        .blockingEffectIds = m_latestDecision->blockingEffectIds,
        .firstBlockingEffectId = m_latestDecision->firstBlockingEffectId,
        .firstBlockingStage = m_latestDecision->firstBlockingStage,
        .supportedActiveEffects = m_latestDecision->supportedActiveEffects,
        .reason = m_latestDecision->reason,
    };
}

void TextEffectRenderer::clearPasses () {
    for (auto* pass : m_passes) {
        delete pass;
    }
    m_passes.clear ();
    m_effectProviders.clear ();
}

void TextEffectRenderer::createGeometry () {
    if (m_scenePosition == GL_NONE) {
        glGenBuffers (1, &m_scenePosition);
        glGenBuffers (1, &m_passPosition);
        glGenBuffers (1, &m_passTexCoord);
    }

    const float width = static_cast<float> (m_textureSize.x);
    const float height = static_cast<float> (m_textureSize.y);
    const float halfWidth = width * 0.5f;
    const float halfHeight = height * 0.5f;
    // The quad stays centred because the source FBO is rendered centred too —
    // renderEffects builds its MVP as ortho(-w/2, w/2, -h/2, h/2). Reshaping
    // this quad to the alignment extents instead samples half the texture and
    // clips the glyphs; alignment is applied as an origin offset in
    // updateScreenMVP, which keeps quad and content in agreement.
    const float quadLeft = -halfWidth;
    const float quadRight = halfWidth;

    // Vertex order must correspond to `texcoord` below, which every pass shares.
    // This used to run bottom-left, bottom-right, top-right… against texcoords
    // ordered top-left, bottom-left, top-right, so the composited result was
    // mirrored in both axes — a 180 degree rotation of the glyphs. `pass` is the
    // reference order: it pairs with the same texcoords and its intermediate
    // results are upright.
    const GLfloat scene[] = {
        quadLeft, halfHeight, 0.0f, quadLeft, -halfHeight, 0.0f,
        quadRight, halfHeight, 0.0f, quadRight, halfHeight, 0.0f,
        quadLeft, -halfHeight, 0.0f, quadRight, -halfHeight, 0.0f,
    };
    const GLfloat pass[] = {
        -1.0f, 1.0f, 0.0f, -1.0f, -1.0f, 0.0f, 1.0f, 1.0f, 0.0f,
        1.0f, 1.0f, 0.0f, -1.0f, -1.0f, 0.0f, 1.0f, -1.0f, 0.0f,
    };
    const GLfloat texcoord[] = {
        0.0f, 1.0f, 0.0f, 0.0f, 1.0f, 1.0f,
        1.0f, 1.0f, 0.0f, 0.0f, 1.0f, 0.0f,
    };

    const auto upload = [] (GLuint buffer, const void* values, GLsizeiptr size) {
        glBindBuffer (GL_ARRAY_BUFFER, buffer);
        glBufferData (GL_ARRAY_BUFFER, size, values, GL_DYNAMIC_DRAW);
    };
    upload (m_scenePosition, scene, sizeof (scene));
    upload (m_passPosition, pass, sizeof (pass));
    upload (m_passTexCoord, texcoord, sizeof (texcoord));

    m_modelMatrix = glm::ortho (0.0f, width, 0.0f, height);
}

void TextEffectRenderer::rebuild (glm::ivec2 textureSize) {
    clearPasses ();
    m_textureSize = glm::max (textureSize, glm::ivec2 (1));
    const glm::vec2 size (m_textureSize);
    const std::string suffix = std::to_string (m_text.id);

    m_sourceFBO = create (
        "_rt_textSource_" + suffix, TextureFormat_ARGB8888,
        TextureFlags_NoFlags, 1.0f, size, size
    );
    m_mainFBO = create (
        "_rt_textComposite_" + suffix + "_a", TextureFormat_ARGB8888,
        TextureFlags_NoFlags, 1.0f, size, size
    );
    m_subFBO = create (
        "_rt_textComposite_" + suffix + "_b", TextureFormat_ARGB8888,
        TextureFlags_NoFlags, 1.0f, size, size
    );
    m_texture = m_sourceFBO;
    createGeometry ();

    for (const auto& effect : m_effects) {
        if (effect == nullptr
            || std::find (m_activeEffects.begin (), m_activeEffects.end (), effect->id)
                == m_activeEffects.end ()) {
            continue;
        }

        auto provider = std::make_shared<FBOProvider> (this);
        for (const auto& fbo : effect->effect->fbos) {
            provider->create (*fbo, TextureFlags_NoFlags, size);
        }
        m_effectProviders.push_back (provider);

        auto overrideIt = effect->passOverrides.begin ();
        for (const auto& effectPass : effect->effect->passes) {
            std::optional<std::reference_wrapper<const ImageEffectPassOverride>> passOverride;
            if (overrideIt != effect->passOverrides.end ()) {
                passOverride = std::cref (**overrideIt);
                ++overrideIt;
            }
            std::optional<std::reference_wrapper<const TextureMap>> binds
                = std::cref (effectPass->binds);
            std::optional<std::reference_wrapper<std::string>> target;
            if (effectPass->target.has_value ()) {
                target = std::ref (*effectPass->target);
            }
            for (const auto& materialPass : effectPass->material.value ()->passes) {
                m_passes.push_back (new CPass (
                    *this, provider, *materialPass, passOverride, binds, target
                ));
            }
        }
    }

    if (m_passes.size () > 1) {
        m_passes.back ()->setBlendingMode (m_passes.front ()->getBlendingMode ());
        m_passes.front ()->setBlendingMode (BlendingMode_Normal);
    }
    configurePasses ();
}

void TextEffectRenderer::configurePasses () {
    std::shared_ptr<const CFBO> destination = m_mainFBO;
    std::shared_ptr<const TextureProvider> input = m_sourceFBO;
    std::shared_ptr<const TextureProvider> effectInput;
    bool inTargetSequence = false;

    for (auto it = m_passes.begin (); it != m_passes.end (); ++it) {
        CPass* pass = *it;
        const bool last = std::next (it) == m_passes.end ();
        const auto previousDestination = destination;
        bool writesTarget = false;

        if (pass->getTarget ().has_value ()) {
            const std::string& targetName = pass->getTarget ().value ().get ();
            auto target = pass->getFBOProvider ()->find (targetName);
            if (target == nullptr) {
                sLog.error (
                    "CText: unresolved effect target '", targetName,
                    "' on object ", m_text.id
                );
            } else {
                if (!inTargetSequence) {
                    effectInput = input;
                    inTargetSequence = true;
                }
                destination = target;
                writesTarget = true;
            }
        } else if (last) {
            destination = getScene ().getFBO ();
        }

        const bool rendersToScene = last && !writesTarget;

        // A pass that composites onto the scene has to blend. BlendingMode_Normal
        // is a straight replace — CPass maps it to glBlendFuncSeparate(GL_ONE,
        // GL_ZERO) — so the transparent margin around the glyphs overwrites the
        // scene with the source FBO's cleared black. That is what made Persona's
        // shadow and media text render as opaque black rectangles rather than
        // text. The direct glyph path always blends SRC_ALPHA/ONE_MINUS_SRC_ALPHA,
        // which is BlendingMode_Translucent, so matching it keeps the two paths
        // consistent. An authored Additive or Translucent mode is left alone.
        if (rendersToScene && pass->getBlendingMode () == BlendingMode_Normal) {
            pass->setBlendingMode (BlendingMode_Translucent);
        }

        pass->setDestination (destination);
        pass->setInput (input);
        pass->setPreviousInput (inTargetSequence ? effectInput : nullptr);
        // Every pass here is an effect pass, so they all take the NDC quad and
        // the identity MVP. CImage gives its first pass a copy-space quad in
        // texture pixels because that pass is the image's own material, drawing
        // the image into the FBO the effects then read; its effect passes are
        // never first. Text has no such pass — renderSource fills the source FBO
        // — so copying that special case put the effect chain's own first pass on
        // geometry it cannot use. `blur_precise_gaussian.vert` is where it showed:
        // the horizontal variant is `gl_Position = vec4(a_Position, 1.0)`, no MVP
        // at all, so a quad spanning 0..265 in texture pixels landed entirely
        // outside clip space and the pass rasterised nothing. Every composited
        // chain on Persona is a blurprecise, which is why the whole path drew no
        // pixels while still reporting mode=composited.
        pass->setPosition (rendersToScene ? m_scenePosition : m_passPosition);
        pass->setTexCoord (m_passTexCoord);
        pass->setModelViewProjectionMatrix (
            rendersToScene ? &m_screenMVP : &m_passMVP
        );
        pass->setModelViewProjectionMatrixInverse (
            rendersToScene ? &m_screenMVPInverse : &m_passMVPInverse
        );
        pass->setModelMatrix (&m_modelMatrix);
        pass->setViewProjectionMatrix (&m_viewProjectionMatrix);

        if (writesTarget) {
            input = destination;
            destination = previousDestination;
        } else if (!last) {
            input = destination;
            destination = destination == m_mainFBO ? m_subFBO : m_mainFBO;
            inTargetSequence = false;
            effectInput.reset ();
        }
    }
}

void TextEffectRenderer::updateScreenMVP () {
    const auto transform = resolveSceneObjectTransform (getScene (), m_text);
    const glm::vec3 origin = transform.origin;
    const glm::vec3 scale = transform.scale;
    const float sceneWidth = getScene ().getCamera ().getWidth ();
    const float sceneHeight = getScene ().getCamera ().getHeight ();
    // Scene origins run bottom-up, and this must match the direct glyph path in
    // the CText patch block, which maps Y as `scene_h * 0.5 - origin.y`. This
    // expression was the sign mirror of it, so every text whose active effect
    // chain composites rendered at `sceneHeight - origin.y` — a reflection
    // about the scene's horizontal centre, growing with distance from it.
    //
    // It survived because nothing measured it. `renderTextEffects` only
    // composites when a TextEffectRegistrySession is active, and only
    // RendererSession creates one, so the smoke tool never takes this path at
    // all: a Persona render with FRESCO_SCENE_TEXT_EFFECTS_DISABLED set and
    // unset differs by 39 pixels against a 67-pixel same-build noise floor.
    // Verify changes here against a helper session or a window capture of the
    // live desktop; a green smoke suite says nothing about this line.
    // The composited quad is centred on its origin, so the authored alignment
    // has to be applied here as an offset — the same intent as m_quadLeft and
    // m_quadRight on the direct glyph path, expressed as a translation because
    // the effect FBO's content is centred. Without it, right-aligned text sat
    // half its width too far right: Persona's song, artist and album lines
    // landed on top of the album cover instead of ending to its left.
    float alignmentOffset = 0.0f;
    if (m_text.alignment == "right") {
        alignmentOffset = -static_cast<float> (m_textureSize.x) * 0.5f;
    } else if (m_text.alignment == "left") {
        alignmentOffset = static_cast<float> (m_textureSize.x) * 0.5f;
    }

    const glm::vec3 glOrigin {
        origin.x + alignmentOffset - sceneWidth * 0.5f,
        sceneHeight * 0.5f - origin.y,
        getScene ().getCamera ().isOrthogonal () ? 0.0f : origin.z,
    };
    glm::mat4 model = glm::translate (glm::mat4 (1.0f), glOrigin);
    model = glm::rotate (
        model, -transform.angle, glm::vec3 (0.0f, 0.0f, 1.0f)
    );
    model = glm::scale (model, scale);
    m_screenMVP = applyCamera2DControl (
        getScene (), getScene ().getCamera ().getProjection ()
    )
        * getScene ().getCamera ().getLookAt () * model;
    m_screenMVPInverse = glm::inverse (m_screenMVP);
}

void TextEffectRenderer::renderEffects (
    glm::ivec2 textureSize, const TextEffectChainDecision& decision,
    const TextEffectSourceRenderer& renderSource
) {
    const int padding = std::max (m_text.padding, 0);
    const glm::ivec2 effectSize = textureSize + glm::ivec2 (padding * 2);
    if (effectSize != m_textureSize || m_passes.empty ()
        || decision.compositedEffectIds != m_activeEffects) {
        m_activeEffects = decision.compositedEffectIds;
        rebuild (effectSize);
    }
    updateScreenMVP ();
    const glm::mat4 sourceMVP = glm::ortho (
        -static_cast<float> (m_textureSize.x) * 0.5f,
        static_cast<float> (m_textureSize.x) * 0.5f,
        -static_cast<float> (m_textureSize.y) * 0.5f,
        static_cast<float> (m_textureSize.y) * 0.5f
    );
    // The composited geometry is otherwise unmeasurable from a capture: a quad
    // that covers the whole screen and one that covers the glyphs both read as
    // "the text is there". Reports the raster the FBO was sized from and the
    // scene extent the quad reaches, which is what separates the two.
    if (std::getenv ("FRESCO_SCENE_TEXT_EFFECT_TRACE") != nullptr) {
        const glm::vec4 centre = m_screenMVP * glm::vec4 (0.0f, 0.0f, 0.0f, 1.0f);
        sLog.out (
            "textEffectQuad id=", m_text.id,
            " ndc=", centre.x / centre.w, ',', centre.y / centre.w,
            ',', centre.z / centre.w,
            " raster=", textureSize.x, 'x', textureSize.y,
            " padding=", padding,
            " texture=", m_textureSize.x, 'x', m_textureSize.y,
            " scene=", static_cast<int> (getScene ().getCamera ().getWidth ()),
            'x', static_cast<int> (getScene ().getCamera ().getHeight ()),
            " passes=", m_passes.size ()
        );
    }
    renderSource (m_sourceFBO, sourceMVP);
    probeStage (m_text.id, "source", m_sourceFBO);
    for (auto it = m_passes.begin (); it != m_passes.end (); ++it) {
        (*it)->render ();
        // The probe reads whatever the pass left bound, so the last one reports
        // the scene rather than an intermediate FBO.
        probeStage (
            m_text.id, std::next (it) == m_passes.end () ? "scene" : "pass", nullptr
        );
    }
}

const float& TextEffectRenderer::getBrightness () const {
    static const float brightness = 1.0f;
    return brightness;
}

const float& TextEffectRenderer::getUserAlpha () const {
    return m_text.alpha->value->getFloat ();
}

const float& TextEffectRenderer::getAlpha () const {
    return m_text.alpha->value->getFloat ();
}

const glm::vec3& TextEffectRenderer::getColor () const {
    return m_text.color->value->getVec3 ();
}

const glm::vec4& TextEffectRenderer::getColor4 () const {
    return m_text.color->value->getVec4 ();
}

const glm::vec3& TextEffectRenderer::getCompositeColor () const {
    return m_text.color->value->getVec3 ();
}

bool renderTextEffects (
    CScene& scene, const Text& text, glm::ivec2 textureSize,
    const TextEffectSourceRenderer& renderSource
) {
    const auto& effects = textEffects (&scene, text.id);
    if (effects.empty ()
        || std::getenv ("FRESCO_SCENE_TEXT_EFFECTS_DISABLED") != nullptr) {
        return false;
    }

    const RendererKey key { &scene, text.id };
    auto it = renderers.find (key);
    if (it == renderers.end ()) {
        it = renderers.emplace (
            key, std::make_unique<TextEffectRenderer> (scene, text, effects)
        ).first;
    }
    auto decision = it->second->chainDecision ();
    if (decision.activeEffectIds.empty ()) {
        decision.mode = TextEffectChainMode::directFallback;
        decision.compositedEffectIds.clear ();
        decision.reason = "text-effect-chain-inactive";
    }
    it->second->recordDecision (decision);
    if (decision.mode != TextEffectChainMode::composited
        || decision.activeEffectIds.empty ()) {
        return false;
    }
    it->second->renderEffects (textureSize, decision, renderSource);
    return true;
}

void clearTextEffectRenderers (const CScene* scene) {
    std::erase_if (renderers, [scene] (const auto& entry) {
        return entry.first.first == scene;
    });
}

std::vector<TextEffectChainEvidence> textEffectChainEvidence (const CScene* scene) {
    std::vector<TextEffectChainEvidence> result;
    for (const auto& [key, renderer] : renderers) {
        if (key.first != scene) {
            continue;
        }
        if (auto evidence = renderer->decisionEvidence ()) {
            result.push_back (std::move (*evidence));
        }
    }
    return result;
}

}
