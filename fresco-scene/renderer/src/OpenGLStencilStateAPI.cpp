#include "FrescoScene/OpenGLStencilStateAPI.h"

#if defined(FRESCO_SCENE_ANGLE_RUNTIME) || defined(FRESCO_SCENE_GLES)
#include <GLES3/gl3.h>
#elif defined(__APPLE__)
#define GL_SILENCE_DEPRECATION
#include <OpenGL/gl3.h>
#else
#error "OpenGLStencilStateAPI requires ANGLE GLES3 or Apple OpenGL"
#endif

namespace FrescoScene {
namespace {

GLenum glFace (StencilFace face) noexcept {
    return face == StencilFace::front ? GL_FRONT : GL_BACK;
}

GLenum faceQuery (
    StencilFace face, GLenum frontQuery, GLenum backQuery
) noexcept {
    return face == StencilFace::front ? frontQuery : backQuery;
}

GLint integerState (GLenum query) noexcept {
    GLint value = 0;
    glGetIntegerv (query, &value);
    return value;
}

} // namespace

bool OpenGLStencilStateAPI::stencilEnabled () const noexcept {
    return glIsEnabled (GL_STENCIL_TEST) == GL_TRUE;
}

StencilFaceState OpenGLStencilStateAPI::stencilFaceState (
    StencilFace face
) const noexcept {
    return {
        .function = static_cast<std::uint32_t> (integerState (faceQuery (
            face, GL_STENCIL_FUNC, GL_STENCIL_BACK_FUNC
        ))),
        .reference = integerState (faceQuery (
            face, GL_STENCIL_REF, GL_STENCIL_BACK_REF
        )),
        .valueMask = static_cast<std::uint32_t> (integerState (faceQuery (
            face, GL_STENCIL_VALUE_MASK, GL_STENCIL_BACK_VALUE_MASK
        ))),
        .stencilFail = static_cast<std::uint32_t> (integerState (faceQuery (
            face, GL_STENCIL_FAIL, GL_STENCIL_BACK_FAIL
        ))),
        .depthFail = static_cast<std::uint32_t> (integerState (faceQuery (
            face, GL_STENCIL_PASS_DEPTH_FAIL, GL_STENCIL_BACK_PASS_DEPTH_FAIL
        ))),
        .depthPass = static_cast<std::uint32_t> (integerState (faceQuery (
            face, GL_STENCIL_PASS_DEPTH_PASS, GL_STENCIL_BACK_PASS_DEPTH_PASS
        ))),
        .writeMask = static_cast<std::uint32_t> (integerState (faceQuery (
            face, GL_STENCIL_WRITEMASK, GL_STENCIL_BACK_WRITEMASK
        ))),
    };
}

std::int32_t OpenGLStencilStateAPI::stencilClearValue () const noexcept {
    return integerState (GL_STENCIL_CLEAR_VALUE);
}

std::array<bool, 4> OpenGLStencilStateAPI::colorWriteMask () const noexcept {
    GLboolean values[4] = {};
    glGetBooleanv (GL_COLOR_WRITEMASK, values);
    return {
        values[0] == GL_TRUE, values[1] == GL_TRUE,
        values[2] == GL_TRUE, values[3] == GL_TRUE,
    };
}

bool OpenGLStencilStateAPI::scissorEnabled () const noexcept {
    return glIsEnabled (GL_SCISSOR_TEST) == GL_TRUE;
}

std::uint32_t OpenGLStencilStateAPI::drawFramebuffer () const noexcept {
    return static_cast<std::uint32_t> (integerState (GL_DRAW_FRAMEBUFFER_BINDING));
}

StencilAttachment OpenGLStencilStateAPI::drawFramebufferStencilAttachment () const noexcept {
    GLint objectType = GL_NONE;
    glGetFramebufferAttachmentParameteriv (
        GL_DRAW_FRAMEBUFFER, GL_STENCIL_ATTACHMENT,
        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &objectType
    );
    if (objectType == GL_NONE) {
        return {};
    }

    GLint objectName = 0;
    glGetFramebufferAttachmentParameteriv (
        GL_DRAW_FRAMEBUFFER, GL_STENCIL_ATTACHMENT,
        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &objectName
    );
    const auto type = objectType == GL_TEXTURE
        ? StencilAttachmentObjectType::texture
        : objectType == GL_RENDERBUFFER
        ? StencilAttachmentObjectType::renderbuffer
        : StencilAttachmentObjectType::none;
    return {
        type,
        type == StencilAttachmentObjectType::none
            ? 0U : static_cast<std::uint32_t> (objectName),
    };
}

std::uint32_t OpenGLStencilStateAPI::boundRenderbuffer () const noexcept {
    return static_cast<std::uint32_t> (integerState (GL_RENDERBUFFER_BINDING));
}

void OpenGLStencilStateAPI::setStencilEnabled (bool enabled) noexcept {
    if (enabled) {
        glEnable (GL_STENCIL_TEST);
    } else {
        glDisable (GL_STENCIL_TEST);
    }
}

void OpenGLStencilStateAPI::setStencilFunction (
    StencilFace face, std::uint32_t function, std::int32_t reference,
    std::uint32_t valueMask
) noexcept {
    glStencilFuncSeparate (
        glFace (face), static_cast<GLenum> (function), reference,
        static_cast<GLuint> (valueMask)
    );
}

void OpenGLStencilStateAPI::setStencilOperation (
    StencilFace face, std::uint32_t stencilFail, std::uint32_t depthFail,
    std::uint32_t depthPass
) noexcept {
    glStencilOpSeparate (
        glFace (face), static_cast<GLenum> (stencilFail),
        static_cast<GLenum> (depthFail), static_cast<GLenum> (depthPass)
    );
}

void OpenGLStencilStateAPI::setStencilWriteMask (
    StencilFace face, std::uint32_t writeMask
) noexcept {
    glStencilMaskSeparate (glFace (face), static_cast<GLuint> (writeMask));
}

void OpenGLStencilStateAPI::setStencilClearValue (std::int32_t value) noexcept {
    glClearStencil (value);
}

void OpenGLStencilStateAPI::setColorWriteMask (
    std::array<bool, 4> mask
) noexcept {
    glColorMask (mask[0], mask[1], mask[2], mask[3]);
}

void OpenGLStencilStateAPI::setScissorEnabled (bool enabled) noexcept {
    if (enabled) {
        glEnable (GL_SCISSOR_TEST);
    } else {
        glDisable (GL_SCISSOR_TEST);
    }
}

void OpenGLStencilStateAPI::clearStencilBuffer () noexcept {
    glClear (GL_STENCIL_BUFFER_BIT);
}

void OpenGLStencilStateAPI::bindDrawFramebuffer (
    std::uint32_t framebuffer
) noexcept {
    glBindFramebuffer (GL_DRAW_FRAMEBUFFER, static_cast<GLuint> (framebuffer));
}

void OpenGLStencilStateAPI::bindRenderbuffer (
    std::uint32_t renderbuffer
) noexcept {
    glBindRenderbuffer (GL_RENDERBUFFER, static_cast<GLuint> (renderbuffer));
}

void OpenGLStencilStateAPI::allocateStencil8Storage (
    std::int32_t width, std::int32_t height
) noexcept {
    glRenderbufferStorage (GL_RENDERBUFFER, GL_STENCIL_INDEX8, width, height);
}

void OpenGLStencilStateAPI::setDrawFramebufferStencilAttachment (
    StencilAttachment attachment
) noexcept {
    switch (attachment.objectType) {
    case StencilAttachmentObjectType::none:
        glFramebufferRenderbuffer (
            GL_DRAW_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, 0
        );
        break;
    case StencilAttachmentObjectType::texture:
        glFramebufferTexture2D (
            GL_DRAW_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_TEXTURE_2D,
            static_cast<GLuint> (attachment.objectName), 0
        );
        break;
    case StencilAttachmentObjectType::renderbuffer:
        glFramebufferRenderbuffer (
            GL_DRAW_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER,
            static_cast<GLuint> (attachment.objectName)
        );
        break;
    }
}

bool OpenGLStencilStateAPI::drawFramebufferComplete () const noexcept {
    return glCheckFramebufferStatus (GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}

} // namespace FrescoScene
