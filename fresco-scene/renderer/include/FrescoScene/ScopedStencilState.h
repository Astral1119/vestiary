#pragma once

#include <array>
#include <cstdint>

namespace FrescoScene {

enum class StencilFace {
    front,
    back,
};

enum class StencilAttachmentObjectType {
    none,
    texture,
    renderbuffer,
};

struct StencilFaceState {
    std::uint32_t function = 0;
    std::int32_t reference = 0;
    std::uint32_t valueMask = 0;
    std::uint32_t stencilFail = 0;
    std::uint32_t depthFail = 0;
    std::uint32_t depthPass = 0;
    std::uint32_t writeMask = 0;

    bool operator== (const StencilFaceState& other) const noexcept {
        return function == other.function && reference == other.reference
            && valueMask == other.valueMask && stencilFail == other.stencilFail
            && depthFail == other.depthFail && depthPass == other.depthPass
            && writeMask == other.writeMask;
    }
};

struct StencilAttachment {
    StencilAttachmentObjectType objectType = StencilAttachmentObjectType::none;
    std::uint32_t objectName = 0;

    bool operator== (const StencilAttachment& other) const noexcept {
        return objectType == other.objectType && objectName == other.objectName;
    }
};

struct StencilStateSnapshot {
    bool enabled = false;
    StencilFaceState front;
    StencilFaceState back;
    std::int32_t clearValue = 0;
    std::array<bool, 4> colorWriteMask = { true, true, true, true };
    bool scissorEnabled = false;
    std::uint32_t drawFramebuffer = 0;
    StencilAttachment attachment;
    std::uint32_t boundRenderbuffer = 0;

    bool operator== (const StencilStateSnapshot& other) const noexcept {
        return enabled == other.enabled && front == other.front && back == other.back
            && clearValue == other.clearValue
            && colorWriteMask == other.colorWriteMask
            && scissorEnabled == other.scissorEnabled
            && drawFramebuffer == other.drawFramebuffer
            && attachment == other.attachment
            && boundRenderbuffer == other.boundRenderbuffer;
    }
};

class StencilStateAPI {
public:
    virtual ~StencilStateAPI () = default;

    [[nodiscard]] virtual bool stencilEnabled () const noexcept = 0;
    [[nodiscard]] virtual StencilFaceState stencilFaceState (
        StencilFace face
    ) const noexcept = 0;
    [[nodiscard]] virtual std::int32_t stencilClearValue () const noexcept = 0;
    [[nodiscard]] virtual std::array<bool, 4> colorWriteMask () const noexcept = 0;
    [[nodiscard]] virtual bool scissorEnabled () const noexcept = 0;
    [[nodiscard]] virtual std::uint32_t drawFramebuffer () const noexcept = 0;
    [[nodiscard]] virtual StencilAttachment drawFramebufferStencilAttachment () const noexcept = 0;
    [[nodiscard]] virtual std::uint32_t boundRenderbuffer () const noexcept = 0;

    virtual void setStencilEnabled (bool enabled) noexcept = 0;
    virtual void setStencilFunction (
        StencilFace face, std::uint32_t function, std::int32_t reference,
        std::uint32_t valueMask
    ) noexcept = 0;
    virtual void setStencilOperation (
        StencilFace face, std::uint32_t stencilFail, std::uint32_t depthFail,
        std::uint32_t depthPass
    ) noexcept = 0;
    virtual void setStencilWriteMask (
        StencilFace face, std::uint32_t writeMask
    ) noexcept = 0;
    virtual void setStencilClearValue (std::int32_t value) noexcept = 0;
    virtual void setColorWriteMask (std::array<bool, 4> mask) noexcept = 0;
    virtual void setScissorEnabled (bool enabled) noexcept = 0;
    virtual void clearStencilBuffer () noexcept = 0;
    virtual void bindDrawFramebuffer (std::uint32_t framebuffer) noexcept = 0;
    virtual void bindRenderbuffer (std::uint32_t renderbuffer) noexcept = 0;
    virtual void allocateStencil8Storage (
        std::int32_t width, std::int32_t height
    ) noexcept = 0;
    virtual void setDrawFramebufferStencilAttachment (
        StencilAttachment attachment
    ) noexcept = 0;
    [[nodiscard]] virtual bool drawFramebufferComplete () const noexcept = 0;
};

class ScopedStencilState {
public:
    ScopedStencilState (
        StencilStateAPI& api, std::uint32_t temporaryStencilRenderbuffer,
        std::int32_t width, std::int32_t height
    );
    ~ScopedStencilState () noexcept;

    ScopedStencilState (const ScopedStencilState&) = delete;
    ScopedStencilState& operator= (const ScopedStencilState&) = delete;
    ScopedStencilState (ScopedStencilState&&) = delete;
    ScopedStencilState& operator= (ScopedStencilState&&) = delete;

    [[nodiscard]] const StencilStateSnapshot& snapshot () const noexcept;
    void beginMaskWrite () noexcept;
    void beginMaskedDraw () noexcept;
    void restorePipelineState () noexcept;

private:
    void restore () noexcept;

    StencilStateAPI& m_api;
    StencilStateSnapshot m_snapshot;
    std::uint32_t m_temporaryStencilRenderbuffer = 0;
    bool m_attached = false;
};

} // namespace FrescoScene
