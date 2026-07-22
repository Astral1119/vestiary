#pragma once

#ifdef FRESCO_SCENE_GLES
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#include <vector>

// ES 3.0 has no double-precision uniforms. Wallpaper Engine stores some
// scalar uniforms as doubles even though its shader values are floats.
inline void frescoUniform1d (GLint location, double value) {
    glUniform1f (location, static_cast<GLfloat> (value));
}

inline void frescoUniform1dv (GLint location, GLsizei count, const double* values) {
    std::vector<GLfloat> converted (static_cast<std::size_t> (count));
    for (GLsizei index = 0; index < count; ++index) {
        converted[static_cast<std::size_t> (index)] = static_cast<GLfloat> (values[index]);
    }
    glUniform1fv (location, count, converted.data ());
}

// These calls only annotate desktop debug captures. The GLES core does not
// require KHR_debug at runtime.
#define glObjectLabel(...) ((void) 0)
#define glPushDebugGroup(...) ((void) 0)
#define glPopDebugGroup(...) ((void) 0)
#define glUniform1d frescoUniform1d
#define glUniform1dv frescoUniform1dv

// ES 3.0 does not guarantee border clamp, depth clamp, or anisotropic
// filtering. These compile scaffolds can change edge and particle visuals;
// fixture parity remains required before the GLES renderer is supported.
#ifndef GL_CLAMP_TO_BORDER
#define GL_CLAMP_TO_BORDER GL_CLAMP_TO_EDGE
#endif
#ifndef GL_DEPTH_CLAMP
#define GL_DEPTH_CLAMP 0x864F
#endif
#ifndef GL_TEXTURE_MAX_ANISOTROPY
#define GL_TEXTURE_MAX_ANISOTROPY GL_TEXTURE_MAX_ANISOTROPY_EXT
#endif

inline void frescoEnable (GLenum capability) {
    if (capability != GL_DEPTH_CLAMP) {
        glEnable (capability);
    }
}

inline void frescoDisable (GLenum capability) {
    if (capability != GL_DEPTH_CLAMP) {
        glDisable (capability);
    }
}

inline void frescoTexParameterf (GLenum target, GLenum name, GLfloat value) {
    if (name != GL_TEXTURE_MAX_ANISOTROPY) {
        glTexParameterf (target, name, value);
    }
}

#define glEnable frescoEnable
#define glDisable frescoDisable
#define glTexParameterf frescoTexParameterf
#else
#include <OpenGL/gl3.h>
#include <OpenGL/gl3ext.h>

#ifndef GL_TEXTURE_MAX_ANISOTROPY
#define GL_TEXTURE_MAX_ANISOTROPY GL_TEXTURE_MAX_ANISOTROPY_EXT
#endif

#ifndef GLEW_VERSION_4_5
#define GLEW_VERSION_4_5 0
#endif

inline void frescoGetnTexImage (
    GLenum target, GLint level, GLenum format, GLenum type, GLsizei, void* pixels
) {
    glGetTexImage (target, level, format, type, pixels);
}

#define glGetnTexImage frescoGetnTexImage
#endif
