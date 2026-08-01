function(fresco_replace_section source_variable start_marker end_marker replacement description)
    string(FIND "${${source_variable}}" "${start_marker}" start_offset)
    if(start_offset EQUAL -1)
        message(FATAL_ERROR "cannot apply puppet patch: missing ${description} start")
    endif()
    string(FIND "${${source_variable}}" "${end_marker}" end_offset)
    if(end_offset EQUAL -1 OR end_offset LESS start_offset)
        message(FATAL_ERROR "cannot apply puppet patch: missing ${description} end")
    endif()
    string(SUBSTRING "${${source_variable}}" 0 ${start_offset} prefix)
    string(SUBSTRING "${${source_variable}}" ${end_offset} -1 suffix)
    set(${source_variable} "${prefix}${replacement}${suffix}" PARENT_SCOPE)
endfunction()

set(puppet_object_parser_source "${object_parser_source}")
string(REPLACE
    "#include \"ObjectParser.h\""
    "#include \"ObjectParser.h\"\n#include \"FrescoScene/PuppetLayerSemantics.h\""
    puppet_object_parser_source
    "${puppet_object_parser_source}"
)
set(puppet_layer_parser_before [=[return std::make_unique<ImageAnimationLayer> (ImageAnimationLayer {
	.id = it.require<int> ("id", "Animation layer must have an id"),
	.rate = it.user ("rate", properties, 1.0f),
	.visible = it.user ("visible", properties, false),
	.blend = it.user ("blend", properties, 1.0f),
	.animation = it.user ("animation", properties, 0),
    });]=])
set(puppet_layer_parser_after [=[auto layer = std::make_unique<ImageAnimationLayer> (ImageAnimationLayer {
	.id = it.require<int> ("id", "Animation layer must have an id"),
	.rate = it.user ("rate", properties, 1.0f),
	.visible = it.user ("visible", properties, false),
	.blend = it.user ("blend", properties, 1.0f),
	.animation = it.user ("animation", properties, 0),
    });
    FrescoScene::registerPuppetLayerSemantics (
	layer.get (), it.optional<bool> ("additive", false)
    );
    return layer;]=])
string(REPLACE
    "${puppet_layer_parser_before}"
    "${puppet_layer_parser_after}"
    puppet_object_parser_source
    "${puppet_object_parser_source}"
)
fresco_require_generated_patch(
    puppet_object_parser_source
    "registerPuppetLayerSemantics"
    "puppet additive layer preservation"
)
set(puppet_image_return_before [=[    return result;
}

std::vector<ImageEffectUniquePtr>]=])
set(puppet_image_return_after [=[    FrescoScene::registerPuppetAttachment (
	result.get (), it.optional<std::string> ("attachment", "")
    );
    return result;
}

std::vector<ImageEffectUniquePtr>]=])
string(REPLACE
    "${puppet_image_return_before}"
    "${puppet_image_return_after}"
    puppet_object_parser_source
    "${puppet_object_parser_source}"
)
fresco_require_generated_patch(
    puppet_object_parser_source
    "registerPuppetAttachment"
    "puppet attachment preservation"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/ObjectParser.cpp"
    puppet_object_parser_source
)

set(puppet_wallpaper_parser_source "${wallpaper_parser_source}")
string(REPLACE
    "#include \"WallpaperParser.h\""
    "#include \"WallpaperParser.h\"\n#include \"FrescoScene/PuppetLayerSemantics.h\""
    puppet_wallpaper_parser_source
    "${puppet_wallpaper_parser_source}"
)
string(REPLACE
    "ObjectList WallpaperParser::parseObjects (const JSON& objects, const Project& project) {"
    "ObjectList WallpaperParser::parseObjects (const JSON& objects, const Project& project) {\n    FrescoScene::clearPuppetLayerSemantics ();"
    puppet_wallpaper_parser_source
    "${puppet_wallpaper_parser_source}"
)
fresco_require_generated_patch(
    puppet_wallpaper_parser_source
    "clearPuppetLayerSemantics"
    "scene-scoped puppet metadata ownership"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/WallpaperParser.cpp"
    puppet_wallpaper_parser_source
)

file(READ
    "${upstream}/src/WallpaperEngine/Render/Objects/CImage.h"
    puppet_image_header
)
string(REPLACE
    "#include \"CRenderable.h\""
    "#include \"WallpaperEngine/Render/Objects/CRenderable.h\""
    puppet_image_header
    "${puppet_image_header}"
)
string(REPLACE
    "#include \"../TextureProvider.h\""
    "#include \"WallpaperEngine/Render/TextureProvider.h\""
    puppet_image_header
    "${puppet_image_header}"
)
string(REPLACE
    "#include <glm/vec3.hpp>"
    "#include <glm/vec3.hpp>\n#include <memory>\n#include <unordered_map>\n#include \"FrescoScene/PuppetRuntimeMesh.h\""
    puppet_image_header
    "${puppet_image_header}"
)
string(REPLACE
    "    std::vector<GLfloat> m_puppetRawPositions = {};"
    "    std::unique_ptr<FrescoScene::PuppetRuntimeMesh> m_puppetRuntime = nullptr;\n    std::vector<std::shared_ptr<const TextureProvider>> m_puppetMaskTextures = {};\n    std::unordered_map<GLuint, GLuint> m_puppetStencilBuffers = {};\n    GLuint m_puppetMaskProgram = GL_NONE;\n    GLuint m_puppetMaskVAO = GL_NONE;\n    GLint m_puppetMaskPosition = -1;\n    GLint m_puppetMaskTexCoord = -1;\n    GLint m_puppetMaskTransform = -1;\n    GLint m_puppetMaskSize = -1;\n    GLint m_puppetMaskUseTransform = -1;"
    puppet_image_header
    "${puppet_image_header}"
)
string(REPLACE
    "private:\n    bool loadPuppetMesh"
    "private:\n    [[nodiscard]] bool isVisibleWithParents () const;\n    bool loadPuppetMesh"
    puppet_image_header
    "${puppet_image_header}"
)
# Cursor hit-testing needs the box a layer actually draws, which is m_pos: the
# resolved parent chain, the scale and the alignment are already folded into it.
# This lives here rather than in GeneratedPatches.cmake only because CImage is
# read, patched and written in this file, and two writers would race.
string(REPLACE
    "    [[nodiscard]] glm::vec2 getSize () const;"
    "    [[nodiscard]] glm::vec2 getSize () const;\n\n    /** The drawn box as (left, bottom, right, top) in absolute bottom-up scene coordinates. */\n    [[nodiscard]] glm::vec4 frescoSceneBox () const;"
    puppet_image_header
    "${puppet_image_header}"
)
# A puppet mesh needs its vertices in two spaces, for the same reason the
# non-puppet path keeps m_sceneSpacePosition beside m_copySpacePosition. A first
# pass rendering into an FBO wants the layer-local box; a pass drawing straight
# to the scene wants scene coordinates with the resolved parent chain in them.
string(REPLACE
    "    GLuint m_puppetSpacePosition = GL_NONE;"
    "    GLuint m_puppetSpacePosition = GL_NONE;\n    GLuint m_puppetScenePosition = GL_NONE;\n    mutable GLuint m_puppetActivePosition = GL_NONE;"
    puppet_image_header
    "${puppet_image_header}"
)
string(REPLACE
    "    void setupPuppetGeometryCallback (Effects::CPass* pass) const;"
    "    void setupPuppetGeometryCallback (Effects::CPass* pass) const;"
    puppet_image_header
    "${puppet_image_header}"
)
fresco_require_generated_patch(
    puppet_image_header
    "frescoSceneBox"
    "scene-space layer box accessor"
)
fresco_require_generated_patch(
    puppet_image_header
    "m_puppetScenePosition"
    "scene-space puppet vertex buffer"
)
fresco_require_generated_patch(
    puppet_image_header
    "m_puppetActivePosition"
    "puppet active vertex buffer selection"
)
fresco_require_generated_patch(
    puppet_image_header
    "m_puppetRuntime"
    "puppet runtime ownership"
)
fresco_require_generated_patch(
    puppet_image_header
    "isVisibleWithParents"
    "procedural quad parent visibility declaration"
)
file(MAKE_DIRECTORY
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render/Objects"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render/Objects/CImage.h"
    puppet_image_header
)

file(READ
    "${upstream}/src/WallpaperEngine/Render/Objects/CImage.cpp"
    puppet_image_source
)
string(REPLACE
    "local.origin.x * resolved.scale.x, -local.origin.y * resolved.scale.y"
    "local.origin.x * resolved.scale.x, local.origin.y * resolved.scale.y"
    puppet_image_source
    "${puppet_image_source}"
)
fresco_require_generated_patch(
    puppet_image_source
    "local.origin.y * resolved.scale.y"
    "image parent-local Y coordinate composition"
)
string(REPLACE
    "    this->detectTexture ();"
    "    if (this->getImage ().model->filename != \"models/fresco_procedural_quad.json\") {\n\tthis->detectTexture ();\n    }"
    puppet_image_source
    "${puppet_image_source}"
)
fresco_require_generated_patch(
    puppet_image_source
    "models/fresco_procedural_quad.json"
    "effect-only procedural quad texture bypass"
)
string(REPLACE
    "#include \"CImage.h\""
    "#include \"WallpaperEngine/Render/Objects/CImage.h\"\n#include \"FrescoScene/Camera2DControl.h\"\n#include \"FrescoScene/OpenGLStencilStateAPI.h\"\n#include \"FrescoScene/PassthroughLayerSemantics.h\"\n#include \"FrescoScene/PuppetLayerSemantics.h\"\n#include \"FrescoScene/PuppetRenderEvidence.h\"\n#include \"FrescoScene/SceneObjectModelTransform.h\"\n#include \"FrescoScene/ScopedStencilState.h\"\n#include <cstdint>\n#include <cstdio>\n#include <cstdlib>\n#include <optional>\n#include <stdexcept>"
    puppet_image_source
    "${puppet_image_source}"
)
string(REPLACE
    "this->getScene ().getCamera ().getProjection ()"
    "FrescoScene::applyCamera2DControl (this->getScene (), this->getScene ().getCamera ().getProjection ())"
    puppet_image_source
    "${puppet_image_source}"
)
fresco_require_generated_patch(
    puppet_image_source
    "FrescoScene::applyCamera2DControl"
    "2D camera image projection"
)
string(REPLACE
    "#include \"CRenderable.h\""
    "#include \"WallpaperEngine/Render/Objects/CRenderable.h\""
    puppet_image_source
    "${puppet_image_source}"
)
set(passthrough_copy_before [=[    // copy pass to the composite layer
    for (const auto& cur : this->getImage ().model->material->passes) {
	this->m_passes.push_back (
	    new CPass (*this, std::make_shared<FBOProvider> (this), *cur, std::nullopt, std::nullopt, std::nullopt)
	);
    }]=])
set(passthrough_copy_after [=[    // copy pass to the composite layer unless the author requested a
    // transparent passthrough effect chain.
    if (FrescoScene::shouldCopyPassthroughBackground (
	    this->getImage ().model->passthrough,
	    this->getImage ().copyBackground
	)) {
	for (const auto& cur : this->getImage ().model->material->passes) {
	    this->m_passes.push_back (
		new CPass (*this, std::make_shared<FBOProvider> (this), *cur, std::nullopt, std::nullopt, std::nullopt)
	    );
	}
    }]=])
string(REPLACE
    "${passthrough_copy_before}"
    "${passthrough_copy_after}"
    puppet_image_source
    "${puppet_image_source}"
)
fresco_require_generated_patch(
    puppet_image_source
    "FrescoScene::shouldCopyPassthroughBackground"
    "passthrough copy-background effect-chain semantics"
)
string(REPLACE
    "    std::shared_ptr<const TextureProvider> asInput = this->getTexture ();"
    "    std::shared_ptr<const TextureProvider> asInput\n\t= FrescoScene::shouldCopyPassthroughBackground (\n\t      this->getImage ().model->passthrough,\n\t      this->getImage ().copyBackground\n\t  )\n\t? this->getTexture ()\n\t: this->m_currentSubFBO;"
    puppet_image_source
    "${puppet_image_source}"
)
fresco_require_generated_patch(
    puppet_image_source
    ": this->m_currentSubFBO;"
    "transparent passthrough effect-chain input"
)
set(puppet_resolve_return_before [=[    return resolved;
}

CImage::CImage]=])
set(puppet_resolve_return_after [=[    if (std::getenv ("FRESCO_SCENE_TRACE_IMAGE_TRANSFORM") != nullptr) {
	const auto local = localTransform (object);
	std::fprintf (
	    stderr,
	    "image-transform|%d|%d|%.6f|%.6f|%.6f|%.6f\n",
	    object.id,
	    object.parent.value_or (-1),
	    local.origin.x,
	    local.origin.y,
	    resolved.origin.x,
	    resolved.origin.y
	);
    }
    const std::string attachment = FrescoScene::puppetAttachment (&object);
    if (!attachment.empty () && object.parent.has_value ()) {
	const auto* parentObject = this->getScene ().getObject (*object.parent);
	const auto* parentImage = dynamic_cast<const CImage*> (parentObject);
	if (parentImage != nullptr && parentImage->m_puppetRuntime != nullptr) {
	    const auto anchor = parentImage->m_puppetRuntime->attachmentPosition (attachment);
	    if (anchor.has_value ()) {
		FrescoScene::recordPuppetAttachmentResolution ();
		const ResolvedTransform parentTransform = parentImage->resolveTransform (parentImage->getImage ());
		const glm::vec2 offset = rotateVec2 ({
		    anchor->x * parentTransform.scale.x,
		    -anchor->y * parentTransform.scale.y,
		}, parentTransform.angle);
		resolved.origin.x += offset.x;
		resolved.origin.y += offset.y;
		resolved.origin.z += anchor->z * parentTransform.scale.z;
	    }
	}
    }
    return resolved;
}

CImage::CImage]=])
string(REPLACE
    "${puppet_resolve_return_before}"
    "${puppet_resolve_return_after}"
    puppet_image_source
    "${puppet_image_source}"
)
fresco_require_generated_patch(
    puppet_image_source
    "attachmentPosition (attachment)"
    "puppet attachment transform propagation"
)
set(procedural_quad_visibility [=[bool CImage::isVisibleWithParents () const {
    return FrescoScene::sceneObjectVisibleWithParents (
	this->getScene (), this->getImage ()
    );
}

]=])
string(REPLACE
    "CImage::CImage (Wallpapers::CScene& scene, const Image& image) :"
    "${procedural_quad_visibility}CImage::CImage (Wallpapers::CScene& scene, const Image& image) :"
    puppet_image_source
    "${puppet_image_source}"
)
string(REPLACE
    "if (!this->getImage ().visible->value->getBool ())"
    "if (!this->isVisibleWithParents ())"
    puppet_image_source
    "${puppet_image_source}"
)
fresco_require_generated_patch(
    puppet_image_source
    "bool CImage::isVisibleWithParents () const"
    "procedural quad parent visibility implementation"
)
set(puppet_geometry_implementation [=[bool CImage::loadPuppetMesh (const glm::vec2& size) {
    if (!this->getImage ().model->puppet.has_value ()) {
	return false;
    }

    try {
	const auto stream = this->getScene ().getScene ().project.assetLocator->read (
	    *this->getImage ().model->puppet
	);
	std::vector<char> data {
	    std::istreambuf_iterator<char> (*stream), std::istreambuf_iterator<char> ()
	};
	const auto bytes = std::span<const std::byte> (
	    reinterpret_cast<const std::byte*> (data.data ()), data.size ()
	);
	this->m_puppetRuntime = std::make_unique<FrescoScene::PuppetRuntimeMesh> (bytes);
	const auto& texcoords = this->m_puppetRuntime->textureCoordinates ();
	const auto& indices = this->m_puppetRuntime->indices ();
	const auto& masks = this->m_puppetRuntime->model ().masks ();
	this->m_puppetMaskTextures.reserve (masks.size ());
	for (const auto& mask : masks) {
	    this->m_puppetMaskTextures.push_back (
		this->getScene ().getContext ().resolveTexture (mask.texture)
	    );
	}
	if (!masks.empty ()) {
#if FRESCO_SCENE_GLES
	    constexpr const char* vertexSource = R"(#version 300 es
		precision highp float;
		in vec3 a_Position;
		in vec2 a_TexCoord;
		uniform vec2 g_Size;
		uniform mat4 g_Transform;
		uniform int g_UseTransform;
		out vec2 v_TexCoord;
		void main() {
		    if (g_UseTransform != 0) {
			gl_Position = g_Transform * vec4(a_Position, 1.0);
		    } else {
			vec2 clip = a_Position.xy / g_Size * 2.0 - 1.0;
			gl_Position = vec4(clip, a_Position.z, 1.0);
		    }
		    v_TexCoord = a_TexCoord;
		})";
	    constexpr const char* fragmentSource = R"(#version 300 es
		precision highp float;
		in vec2 v_TexCoord;
		uniform sampler2D g_Texture0;
		uniform sampler2D g_Texture1;
		out vec4 fragColor;
		void main() {
		    float albedo = texture(g_Texture0, v_TexCoord).a;
		    float mask = texture(g_Texture1, v_TexCoord).r;
		    float coverage = mask * mix(pow(albedo, 4.0), albedo, mask);
		    if (coverage <= (1.0 / 255.0)) discard;
		    fragColor = vec4(coverage);
		})";
#else
	    constexpr const char* vertexSource = R"(#version 330 core
		in vec3 a_Position;
		in vec2 a_TexCoord;
		uniform vec2 g_Size;
		uniform mat4 g_Transform;
		uniform int g_UseTransform;
		out vec2 v_TexCoord;
		void main() {
		    if (g_UseTransform != 0) {
			gl_Position = g_Transform * vec4(a_Position, 1.0);
		    } else {
			vec2 clip = a_Position.xy / g_Size * 2.0 - 1.0;
			gl_Position = vec4(clip, a_Position.z, 1.0);
		    }
		    v_TexCoord = a_TexCoord;
		})";
	    constexpr const char* fragmentSource = R"(#version 330 core
		in vec2 v_TexCoord;
		uniform sampler2D g_Texture0;
		uniform sampler2D g_Texture1;
		out vec4 fragColor;
		void main() {
		    float albedo = texture(g_Texture0, v_TexCoord).a;
		    float mask = texture(g_Texture1, v_TexCoord).r;
		    float coverage = mask * mix(pow(albedo, 4.0), albedo, mask);
		    if (coverage <= (1.0 / 255.0)) discard;
		    fragColor = vec4(coverage);
		})";
#endif
	    const auto compile = [] (GLenum type, const char* source) {
		const GLuint shader = glCreateShader (type);
		glShaderSource (shader, 1, &source, nullptr);
		glCompileShader (shader);
		GLint compiled = GL_FALSE;
		glGetShaderiv (shader, GL_COMPILE_STATUS, &compiled);
		if (compiled != GL_TRUE) {
		    glDeleteShader (shader);
		    throw std::runtime_error ("puppet mask shader compilation failed");
		}
		return shader;
	    };
	    const GLuint vertex = compile (GL_VERTEX_SHADER, vertexSource);
	    GLuint fragment = GL_NONE;
	    try {
		fragment = compile (GL_FRAGMENT_SHADER, fragmentSource);
	    } catch (...) {
		glDeleteShader (vertex);
		throw;
	    }
	    this->m_puppetMaskProgram = glCreateProgram ();
	    glAttachShader (this->m_puppetMaskProgram, vertex);
	    glAttachShader (this->m_puppetMaskProgram, fragment);
	    glLinkProgram (this->m_puppetMaskProgram);
	    glDeleteShader (vertex);
	    glDeleteShader (fragment);
	    GLint linked = GL_FALSE;
	    glGetProgramiv (this->m_puppetMaskProgram, GL_LINK_STATUS, &linked);
	    if (linked != GL_TRUE) {
		glDeleteProgram (this->m_puppetMaskProgram);
		this->m_puppetMaskProgram = GL_NONE;
		throw std::runtime_error ("puppet mask shader link failed");
	    }
	    this->m_puppetMaskPosition = glGetAttribLocation (this->m_puppetMaskProgram, "a_Position");
	    this->m_puppetMaskTexCoord = glGetAttribLocation (this->m_puppetMaskProgram, "a_TexCoord");
	    this->m_puppetMaskTransform = glGetUniformLocation (this->m_puppetMaskProgram, "g_Transform");
	    this->m_puppetMaskSize = glGetUniformLocation (this->m_puppetMaskProgram, "g_Size");
	    this->m_puppetMaskUseTransform = glGetUniformLocation (this->m_puppetMaskProgram, "g_UseTransform");
	}

	this->updatePuppetPositionBuffer (size);
	glGenBuffers (1, &this->m_puppetTexCoord);
	glBindBuffer (GL_ARRAY_BUFFER, this->m_puppetTexCoord);
	glBufferData (
	    GL_ARRAY_BUFFER, texcoords.size () * sizeof (float), texcoords.data (), GL_STATIC_DRAW
	);
	glGenBuffers (1, &this->m_puppetIndices);
	glBindBuffer (GL_ELEMENT_ARRAY_BUFFER, this->m_puppetIndices);
	glBufferData (
	    GL_ELEMENT_ARRAY_BUFFER, indices.size () * sizeof (uint16_t), indices.data (), GL_STATIC_DRAW
	);
	if (this->m_puppetMaskProgram != GL_NONE) {
	    GLint previousVAO = 0;
	    GLint previousArrayBuffer = 0;
	    glGetIntegerv (GL_VERTEX_ARRAY_BINDING, &previousVAO);
	    glGetIntegerv (GL_ARRAY_BUFFER_BINDING, &previousArrayBuffer);
	    glGenVertexArrays (1, &this->m_puppetMaskVAO);
	    glBindVertexArray (this->m_puppetMaskVAO);
	    glEnableVertexAttribArray (this->m_puppetMaskPosition);
	    glBindBuffer (GL_ARRAY_BUFFER, this->m_puppetSpacePosition);
	    glVertexAttribPointer (this->m_puppetMaskPosition, 3, GL_FLOAT, GL_FALSE, 0, nullptr);
	    glEnableVertexAttribArray (this->m_puppetMaskTexCoord);
	    glBindBuffer (GL_ARRAY_BUFFER, this->m_puppetTexCoord);
	    glVertexAttribPointer (this->m_puppetMaskTexCoord, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
	    glBindBuffer (GL_ELEMENT_ARRAY_BUFFER, this->m_puppetIndices);
	    glBindVertexArray (static_cast<GLuint> (previousVAO));
	    glBindBuffer (GL_ARRAY_BUFFER, static_cast<GLuint> (previousArrayBuffer));
	}
	this->m_puppetIndexCount = static_cast<GLsizei> (indices.size ());

	const auto& model = this->m_puppetRuntime->model ();
	FrescoScene::recordPuppetMeshLoaded (
	    model.vertices ().size (),
	    model.masks ().size (),
	    model.attachments ().size (),
	    model.simulationEnabledBoneCount (),
	    model.activeIKBoneCount ()
	);
	if (model.attachmentCount () > 0) {
	    sLog.out ("Loaded puppet attachment metadata in ", *this->getImage ().model->puppet);
	}
	if (model.activeIKBoneCount () > 0) {
	    sLog.error (
		"Puppet active IK remains deferred in ", *this->getImage ().model->puppet,
		" bones=", model.activeIKBoneCount ()
	    );
	}
	if (model.simulationEnabledBoneCount () > 0) {
	    if (this->m_puppetRuntime->secondaryMotionSupported ()) {
		sLog.out (
		    "Loaded bounded puppet secondary motion in ",
		    *this->getImage ().model->puppet,
		    " bones=", model.simulationEnabledBoneCount ()
		);
	    } else {
		sLog.error (
		    "Could not enable puppet secondary motion in ",
		    *this->getImage ().model->puppet,
		    ": ", this->m_puppetRuntime->secondaryMotionDiagnostic ()
		);
	    }
	}
	if (model.hasExtendedBindMetadata ()) {
	    sLog.out (
		"Puppet MDLE element metadata retained with mesh-authoritative geometry in ",
		*this->getImage ().model->puppet,
		" inverse-bind difference=", model.extendedBindMaxDifference ()
	    );
	}
	sLog.out (
	    "Loaded animated puppet ", *this->getImage ().model->puppet,
	    " vertices=", model.vertices ().size (),
	    " parts=", model.parts ().size (),
	    " animations=", model.animations ().size ()
	);
	return true;
    } catch (const std::exception& ex) {
	sLog.error ("Could not load puppet ", *this->getImage ().model->puppet, ": ", ex.what ());
	this->m_puppetRuntime.reset ();
	return false;
    }
}

void CImage::updatePuppetPositionBuffer (const glm::vec2& size) {
    if (this->m_puppetRuntime == nullptr) {
	return;
    }
    const auto positions = this->m_puppetRuntime->positions (size.x, size.y);
    FrescoScene::recordPuppetDeformation (this, positions);
    if (this->m_puppetSpacePosition == GL_NONE) {
	glGenBuffers (1, &this->m_puppetSpacePosition);
    }
    glBindBuffer (GL_ARRAY_BUFFER, this->m_puppetSpacePosition);
    glBufferData (
	GL_ARRAY_BUFFER, positions.size () * sizeof (float), positions.data (), GL_DYNAMIC_DRAW
    );

    // positions() is layer-local, centred on the layer's own size, which is what
    // a first pass rendering into an FBO wants. A pass that draws straight to
    // the scene is projected with m_modelViewProjectionScreen and expects the
    // vertices to carry the origin already, exactly as m_pos does for the
    // non-puppet quad. Mapping the local box onto m_pos gives the same vertices
    // in that space; without it every puppet layer drew at its mesh
    // coordinates, so all of them landed on top of each other.
    std::vector<float> scenePositions = positions;
    const float spanX = this->m_pos.z - this->m_pos.x;
    const float spanY = this->m_pos.w - this->m_pos.y;
    if (size.x > 0.0f && size.y > 0.0f && spanX != 0.0f && spanY != 0.0f) {
	for (std::size_t index = 0; index + 2 < scenePositions.size (); index += 3) {
	    scenePositions[index] = this->m_pos.x + scenePositions[index] / size.x * spanX;
	    scenePositions[index + 1] = this->m_pos.w - scenePositions[index + 1] / size.y * spanY;
	}
    }
    if (this->m_puppetScenePosition == GL_NONE) {
	glGenBuffers (1, &this->m_puppetScenePosition);
    }
    glBindBuffer (GL_ARRAY_BUFFER, this->m_puppetScenePosition);
    glBufferData (
	GL_ARRAY_BUFFER, scenePositions.size () * sizeof (float), scenePositions.data (),
	GL_DYNAMIC_DRAW
    );
}

]=])
fresco_replace_section(
    puppet_image_source
    "bool CImage::loadPuppetMesh (const glm::vec2& size) {"
    "void CImage::setupPuppetGeometryCallback (Effects::CPass* pass) const {"
    "${puppet_geometry_implementation}"
    "puppet geometry implementation"
)
set(puppet_callback_implementation [=[void CImage::setupPuppetGeometryCallback (Effects::CPass* pass) const {
    pass->setGeometryCallback (
	[this, pass] () {
	    const GLint position = glGetAttribLocation (pass->getProgramID (), "a_Position");
	    const GLint texCoord = glGetAttribLocation (pass->getProgramID (), "a_TexCoord");

	    if (position >= 0) {
		glEnableVertexAttribArray (position);
		glBindBuffer (GL_ARRAY_BUFFER, this->m_puppetActivePosition);
		glVertexAttribPointer (position, 3, GL_FLOAT, GL_FALSE, 0, nullptr);
	    }
	    if (texCoord >= 0) {
		glEnableVertexAttribArray (texCoord);
		glBindBuffer (GL_ARRAY_BUFFER, this->m_puppetTexCoord);
		glVertexAttribPointer (texCoord, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
	    }
	},
	[this] () {
	    const bool sceneSpacePuppet = this->m_puppetActivePosition == this->m_puppetScenePosition;
	    GLint currentFramebuffer = 0;
	    glGetIntegerv (GL_DRAW_FRAMEBUFFER_BINDING, &currentFramebuffer);
	    if (currentFramebuffer != static_cast<GLint> (this->getScene ().getFBO ()->getFramebuffer ())) {
		GLfloat previousClearColor[4] = {};
		glGetFloatv (GL_COLOR_CLEAR_VALUE, previousClearColor);
		glClearColor (0.0f, 0.0f, 0.0f, 0.0f);
		glClear (GL_COLOR_BUFFER_BIT);
		glClearColor (
		    previousClearColor[0], previousClearColor[1], previousClearColor[2], previousClearColor[3]
		);
	    }
	    glBindBuffer (GL_ELEMENT_ARRAY_BUFFER, this->m_puppetIndices);
	    const auto& model = this->m_puppetRuntime->model ();
	    const auto& parts = model.parts ();
	    const auto& masks = model.masks ();
	    if (masks.empty () || parts.empty () || this->m_puppetMaskProgram == GL_NONE) {
		glDrawElements (GL_TRIANGLES, this->m_puppetIndexCount, GL_UNSIGNED_SHORT, nullptr);
		return;
	    }

	    bool stencilReady = false;
	    FrescoScene::OpenGLStencilStateAPI stencilAPI;
	    std::optional<FrescoScene::ScopedStencilState> stencilState;
	    if (currentFramebuffer != 0) {
		auto& stencil = const_cast<CImage*> (this)->m_puppetStencilBuffers[
		    static_cast<GLuint> (currentFramebuffer)
		];
		if (stencil == GL_NONE) {
		    glGenRenderbuffers (1, &stencil);
		}
		try {
			stencilState.emplace (
			    stencilAPI, stencil,
			    std::max (1, static_cast<int> (this->m_size.x)),
			    std::max (1, static_cast<int> (this->m_size.y))
			);
			stencilReady = true;
		} catch (const std::exception& error) {
			std::fprintf (
			    stderr, "puppet mask fallback: %s\n", error.what ()
			);
		}
	    }

	    const auto drawPart = [&parts] (size_t ordinal) {
		const auto& part = parts[ordinal];
		glDrawElements (
		    GL_TRIANGLES, static_cast<GLsizei> (part.indexCount), GL_UNSIGNED_SHORT,
		    reinterpret_cast<const void*> (
			static_cast<uintptr_t> (part.firstIndex * sizeof (uint16_t))
		    )
		);
	    };
	    for (size_t ordinal = 0; ordinal < parts.size (); ++ordinal) {
		const auto mask = std::find_if (masks.begin (), masks.end (),
		    [ordinal] (const auto& candidate) {
			return std::find (
			    candidate.targetPartOrdinals.begin (), candidate.targetPartOrdinals.end (), ordinal
			) != candidate.targetPartOrdinals.end ();
		    });
		if (mask == masks.end () || !stencilReady) {
		    drawPart (ordinal);
		    continue;
		}

	const size_t maskIndex = static_cast<size_t> (std::distance (masks.begin (), mask));
	FrescoScene::recordPuppetMaskPass ();
		stencilState->beginMaskWrite ();

		GLint previousProgram = 0;
		GLint previousActiveTexture = 0;
		GLint previousTexture0 = 0;
		GLint previousTexture1 = 0;
		GLint previousVAO = 0;
		GLint previousArrayBuffer = 0;
		glGetIntegerv (GL_CURRENT_PROGRAM, &previousProgram);
		glGetIntegerv (GL_ACTIVE_TEXTURE, &previousActiveTexture);
		glGetIntegerv (GL_VERTEX_ARRAY_BINDING, &previousVAO);
		glGetIntegerv (GL_ARRAY_BUFFER_BINDING, &previousArrayBuffer);
		glActiveTexture (GL_TEXTURE0);
		glGetIntegerv (GL_TEXTURE_BINDING_2D, &previousTexture0);
		glActiveTexture (GL_TEXTURE1);
		glGetIntegerv (GL_TEXTURE_BINDING_2D, &previousTexture1);
		glUseProgram (this->m_puppetMaskProgram);
		// The stencil has to land where the geometry lands, so the mask
		// takes the same transform the draw is using. Scene-space vertices
		// carry the origin and want the screen projection; layer-local ones
		// want the [0..size] to clip mapping this shader used to hardcode.
		// The local path keeps the arithmetic it always had, so a layer
		// that is not in scene space renders bit-identically; a matrix
		// doing the same mapping is only equal to within rounding, and
		// that is enough to move an exact-reference hash.
		glUniform2f (this->m_puppetMaskSize, this->m_size.x, this->m_size.y);
		glUniform1i (this->m_puppetMaskUseTransform, sceneSpacePuppet ? 1 : 0);
		const glm::mat4 maskTransform = this->m_modelViewProjectionScreen;
		glUniformMatrix4fv (
		    this->m_puppetMaskTransform, 1, GL_FALSE, &maskTransform[0][0]
		);
		glUniform1i (glGetUniformLocation (this->m_puppetMaskProgram, "g_Texture0"), 0);
		glUniform1i (glGetUniformLocation (this->m_puppetMaskProgram, "g_Texture1"), 1);
		glActiveTexture (GL_TEXTURE0);
		glBindTexture (GL_TEXTURE_2D, this->m_texture->getTextureID (0));
		glActiveTexture (GL_TEXTURE1);
		glBindTexture (GL_TEXTURE_2D, this->m_puppetMaskTextures[maskIndex]->getTextureID (0));
		glBindVertexArray (this->m_puppetMaskVAO);
		glBindBuffer (GL_ARRAY_BUFFER, this->m_puppetActivePosition);
		glVertexAttribPointer (
		    this->m_puppetMaskPosition, 3, GL_FLOAT, GL_FALSE, 0, nullptr
		);
		for (const uint32_t sourceOrdinal : mask->maskPartOrdinals) drawPart (sourceOrdinal);

		glActiveTexture (GL_TEXTURE0);
		glBindTexture (GL_TEXTURE_2D, static_cast<GLuint> (previousTexture0));
		glActiveTexture (GL_TEXTURE1);
		glBindTexture (GL_TEXTURE_2D, static_cast<GLuint> (previousTexture1));
		glActiveTexture (static_cast<GLenum> (previousActiveTexture));
		glUseProgram (static_cast<GLuint> (previousProgram));
		glBindVertexArray (static_cast<GLuint> (previousVAO));
		glBindBuffer (GL_ARRAY_BUFFER, static_cast<GLuint> (previousArrayBuffer));
		stencilState->beginMaskedDraw ();
		drawPart (ordinal);
		stencilState->restorePipelineState ();
	    }
	},
	[pass] () {
	    const GLint position = glGetAttribLocation (pass->getProgramID (), "a_Position");
	    const GLint texCoord = glGetAttribLocation (pass->getProgramID (), "a_TexCoord");
	    if (position >= 0) glDisableVertexAttribArray (position);
	    if (texCoord >= 0) glDisableVertexAttribArray (texCoord);
	}
    );
}

]=])
fresco_replace_section(
    puppet_image_source
    "void CImage::setupPuppetGeometryCallback (Effects::CPass* pass) const {"
    "void CImage::setup () {"
    "${puppet_callback_implementation}"
    "puppet masked geometry callback"
)
# A layer with no effects has one pass that is both first and final: it is
# projected with m_modelViewProjectionScreen, so its vertices must carry the
# origin. Upstream installed the geometry callback before that branch runs and
# always bound the layer-local buffer, so every such puppet layer drew at its
# mesh coordinates instead of its authored origin and they all piled up
# together. Deciding the buffer first and installing the callback after is the
# whole fix; a first pass that renders into an FBO still gets the local box.
string(REPLACE
    "	    spacePosition = this->getSceneSpacePosition ();
	    drawTo = this->getScene ().getFBO ();"
    "	    spacePosition = (isFirstPass && this->m_hasPuppetMesh)
		? this->m_puppetScenePosition
		: this->getSceneSpacePosition ();
	    drawTo = this->getScene ().getFBO ();"
    puppet_image_source
    "${puppet_image_source}"
)
string(REPLACE
    "	pass->setDestination (drawTo);"
    "	if (isFirstPass && this->m_hasPuppetMesh) {
	    this->m_puppetActivePosition = spacePosition;
	}

	pass->setDestination (drawTo);"
    puppet_image_source
    "${puppet_image_source}"
)
# Literal FIND rather than the count helper, which matches its marker as a
# regex and would read these parentheses as groups.
fresco_require_generated_patch(
    puppet_image_source
    "? this->m_puppetScenePosition"
    "scene-space puppet vertices on the final pass"
)
fresco_require_generated_patch(
    puppet_image_source
    "m_puppetActivePosition = spacePosition"
    "puppet active buffer recorded from the pass selection"
)

set(puppet_delete_before [=[    if (this->m_puppetIndices != GL_NONE) {
	glDeleteBuffers (1, &this->m_puppetIndices);
    }
}]=])
set(puppet_delete_after [=[    if (this->m_puppetIndices != GL_NONE) {
	glDeleteBuffers (1, &this->m_puppetIndices);
    }
    if (this->m_puppetScenePosition != GL_NONE) {
	glDeleteBuffers (1, &this->m_puppetScenePosition);
    }
    if (this->m_puppetMaskProgram != GL_NONE) {
	glDeleteProgram (this->m_puppetMaskProgram);
    }
    if (this->m_puppetMaskVAO != GL_NONE) {
	glDeleteVertexArrays (1, &this->m_puppetMaskVAO);
    }
    for (const auto& [framebuffer, stencil] : this->m_puppetStencilBuffers) {
	static_cast<void> (framebuffer);
	glDeleteRenderbuffers (1, &stencil);
    }
}]=])
string(REPLACE
    "${puppet_delete_before}"
    "${puppet_delete_after}"
    puppet_image_source
    "${puppet_image_source}"
)
fresco_require_generated_patch(
    puppet_image_source
    "m_puppetStencilBuffers"
    "puppet mask resource cleanup"
)
set(puppet_render_update [=[    if (this->m_puppetRuntime != nullptr) {
	std::vector<FrescoScene::PuppetLayerInput> layers;
	layers.reserve (this->getImage ().animationLayers.size ());
	for (const auto& layer : this->getImage ().animationLayers) {
	    layers.push_back ({
		.layerID = layer->id,
		.animationID = layer->animation->value->getInt (),
		.rate = layer->rate->value->getFloat (),
		.blend = layer->blend->value->getFloat (),
		.visible = layer->visible->value->getBool (),
		.additive = FrescoScene::puppetLayerIsAdditive (layer.get ()),
	    });
	}
	this->m_puppetRuntime->configureLayers (layers);
	const auto transform = this->resolveTransform (this->getImage ());
	const auto secondaryMotion = this->m_puppetRuntime->advance (
	    this->getScene ().getTime (), {
		.translationX = transform.origin.x,
		.translationY = transform.origin.y,
		.rotationZ = transform.angle,
		.scaleX = transform.scale.x,
		.scaleY = transform.scale.y,
	    }
	);
	FrescoScene::recordPuppetSecondaryMotionSteps (
	    secondaryMotion.steps, secondaryMotion.changes
	);
	this->updatePuppetPositionBuffer (this->m_size);
    }

]=])
string(REPLACE
    "    // Always update screen transform (handles rotation + parallax dynamically)\n    this->updateScreenSpacePosition ();\n"
    "    // Always update screen transform (handles rotation + parallax dynamically)\n    this->updateScreenSpacePosition ();\n\n${puppet_render_update}"
    puppet_image_source
    "${puppet_image_source}"
)
fresco_require_generated_patch(
    puppet_image_source
    "configureLayers (layers)"
    "per-frame puppet animation inputs"
)
set(puppet_final_pass_before [=[    if (!isLastPass || !this->getImage ().visible->value->getBool ()) {
	return false;
    }
]=])
set(puppet_final_pass_after [=[    // Pass wiring is structural and decided once, in setupPasses, while visible
    // is a dynamic property. Reading it here latched any layer that was hidden
    // at construction into drawing to its own ping-pong FBO for the lifetime of
    // the scene, so it stayed invisible after its script turned it on. Nothing
    // draws while hidden regardless: CImage::render skips the whole pass list.
    if (!isLastPass) {
	return false;
    }
]=])
string(REPLACE
    "${puppet_final_pass_before}"
    "${puppet_final_pass_after}"
    puppet_image_source
    "${puppet_image_source}"
)
fresco_require_generated_patch(
    puppet_image_source
    "Pass wiring is structural and decided once"
    "dynamic visibility final-pass wiring"
)
set(passthrough_size_before [=[glm::vec2 CImage::getSize () const {
    if (this->m_texture == nullptr) {
	return this->getImage ().size;
    }

    return { this->m_texture->getRealWidth (), this->m_texture->getRealHeight () };
}]=])
set(passthrough_size_after [=[glm::vec2 CImage::getSize () const {
    const glm::vec2 authoredSize = this->getImage ().size;
    if (
	this->getImage ().model->passthrough
	&& authoredSize.x != 0.0f
	&& authoredSize.y != 0.0f
    ) {
	return authoredSize;
    }
    if (this->m_texture == nullptr) {
	return authoredSize;
    }

    return { this->m_texture->getRealWidth (), this->m_texture->getRealHeight () };
}]=])
string(REPLACE
    "${passthrough_size_before}"
    "${passthrough_size_after}"
    puppet_image_source
    "${puppet_image_source}"
)
fresco_require_generated_patch(
    puppet_image_source
    "const glm::vec2 authoredSize = this->getImage ().size"
    "passthrough composition authored size"
)
# m_pos is kept in centred, y-down scene space; cursor events arrive absolute and
# bottom-up, so invert the two lines updateScenePosition ends with.
set(scene_box_anchor
    "GLuint CImage::getSceneSpacePosition () const { return this->m_sceneSpacePosition; }"
)
set(scene_box_after [=[glm::vec4 CImage::frescoSceneBox () const {
    const auto halfWidth = static_cast<float> (this->getScene ().getWidth ()) / 2.0f;
    const auto halfHeight = static_cast<float> (this->getScene ().getHeight ()) / 2.0f;
    return {
	this->m_pos.x + halfWidth,
	halfHeight - this->m_pos.y,
	this->m_pos.z + halfWidth,
	halfHeight - this->m_pos.w,
    };
}

GLuint CImage::getSceneSpacePosition () const { return this->m_sceneSpacePosition; }]=])
string(REPLACE
    "${scene_box_anchor}"
    "${scene_box_after}"
    puppet_image_source
    "${puppet_image_source}"
)
fresco_require_generated_patch(
    puppet_image_source
    "glm::vec4 CImage::frescoSceneBox () const"
    "scene-space layer box"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/CImage.cpp"
    puppet_image_source
)
