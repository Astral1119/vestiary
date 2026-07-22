#include "FrescoScene/ScopedStencilState.h"

#include <stdexcept>

namespace FrescoScene {
namespace {

StencilStateSnapshot capture (const StencilStateAPI& api) noexcept {
    StencilStateSnapshot result;
    result.enabled = api.stencilEnabled ();
    result.front = api.stencilFaceState (StencilFace::front);
    result.back = api.stencilFaceState (StencilFace::back);
    result.clearValue = api.stencilClearValue ();
    result.colorWriteMask = api.colorWriteMask ();
    result.scissorEnabled = api.scissorEnabled ();
    result.drawFramebuffer = api.drawFramebuffer ();
    result.attachment = api.drawFramebufferStencilAttachment ();
    result.boundRenderbuffer = api.boundRenderbuffer ();
    return result;
}

void restoreFace (
    StencilStateAPI& api, StencilFace face, const StencilFaceState& state
) noexcept {
    api.setStencilFunction (face, state.function, state.reference, state.valueMask);
    api.setStencilOperation (
        face, state.stencilFail, state.depthFail, state.depthPass
    );
    api.setStencilWriteMask (face, state.writeMask);
}

} // namespace

ScopedStencilState::ScopedStencilState (
    StencilStateAPI& api, std::uint32_t temporaryStencilRenderbuffer,
    std::int32_t width, std::int32_t height
) : m_api (api),
    m_temporaryStencilRenderbuffer (temporaryStencilRenderbuffer) {
    if (temporaryStencilRenderbuffer == 0) {
        throw std::invalid_argument ("temporary stencil renderbuffer must be nonzero");
    }
    if (width <= 0 || height <= 0) {
        throw std::invalid_argument ("temporary stencil dimensions must be positive");
    }

    m_snapshot = capture (api);
    if (m_snapshot.attachment.objectType == StencilAttachmentObjectType::texture) {
        throw std::runtime_error (
            "prior stencil texture attachment has unknown target provenance"
        );
    }
    m_api.bindRenderbuffer (temporaryStencilRenderbuffer);
    m_api.allocateStencil8Storage (width, height);
    m_api.bindRenderbuffer (m_snapshot.boundRenderbuffer);
    m_api.setDrawFramebufferStencilAttachment ({
        StencilAttachmentObjectType::renderbuffer, temporaryStencilRenderbuffer
    });
    m_attached = true;

    if (!m_api.drawFramebufferComplete ()) {
        restore ();
        throw std::runtime_error (
            "draw framebuffer is incomplete with temporary stencil attachment"
        );
    }
    m_api.setDrawFramebufferStencilAttachment (m_snapshot.attachment);
}

ScopedStencilState::~ScopedStencilState () noexcept {
    restore ();
}

const StencilStateSnapshot& ScopedStencilState::snapshot () const noexcept {
    return m_snapshot;
}

void ScopedStencilState::beginMaskWrite () noexcept {
    m_api.bindDrawFramebuffer (m_snapshot.drawFramebuffer);
    m_api.setDrawFramebufferStencilAttachment ({
        StencilAttachmentObjectType::renderbuffer,
        m_temporaryStencilRenderbuffer,
    });
    m_api.setStencilEnabled (true);
    m_api.setStencilWriteMask (StencilFace::front, 0xffU);
    m_api.setStencilWriteMask (StencilFace::back, 0xffU);
    m_api.setStencilClearValue (0);
    m_api.setScissorEnabled (false);
    m_api.clearStencilBuffer ();
    m_api.setScissorEnabled (m_snapshot.scissorEnabled);
    for (const auto face : { StencilFace::front, StencilFace::back }) {
        m_api.setStencilFunction (face, 0x0207U, 1, 0xffU);
        m_api.setStencilOperation (face, 0x1e00U, 0x1e00U, 0x1e01U);
    }
    m_api.setColorWriteMask ({ false, false, false, false });
}

void ScopedStencilState::beginMaskedDraw () noexcept {
    m_api.setColorWriteMask (m_snapshot.colorWriteMask);
    m_api.setStencilEnabled (true);
    for (const auto face : { StencilFace::front, StencilFace::back }) {
        m_api.setStencilWriteMask (face, 0U);
        m_api.setStencilFunction (face, 0x0202U, 1, 0xffU);
        m_api.setStencilOperation (face, 0x1e00U, 0x1e00U, 0x1e00U);
    }
}

void ScopedStencilState::restorePipelineState () noexcept {
    m_api.bindDrawFramebuffer (m_snapshot.drawFramebuffer);
    m_api.setDrawFramebufferStencilAttachment (m_snapshot.attachment);
    restoreFace (m_api, StencilFace::front, m_snapshot.front);
    restoreFace (m_api, StencilFace::back, m_snapshot.back);
    m_api.setStencilClearValue (m_snapshot.clearValue);
    m_api.setColorWriteMask (m_snapshot.colorWriteMask);
    m_api.setScissorEnabled (m_snapshot.scissorEnabled);
    m_api.setStencilEnabled (m_snapshot.enabled);
}

void ScopedStencilState::restore () noexcept {
    if (!m_attached) {
        return;
    }

    restorePipelineState ();
    m_api.bindRenderbuffer (m_snapshot.boundRenderbuffer);
    m_attached = false;
}

} // namespace FrescoScene
