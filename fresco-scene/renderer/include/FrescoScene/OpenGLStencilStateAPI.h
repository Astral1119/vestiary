#pragma once

#include "FrescoScene/ScopedStencilState.h"

namespace FrescoScene {

class OpenGLStencilStateAPI final : public StencilStateAPI {
public:
    [[nodiscard]] bool stencilEnabled () const noexcept override;
    [[nodiscard]] StencilFaceState stencilFaceState (
        StencilFace face
    ) const noexcept override;
    [[nodiscard]] std::int32_t stencilClearValue () const noexcept override;
    [[nodiscard]] std::array<bool, 4> colorWriteMask () const noexcept override;
    [[nodiscard]] bool scissorEnabled () const noexcept override;
    [[nodiscard]] std::uint32_t drawFramebuffer () const noexcept override;
    [[nodiscard]] StencilAttachment drawFramebufferStencilAttachment () const noexcept override;
    [[nodiscard]] std::uint32_t boundRenderbuffer () const noexcept override;

    void setStencilEnabled (bool enabled) noexcept override;
    void setStencilFunction (
        StencilFace face, std::uint32_t function, std::int32_t reference,
        std::uint32_t valueMask
    ) noexcept override;
    void setStencilOperation (
        StencilFace face, std::uint32_t stencilFail, std::uint32_t depthFail,
        std::uint32_t depthPass
    ) noexcept override;
    void setStencilWriteMask (
        StencilFace face, std::uint32_t writeMask
    ) noexcept override;
    void setStencilClearValue (std::int32_t value) noexcept override;
    void setColorWriteMask (std::array<bool, 4> mask) noexcept override;
    void setScissorEnabled (bool enabled) noexcept override;
    void clearStencilBuffer () noexcept override;
    void bindDrawFramebuffer (std::uint32_t framebuffer) noexcept override;
    void bindRenderbuffer (std::uint32_t renderbuffer) noexcept override;
    void allocateStencil8Storage (
        std::int32_t width, std::int32_t height
    ) noexcept override;
    void setDrawFramebufferStencilAttachment (
        StencilAttachment attachment
    ) noexcept override;
    [[nodiscard]] bool drawFramebufferComplete () const noexcept override;
};

} // namespace FrescoScene
