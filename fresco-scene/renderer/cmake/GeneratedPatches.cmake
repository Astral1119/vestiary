
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(READ
    "${upstream}/src/WallpaperEngine/Render/Shaders/GLSLContext.cpp"
    glsl_context_source
)
string(REPLACE
    "#include \"GLSLContext.h\""
    "#include \"GLSLContext.h\"\n#include \"FrescoScene/ShaderTranslationCache.h\""
    glsl_context_source
    "${glsl_context_source}"
)
string(REPLACE
    "options.version = 330;\n    options.es = false;"
    "options.version = ${FRESCO_SCENE_SHADER_VERSION};\n    options.es = ${FRESCO_SCENE_SHADER_ES};\n    options.enable_420pack_extension = false;"
    glsl_context_source
    "${glsl_context_source}"
)
string(REPLACE
    "GLSLContext::~GLSLContext () { glslang::FinalizeProcess (); }"
    "GLSLContext::~GLSLContext () { FrescoScene::clearShaderTranslationCache (); }"
    glsl_context_source
    "${glsl_context_source}"
)
string(REPLACE
    "std::pair<std::string, std::string> GLSLContext::toGlsl (const std::string& vertex, const std::string& fragment) {"
    "static std::pair<std::string, std::string> toGlslUncached (const std::string& vertex, const std::string& fragment) {"
    glsl_context_source
    "${glsl_context_source}"
)
string(REPLACE
    "std::unique_ptr<GLSLContext> GLSLContext::sInstance = nullptr;"
    "std::pair<std::string, std::string> GLSLContext::toGlsl (const std::string& vertex, const std::string& fragment) {\n    return FrescoScene::shaderTranslationCache ().resolve (\n        \"${FRESCO_SCENE_BACKEND_ID}|glslang-opengl-330|opengl-450|spirv-1.5|glsl-${FRESCO_SCENE_SHADER_VERSION}-es-${FRESCO_SCENE_SHADER_ES}\",\n        \"vertex\", vertex, \"fragment\", fragment,\n        [&vertex, &fragment] { return toGlslUncached (vertex, fragment); }\n    );\n}\n\nstd::unique_ptr<GLSLContext> GLSLContext::sInstance = nullptr;"
    glsl_context_source
    "${glsl_context_source}"
)
fresco_require_generated_patch(
    glsl_context_source
    "options.version = ${FRESCO_SCENE_SHADER_VERSION};"
    "configured GLSL version"
)
fresco_require_generated_patch(
    glsl_context_source
    "options.es = ${FRESCO_SCENE_SHADER_ES};"
    "configured GLSL profile"
)
fresco_require_generated_patch(
    glsl_context_source
    "options.enable_420pack_extension = false;"
    "GLSL 4.2-pack disable"
)
fresco_require_generated_patch(
    glsl_context_source
    "clearShaderTranslationCache"
    "glslang process lifetime"
)
fresco_require_generated_patch(
    glsl_context_source
    "shaderTranslationCache ().resolve"
    "shader translation result cache"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/GLSLContext.cpp"
    glsl_context_source
)
file(READ
    "${upstream}/src/WallpaperEngine/Render/Shaders/ShaderUnit.cpp"
    shader_unit_source
)
file(READ
    "${upstream}/src/WallpaperEngine/Render/Shaders/ShaderUnit.h"
    shader_unit_header
)
string(REPLACE
    "#include <memory>"
    "#include <memory>\n#include \"FrescoScene/RenderAllocationEvidence.h\""
    shader_unit_header
    "${shader_unit_header}"
)
string(REPLACE
    "    std::vector<Variables::ShaderVariable*> m_parameters = {};"
    "    std::vector<Variables::ShaderVariable*> m_parameters = {};\n    std::vector<FrescoScene::TrackedRenderUniquePtr<Variables::ShaderVariable>> m_ownedParameters = {};"
    shader_unit_header
    "${shader_unit_header}"
)
fresco_require_generated_patch_count(
    shader_unit_header "m_ownedParameters" 1 "owned shader parameters"
)
file(MAKE_DIRECTORY
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render/Shaders"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render/Shaders/ShaderUnit.h"
    shader_unit_header
)
file(READ
    "${upstream}/src/WallpaperEngine/Render/Shaders/Shader.h"
    shader_header
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render/Shaders/Shader.h"
    shader_header
)
file(READ
    "${upstream}/src/WallpaperEngine/Render/Shaders/Shader.cpp"
    shader_source
)
string(REPLACE
    "#include \"Shader.h\""
    "#include \"WallpaperEngine/Render/Shaders/Shader.h\""
    shader_source
    "${shader_source}"
)
fresco_require_generated_patch_count(
    shader_source
    "#include <WallpaperEngine/Render/Shaders/Shader.h>"
    1
    "generated shader ownership header include"
)
string(REPLACE
    "#include \"GLSLContext.h\""
    "#include \"WallpaperEngine/Render/Shaders/GLSLContext.h\""
    shader_source
    "${shader_source}"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/Shader.cpp"
    shader_source
)
string(REPLACE
    "#include <stack>"
    "#include <stack>\n#include \"FrescoScene/RenderAllocationEvidence.h\"\n#include <mutex>\n#include <tuple>"
    shader_unit_source
    "${shader_unit_source}"
)
string(REPLACE
    "#include \"ShaderUnit.h\""
    "#include \"WallpaperEngine/Render/Shaders/ShaderUnit.h\""
    shader_unit_source
    "${shader_unit_source}"
)
string(REPLACE
    "#include \"GLSLContext.h\""
    "#include \"WallpaperEngine/Render/Shaders/GLSLContext.h\""
    shader_unit_source
    "${shader_unit_source}"
)
fresco_require_generated_patch_count(
    shader_unit_source
    "#include \"WallpaperEngine/Render/Shaders/ShaderUnit.h\""
    1
    "generated shader-unit header include"
)
string(REPLACE
    "    this->m_preprocessed = this->m_content;\n    this->m_includes = \"\";"
    "    this->m_preprocessed = this->m_content;\n    for (std::size_t position = 0; (position = this->m_preprocessed.find ('\\r', position)) != std::string::npos;) {\n\tthis->m_preprocessed.erase (position, 1);\n    }\n    const std::string malformedAudioBars = \"#if DEFORMITY == 2\\n\\tfloat yFactor = g_Texture0Resolution.y / g_Texture0Resolution.x;\\n\\tv_TexCoord.y *= yFactor;\\n\\tv_TexCoord.y += 0.5 - (0.5 * yFactor);\\n#endif\\n\\n#endif\\n\\n#if TRANSFORM\";\n    const std::string correctedAudioBars = \"#if DEFORMITY == 2\\n\\tfloat yFactor = g_Texture0Resolution.y / g_Texture0Resolution.x;\\n\\tv_TexCoord.y *= yFactor;\\n\\tv_TexCoord.y += 0.5 - (0.5 * yFactor);\\n#endif\\n\\n#if TRANSFORM\";\n    if (const std::size_t position = this->m_preprocessed.find (malformedAudioBars); position != std::string::npos) {\n\tthis->m_preprocessed.replace (position, malformedAudioBars.size (), correctedAudioBars);\n    }\n    this->m_includes = \"\";"
    shader_unit_source
    "${shader_unit_source}"
)
string(REPLACE
    "new Variables::ShaderVariableVector4 (VectorBuilder::parse<glm::vec4> (defvalue->get<std::string> ()))"
    "new Variables::ShaderVariableVector4 (defvalue.has_value () ? VectorBuilder::parse<glm::vec4> (defvalue->get<std::string> ()) : glm::vec4 (0.0f))"
    shader_unit_source
    "${shader_unit_source}"
)
string(REPLACE
    "new Variables::ShaderVariableVector3 (VectorBuilder::parse<glm::vec3> (*defvalue))"
    "new Variables::ShaderVariableVector3 (defvalue.has_value () ? VectorBuilder::parse<glm::vec3> (*defvalue) : glm::vec3 (0.0f))"
    shader_unit_source
    "${shader_unit_source}"
)
string(REPLACE
    "new Variables::ShaderVariableVector2 (VectorBuilder::parse<glm::vec2> (*defvalue))"
    "new Variables::ShaderVariableVector2 (defvalue.has_value () ? VectorBuilder::parse<glm::vec2> (*defvalue) : glm::vec2 (0.0f))"
    shader_unit_source
    "${shader_unit_source}"
)
string(REPLACE
    "if (defvalue->is_string ()) {\n\t    parameter = new Variables::ShaderVariableFloat (std::stoi (defvalue->get<std::string> ()));\n\t} else {\n\t    parameter = new Variables::ShaderVariableFloat (defvalue->get<float> ());\n\t}"
    "if (!defvalue.has_value ()) {\n\t    parameter = new Variables::ShaderVariableFloat (0.0f);\n\t} else if (defvalue->is_string ()) {\n\t    parameter = new Variables::ShaderVariableFloat (std::stof (defvalue->get<std::string> ()));\n\t} else {\n\t    parameter = new Variables::ShaderVariableFloat (defvalue->get<float> ());\n\t}"
    shader_unit_source
    "${shader_unit_source}"
)
string(REPLACE
    "if (defvalue->is_string ()) {\n\t    parameter = new Variables::ShaderVariableInteger (std::stoi (defvalue->get<std::string> ()));\n\t} else {\n\t    parameter = new Variables::ShaderVariableInteger (defvalue->get<int> ());\n\t}"
    "if (!defvalue.has_value ()) {\n\t    parameter = new Variables::ShaderVariableInteger (0);\n\t} else if (defvalue->is_string ()) {\n\t    parameter = new Variables::ShaderVariableInteger (std::stoi (defvalue->get<std::string> ()));\n\t} else {\n\t    parameter = new Variables::ShaderVariableInteger (defvalue->get<int> ());\n\t}"
    shader_unit_source
    "${shader_unit_source}"
)
fresco_require_generated_patch(
    shader_unit_source
    "const std::string malformedAudioBars"
    "GBC Subaru audio-bars orphan preprocessor terminator"
)
fresco_require_generated_patch(
    shader_unit_source
    "defvalue.has_value () ? VectorBuilder::parse<glm::vec4>"
    "missing vec4 shader default"
)
fresco_require_generated_patch(
    shader_unit_source
    "defvalue.has_value () ? VectorBuilder::parse<glm::vec3>"
    "missing vec3 shader default"
)
fresco_require_generated_patch(
    shader_unit_source
    "defvalue.has_value () ? VectorBuilder::parse<glm::vec2>"
    "missing vec2 shader default"
)
fresco_require_generated_patch(
    shader_unit_source
    "new Variables::ShaderVariableFloat (std::stof"
    "floating-point string shader default"
)
fresco_require_generated_patch(
    shader_unit_source
    "new Variables::ShaderVariableInteger (0);"
    "missing integer shader default"
)
string(REPLACE
    "    Variables::ShaderVariable* parameter = nullptr;"
    "    FrescoScene::TrackedRenderUniquePtr<Variables::ShaderVariable> parameter;"
    shader_unit_source
    "${shader_unit_source}"
)
foreach(shader_variable_type IN ITEMS
    ShaderVariableVector4
    ShaderVariableVector3
    ShaderVariableVector2
    ShaderVariableFloat
    ShaderVariableInteger)
    string(REPLACE
        "new Variables::${shader_variable_type} ("
        "FrescoScene::makeTrackedRenderUnique<Variables::${shader_variable_type}> (FrescoScene::RenderAllocationKind::shaderVariable, "
        shader_unit_source
        "${shader_unit_source}"
    )
endforeach()
string(REPLACE
    "\tthis->m_parameters.push_back (parameter);"
    "\tthis->m_parameters.push_back (parameter.get ());\n\tthis->m_ownedParameters.emplace_back (std::move (parameter));"
    shader_unit_source
    "${shader_unit_source}"
)
fresco_require_generated_patch_count(
    shader_unit_source
    "m_ownedParameters.emplace_back"
    1
    "shader parameter ownership transfer"
)
fresco_require_generated_patch_count(
    shader_unit_source
    "RenderAllocationKind::shaderVariable"
    9
    "shader variable tracked allocations"
)
string(REPLACE
    "    this->m_final\n\t+= this->applyFragmentTexCoordCompatibility (this->applyLinkedVaryingCompatibility (this->m_preprocessed));"
    "    // Compatibility transforms depend only on the unit kind and the exact\n    // preprocessed peer sources, never on GL context or pass-local state.\n    using CompatibilityCacheKey = std::tuple<int, std::string, std::string>;\n    static std::map<CompatibilityCacheKey, std::string> compatibilityCache;\n    static std::mutex compatibilityCacheMutex;\n    const CompatibilityCacheKey compatibilityKey {\n\tstatic_cast<int> (this->m_type), this->m_preprocessed,\n\tthis->m_link == nullptr ? std::string () : this->m_link->m_preprocessed\n    };\n    std::scoped_lock compatibilityLock (compatibilityCacheMutex);\n    const auto cached = compatibilityCache.find (compatibilityKey);\n    if (cached != compatibilityCache.end ()) {\n\tthis->m_final += cached->second;\n    } else {\n\tauto compatible = this->applyFragmentTexCoordCompatibility (\n\t    this->applyLinkedVaryingCompatibility (this->m_preprocessed)\n\t);\n\tthis->m_final += compatible;\n\tif (compatibilityCache.size () >= 512) {\n\t    compatibilityCache.erase (compatibilityCache.begin ());\n\t}\n\tcompatibilityCache.emplace (compatibilityKey, std::move (compatible));\n    }"
    shader_unit_source
    "${shader_unit_source}"
)
fresco_require_generated_patch(
    shader_unit_source
    "CompatibilityCacheKey"
    "shader compatibility transform cache"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/ShaderUnit.cpp"
    shader_unit_source
)

file(READ
    "${upstream}/src/WallpaperEngine/Data/Parsers/WallpaperParser.cpp"
    wallpaper_parser_source
)
string(REPLACE
    "    const auto& properties = project.properties;\n"
    "    const auto& properties = project.properties;\n    FrescoScene::registerPendingSceneZoom (general.user (\"zoom\", properties, 1.0f));\n    const bool autoProjection = projection.optional (\"auto\", false)\n        || !projection.optional (\"width\").has_value ()\n        || !projection.optional (\"height\").has_value ();\n"
    wallpaper_parser_source
    "${wallpaper_parser_source}"
)
string(REPLACE
    "#include \"WallpaperEngine/Logging/Log.h\""
    "#include \"WallpaperEngine/Logging/Log.h\"\n#include \"FrescoScene/SceneZoomControl.h\""
    wallpaper_parser_source
    "${wallpaper_parser_source}"
)
string(REPLACE
    "projection.optional (\"auto\", false) ? 0 : projection.require <int> (\"width\",  \"Projection must have a width\")"
    "autoProjection ? 0 : projection.require <int> (\"width\",  \"Projection must have a width\")"
    wallpaper_parser_source
    "${wallpaper_parser_source}"
)
string(REPLACE
    "projection.optional (\"auto\", false) ? 0 : projection.require <int> (\"height\", \"Projection must have a height\")"
    "autoProjection ? 0 : projection.require <int> (\"height\", \"Projection must have a height\")"
    wallpaper_parser_source
    "${wallpaper_parser_source}"
)
string(REPLACE
    ".isAuto = projection.optional (\"auto\", false),"
    ".isAuto = autoProjection,"
    wallpaper_parser_source
    "${wallpaper_parser_source}"
)
fresco_require_generated_patch(
    wallpaper_parser_source
    "const bool autoProjection ="
    "current automatic projection detection"
)
fresco_require_generated_patch(
    wallpaper_parser_source
    "autoProjection ? 0 : projection.require <int> (\"width\""
    "automatic projection width"
)
fresco_require_generated_patch(
    wallpaper_parser_source
    "autoProjection ? 0 : projection.require <int> (\"height\""
    "automatic projection height"
)
fresco_require_generated_patch(
    wallpaper_parser_source
    ".isAuto = autoProjection,"
    "automatic projection flag"
)
fresco_require_generated_patch(
    wallpaper_parser_source
    "FrescoScene::registerPendingSceneZoom"
    "scene zoom script retention"
)

file(READ
    "${upstream}/src/WallpaperEngine/Data/JSON.h"
    json_header_source
)
string(REPLACE
    "#include \"Builders/ColorBuilder.h\""
    "#include \"WallpaperEngine/Data/Builders/ColorBuilder.h\""
    json_header_source
    "${json_header_source}"
)
string(REPLACE
    "#include <optional>"
    "#include <optional>\n#include <stdexcept>"
    json_header_source
    "${json_header_source}"
)
string(REPLACE
    "optional (const std::string& key) const noexcept"
    "optional (const std::string& key) const"
    json_header_source
    "${json_header_source}"
)
string(REPLACE
    "optional (const std::string& key, T defaultValue) const noexcept"
    "optional (const std::string& key, T defaultValue) const"
    json_header_source
    "${json_header_source}"
)
string(REPLACE
    "\treturn *it;\n    }\n    template <typename T> [[nodiscard]] T optional"
    "\ttry {\n\t    return *it;\n\t} catch (const std::exception& error) {\n\t    throw std::runtime_error (\"optional field '\" + key + \"' has incompatible value \" + it->dump () + \": \" + error.what ());\n\t}\n    }\n    template <typename T> [[nodiscard]] T optional"
    json_header_source
    "${json_header_source}"
)
string(REPLACE
    "\treturn (*it);\n    }\n    [[nodiscard]] UserSettingUniquePtr user"
    "\ttry {\n\t    return (*it);\n\t} catch (const std::exception& error) {\n\t    throw std::runtime_error (\"optional field '\" + key + \"' has incompatible value \" + it->dump () + \": \" + error.what ());\n\t}\n    }\n    [[nodiscard]] UserSettingUniquePtr user"
    json_header_source
    "${json_header_source}"
)
fresco_require_generated_patch(
    json_header_source
    "#include \"WallpaperEngine/Data/Builders/ColorBuilder.h\""
    "generated JSON include path"
)
fresco_require_generated_patch(
    json_header_source "#include <stdexcept>" "generated JSON exception support"
)
fresco_require_generated_patch(
    json_header_source
    "optional (const std::string& key) const"
    "throwing typed optional accessor"
)
fresco_require_generated_patch(
    json_header_source
    "optional (const std::string& key, T defaultValue) const"
    "throwing typed optional default accessor"
)
fresco_require_generated_patch(
    json_header_source
    "try {\n\t    return *it;"
    "typed optional error context"
)
fresco_require_generated_patch(
    json_header_source
    "try {\n\t    return (*it);"
    "typed optional default error context"
)
file(MAKE_DIRECTORY
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Data"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Data/JSON.h"
    json_header_source
)
file(READ
    "${upstream}/src/WallpaperEngine/Data/JSON.cpp"
    json_source
)
string(REPLACE
    "#include \"JSON.h\""
    "#include \"WallpaperEngine/Data/JSON.h\""
    json_source
    "${json_source}"
)
fresco_require_generated_patch(
    json_source
    "#include \"WallpaperEngine/Data/JSON.h\""
    "generated JSON implementation include path"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/JSON.cpp"
    json_source
)

file(READ
    "${upstream}/src/WallpaperEngine/Data/Model/Object.h"
    object_header_source
)
foreach(object_model_header IN ITEMS DynamicValue Effect Material Model Types UserSetting)
    string(REPLACE
        "#include \"${object_model_header}.h\""
        "#include \"WallpaperEngine/Data/Model/${object_model_header}.h\""
        object_header_source
        "${object_header_source}"
    )
endforeach()
string(REPLACE
    "    int padding;\n    // TODO: PARSE LIMITS TOO!"
    "    int padding;\n    bool limitWidth;\n    bool limitRows;\n    bool limitUseEllipsis;\n    int maxRows;\n    UserSettingUniquePtr maxWidth;"
    object_header_source
    "${object_header_source}"
)
string(REPLACE
    "    /** The effects applied to this image after the material is rendered */"
    "    /** Whether passthrough layers seed effects with the current scene. */\n    bool copyBackground = true;\n    /** The effects applied to this image after the material is rendered */"
    object_header_source
    "${object_header_source}"
)
fresco_require_generated_patch(
    object_header_source
    "UserSettingUniquePtr maxWidth;"
    "bounded text width-limit model"
)
fresco_require_generated_patch(
    object_header_source
    "bool copyBackground = true;"
    "passthrough copy-background model"
)
file(MAKE_DIRECTORY
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Data/Model"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Data/Model/Object.h"
    object_header_source
)
file(READ
    "${upstream}/src/WallpaperEngine/Data/Model/Wallpaper.h"
    wallpaper_model_header_source
)
string(REPLACE
    "#include \"Object.h\""
    "#include \"WallpaperEngine/Data/Model/Object.h\""
    wallpaper_model_header_source
    "${wallpaper_model_header_source}"
)
string(REPLACE
    "#include \"Types.h\""
    "#include \"WallpaperEngine/Data/Model/Types.h\""
    wallpaper_model_header_source
    "${wallpaper_model_header_source}"
)
fresco_require_generated_patch(
    wallpaper_model_header_source
    "#include \"WallpaperEngine/Data/Model/Object.h\""
    "generated text model include identity"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Data/Model/Wallpaper.h"
    wallpaper_model_header_source
)

file(READ
    "${upstream}/src/WallpaperEngine/Data/Parsers/ObjectParser.cpp"
    object_parser_source
)
string(REPLACE
    "#include \"EffectParser.h\""
    "#include \"EffectParser.h\"\n#include \"FrescoScene/ParticleBlueprintCache.h\"\n#include \"FrescoScene/TextEffectRegistry.h\""
    object_parser_source
    "${object_parser_source}"
)
string(REPLACE
    "= WallpaperEngine::Data::JSON::JSON::parse (project.assetLocator->readString (particleFile));"
    "= *FrescoScene::loadParticleBlueprintAsset (project, particleFile);"
    object_parser_source
    "${object_parser_source}"
)
string(REPLACE
    "TextUniquePtr ObjectParser::parseText (const JSON& it, const Project& project, ObjectData base) {"
    "TextUniquePtr ObjectParser::parseText (const JSON& it, const Project& project, ObjectData base) {\n    const auto textEffects = it.optional (\"effects\");\n    FrescoScene::registerTextEffects (\n        base.id, textEffects.has_value () ? parseEffects (*textEffects, project)\n                                         : std::vector<ImageEffectUniquePtr> {}\n    );"
    object_parser_source
    "${object_parser_source}"
)
string(REPLACE
    "#include <glm/gtc/constants.hpp>\n#include <sstream>"
    "#include <glm/gtc/constants.hpp>\n#include <cstdlib>\n#include <sstream>\n#include \"FrescoScene/Camera2DControl.h\""
    object_parser_source
    "${object_parser_source}"
)
string(REPLACE
    "    const auto lightIt = it.find (\"light\");\n    // use shape to refer to VolumeLight"
    "    const auto lightIt = it.find (\"light\");\n    const auto cameraIt = it.find (\"camera\");\n    // use shape to refer to VolumeLight"
    object_parser_source
    "${object_parser_source}"
)
string(REPLACE
    "    } else if (lightIt != it.end ()) {\n\tsLog.error (\"Light objects are not supported yet\");"
    "    } else if (cameraIt != it.end ()) {\n\tconst auto path = it.optional<std::string> (\"path\", std::string ());\n\tbool emptyPath = path.empty ();\n\tif (!path.empty ()) {\n\t    try {\n\t\tconst auto pathData = JSON::parse (project.assetLocator->readString (path));\n\t\tconst auto paths = pathData.optional (\"paths\");\n\t\temptyPath = paths.has_value () && paths->is_array () && paths->empty ();\n\t    } catch (const std::exception& error) {\n\t\tsLog.error (\"Cannot inspect 2D camera path: \", error.what ());\n\t\temptyPath = false;\n\t    }\n\t}\n\tconst bool supported2D = cameraIt->is_string ()\n\t    && cameraIt->get<std::string> () == \"default\"\n\t    && emptyPath\n\t    && it.optional<std::string> (\"queuemode\", \"random\") == \"random\"\n\t    && basedata.groupAngles->value->getVec3 () == glm::vec3 (0.0f);\n\tif (supported2D) {\n\t    FrescoScene::registerCamera2DControl (\n\t\t*basedata.origin->value,\n\t\tFrescoScene::Camera2DControlDefinition {\n\t\t    .objectId = basedata.id,\n\t\t    .path = path,\n\t\t    .zoom = it.user (\"zoom\", project.properties, 1.0f),\n\t\t}\n\t    );\n\t} else {\n\t    sLog.error (\"Unsupported camera object; only default, empty-path 2D camera controls are supported\");\n\t}\n    } else if (lightIt != it.end ()) {\n\tsLog.error (\"Light objects are not supported yet\");"
    object_parser_source
    "${object_parser_source}"
)
string(REPLACE
    "    } else if (shapeIt != it.end ()) {\n\tsLog.error (\"VolumeLight objects are not supported yet\");"
    "    } else if (shapeIt != it.end ()) {\n\tconst auto effects = it.optional (\"effects\");\n\tconst bool effectQuad = shapeIt->is_string ()\n\t    && shapeIt->get<std::string> () == \"quad\"\n\t    && effects.has_value () && effects->is_array () && !effects->empty ()\n\t    && it.find (\"light\") == it.end ()\n\t    && it.find (\"camera\") == it.end ()\n\t    && it.find (\"model\") == it.end ()\n\t    && !it.optional (\"castshadow\", false);\n\tif (effectQuad && std::getenv (\"FRESCO_SCENE_PROCEDURAL_QUAD_DISABLED\") == nullptr) {\n\t    JSON image = it;\n\t    image[\"image\"] = \"models/fresco_procedural_quad.json\";\n\t    image[\"size\"] = \"1000 1000\";\n\t    return parseImage (image, project, std::move (basedata), \"models/fresco_procedural_quad.json\");\n\t}\n\tsLog.error (effectQuad\n\t    ? \"Procedural effect quad disabled by compatibility test\"\n\t    : \"Unsupported shape object; only effect-only 2D quads are supported\");"
    object_parser_source
    "${object_parser_source}"
)
string(REPLACE
    "\tconst bool effectQuad = shapeIt->is_string ()"
    "\tbool effectOnlyFields = true;\n\tfor (const auto& field : it.items ()) {\n\t    const std::string& key = field.key ();\n\t    if (key != \"shape\" && key != \"effects\" && key != \"id\" && key != \"name\"\n\t        && key != \"dependencies\" && key != \"parent\" && key != \"origin\"\n\t        && key != \"scale\" && key != \"angles\" && key != \"visible\"\n\t        && key != \"locktransforms\" && key != \"disablepropagation\"\n\t        && key != \"castshadow\" && key != \"alpha\"\n\t        && key != \"color\" && key != \"horizontalalign\" && key != \"alignment\"\n\t        && key != \"parallaxDepth\" && key != \"colorBlendMode\"\n\t        && key != \"brightness\") {\n\t\teffectOnlyFields = false;\n\t\tbreak;\n\t    }\n\t}\n\tconst bool effectQuad = effectOnlyFields && shapeIt->is_string ()"
    object_parser_source
    "${object_parser_source}"
)
string(REPLACE
    "\tif (effectQuad && std::getenv (\"FRESCO_SCENE_PROCEDURAL_QUAD_DISABLED\") == nullptr) {"
    "\tconst char* selectedQuad = std::getenv (\"FRESCO_SCENE_PROCEDURAL_QUAD_OBJECT_ID\");\n\tif (effectQuad\n\t    && std::getenv (\"FRESCO_SCENE_PROCEDURAL_QUAD_DISABLED\") == nullptr\n\t    && (selectedQuad == nullptr || std::atoi (selectedQuad) == basedata.id)) {"
    object_parser_source
    "${object_parser_source}"
)
string(REPLACE
    ".padding = it.optional (\"padding\", 0),"
    ".padding = [&it] {\n\t\tconst auto padding = it.optional (\"padding\");\n\t\tif (!padding.has_value ()) {\n\t\t    return 0;\n\t\t}\n\t\tif (padding->is_number ()) {\n\t\t    return padding->get<int> ();\n\t\t}\n\t\tif (padding->is_string ()) {\n\t\t    return static_cast<int> (std::stof (padding->get<std::string> ()));\n\t\t}\n\t\treturn 0;\n\t    } (),\n\t    .limitWidth = it.optional (\"limitwidth\", false),\n\t    .limitRows = it.optional (\"limitrows\", false),\n\t    .limitUseEllipsis = it.optional (\"limituseellipsis\", false),\n\t    .maxRows = it.optional (\"maxrows\", 1),\n\t    .maxWidth = it.user (\"maxwidth\", project.properties, 0.0f),"
    object_parser_source
    "${object_parser_source}"
)
string(REPLACE
    ".text = it.user (\"text\", project.properties),"
    ".text = [&it, &project] {\n\t\tauto setting = it.user (\"text\", project.properties);\n\t\tauto value = it.require (\"text\", \"Text object must have text\");\n\t\tif (value.is_object ()) {\n\t\t    value = value.require (\"value\", \"Text setting must have a value\");\n\t\t}\n\t\tif (value.is_string ()) {\n\t\t    setting->value->update (value.get<std::string> (), DynamicValue::UpdateSource::Initialization);\n\t\t}\n\t\treturn setting;\n\t    } (),"
    object_parser_source
    "${object_parser_source}"
)
string(REPLACE
    ".model = ModelParser::load (project, image),"
    ".model = ModelParser::load (project, image),\n\t    .copyBackground = it.optional (\"copybackground\", true),"
    object_parser_source
    "${object_parser_source}"
)
string(REPLACE
    ".scale = parseVec3 (\"scale\", glm::vec3 (1.0f)),\n\t.particleFile = particleFile,"
    ".scale = parseVec3 (\"scale\", glm::vec3 (1.0f)),\n\t.particleFile = particleFile.empty () ? name : particleFile,"
    object_parser_source
    "${object_parser_source}"
)
fresco_require_generated_patch(
    object_parser_source
    "const auto padding = it.optional (\"padding\");"
    "current text padding"
)
fresco_require_generated_patch(
    object_parser_source
    ".maxWidth = it.user (\"maxwidth\""
    "bounded scripted text maxwidth"
)
fresco_require_generated_patch(
    object_parser_source
    "setting->value->update (value.get<std::string> ()"
    "numeric-looking text preservation"
)
fresco_require_generated_patch(
    object_parser_source
    "FrescoScene::registerTextEffects"
    "text effect retention"
)
fresco_require_generated_patch(
    object_parser_source
    ".copyBackground = it.optional (\"copybackground\", true),"
    "passthrough copy-background parsing"
)
fresco_require_generated_patch(
    object_parser_source
    "FrescoScene::loadParticleBlueprintAsset"
    "immutable particle asset blueprint cache"
)
fresco_require_generated_patch(
    object_parser_source
    ".particleFile = particleFile.empty () ? name : particleFile,"
    "particle child definition path preservation"
)
fresco_require_generated_patch(
    object_parser_source
    "models/fresco_procedural_quad.json"
    "2D procedural effect quad conversion"
)
fresco_require_generated_patch(
    object_parser_source
    "bool effectOnlyFields = true;"
    "2D procedural effect quad field boundary"
)
fresco_require_generated_patch(
    object_parser_source
    "FRESCO_SCENE_PROCEDURAL_QUAD_OBJECT_ID"
    "2D procedural effect quad reachability test boundary"
)
fresco_require_generated_patch(
    object_parser_source
    "#include <cstdlib>"
    "procedural effect quad test boundary"
)
fresco_require_generated_patch(
    object_parser_source
    "FrescoScene::registerCamera2DControl"
    "empty-path 2D camera control registration"
)

file(READ
    "${upstream}/src/WallpaperEngine/Data/Parsers/MaterialParser.cpp"
    material_parser_source
)
string(REPLACE
    "#include \"MaterialParser.h\""
    "#include \"MaterialParser.h\"\n#include \"FrescoScene/ParticleBlueprintCache.h\""
    material_parser_source
    "${material_parser_source}"
)
string(REPLACE
    "const auto materialJson = JSON::parse (project.assetLocator->readString (filename));"
    "const auto materialJson = *FrescoScene::loadParticleBlueprintAsset (project, filename);"
    material_parser_source
    "${material_parser_source}"
)
fresco_require_generated_patch(
    material_parser_source
    "FrescoScene::loadParticleBlueprintAsset"
    "immutable material asset blueprint cache"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/MaterialParser.cpp"
    material_parser_source
)

file(READ
    "${upstream}/src/WallpaperEngine/Render/Objects/CText.h"
    text_header_source
)
string(REPLACE
    "    glm::vec2 m_quadSize = { 0.0f, 0.0f };"
    "    glm::vec2 m_quadSize = { 0.0f, 0.0f };\n    float m_quadLeft = 0.0f;\n    float m_quadRight = 0.0f;\n    float m_lastMaxWidth = -1.0f;\n    std::string m_lastAlignment;\n    bool m_widthLimitDiagnosticReported = false;\n    FT_Face m_fallbackFace = nullptr;\n    bool m_fallbackFaceResolved = false;"
    text_header_source
    "${text_header_source}"
)
fresco_require_generated_patch(
    text_header_source
    "m_lastMaxWidth"
    "bounded text width-limit render state"
)
fresco_require_generated_patch(
    text_header_source
    "m_fallbackFace"
    "missing-glyph fallback face state"
)
file(MAKE_DIRECTORY
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render/Objects"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render/Objects/CText.h"
    text_header_source
)

file(READ
    "${upstream}/src/WallpaperEngine/Render/Objects/CText.cpp"
    text_source
)
if(FRESCO_SCENE_RENDER_BACKEND MATCHES "^angle-")
    string(REPLACE
        "#version 330 core"
        "#version 300 es\nprecision highp float;"
        text_source
        "${text_source}"
    )
    fresco_require_generated_patch(
        text_source "#version 300 es" "GLSL ES text shaders"
    )
endif()
string(REPLACE
    "R\"glsl(\n#version"
    "R\"glsl(#version"
    text_source
    "${text_source}"
)
fresco_require_generated_patch(
    text_source "R\"glsl(#version" "shader version at byte zero"
)
string(REPLACE
    "#include \"CText.h\""
    "#include \"WallpaperEngine/Render/Objects/CText.h\"\n#include \"FrescoScene/Camera2DControl.h\"\n#include \"FrescoScene/MacSystemFontResolver.h\"\n#include \"FrescoScene/SceneObjectModelTransform.h\"\n#include \"FrescoScene/TextCodepoints.h\"\n#include \"FrescoScene/TextEffectRenderer.h\"\n#include \"FrescoScene/TextRasterSize.h\"\n#include \"FrescoScene/TextWidthLimit.h\"\n#include \"WallpaperEngine/Render/CFBO.h\""
    text_source
    "${text_source}"
)
string(REPLACE
    "getScene ().getCamera ().getProjection ()"
    "FrescoScene::applyCamera2DControl (getScene (), getScene ().getCamera ().getProjection ())"
    text_source
    "${text_source}"
)
string(REPLACE
    "#include <filesystem>"
    "#include <filesystem>\n#include <algorithm>\n#include <cmath>\n#include <cstdio>\n#include <cstdlib>\n#include <limits>\n#ifdef __APPLE__\n#include <CoreText/CoreText.h>\n#include <limits.h>\n#endif"
    text_source
    "${text_source}"
)
string(REPLACE
    "    this->registerProperty (\"text\", *text.text->value);\n    this->registerProperty (\"pointSize\", *text.pointSize->value);"
    "    this->registerProperty (\"text\", *text.text->value);\n    this->registerProperty (\"maxwidth\", *text.maxWidth->value);"
    text_source
    "${text_source}"
)
string(REPLACE
    "    FT_GlyphSlot slot = m_ftFace->glyph;"
    "    const std::string rasterText = m_text.limitRows\n\t? FrescoScene::singleTextRow (text) : text;\n    FT_GlyphSlot slot = m_ftFace->glyph;"
    text_source
    "${text_source}"
)
string(REPLACE
    "for (unsigned char c : text)"
    "for (unsigned char c : rasterText)"
    text_source
    "${text_source}"
)
string(REPLACE
    "    int penX = 0;\n    int maxAscent = 0;\n    int maxDescent = 0;"
    "    int penX = 0;\n    int maxAscent = 0;\n    int maxDescent = 0;\n    size_t coveredGlyphs = 0;\n    size_t missingGlyphs = 0;\n    for (const char32_t character : codepoints) {\n\tif (character < 0x20) {\n\t    continue;\n\t}\n\tif (FT_Get_Char_Index (m_ftFace, static_cast<FT_ULong> (character)) == 0) {\n\t    ++missingGlyphs;\n\t} else {\n\t    ++coveredGlyphs;\n\t}\n    }\n    if (std::getenv (\"FRESCO_SCENE_TRACE_TEXT_FONT\") != nullptr) {\n\tstd::fprintf (stderr, \"text-glyphs object=%d chars=%zu covered=%zu missing=%zu family=%s\\n\",\n\t    m_text.id, coveredGlyphs + missingGlyphs, coveredGlyphs, missingGlyphs,\n\t    m_ftFace->family_name == nullptr ? \"<unknown>\" : m_ftFace->family_name);\n    }"
    text_source
    "${text_source}"
)
fresco_require_generated_patch(
    text_source
    "text-glyphs object=%d"
    "text glyph coverage diagnostics"
)
string(REPLACE
    "    const bool firstUpload = (m_texture == 0);"
    "    int uploadWidth = width;\n    int visibleWidth = width;\n    std::vector<uint8_t> uploadPixels = std::move (pixels);\n    m_quadLeft = -static_cast<float> (width) * 0.5f;\n    m_quadRight = static_cast<float> (width) * 0.5f;\n    const float maxWidth = m_text.maxWidth->value->getFloat ();\n    if (m_text.limitWidth) {\n\tconst float pointSize = std::max (1.0f, m_text.pointSize->value->getFloat ());\n\tconst double scaledWidth = static_cast<double> (maxWidth)\n\t    * static_cast<double> (m_lastPixelSize) / pointSize;\n\tconst int maxWidthPixels = std::isfinite (scaledWidth) && scaledWidth >= 0.0\n\t    && scaledWidth <= static_cast<double> (std::numeric_limits<int>::max ())\n\t    ? static_cast<int> (std::floor (scaledWidth)) : -1;\n\tconst auto limit = FrescoScene::computeTextWidthLimit ({\n\t    .limitWidth = m_text.limitWidth,\n\t    .limitRows = m_text.limitRows,\n\t    .useEllipsis = m_text.limitUseEllipsis,\n\t    .maxRows = m_text.maxRows,\n\t    .fullWidthPixels = width,\n\t    .maxWidthPixels = maxWidthPixels,\n\t    .alignment = m_text.alignment,\n\t});\n\tif (!limit.supported) {\n\t    if (!m_widthLimitDiagnosticReported) {\n\t\tsLog.error (\"CText width limit rejected for object \", m_text.id, \": \", limit.diagnostic);\n\t\tm_widthLimitDiagnosticReported = true;\n\t    }\n\t    uploadWidth = 1;\n\t    visibleWidth = 0;\n\t    uploadPixels.assign (static_cast<std::size_t> (height), 0);\n\t    m_quadLeft = 0.0f;\n\t    m_quadRight = 0.0f;\n\t} else {\n\t    m_widthLimitDiagnosticReported = false;\n\t    visibleWidth = limit.widthPixels;\n\t    uploadWidth = std::max (1, visibleWidth);\n\t    std::vector<uint8_t> cropped (\n\t\tstatic_cast<std::size_t> (uploadWidth) * height, 0\n\t    );\n\t    if (visibleWidth > 0) {\n\t\tfor (int row = 0; row < height; ++row) {\n\t\t    std::copy_n (\n\t\t\tuploadPixels.begin () + static_cast<std::size_t> (row) * width\n\t\t\t    + limit.sourceOffsetPixels,\n\t\t\tvisibleWidth,\n\t\t\tcropped.begin () + static_cast<std::size_t> (row) * uploadWidth\n\t\t    );\n\t\t}\n\t    }\n\t    uploadPixels = std::move (cropped);\n\t    m_quadLeft = limit.quadLeft;\n\t    m_quadRight = limit.quadRight;\n\t    if (std::getenv (\"FRESCO_SCENE_TRACE_TEXT_WIDTH\") != nullptr) {\n\t\tstd::fprintf (\n\t\t    stderr,\n\t\t    \"text-width object=%d full=%d offset=%d visible=%d left=%.1f right=%.1f alignment=%s maxwidth=%.3f\\n\",\n\t\t    m_text.id, measuredWidth, limit.sourceOffsetPixels, visibleWidth,\n\t\t    m_quadLeft, m_quadRight, m_text.alignment.c_str (), maxWidth\n\t\t);\n\t    }\n\t}\n    }\n\n    const bool firstUpload = (m_texture == 0);"
    text_source
    "${text_source}"
)
string(REPLACE
    "glTexImage2D (GL_TEXTURE_2D, 0, GL_RED, width, height, 0, GL_RED, GL_UNSIGNED_BYTE, pixels.data ())"
    "glTexImage2D (GL_TEXTURE_2D, 0, GL_RED, uploadWidth, height, 0, GL_RED, GL_UNSIGNED_BYTE, uploadPixels.data ())"
    text_source
    "${text_source}"
)
string(REPLACE
    "const int maxWidthPixels = std::isfinite (scaledWidth) && scaledWidth >= 0.0\n\t    && scaledWidth <= static_cast<double> (std::numeric_limits<int>::max ())\n\t    ? static_cast<int> (std::floor (scaledWidth)) : -1;"
    "const int maxWidthPixels = std::isfinite (scaledWidth)\n\t    && scaledWidth <= static_cast<double> (std::numeric_limits<int>::max ())\n\t    ? static_cast<int> (std::floor (std::max (0.0, scaledWidth))) : -1;"
    text_source
    "${text_source}"
)
string(REPLACE
    "    m_textureSize = { width, height };\n    m_quadSize = { static_cast<float> (width), static_cast<float> (height) };\n    m_lastRenderedText = text;"
    "    m_textureSize = { uploadWidth, height };\n    m_quadSize = { static_cast<float> (visibleWidth), static_cast<float> (height) };\n    m_lastRenderedText = text;\n    m_lastMaxWidth = maxWidth;\n    m_lastAlignment = m_text.alignment;"
    text_source
    "${text_source}"
)
string(REPLACE
    "    const float hx = m_quadSize.x * 0.5f;\n    const float hy = m_quadSize.y * 0.5f;"
    "    const float left = m_quadLeft;\n    const float right = m_quadRight;\n    const float hy = m_quadSize.y * 0.5f;"
    text_source
    "${text_source}"
)
string(REPLACE
    "\t-hx, -hy, 0.0f, 0.0f, hx, -hy, 1.0f, 0.0f, hx,  hy, 1.0f, 1.0f,\n\t-hx, -hy, 0.0f, 0.0f, hx, hy,  1.0f, 1.0f, -hx, hy, 0.0f, 1.0f,"
    "\tleft, -hy, 0.0f, 0.0f, right, -hy, 1.0f, 0.0f, right, hy, 1.0f, 1.0f,\n\tleft, -hy, 0.0f, 0.0f, right, hy, 1.0f, 1.0f, left, hy, 0.0f, 1.0f,"
    text_source
    "${text_source}"
)
string(REPLACE
    "    const unsigned int pixelSize = computeEffectivePixelSize ();\n    if (pixelSize != m_lastPixelSize) {"
    "    const unsigned int pixelSize = computeEffectivePixelSize ();\n    const float currentMaxWidth = m_text.maxWidth->value->getFloat ();\n    const bool widthLayoutChanged = m_text.limitWidth\n\t&& (currentMaxWidth != m_lastMaxWidth || m_text.alignment != m_lastAlignment);\n    if (m_text.limitWidth && std::getenv (\"FRESCO_SCENE_TRACE_TEXT_WIDTH\") != nullptr\n\t&& (renderedText != m_lastRenderedText || widthLayoutChanged)) {\n\tstd::fprintf (stderr, \"text-width-layout object=%d text=%zu prior=%zu maxwidth=%.3f priorMaxwidth=%.3f alignment=%s priorAlignment=%s scaleX=%.3f\\n\",\n\t    m_text.id, renderedText.size (), m_lastRenderedText.size (), currentMaxWidth,\n\t    m_lastMaxWidth, m_text.alignment.c_str (), m_lastAlignment.c_str (),\n\t    m_text.scale->value->getVec3 ().x);\n    }\n    if (pixelSize != m_lastPixelSize) {"
    text_source
    "${text_source}"
)
string(REPLACE
    "    } else if (renderedText != m_lastRenderedText) {\n\trebuildTextureFrom (renderedText);"
    "    } else if (renderedText != m_lastRenderedText || widthLayoutChanged) {\n\trebuildTextureFrom (renderedText);"
    text_source
    "${text_source}"
)
string(REPLACE
    "    if (!m_text.visible->value->getBool ()) {\n\treturn;\n    }"
    "    if (!FrescoScene::sceneObjectVisibleWithParents (getScene (), m_text)) {\n\treturn;\n    }"
    text_source
    "${text_source}"
)
string(REPLACE
    "\torigin.y - scene_h * 0.5f,"
    "\tscene_h * 0.5f - origin.y,"
    text_source
    "${text_source}"
)
string(REPLACE
    "\torigin.z,\n    };"
    "\tgetScene ().getCamera ().isOrthogonal () ? 0.0f : origin.z,\n    };"
    text_source
    "${text_source}"
)
string(REPLACE
    "    const glm::vec3 scale = m_text.scale->value->getVec3 ();\n    const glm::vec3 origin = m_text.origin->value->getVec3 ();"
    "    const auto transform = FrescoScene::resolveSceneObjectTransform (getScene (), m_text);\n    const glm::vec3 scale = transform.scale;\n    const glm::vec3 origin = transform.origin;"
    text_source
    "${text_source}"
)
string(REPLACE
    "    glm::mat4 model = glm::translate (glm::mat4 (1.0f), gl_origin);\n    model = glm::scale (model, scale);"
    "    glm::mat4 model = glm::translate (glm::mat4 (1.0f), gl_origin);\n    model = glm::rotate (model, -transform.angle, glm::vec3 (0.0f, 0.0f, 1.0f));\n    model = glm::scale (model, scale);"
    text_source
    "${text_source}"
)
string(REPLACE
    "    const glm::vec4 color = m_text.color->value->getVec4 ();"
    "    const bool renderedWithEffects = FrescoScene::renderTextEffects (\n\tgetScene (), m_text, m_textureSize,\n\t[this] (const std::shared_ptr<const WallpaperEngine::Render::CFBO>& fbo, const glm::mat4& mvp) {\n\t    const glm::vec4 effectColor = m_text.color->value->getVec4 ();\n\t    const float effectAlpha = m_text.alpha->value->getFloat ();\n\t    glBindFramebuffer (GL_FRAMEBUFFER, fbo->getFramebuffer ());\n\t    glViewport (0, 0, fbo->getRealWidth (), fbo->getRealHeight ());\n\t    glColorMask (GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);\n\t    glClearColor (0.0f, 0.0f, 0.0f, 0.0f);\n\t    glClear (GL_COLOR_BUFFER_BIT);\n\t    glEnable (GL_BLEND);\n\t    glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);\n\t    glUseProgram (m_program);\n\t    glUniformMatrix4fv (m_uMVP, 1, GL_FALSE, glm::value_ptr (mvp));\n\t    glUniform4f (\n\t\tm_uColor, effectColor.r, effectColor.g, effectColor.b,\n\t\teffectColor.a * effectAlpha\n\t    );\n\t    glActiveTexture (GL_TEXTURE0);\n\t    glBindTexture (GL_TEXTURE_2D, m_texture);\n\t    glUniform1i (m_uTexture, 0);\n\t    glBindVertexArray (m_vao);\n\t    glDrawArrays (GL_TRIANGLES, 0, 6);\n\t    glBindVertexArray (0);\n\t}\n    );\n    if (renderedWithEffects) {\n#if !NDEBUG\n\tglPopDebugGroup ();\n#endif\n\treturn;\n    }\n\n    const glm::vec4 color = m_text.color->value->getVec4 ();"
    text_source
    "${text_source}"
)
string(REPLACE
    "    FT_GlyphSlot slot = m_ftFace->glyph;"
    "    // An embedded wallpaper font may lack the characters its own scripted\n    // text produces, and FreeType renders those as .notdef boxes. Resolve one\n    // fallback face through Core Text's cascade from the first uncovered\n    // character and draw the uncovered glyphs from it.\n    auto faceForCharacter = [this] (FT_ULong codepoint) -> FT_Face {\n\tif (m_ftFace == nullptr || FT_Get_Char_Index (m_ftFace, codepoint) != 0) {\n\t    return m_ftFace;\n\t}\n\tif (!m_fallbackFaceResolved) {\n\t    m_fallbackFaceResolved = true;\n\t    const auto fallbackPath = FrescoScene::resolveMacFallbackFontPath (\n\t\tstatic_cast<char32_t> (codepoint)\n\t    );\n\t    if (!fallbackPath.has_value ()\n\t\t|| FT_New_Face (\n\t\t    m_ftLibrary, fallbackPath->c_str (), 0, &m_fallbackFace\n\t\t) != 0) {\n\t\tm_fallbackFace = nullptr;\n\t\tsLog.error (\n\t\t    \"CText: no fallback face for object \", m_text.id,\n\t\t    \" codepoint \", static_cast<unsigned long> (codepoint)\n\t\t);\n\t    }\n\t}\n\tif (m_fallbackFace == nullptr\n\t    || FT_Get_Char_Index (m_fallbackFace, codepoint) == 0) {\n\t    return m_ftFace;\n\t}\n\tFT_Set_Pixel_Sizes (\n\t    m_fallbackFace, 0, static_cast<FT_UInt> (m_lastPixelSize)\n\t);\n\treturn m_fallbackFace;\n    };\n    // Wallpaper text is UTF-8. Iterating it as bytes rasterized each byte as a\n    // separate Latin-1 character.\n    const std::vector<char32_t> codepoints = FrescoScene::decodeUtf8 (rasterText);"
    text_source
    "${text_source}"
)
string(REPLACE
    "    for (unsigned char c : rasterText) {"
    "    for (const char32_t c : codepoints) {"
    text_source
    "${text_source}"
)
string(REPLACE
    "\tif (FT_Load_Char (m_ftFace, static_cast<FT_ULong> (c), FT_LOAD_RENDER) != 0) {\n\t    continue;\n\t}"
    "\t// No glyph carries a control character, and rasterization is still\n\t// single-row, so an authored newline would draw .notdef rather than wrap.\n\tif (c < 0x20) {\n\t    continue;\n\t}\n\tFT_Face face = faceForCharacter (static_cast<FT_ULong> (c));\n\tif (face == nullptr\n\t    || FT_Load_Char (face, static_cast<FT_ULong> (c), FT_LOAD_RENDER) != 0) {\n\t    continue;\n\t}\n\tconst FT_GlyphSlot slot = face->glyph;"
    text_source
    "${text_source}"
)
string(REPLACE
    "    if (m_ftFace != nullptr) {\n\tFT_Done_Face (m_ftFace);\n    }"
    "    if (m_fallbackFace != nullptr) {\n\tFT_Done_Face (m_fallbackFace);\n    }\n    if (m_ftFace != nullptr) {\n\tFT_Done_Face (m_ftFace);\n    }"
    text_source
    "${text_source}"
)
string(REPLACE
    "    const int width = std::max (1, penX);\n    const int height = std::max (1, maxAscent + maxDescent);"
    "    GLint maximumTextureExtent = 0;\n    glGetIntegerv (GL_MAX_TEXTURE_SIZE, &maximumTextureExtent);\n    const int measuredWidth = std::max (1, penX);\n    const int width = FrescoScene::boundedGlyphAtlasExtent (\n\tpenX, static_cast<int> (maximumTextureExtent)\n    );\n    const int height = FrescoScene::boundedGlyphAtlasExtent (\n\tmaxAscent + maxDescent, static_cast<int> (maximumTextureExtent)\n    );"
    text_source
    "${text_source}"
)
string(REPLACE
    "    // WE text objects often come with scale ~0.09 that, combined with a modest\n    // pointsize, would rasterize glyphs to ~2px on screen (invisible). Rasterize\n    // at higher resolution so that after the model scale is applied in render()\n    // the on-screen size matches the intended pointsize.\n    const glm::vec3 initialScale = m_text.scale->value->getVec3 ();\n    const float avgScale = (initialScale.x + initialScale.y) * 0.5f;\n    const float compensate = (avgScale > 0.0f && avgScale < 1.0f) ? std::min (1.0f / avgScale, 32.0f) : 1.0f;\n    return std::max<unsigned int> (1u, static_cast<unsigned int> (m_text.pointSize->value->getFloat () * compensate));"
    "    // Wallpaper Engine rasterizes text at 300 DPI against a 72-point em and\n    // applies the layer transform separately in render (), so the raster size\n    // follows the authored pointsize alone. Deriving it from the layer scale\n    // instead rendered scale-1 text about four times too small.\n    return FrescoScene::textRasterPixelSize (m_text.pointSize->value->getFloat ());"
    text_source
    "${text_source}"
)
string(REPLACE
    "bool CText::loadSystemFont () {\n    std::string fontPath;"
    "bool CText::loadSystemFont () {\n    std::string fontPath;\n#ifdef __APPLE__\n    const auto resolved = FrescoScene::resolveMacSystemFont (m_text.font);\n    if (resolved.has_value ()) {\n\tfontPath = resolved->path;\n\tif (FT_New_Face (m_ftLibrary, fontPath.c_str (), 0, &m_ftFace) == 0) {\n\t    if (std::getenv (\"FRESCO_SCENE_TRACE_TEXT_FONT\") != nullptr) {\n\t\tstd::fprintf (stderr, \"text-font object=%d requested=%s resolved=%s substituted=%d fixed=%d path=%s\\n\",\n\t\t    m_text.id, resolved->requestedFamily.c_str (),\n\t\t    resolved->resolvedFamily.c_str (), resolved->substituted ? 1 : 0,\n\t\t    resolved->fixedPitch ? 1 : 0, resolved->path.c_str ());\n\t    }\n\t    return true;\n\t}\n\tsLog.error (\"CText: FT_New_Face failed for resolved system font \", fontPath);\n    }\n    fontPath.clear ();\n#endif"
    text_source
    "${text_source}"
)
fresco_require_generated_patch(
    text_source
    "#include \"WallpaperEngine/Render/Objects/CText.h\""
    "generated text implementation include path"
)
fresco_require_generated_patch(
    text_source "#include <CoreText/CoreText.h>" "Core Text font discovery"
)
fresco_require_generated_patch(
    text_source
    "FrescoScene::resolveMacSystemFont"
    "macOS system font fallback"
)
fresco_require_generated_patch(
    text_source
    "FrescoScene::applyCamera2DControl"
    "2D camera text projection"
)
fresco_require_generated_patch(
    text_source
    "FrescoScene::sceneObjectVisibleWithParents"
    "text parent visibility composition"
)
fresco_require_generated_patch(
    text_source
    "FrescoScene::resolveSceneObjectTransform"
    "text parent transform composition"
)
fresco_require_generated_patch(
    text_source
    "scene_h * 0.5f - origin.y"
    "bottom-up text origin mapping"
)
fresco_require_generated_patch(
    text_source
    "getScene ().getCamera ().isOrthogonal () ? 0.0f : origin.z"
    "orthographic text origin z removal"
)
fresco_require_generated_patch(
    text_source
    "FrescoScene::renderTextEffects"
    "bounded text effect render path"
)
fresco_require_generated_patch(
    text_source
    "FrescoScene::computeTextWidthLimit"
    "bounded single-row text width limit"
)
fresco_require_generated_patch(
    text_source
    "this->registerProperty (\"maxwidth\""
    "scripted text maxwidth registration"
)
fresco_require_generated_patch(
    text_source
    "FRESCO_SCENE_TRACE_TEXT_WIDTH"
    "text width visual evidence"
)
fresco_require_generated_patch(
    text_source
    "FrescoScene::textRasterPixelSize"
    "authored text raster size"
)
fresco_require_generated_patch(
    text_source
    "FrescoScene::boundedGlyphAtlasExtent"
    "glyph bitmap texture extent bound"
)
fresco_require_generated_patch(
    text_source
    "FrescoScene::resolveMacFallbackFontPath"
    "missing-glyph font fallback"
)
fresco_require_generated_patch(
    text_source
    "FrescoScene::decodeUtf8"
    "UTF-8 text decoding"
)
fresco_require_generated_patch(
    text_source
    "for (const char32_t c : codepoints)"
    "codepoint text rasterization"
)
fresco_require_generated_patch(
    text_source
    "FT_Done_Face (m_fallbackFace)"
    "fallback face teardown"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/CText.cpp"
    text_source
)

if(FRESCO_SCENE_RENDER_BACKEND MATCHES "^angle-")
    file(READ
        "${upstream}/src/WallpaperEngine/Render/CWallpaper.cpp"
        wallpaper_source
    )
    string(REPLACE
        "#include \"CWallpaper.h\""
        "#include \"WallpaperEngine/Render/CWallpaper.h\""
        wallpaper_source
        "${wallpaper_source}"
    )
    string(REPLACE
        "#version 330\\n"
        "#version 300 es\\n"
        wallpaper_source
        "${wallpaper_source}"
    )
    fresco_require_generated_patch(
        wallpaper_source "#version 300 es\\n" "GLSL ES wallpaper shaders"
    )
    fresco_require_generated_patch(
        wallpaper_source
        "#include \"WallpaperEngine/Render/CWallpaper.h\""
        "generated wallpaper implementation include path"
    )
    fresco_write_generated(
        "${CMAKE_CURRENT_BINARY_DIR}/generated/CWallpaper.cpp"
        wallpaper_source
    )
    set(wallpaper_renderer_source
        "${CMAKE_CURRENT_BINARY_DIR}/generated/CWallpaper.cpp")
else()
    set(wallpaper_renderer_source
        "${upstream}/src/WallpaperEngine/Render/CWallpaper.cpp")
endif()

file(READ
    "${upstream}/src/WallpaperEngine/Render/Objects/Effects/CPass.h"
    pass_header
)
string(REPLACE
    "#include <functional>"
    "#include <functional>\n#include <memory>\n#include \"FrescoScene/RenderAllocationEvidence.h\""
    pass_header
    "${pass_header}"
)
string(REPLACE
    "UniformEntry (const GLint id, std::string name, UniformType type, const void* value, int count) :\n\t    id (id), name (std::move (name)), type (type), value (value), count (count) { }"
    "UniformEntry (const GLint id, std::string name, UniformType type, const void* value, int count, std::shared_ptr<const void> ownedValue = nullptr) :\n\t    id (id), name (std::move (name)), type (type), value (value), count (count), ownedValue (std::move (ownedValue)) { }"
    pass_header
    "${pass_header}"
)
string(REPLACE
    "\tint count;\n    };"
    "\tint count;\n\tstd::shared_ptr<const void> ownedValue;\n    };"
    pass_header
    "${pass_header}"
)
string(REPLACE
    "    std::vector<AttribEntry*> m_attribs = {};\n    std::map<std::string, UniformEntry*> m_uniforms = {};\n    std::map<std::string, ReferenceUniformEntry*> m_referenceUniforms = {};"
    "    std::vector<FrescoScene::TrackedRenderUniquePtr<AttribEntry>> m_attribs = {};\n    std::map<std::string, FrescoScene::TrackedRenderUniquePtr<UniformEntry>> m_uniforms = {};\n    std::map<std::string, FrescoScene::TrackedRenderUniquePtr<ReferenceUniformEntry>> m_referenceUniforms = {};"
    pass_header
    "${pass_header}"
)
string(REPLACE
    "    Render::Shaders::Shader* m_shader = nullptr;"
    "    FrescoScene::TrackedRenderUniquePtr<Render::Shaders::Shader> m_shader;"
    pass_header
    "${pass_header}"
)
string(REPLACE
    "    GLuint m_programID;"
    "    GLuint m_programID;\n    std::shared_ptr<const GLuint> m_sharedProgram;"
    pass_header
    "${pass_header}"
)
fresco_require_generated_patch(
    pass_header
    "std::shared_ptr<const GLuint> m_sharedProgram;"
    "shared render-pass program lifetime"
)
foreach(pass_ownership_marker IN ITEMS
    "TrackedRenderUniquePtr<AttribEntry>"
    "TrackedRenderUniquePtr<UniformEntry>"
    "TrackedRenderUniquePtr<ReferenceUniformEntry>"
    "TrackedRenderUniquePtr<Render::Shaders::Shader>")
    fresco_require_generated_patch_count(
        pass_header
        "${pass_ownership_marker}"
        1
        "render-pass ownership ${pass_ownership_marker}"
    )
endforeach()
fresco_require_generated_patch(
    pass_header
    "std::shared_ptr<const void> ownedValue;"
    "copied uniform ownership"
)
file(MAKE_DIRECTORY
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render/Objects/Effects"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render/Objects/Effects/CPass.h"
    pass_header
)

file(READ
    "${upstream}/src/WallpaperEngine/Render/Objects/Effects/CPass.cpp"
    pass_source
)
string(REPLACE
    "#include \"CPass.h\""
    "#include \"WallpaperEngine/Render/Objects/Effects/CPass.h\"\n#include \"FrescoScene/EffectRenderEvidence.h\"\n#include \"FrescoScene/ProceduralEffectCompositing.h\"\n#include \"FrescoScene/RenderProgramCache.h\"\n#include \"FrescoScene/TextureAnimationScript.h\"\n#include <map>\n#include <memory>\n#include <tuple>\n#include <vector>"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "    // set texture blending\n    switch (this->getBlendingMode ()) {"
    "    // DIRECTDRAW shaders and passthrough images may use alpha as coverage\n    // when composited directly into the scene. Intermediate targets retain\n    // authored blending.\n    auto blendingMode = this->getBlendingMode ();\n    const auto* image = dynamic_cast<const CImage*> (&this->m_renderable);\n    const bool passthroughImage\n\t= image != nullptr && image->getImage ().model->passthrough;\n    const bool coverageCompositing = FrescoScene::requiresCoverageCompositing (\n\tpassthroughImage, this->m_pass.combos, this->m_override.combos\n    );\n    if (blendingMode == BlendingMode_Normal\n\t&& this->m_drawTo == this->m_renderable.getScene ().getFBO ()\n\t&& coverageCompositing) {\n\tblendingMode = BlendingMode_Translucent;\n    }\n\n    // set texture blending\n    switch (blendingMode) {"
    pass_source
    "${pass_source}"
)
fresco_require_generated_patch(
    pass_source
    "passthroughImage, this->m_pass.combos, this->m_override.combos"
    "final-pass alpha-coverage compositing"
)
string(REPLACE
    "    // set texture blending\n    switch (blendingMode) {"
    "    const auto* inputFBO = dynamic_cast<const CFBO*> (this->m_input.get ());\n    FrescoScene::recordEffectPassExecution (\n\tthis->m_renderable.getId (),\n\tthis->m_pass.shader,\n\tthis->m_target.has_value () ? this->m_target->get () : std::string_view (\"<none>\"),\n\tthis->m_drawTo == nullptr ? std::string_view (\"<null>\") : this->m_drawTo->getName (),\n\tinputFBO == nullptr ? std::string_view (\"<texture>\") : inputFBO->getName (),\n\tthis->m_previousInput != nullptr,\n\tstatic_cast<int> (blendingMode)\n    );\n\n    // set texture blending\n    switch (blendingMode) {"
    pass_source
    "${pass_source}"
)
fresco_require_generated_patch_count(
    pass_source
    "recordEffectPassExecution"
    1
    "ordered effect pass execution evidence"
)
string(REPLACE
    "\t    // shader compilation failed completely, throw an exception\n\t    sLog.exception (buffer.str ());"
    "\t    // shader compilation failed completely; the scope guard releases it.\n\t    FrescoScene::recordRenderShaderCompileFailure ();\n\t    sLog.exception (buffer.str ());"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "namespace {"
    "namespace {\n// Cached GL programs are retained by their owning RenderContext session. Exact\n// translated-source keys preserve pass-local uniforms and binding independence.\nclass ScopedShaderHandle {\npublic:\n    explicit ScopedShaderHandle (GLuint id) noexcept : m_id (id) { }\n    ~ScopedShaderHandle () { reset (); }\n    ScopedShaderHandle (const ScopedShaderHandle&) = delete;\n    ScopedShaderHandle& operator= (const ScopedShaderHandle&) = delete;\n    [[nodiscard]] GLuint release () noexcept { return std::exchange (m_id, GL_NONE); }\n    void reset () noexcept { if (m_id != GL_NONE) { glDeleteShader (m_id); m_id = GL_NONE; } }\nprivate:\n    GLuint m_id;\n};\n\nclass ScopedProgramHandle {\npublic:\n    explicit ScopedProgramHandle (GLuint id) noexcept : m_id (id) { }\n    ~ScopedProgramHandle () { if (m_id != GL_NONE) { glDeleteProgram (m_id); FrescoScene::recordRenderProgramRollback (); } }\n    ScopedProgramHandle (const ScopedProgramHandle&) = delete;\n    ScopedProgramHandle& operator= (const ScopedProgramHandle&) = delete;\n    [[nodiscard]] GLuint get () const noexcept { return m_id; }\n    [[nodiscard]] GLuint release () noexcept { return std::exchange (m_id, GL_NONE); }\nprivate:\n    GLuint m_id;\n};\n\nstruct SharedProgramHandle {\n    SharedProgramHandle (GLuint value, FrescoScene::RenderResourceGeneration resourceGeneration) noexcept : id (value), generation (resourceGeneration) { }\n    ~SharedProgramHandle () { glDeleteProgram (id); if (published) { FrescoScene::recordRenderProgramDeletion (generation); } }\n    GLuint id;\n    FrescoScene::RenderResourceGeneration generation;\n    bool published = false;\n};"
    pass_source
    "${pass_source}"
)
string(REPLACE [=[    // destroy shader programs
    if (!glIsProgram (this->m_programID)) {
	return; // program already invalid or deleted
    }

    GLint shaderCount = 0;
    glGetProgramiv (this->m_programID, GL_ATTACHED_SHADERS, &shaderCount);

    if (shaderCount > 0) {
	std::vector<GLuint> attachedShaders (shaderCount);
	glGetAttachedShaders (this->m_programID, shaderCount, nullptr, attachedShaders.data ());

	for (GLuint s : attachedShaders) {
	    if (glIsShader (s)) {
		glDeleteShader (s);
	    }
	}
    }

    glDeleteProgram (this->m_programID);
    this->m_programID = 0;]=]
    [=[    this->m_sharedProgram.reset ();
    this->m_programID = 0;]=]
    pass_source
    "${pass_source}"
)
string(REPLACE
    "    // compile the shaders\n    const GLuint vertexShaderID = compileShader (vertex.c_str (), GL_VERTEX_SHADER);"
    "    const auto programGeneration = FrescoScene::renderResourceGeneration (\n\tstatic_cast<const void*> (&this->getContext ())\n    );\n    this->m_sharedProgram = FrescoScene::renderProgramCache ().find (\n\tprogramGeneration, vertex, fragment\n    );\n    if (this->m_sharedProgram != nullptr) {\n\tthis->m_programID = *this->m_sharedProgram;\n    } else {\n    // Own every GL handle immediately so constructor failure cannot leak it.\n    const GLuint vertexShaderID = compileShader (vertex.c_str (), GL_VERTEX_SHADER);\n    ScopedShaderHandle vertexShaderGuard (vertexShaderID);"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "    const auto [vertex, fragment]\n\t= Shaders::GLSLContext::get ().toGlsl (this->m_shader->vertex (), this->m_shader->fragment ());"
    "    const auto translatedSources = [&] {\n\ttry {\n\t    return Shaders::GLSLContext::get ().toGlsl (\n\t\tthis->m_shader->vertex (), this->m_shader->fragment ()\n\t    );\n\t} catch (...) {\n\t    FrescoScene::recordRenderShaderTranslationFailure ();\n\t    throw;\n\t}\n    } ();\n    const auto& [vertex, fragment] = translatedSources;"
    pass_source
    "${pass_source}"
)
fresco_require_generated_patch_count(
    pass_source
    "recordRenderShaderTranslationFailure"
    1
    "shader translation failure propagation"
)
string(REPLACE
    "    const GLuint fragmentShaderID = compileShader (fragment.c_str (), GL_FRAGMENT_SHADER);"
    "    const GLuint fragmentShaderID = compileShader (fragment.c_str (), GL_FRAGMENT_SHADER);\n    ScopedShaderHandle fragmentShaderGuard (fragmentShaderID);"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "    this->m_programID = glCreateProgram ();"
    "    this->m_programID = glCreateProgram ();\n    ScopedProgramHandle programGuard (this->m_programID);\n    static bool injectedProgramFailure = false;\n    const auto* injectedGeneration = std::getenv (\n\t\"FRESCO_SCENE_TEST_FAIL_SHADER_PROGRAM_ONCE\"\n    );\n    if (injectedGeneration != nullptr && !injectedProgramFailure\n\t&& programGeneration == std::strtoull (injectedGeneration, nullptr, 10)) {\n\tinjectedProgramFailure = true;\n\tthrow std::runtime_error (\"injected shader program failure\");\n    }"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "    glDeleteShader (fragmentShaderID);\n\n    // first setup the default values"
    "    fragmentShaderGuard.reset ();\n\n    auto sharedProgramOwner = std::make_shared<SharedProgramHandle> (\n\tprogramGuard.get (), programGeneration\n    );\n    this->m_sharedProgram = std::shared_ptr<const GLuint> (\n\tsharedProgramOwner, &sharedProgramOwner->id\n    );\n    static_cast<void> (programGuard.release ());\n    FrescoScene::renderProgramCache ().insert (\n\tprogramGeneration, vertex, fragment, this->m_sharedProgram\n    );\n    sharedProgramOwner->published = true;\n    }\n\n    // first setup the default values"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "    glDeleteShader (vertexShaderID);"
    "    vertexShaderGuard.reset ();"
    pass_source
    "${pass_source}"
)
foreach(shared_program_marker IN ITEMS
    "renderProgramCache ().find"
    "m_sharedProgram.reset ()"
    "renderProgramCache ().insert"
    "programGuard.release ()")
    fresco_require_generated_patch(
        pass_source
        "${shared_program_marker}"
        "shared render-pass program ${shared_program_marker}"
    )
endforeach()
string(REPLACE
    "    this->setupShaderVariables ();\n    // setup uniforms\n    this->setupUniforms ();\n    // setup attributes too\n    this->setupAttributes ();"
    "    try {\n\tthis->setupShaderVariables ();\n\t// setup uniforms\n\tthis->setupUniforms ();\n\t// setup attributes too\n\tthis->setupAttributes ();\n    } catch (...) {\n\tFrescoScene::recordRenderProgramSetupFailure ();\n\tthrow;\n    }"
    pass_source
    "${pass_source}"
)
fresco_require_generated_patch_count(
    pass_source
    "recordRenderProgramSetupFailure"
    1
    "shader program setup failure propagation"
)
string(REPLACE
    "    const GLuint shaderID = glCreateShader (type);"
    "    const GLuint shaderID = glCreateShader (type);\n    ScopedShaderHandle shaderGuard (shaderID);"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "    return shaderID;"
    "    return shaderGuard.release ();"
    pass_source
    "${pass_source}"
)
fresco_require_generated_patch_count(
    pass_source
    "ScopedShaderHandle shaderGuard"
    1
    "compiled shader unwind ownership"
)
string(REPLACE
    "const auto logBuffer = new char[infoLogLength + 1];"
    "std::vector<char> logBuffer (static_cast<std::size_t> (infoLogLength) + 1, '\\0');"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "\tmemset (logBuffer, 0, infoLogLength + 1);"
    ""
    pass_source
    "${pass_source}"
)
string(REPLACE
    "infoLogLength, nullptr, logBuffer);"
    "infoLogLength, nullptr, logBuffer.data ());"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "buffer << logBuffer <<"
    "buffer << logBuffer.data () <<"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "const std::string message = logBuffer;"
    "const std::string message = logBuffer.data ();"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "\tdelete[] logBuffer;"
    ""
    pass_source
    "${pass_source}"
)
fresco_require_generated_patch_count(
    pass_source
    "std::vector<char> logBuffer"
    2
    "shader and program info-log unwind ownership"
)
string(REPLACE
    "Render::Shaders::Shader* CPass::getShader () const { return this->m_shader; }"
    "Render::Shaders::Shader* CPass::getShader () const { return this->m_shader.get (); }"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "    this->m_shader = new Render::Shaders::Shader ("
    "    this->m_shader = FrescoScene::makeTrackedRenderUnique<Render::Shaders::Shader> (\n\tFrescoScene::RenderAllocationKind::shader,"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "    this->m_attribs.emplace_back (new AttribEntry (id, name, type, elements, value));"
    "    this->m_attribs.emplace_back (FrescoScene::makeTrackedRenderUnique<AttribEntry> (\n\tFrescoScene::RenderAllocationKind::passAttribute, id, name, type, elements, value\n    ));"
    pass_source
    "${pass_source}"
)
string(REPLACE [=[    // free the uniform that's already registered if it's there already
    const auto it = this->m_uniforms.find (name);

    if (it != this->m_uniforms.end ()) {
	delete it->second;
    }

    // build a copy of the value and allocate it somewhere
    T* newValue = new T (value);

    // uniform found, add it to the list
    this->m_uniforms.insert_or_assign (name, new UniformEntry (id, name, type, newValue, 1));]=]
    [=[    auto ownedValue = FrescoScene::makeTrackedRenderShared<T> (
	FrescoScene::RenderAllocationKind::copiedUniformValue, value
    );
    const void* copiedValue = ownedValue.get ();
    this->m_uniforms.insert_or_assign (
	name, FrescoScene::makeTrackedRenderUnique<UniformEntry> (
	    FrescoScene::RenderAllocationKind::passUniform,
	    id, name, type, copiedValue, 1, std::move (ownedValue)
	)
    );]=]
    pass_source
    "${pass_source}"
)
string(REPLACE [=[    // free the uniform that's already registered if it's there already

    if (const auto it = this->m_uniforms.find (name); it != this->m_uniforms.end ()) {
	delete it->second;
    }

    // uniform found, add it to the list
    this->m_uniforms.insert_or_assign (name, new UniformEntry (id, name, type, value, count));]=]
    [=[    this->m_uniforms.insert_or_assign (
	name, FrescoScene::makeTrackedRenderUnique<UniformEntry> (
	    FrescoScene::RenderAllocationKind::passUniform,
	    id, name, type, value, count
	)
    );]=]
    pass_source
    "${pass_source}"
)
string(REPLACE [=[    // free the uniform that's already registered if it's there already

    if (const auto it = this->m_uniforms.find (name); it != this->m_uniforms.end ()) {
	delete it->second;
    }

    // uniform found, add it to the list
    this->m_referenceUniforms.insert_or_assign (
	name, new ReferenceUniformEntry (id, name, type, reinterpret_cast<const void**> (value))
    );]=]
    [=[    this->m_referenceUniforms.insert_or_assign (
	name, FrescoScene::makeTrackedRenderUnique<ReferenceUniformEntry> (
	    FrescoScene::RenderAllocationKind::passReferenceUniform,
	    id, name, type, reinterpret_cast<const void**> (value)
	)
    );]=]
    pass_source
    "${pass_source}"
)
foreach(pass_ownership_marker IN ITEMS
    "m_shader.get ()"
    "RenderAllocationKind::shader,"
    "RenderAllocationKind::passAttribute"
    "RenderAllocationKind::copiedUniformValue"
    "RenderAllocationKind::passUniform"
    "RenderAllocationKind::passReferenceUniform")
    fresco_require_generated_patch(
        pass_source "${pass_ownership_marker}" "render-pass ownership ${pass_ownership_marker}"
    )
endforeach()
fresco_require_generated_patch_count(
    pass_source "m_shader.get \(\)" 1 "render-pass shader getter ownership"
)
fresco_require_generated_patch_count(
    pass_source "RenderAllocationKind::shader," 1 "render-pass shader allocation"
)
fresco_require_generated_patch_count(
    pass_source "RenderAllocationKind::passAttribute" 1 "render-pass attribute allocation"
)
fresco_require_generated_patch_count(
    pass_source "RenderAllocationKind::copiedUniformValue" 1 "copied uniform allocation"
)
fresco_require_generated_patch_count(
    pass_source "RenderAllocationKind::passUniform" 2 "render-pass uniform allocations"
)
fresco_require_generated_patch_count(
    pass_source "RenderAllocationKind::passReferenceUniform" 1 "reference uniform allocation"
)
string(REPLACE
    "    double currentRenderTime = fmod ("
    "    if (const auto scriptedFrame = FrescoScene::scriptedTextureAnimationFrame (&this->m_renderable.getScene (), this->m_renderable.getId ()); scriptedFrame.has_value ()) {\n\tconst auto& frames = texture->getFrames ();\n\tif (!frames.empty ()) {\n\t    const auto& frameCur = frames[std::min<std::size_t> (scriptedFrame.value (), frames.size () - 1)];\n\t    state.currentTexture = frameCur->frameNumber;\n\t    state.translation.x = frameCur->x / texture->getTextureWidth (state.currentTexture);\n\t    state.translation.y = frameCur->y / texture->getTextureHeight (state.currentTexture);\n\t    state.rotation.x = frameCur->width1 / static_cast<float> (texture->getTextureWidth (state.currentTexture));\n\t    state.rotation.y = frameCur->width2 / static_cast<float> (texture->getTextureWidth (state.currentTexture));\n\t    state.rotation.z = frameCur->height2 / static_cast<float> (texture->getTextureHeight (state.currentTexture));\n\t    state.rotation.w = frameCur->height1 / static_cast<float> (texture->getTextureHeight (state.currentTexture));\n\t}\n\treturn state;\n    }\n\n    if (!texture->isAnimated ()) {\n\treturn state;\n    }\n\n    double currentRenderTime = fmod ("
    pass_source
    "${pass_source}"
)
string(REPLACE
    "    if (texture == nullptr || !texture->isAnimated ()) {\n\treturn state;\n    }"
    "    if (texture == nullptr) {\n\treturn state;\n    }"
    pass_source
    "${pass_source}"
)
fresco_require_generated_patch(
    pass_source
    "scriptedTextureAnimationFrame"
    "scripted texture-animation frame selection"
)
fresco_require_generated_patch(
    pass_source
    "if (!texture->isAnimated ())"
    "automatic texture animation remains GIF-only"
)
string(REPLACE
    "recorder.audio16, 16"
    "recorder.audio16Left, 16"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "\"g_AudioSpectrum16Right\", recorder.audio16Left, 16"
    "\"g_AudioSpectrum16Right\", recorder.audio16Right, 16"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "recorder.audio32, 32"
    "recorder.audio32Left, 32"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "\"g_AudioSpectrum32Right\", recorder.audio32Left, 32"
    "\"g_AudioSpectrum32Right\", recorder.audio32Right, 32"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "recorder.audio64, 64"
    "recorder.audio64Left, 64"
    pass_source
    "${pass_source}"
)
string(REPLACE
    "\"g_AudioSpectrum64Right\", recorder.audio64Left, 64"
    "\"g_AudioSpectrum64Right\", recorder.audio64Right, 64"
    pass_source
    "${pass_source}"
)
foreach(audio_marker IN ITEMS
    audio16Left audio16Right audio32Left audio32Right audio64Left audio64Right)
    fresco_require_generated_patch(
        pass_source "recorder.${audio_marker}" "stereo audio uniform ${audio_marker}"
    )
endforeach()
string(REPLACE
    "if (infoLogLength > 0)"
    "if (result == GL_FALSE || infoLogLength > 0)"
    pass_source
    "${pass_source}"
)
fresco_require_generated_patch(
    pass_source
    "if (result == GL_FALSE || infoLogLength > 0)"
    "authoritative shader compile and link status"
)
string(REPLACE
    "    this->addUniform (\"g_TexelSize\", glm::vec2 (1.0 / scene.getWidth (), 1.0 / scene.getHeight ()));"
    "    this->addUniform (\"g_Screen\", glm::vec2 (scene.getWidth (), scene.getHeight ()));\n    this->addUniform (\"g_TexelSize\", glm::vec2 (1.0 / scene.getWidth (), 1.0 / scene.getHeight ()));"
    pass_source
    "${pass_source}"
)
fresco_require_generated_patch(
    pass_source
    "this->addUniform (\"g_Screen\""
    "scene-size shader uniform"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/CPass.cpp"
    pass_source
)

file(READ
    "${upstream}/src/WallpaperEngine/Render/Wallpapers/CScene.cpp"
    scene_source
)
string(REPLACE
    "#include <ranges>"
    "#include <ranges>"
    scene_source
    "${scene_source}"
)
string(REPLACE
    "#include \"CScene.h\""
    "#include \"WallpaperEngine/Render/Wallpapers/CScene.h\"\n#include \"WallpaperEngine/Scripting/ScriptableObject.h\"\n#include \"FrescoScene/RenderProgramCache.h\"\n#include \"FrescoScene/SceneObjectVisibility.h\"\n#include \"FrescoScene/SceneZoomControl.h\"\n#include \"FrescoScene/TextEffectRegistry.h\"\n#include <cstdio>\n#include <cstdlib>"
    scene_source
    "${scene_source}"
)
string(REPLACE
    "\tsLog.error (\"Failed to setup object \", object.id, \": \", e.what ());"
    "\tsLog.error (\"Failed to setup object \", object.id, \": \", e.what ());\n\tFrescoScene::recordRenderObjectSetupFailure (\n\t    static_cast<const void*> (&this->getContext ())\n\t);\n\tif (std::getenv (\"FRESCO_SCENE_TRACE_OBJECT_SETUP_ERRORS\") != nullptr) {\n\t    std::fprintf (stderr, \"object-setup-error|%d|%s\\n\", object.id, e.what ());\n\t}"
    scene_source
    "${scene_source}"
)
fresco_require_generated_patch_count(
    scene_source
    "FRESCO_SCENE_TRACE_OBJECT_SETUP_ERRORS"
    1
    "environment-gated object setup diagnostic"
)
string(REPLACE
    "    this->m_scriptEngine = std::make_unique<Scripting::ScriptEngine> (*this, context.getMediaSource ());"
    "    this->m_scriptEngine = std::make_unique<Scripting::ScriptEngine> (*this, context.getMediaSource ());\n    for (const auto& object : scene->objects) {\n\tif (object->is<Image> ()) {\n\t    const auto* image = object->as<Image> ();\n\t    for (const auto& effect : image->effects) {\n\t\tif (effect->visible != nullptr && effect->visible->value != nullptr) {\n\t\t    this->m_scriptEngine->queuePropertyScript (\n\t\t\t\"effect_visible_\" + std::to_string (object->id) + \"_\"\n\t\t\t    + std::to_string (effect->id),\n\t\t\t*effect->visible->value, object->id\n\t\t    );\n\t\t}\n\t\tif (effect->effect != nullptr) {\n\t\t    for (const auto& effectPass : effect->effect->passes) {\n\t\t\tif (!effectPass->material.has_value ()) {\n\t\t\t    continue;\n\t\t\t}\n\t\t\tfor (const auto& materialPass : effectPass->material.value ()->passes) {\n\t\t\t    for (const auto& [name, setting] : materialPass->constants) {\n\t\t\t\tstatic_cast<void> (name);\n\t\t\t\tthis->m_scriptEngine->queueEffectScript (*setting->value, object->id);\n\t\t\t    }\n\t\t\t}\n\t\t    }\n\t\t}\n\t\tfor (const auto& passOverride : effect->passOverrides) {\n\t\t    for (const auto& [name, setting] : passOverride->constants) {\n\t\t\tstatic_cast<void> (name);\n\t\t\tthis->m_scriptEngine->queueEffectScript (*setting->value, object->id);\n\t\t    }\n\t\t}\n\t    }\n\t}\n\tif (object->is<Particle> ()) {\n\t    const auto* particle = object->as<Particle> ();\n\t    const auto queueInstance = [this, objectId = object->id] (\n\t\t    const char* name, const auto& setting\n\t    ) {\n\t\tif (setting != nullptr && setting->value != nullptr) {\n\t\t    this->m_scriptEngine->queuePropertyScript (\n\t\t\t\"instance_\" + std::string (name) + \"_\"\n\t\t\t    + std::to_string (objectId),\n\t\t\t*setting->value, objectId\n\t\t    );\n\t\t}\n\t    };\n\t    queueInstance (\"enabled\", particle->instanceOverride.enabled);\n\t    queueInstance (\"alpha\", particle->instanceOverride.alpha);\n\t    queueInstance (\"size\", particle->instanceOverride.size);\n\t    queueInstance (\"lifetime\", particle->instanceOverride.lifetime);\n\t    queueInstance (\"rate\", particle->instanceOverride.rate);\n\t    queueInstance (\"speed\", particle->instanceOverride.speed);\n\t    queueInstance (\"count\", particle->instanceOverride.count);\n\t    queueInstance (\"color\", particle->instanceOverride.color);\n\t    queueInstance (\"colorn\", particle->instanceOverride.colorn);\n\t}\n    }"
    scene_source
    "${scene_source}"
)
string(REPLACE
    "    this->m_scriptEngine = std::make_unique<Scripting::ScriptEngine> (*this, context.getMediaSource ());\n    for (const auto& object : scene->objects) {"
    "    this->m_scriptEngine = std::make_unique<Scripting::ScriptEngine> (*this, context.getMediaSource ());\n    if (auto* sceneZoom = FrescoScene::pendingSceneZoom (); sceneZoom != nullptr) {\n\tthis->m_scriptEngine->queuePropertyScript (\"scene_zoom\", *sceneZoom, 0);\n    }\n    for (const auto& object : scene->objects) {"
    scene_source
    "${scene_source}"
)
string(REPLACE
    "\t}\n\tif (object->is<Particle> ()) {"
    "\t}\n\tif (object->is<Text> ()) {\n\t    for (const auto& effect : FrescoScene::textEffects (object->id)) {\n\t\tif (effect->visible != nullptr && effect->visible->value != nullptr) {\n\t\t    this->m_scriptEngine->queuePropertyScript (\n\t\t\t\"text_effect_visible_\" + std::to_string (object->id) + \"_\"\n\t\t\t    + std::to_string (effect->id),\n\t\t\t*effect->visible->value, object->id\n\t\t    );\n\t\t}\n\t\tif (effect->effect != nullptr) {\n\t\t    for (const auto& effectPass : effect->effect->passes) {\n\t\t\tif (!effectPass->material.has_value ()) {\n\t\t\t    continue;\n\t\t\t}\n\t\t\tfor (const auto& materialPass : effectPass->material.value ()->passes) {\n\t\t\t    for (const auto& [name, setting] : materialPass->constants) {\n\t\t\t\tstatic_cast<void> (name);\n\t\t\t\tthis->m_scriptEngine->queueEffectScript (*setting->value, object->id);\n\t\t\t    }\n\t\t\t}\n\t\t    }\n\t\t}\n\t\tfor (const auto& passOverride : effect->passOverrides) {\n\t\t    for (const auto& [name, setting] : passOverride->constants) {\n\t\t\tstatic_cast<void> (name);\n\t\t\tthis->m_scriptEngine->queueEffectScript (*setting->value, object->id);\n\t\t    }\n\t\t}\n\t    }\n\t}\n\tif (object->is<Particle> ()) {"
    scene_source
    "${scene_source}"
)
fresco_require_generated_patch(
    scene_source
    "queueInstance (\"colorn\""
    "effect and instance SceneScript registration"
)
fresco_require_generated_patch(
    scene_source
    "FrescoScene::textEffects"
    "text effect SceneScript registration"
)
string(REPLACE
    "    for (const auto& effect : image->effects) {"
    "    for (const auto& effect : image->effects) {\n\tif (effect == nullptr) {\n\t    continue;\n\t}"
    scene_source
    "${scene_source}"
)
string(REPLACE
    "    for (const auto& effect : FrescoScene::textEffects (object->id)) {"
    "    for (const auto& effect : FrescoScene::textEffects (object->id)) {\n\tif (effect == nullptr) {\n\t    continue;\n\t}"
    scene_source
    "${scene_source}"
)
string(REPLACE
    "if (!effectPass->material.has_value ()) {"
    "if (effectPass == nullptr || !effectPass->material.has_value ()\n\t\t\t    || effectPass->material.value () == nullptr) {"
    scene_source
    "${scene_source}"
)
string(REPLACE
    "for (const auto& materialPass : effectPass->material.value ()->passes) {\n\t\t\t    for (const auto& [name, setting] : materialPass->constants) {"
    "for (const auto& materialPass : effectPass->material.value ()->passes) {\n\t\t\t    if (materialPass == nullptr) {\n\t\t\t\tcontinue;\n\t\t\t    }\n\t\t\t    for (const auto& [name, setting] : materialPass->constants) {"
    scene_source
    "${scene_source}"
)
string(REPLACE
    "this->m_scriptEngine->queueEffectScript (*setting->value, object->id);"
    "if (setting != nullptr && setting->value != nullptr) {\n\t\t\t\t    this->m_scriptEngine->queueEffectScript (*setting->value, object->id);\n\t\t\t\t}"
    scene_source
    "${scene_source}"
)
string(REPLACE
    "for (const auto& passOverride : effect->passOverrides) {\n\t\t    for (const auto& [name, setting] : passOverride->constants) {"
    "for (const auto& passOverride : effect->passOverrides) {\n\t\t    if (passOverride == nullptr) {\n\t\t\tcontinue;\n\t\t    }\n\t\t    for (const auto& [name, setting] : passOverride->constants) {"
    scene_source
    "${scene_source}"
)
fresco_require_generated_patch(
    scene_source
    "if (effect == nullptr)"
    "null-safe effect SceneScript registration"
)
fresco_require_generated_patch(
    scene_source
    "effectPass == nullptr"
    "null-safe effect pass SceneScript registration"
)
fresco_require_generated_patch(
    scene_source
    "materialPass == nullptr"
    "null-safe effect material pass SceneScript registration"
)
fresco_require_generated_patch(
    scene_source
    "passOverride == nullptr"
    "null-safe effect override SceneScript registration"
)
fresco_require_generated_patch(
    scene_source
    "setting != nullptr && setting->value != nullptr"
    "null-safe effect setting SceneScript registration"
)
fresco_require_generated_patch(
    scene_source
    "FrescoScene::pendingSceneZoom"
    "scene zoom SceneScript registration"
)
string(REPLACE
    "\tthis->m_objectsByRenderOrder.push_back (this->m_bloomObject);"
    "\tif (this->m_bloomObject != nullptr) {\n\t    this->m_objectsByRenderOrder.push_back (this->m_bloomObject);\n\t}"
    scene_source
    "${scene_source}"
)
fresco_require_generated_patch(
    scene_source
    "if (this->m_bloomObject != nullptr)"
    "failed bloom object guard"
)
string(REPLACE
    "    // take into account any dependency first\n    for (const auto& dep : object.dependencies) {\n\t// self-dependency is possible\n\tif (dep == object.id) {\n\t    continue;\n\t}\n\n\t// add the dependency to the list if it's created\n\tauto depIt = std::ranges::find_if (this->getScene ().objects, [&dep] (const auto& o) { return o->id == dep; });\n\n\tif (depIt != this->getScene ().objects.end ()) {\n\t    this->addObjectToRenderOrder (**depIt);\n\t} else {\n\t    sLog.error (\"Cannot find dependency \", dep, \" for object \", object.id);\n\t}\n    }"
    "    const bool hoistDependencies = !object.is<Image> ()\n\t|| std::ranges::any_of (object.as<Image> ()->effects, [] (const auto& effect) {\n\t       return effect != nullptr && effect->visible != nullptr\n\t\t   && effect->visible->value != nullptr\n\t\t   && effect->visible->value->getBool ();\n\t   });\n\n    // Only visible effect passes consume their declared layer dependencies.\n    if (hoistDependencies) {\n\tfor (const auto& dep : object.dependencies) {\n\t    // self-dependency is possible\n\t    if (dep == object.id) {\n\t\tcontinue;\n\t    }\n\n\t    // add the dependency to the list if it's created\n\t    auto depIt = std::ranges::find_if (this->getScene ().objects, [&dep] (const auto& o) { return o->id == dep; });\n\n\t    if (depIt != this->getScene ().objects.end ()) {\n\t\tthis->addObjectToRenderOrder (**depIt);\n\t    } else {\n\t\tsLog.error (\"Cannot find dependency \", dep, \" for object \", object.id);\n\t    }\n\t}\n    }"
    scene_source
    "${scene_source}"
)
fresco_require_generated_patch(
    scene_source
    "const bool hoistDependencies"
    "visible effect dependency render ordering"
)
string(REPLACE
    "CScene::~CScene () {\n    // bloom object"
    "CScene::~CScene () {\n    this->m_scriptEngine->shutdown ();\n\n    // bloom object"
    scene_source
    "${scene_source}"
)
string(REPLACE
    "\tcur->render ();\n    }"
    "\t// Fresco: hidden-ancestor particle render gate.\n\tif (cur->is<Objects::CParticle> ()\n\t    && !objectVisibleWithParents (*cur)) {\n\t    continue;\n\t}\n\n\tcur->render ();\n    }"
    scene_source
    "${scene_source}"
)
fresco_require_generated_patch(
    scene_source
    "this->m_scriptEngine->shutdown ();"
    "property script shutdown before object destruction"
)
string(REPLACE
    "\tsLog.error (\"Unknown object type, creating placeholder, empty object: \", object.id);\n\trenderObject = new CObject (*this, object);"
    "\tsLog.error (\"Unknown object type, creating placeholder, empty object: \", object.id);\n\trenderObject = new WallpaperEngine::Scripting::ScriptableObject (*this, object);"
    scene_source
    "${scene_source}"
)
fresco_require_generated_patch(
    scene_source
    "new WallpaperEngine::Scripting::ScriptableObject"
    "scriptable placeholder property registration"
)
string(REPLACE
    "    renderObject = this->dispatchObjectType (object);\n\n    if (renderObject != nullptr) {"
    "    renderObject = this->dispatchObjectType (object);\n\n    if (renderObject == nullptr) {\n\tconst bool requiredAsParent = std::ranges::any_of (\n\t    this->getScene ().objects, [&object] (const auto& candidate) {\n\t\treturn candidate->parent.has_value ()\n\t\t    && *candidate->parent == object.id;\n\t    }\n\t);\n\tif (requiredAsParent) {\n\t    sLog.warning (\n\t\t\"Using a transform-only placeholder for failed parent object \",\n\t\tobject.id\n\t    );\n\t    renderObject = new WallpaperEngine::Scripting::ScriptableObject (*this, object);\n\t    renderObject->setup ();\n\t}\n    }\n\n    if (renderObject != nullptr) {"
    scene_source
    "${scene_source}"
)
string(REPLACE
    "sLog.warning ("
    "sLog.out ("
    scene_source
    "${scene_source}"
)
fresco_require_generated_patch(
    scene_source
    "Using a transform-only placeholder for failed parent object"
    "failed parent transform placeholder"
)
string(REPLACE
    "    this->getScriptEngine ().tick ();"
    "    this->getScriptEngine ().tick ();\n\n    const auto visibilityNode = [] (const CObject& object) {\n\tconst Object& model = object.getObject ();\n\treturn FrescoScene::SceneObjectVisibilityNode {\n\t    .parent = model.parent,\n\t    .visible = model.groupVisible == nullptr\n\t        || model.groupVisible->value == nullptr\n\t        || model.groupVisible->value->getBool (),\n\t    .propagatesVisibility = FrescoScene::sceneObjectTypePropagatesVisibility (\n\t\tmodel.is<Particle> (), model.is<Text> (), model.is<Sound> ()\n\t    ),\n\t};\n    };\n    const auto objectVisibleWithParents = [this, &visibilityNode] (\n\tconst CObject& object\n    ) {\n\treturn FrescoScene::sceneObjectVisibleWithAncestors (\n\t    object.getObject ().parent,\n\t    [this, &visibilityNode] (int parentId)\n\t        -> std::optional<FrescoScene::SceneObjectVisibilityNode> {\n\t\tconst CObject* parent = this->getObject (parentId);\n\t\treturn parent == nullptr\n\t	    ? std::nullopt\n\t	    : std::optional (visibilityNode (*parent));\n\t    }\n\t);\n    };"
    scene_source
    "${scene_source}"
)
string(REPLACE
    "\tconst Objects::CImage* image = cur->as<Objects::CImage> ();"
    "\tconst Objects::CImage* image = cur->as<Objects::CImage> ();\n\t// Fresco: hidden-ancestor dynamic texture update gate.\n\tif (!objectVisibleWithParents (*cur)\n\t    || !image->getImage ().visible->value->getBool ()) {\n\t    continue;\n\t}"
    scene_source
    "${scene_source}"
)
fresco_require_generated_patch(
    scene_source
    "const auto objectVisibleWithParents"
    "dynamic ancestor visibility traversal"
)
fresco_require_generated_patch_count(
    scene_source
    "Fresco: hidden-ancestor dynamic texture update gate"
    1
    "hidden subtree dynamic texture update suppression"
)
fresco_require_generated_patch_count(
    scene_source
    "Fresco: hidden-ancestor particle render gate"
    1
    "hidden subtree particle render suppression"
)
fresco_require_generated_patch(
    scene_source
    "#include \"WallpaperEngine/Render/Wallpapers/CScene.h\""
    "generated scene implementation include path"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/CScene.cpp"
    scene_source
)

file(READ
    "${upstream}/src/WallpaperEngine/Render/Objects/CParticle.cpp"
    particle_source
)
file(READ
    "${upstream}/src/WallpaperEngine/Render/Objects/CParticle.h"
    particle_header
)
string(REPLACE
    "#include \"CRenderable.h\""
    "#include \"WallpaperEngine/Render/Objects/CRenderable.h\""
    particle_header
    "${particle_header}"
)
string(REPLACE
    "#include <functional>"
    "#include \"FrescoScene/ParticleRuntimeEvidence.h\"\n\n#include <functional>"
    particle_header
    "${particle_header}"
)
string(REPLACE
    "    bool alive { false };"
    "    bool alive { false };\n    uint64_t serial { 0 };"
    particle_header
    "${particle_header}"
)
string(REPLACE
    "    [[nodiscard]] const Particle& getParticle () const;"
    "    [[nodiscard]] const Particle& getParticle () const;\n    [[nodiscard]] bool hasLiveParticles () const;\n    [[nodiscard]] FrescoScene::ParticleSystemRuntimeEvidence runtimeEvidence () const;"
    particle_header
    "${particle_header}"
)
string(REPLACE
    "    std::mt19937 m_rng;"
    "    std::mt19937 m_rng;\n    uint64_t m_nextParticleSerial { 1 };\n    bool m_lifecycleKnown { false };\n    bool m_finiteLifecycle { false };\n    std::size_t m_simulationUpdates { 0 };\n    std::size_t m_catchUpFrames { 0 };\n    double m_requestedSeconds { 0.0 };\n    double m_simulatedSeconds { 0.0 };\n    double m_droppedSeconds { 0.0 };\n    double m_maximumRequestedSeconds { 0.0 };\n    double m_maximumSimulatedSeconds { 0.0 };\n    std::size_t m_peakParticleCount { 0 };\n    std::size_t m_poolResizes { 0 };\n    std::size_t m_resourceInitializations { 0 };"
    particle_header
    "${particle_header}"
)
foreach(particle_header_marker IN ITEMS
    "#include \"WallpaperEngine/Render/Objects/CRenderable.h\""
    "uint64_t serial { 0 };"
    "bool hasLiveParticles () const;"
    "runtimeEvidence () const;"
    "uint64_t m_nextParticleSerial { 1 };")
    fresco_require_generated_patch(
        particle_header
        "${particle_header_marker}"
        "particle child lifecycle header ${particle_header_marker}"
    )
endforeach()
file(MAKE_DIRECTORY
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render/Objects"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render/Objects/CParticle.h"
    particle_header
)
string(REPLACE
    "#include \"CParticle.h\""
    "#include \"WallpaperEngine/Render/Objects/CParticle.h\"\n#include \"FrescoScene/Camera2DControl.h\"\n#include \"FrescoScene/ParticleChildRuntime.h\"\n#include \"FrescoScene/ParticleCompatibility.h\"\n#include \"FrescoScene/SceneObjectModelTransform.h\""
    particle_source
    "${particle_source}"
)
string(REPLACE
    "#include <GL/glew.h>"
    "#include <GL/glew.h>\n#include <bit>\n#include <cstdint>"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "getScene ().getCamera ().getProjection ()"
    "FrescoScene::applyCamera2DControl (getScene (), getScene ().getCamera ().getProjection ())"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "    std::random_device rd;\n    m_rng.seed (rd ());"
    "    m_rng.seed (static_cast<std::uint32_t> (m_particle.id));"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "    // Use wallpaper's specified count, or default if maxCount is 0\n    m_maxParticles = (adjustedMaxCount > 0) ? adjustedMaxCount : DEFAULT_MAX_PARTICLES;"
    "    // A zero instance count disables emission. Only an authored zero maxCount uses the fallback.\n    m_maxParticles = particle.maxCount > 0 ? adjustedMaxCount : DEFAULT_MAX_PARTICLES;"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "\tvel.y = -vel.y;\n\tp.velocity += vel;"
    "\tvel.y = -vel.y;\n\tif ((m_particle.flags & 4) == 0) {\n\t    vel.z = 0.0f;\n\t}\n\tp.velocity += vel;"
    particle_source
    "${particle_source}"
)
fresco_require_generated_patch(
    particle_source
    "vel.z = 0.0f;"
    "orthographic particle velocity projection"
)
fresco_require_generated_patch(
    particle_source
    "A zero instance count disables emission."
    "particle zero-count instance override"
)
string(REPLACE
    "void CParticle::update (float dt) {"
    [=[void CParticle::update (float dt) {
    const float countMultiplier = std::max (
	0.0f, m_particle.instanceOverride.count->value->getFloat ()
    );
    const uint32_t desiredMaxParticles = m_particle.maxCount > 0
	? static_cast<uint32_t> (m_particle.maxCount * countMultiplier)
	: DEFAULT_MAX_PARTICLES;
    if (desiredMaxParticles != m_maxParticles) {
	++m_poolResizes;
	m_maxParticles = desiredMaxParticles;
	m_particleCount = std::min (m_particleCount, m_maxParticles);
	m_particles.resize (m_maxParticles);
	if (m_useRopeRenderer) {
	    const int subdivision = std::max (1, m_ropeSubdivision);
	    const int maxSubSegments = std::max (
		1, static_cast<int> (m_maxParticles) - 1
	    ) * subdivision;
	    m_vertices.resize (maxSubSegments * 4 * ROPE_FLOATS_PER_VERTEX);
	    m_indices.resize (maxSubSegments * 6);
	} else {
	    m_vertices.resize (m_maxParticles * 4 * SPRITE_FLOATS_PER_VERTEX);
	    m_indices.resize (m_maxParticles * 6);
	}
    }]=]
    particle_source
    "${particle_source}"
)
fresco_require_generated_patch(
    particle_source
    "const uint32_t desiredMaxParticles"
    "dynamic particle count instance override"
)
string(REPLACE [=[    // Detect resolution changes and recalculate transformed origin
    float screenWidth = static_cast<float> (getScene ().getWidth ());
    float screenHeight = static_cast<float> (getScene ().getHeight ());

    if (screenWidth != m_lastScreenWidth || screenHeight != m_lastScreenHeight) {
	// Resolution changed - recalculate transformed origin
	glm::vec3 origin = m_particle.origin->value->getVec3 ();
	origin.x -= screenWidth / 2.0f;
	origin.y = screenHeight / 2.0f - origin.y;
	m_transformedOrigin = origin;]=]
    [=[    // Detect camera or composed-origin changes and recalculate transformed origin
    float screenWidth = getScene ().getCamera ().getWidth ();
    float screenHeight = getScene ().getCamera ().getHeight ();
    glm::vec3 origin = FrescoScene::resolveSceneObjectTransform (
	getScene (), m_particle
    ).origin;
    origin.x -= screenWidth / 2.0f;
    origin.y = screenHeight / 2.0f - origin.y;

    if (screenWidth != m_lastScreenWidth || screenHeight != m_lastScreenHeight
        || origin != m_transformedOrigin) {
	m_transformedOrigin = origin;]=]
    particle_source
    "${particle_source}"
)
string(REPLACE
    "    glm::vec3 origin = m_particle.origin->value->getVec3 ();"
    "    glm::vec3 origin = FrescoScene::resolveSceneObjectTransform (\n\tgetScene (), m_particle\n    ).origin;"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "    glm::vec3 scale = m_particle.scale->value->getVec3 ();\n    glm::vec3 angles = m_particle.angles->value->getVec3 ();"
    "    const auto transform = FrescoScene::resolveSceneObjectTransform (\n\tgetScene (), m_particle\n    );\n    glm::vec3 scale = transform.scale;\n    glm::vec3 angles = { 0.0f, 0.0f, transform.angle };"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "static_cast<std::mt19937::result_type> (reinterpret_cast<uintptr_t> (&p))"
    "static_cast<std::mt19937::result_type> (p.serial)"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "    setupEmitters ();\n    setupInitializers ();"
    "    for (const auto& child : m_particle.children) {\n\tconst auto contract = FrescoScene::particleChildContract (\n\t    child.type, child.particleFile, child.maxCount\n\t);\n\tif (!contract.diagnostic.empty ()) {\n\t    sLog.out (contract.diagnostic);\n\t}\n    }\n    FrescoScene::setupParticleChildren (*this);\n\n    setupEmitters ();\n    setupInitializers ();"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "    setupPass ();\n\n    // Setup control points (max 8)"
    [=[    setupPass ();

    const auto nonnullInitializers = std::ranges::count_if (
	m_particle.initializers, [] (const auto& value) { return value != nullptr; }
    );
    const auto nonnullOperators = std::ranges::count_if (
	m_particle.operators, [] (const auto& value) { return value != nullptr; }
    );
    const bool finiteEmitters = !m_particle.emitters.empty ()
	&& std::ranges::all_of (m_particle.emitters, [] (const auto& emitter) {
	    return (emitter.name == "boxrandom" || emitter.name == "sphererandom")
		&& emitter.rate <= 0.0f && emitter.instantaneous > 0
		&& (emitter.flags & 4) == 0;
	});
    const bool knownRenderers = std::ranges::all_of (
	m_particle.renderers, [] (const auto& renderer) {
	    return renderer.name == "sprite" || renderer.name == "rope"
		|| renderer.name == "ropetrail" || renderer.name == "spritetrail";
	}
    );
    const bool supportedEmitters = !m_particle.emitters.empty ()
	&& std::ranges::all_of (m_particle.emitters, [] (const auto& emitter) {
	    return (emitter.name == "boxrandom" || emitter.name == "sphererandom")
		&& (emitter.flags & 4) == 0;
	});
    m_lifecycleKnown = supportedEmitters
	&& m_emitters.size () == m_particle.emitters.size ()
	&& m_initializers.size () == nonnullInitializers
	&& m_operators.size () == nonnullOperators && knownRenderers;
    m_finiteLifecycle = m_lifecycleKnown && finiteEmitters
	&& m_particle.children.empty ();
    ++m_resourceInitializations;

    // Setup control points (max 8)]=]
    particle_source
    "${particle_source}"
)
string(REPLACE
    "CParticle::~CParticle () {\n    delete m_pass;"
    "CParticle::~CParticle () {\n    FrescoScene::destroyParticleChildren (*this);\n    delete m_pass;"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "\treturn;\n    }\n\n    // Update particles"
    "\tFrescoScene::renderParticleChildren (*this);\n\treturn;\n    }\n\n    // Update particles"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "\t}\n    }\n}\n\nvoid CParticle::update (float dt)"
    "\t}\n    }\n    FrescoScene::renderParticleChildren (*this);\n}\n\nvoid CParticle::update (float dt)"
    particle_source
    "${particle_source}"
)
string(REPLACE
    [=[    if (dt > 0.0f) {
	// Cap dt to prevent simulation instability
	// Also provides more consistent behavior across different FPS
	dt = std::min (dt, 0.1f);
	update (dt);
    }]=]
    [=[    if (dt > 0.0f) {
	const float requested = dt;
	const float simulated = std::min (requested, 0.1f);
	m_requestedSeconds += requested;
	m_simulatedSeconds += simulated;
	m_droppedSeconds += requested - simulated;
	m_maximumRequestedSeconds = std::max<double> (
	    m_maximumRequestedSeconds, requested
	);
	m_maximumSimulatedSeconds = std::max<double> (
	    m_maximumSimulatedSeconds, simulated
	);
	if (requested > simulated) {
	    ++m_catchUpFrames;
	}
	update (simulated);
	++m_simulationUpdates;
    }]=]
    particle_source
    "${particle_source}"
)
string(REPLACE
    "    m_particleCount = writeIdx;\n}\n\nconst Particle& CParticle::getParticle () const { return m_particle; }"
    "    m_particleCount = writeIdx;\n    FrescoScene::updateParticleChildren (*this, m_particles, m_particleCount);\n}\n\nconst Particle& CParticle::getParticle () const { return m_particle; }\n\nbool CParticle::hasLiveParticles () const { return m_particleCount > 0; }"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "    // Update particle age"
    "    m_peakParticleCount = std::max<std::size_t> (m_peakParticleCount, m_particleCount);\n\n    // Update particle age"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "bool CParticle::hasLiveParticles () const { return m_particleCount > 0; }"
    [=[bool CParticle::hasLiveParticles () const { return m_particleCount > 0; }

FrescoScene::ParticleSystemRuntimeEvidence CParticle::runtimeEvidence () const {
    std::uint64_t hash = 1469598103934665603ULL;
    const auto mix = [&hash] (std::uint64_t value) {
	hash ^= value;
	hash *= 1099511628211ULL;
    };
    mix (static_cast<std::uint32_t> (m_particle.id));
    for (std::uint32_t index = 0; index < m_particleCount; ++index) {
	const auto& particle = m_particles[index];
	mix (particle.serial);
	for (const float value : {
		 particle.position.x, particle.position.y, particle.position.z,
		 particle.velocity.x, particle.velocity.y, particle.velocity.z,
		 particle.age, particle.lifetime, particle.size, particle.alpha,
	     }) {
	    mix (std::bit_cast<std::uint32_t> (value));
	}
    }
    const bool emitted = m_nextParticleSerial > 1;
    return {
	.objectId = m_particle.id,
	.seed = static_cast<std::uint32_t> (m_particle.id),
	.lifecycleKnown = m_lifecycleKnown,
	.finiteLifecycle = m_finiteLifecycle,
	.continuousRequired = !m_finiteLifecycle || !emitted || m_particleCount > 0,
	.quiescent = m_finiteLifecycle && emitted && m_particleCount == 0,
	.updates = m_simulationUpdates,
	.catchUpFrames = m_catchUpFrames,
	.requestedMilliseconds = m_requestedSeconds * 1000.0,
	.simulatedMilliseconds = m_simulatedSeconds * 1000.0,
	.droppedMilliseconds = m_droppedSeconds * 1000.0,
	.maximumRequestedMilliseconds = m_maximumRequestedSeconds * 1000.0,
	.maximumSimulatedMilliseconds = m_maximumSimulatedSeconds * 1000.0,
	.emitted = static_cast<std::size_t> (m_nextParticleSerial - 1),
	.live = m_particleCount,
	.peakLive = m_peakParticleCount,
	.poolCapacity = m_particles.size (),
	.poolResizes = m_poolResizes,
	.resourceInitializations = m_resourceInitializations,
	.stateHash = hash,
    };
}]=]
    particle_source
    "${particle_source}"
)
string(REPLACE
    "\t    p.alive = true;\n\t    p.frame = -1.0f;"
    "\t    p.alive = true;\n\t    p.serial = m_nextParticleSerial++;\n\t    p.frame = -1.0f;"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "\t\tp.alive = true;\n\t\tp.frame = -1.0f;"
    "\t\tp.alive = true;\n\t\tp.serial = m_nextParticleSerial++;\n\t\tp.frame = -1.0f;"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "    for (const auto& emitter : m_particle.emitters) {\n\tEmitterFunc func;"
    "    for (const auto& emitter : m_particle.emitters) {\n\tconst auto audio = FrescoScene::particleAudioFactor (\n\t    this->getScene ().getAudioContext ().getRecorder (),\n\t    FrescoScene::ParticleAudioConfiguration {\n\t\t.mode = emitter.audioProcessingMode,\n\t\t.lowerBound = emitter.audioProcessingBounds.x,\n\t\t.upperBound = emitter.audioProcessingBounds.y,\n\t\t.exponent = emitter.audioProcessingExponent,\n\t\t.frequencyStart = emitter.audioProcessingFrequencyStart,\n\t\t.frequencyEnd = emitter.audioProcessingFrequencyEnd,\n\t    }\n\t);\n\tif (!audio.supported) {\n\t    sLog.error (audio.diagnostic);\n\t}\n\n\tEmitterFunc func;"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "\t    // TODO: Audio processing (audioProcessingMode, audioProcessingBounds, etc.)"
    "\t    const auto audio = FrescoScene::particleAudioFactor (\n\t\tthis->getScene ().getAudioContext ().getRecorder (),\n\t\tFrescoScene::ParticleAudioConfiguration {\n\t\t    .mode = emitter.audioProcessingMode,\n\t\t    .lowerBound = emitter.audioProcessingBounds.x,\n\t\t    .upperBound = emitter.audioProcessingBounds.y,\n\t\t    .exponent = emitter.audioProcessingExponent,\n\t\t    .frequencyStart = emitter.audioProcessingFrequencyStart,\n\t\t    .frequencyEnd = emitter.audioProcessingFrequencyEnd,\n\t\t}\n\t    );"
    particle_source
    "${particle_source}"
)
string(REPLACE
    "\t    if (emitter.rate > 0.0f) {\n\t\temissionTimer += dt * rate;"
    "\t    if (emitter.rate > 0.0f) {\n\t\temissionTimer += dt * rate * audio.factor;"
    particle_source
    "${particle_source}"
)
fresco_require_generated_patch(
    particle_source
    "#include \"FrescoScene/ParticleCompatibility.h\""
    "particle compatibility include"
)
fresco_require_generated_patch(
    particle_source
    "FrescoScene::resolveSceneObjectTransform"
    "particle parent transform composition"
)
fresco_require_generated_patch(
    particle_source
    "static_cast<std::mt19937::result_type> (p.serial)"
    "stable random-frame particle selection"
)
foreach(particle_child_marker IN ITEMS
    "setupParticleChildren (*this)"
    "updateParticleChildren (*this, m_particles, m_particleCount)"
    "renderParticleChildren (*this)"
    "destroyParticleChildren (*this)"
    "p.serial = m_nextParticleSerial++"
    "bool CParticle::hasLiveParticles () const"
    "CParticle::runtimeEvidence () const")
    fresco_require_generated_patch(
        particle_source
        "${particle_child_marker}"
        "particle child lifecycle ${particle_child_marker}"
    )
endforeach()
fresco_require_generated_patch(
    particle_source
    "m_droppedSeconds += requested - simulated;"
    "particle requested/simulated clock evidence"
)
fresco_require_generated_patch(
    particle_source
    "origin != m_transformedOrigin"
    "dynamic particle-system origin tracking"
)
fresco_require_generated_patch(
    particle_source
    "m_rng.seed (static_cast<std::uint32_t> (m_particle.id));"
    "deterministic particle simulation seed"
)
fresco_require_generated_patch(
    particle_source
    "particleChildContract"
    "particle child compatibility diagnostic"
)
fresco_require_generated_patch(
    particle_source
    "sLog.error (audio.diagnostic)"
    "particle audio compatibility diagnostic"
)
fresco_require_generated_patch(
    particle_source
    ".mode = emitter.audioProcessingMode"
    "particle emitter mode-3 audio processing"
)
fresco_require_generated_patch(
    particle_source
    "emissionTimer += dt * rate * audio.factor;"
    "particle emitter audio response factor"
)
fresco_require_generated_patch(
    particle_source
    "FrescoScene::applyCamera2DControl"
    "2D camera particle projection"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/CParticle.cpp"
    particle_source
)

file(READ
    "${upstream}/src/WallpaperEngine/FileSystem/Adapters/Virtual.cpp"
    virtual_adapter_source
)
string(REPLACE
    "#include \"Virtual.h\""
    "#include \"WallpaperEngine/FileSystem/Adapters/Virtual.h\""
    virtual_adapter_source
    "${virtual_adapter_source}"
)
string(REPLACE
    "    return file->second;"
    "    file->second->clear ();\n    file->second->seekg (0, std::ios_base::beg);\n    return file->second;"
    virtual_adapter_source
    "${virtual_adapter_source}"
)
fresco_require_generated_patch(
    virtual_adapter_source
    "file->second->seekg (0, std::ios_base::beg);"
    "repeatable virtual-file reads"
)
fresco_require_generated_patch(
    virtual_adapter_source
    "#include \"WallpaperEngine/FileSystem/Adapters/Virtual.h\""
    "generated virtual-adapter include path"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/Virtual.cpp"
    virtual_adapter_source
)

file(READ
    "${upstream}/src/WallpaperEngine/Data/Builders/ColorBuilder.cpp"
    color_builder_source
)
string(REPLACE
    "#include \"ColorBuilder.h\"\n#include \"VectorBuilder.h\""
    "#include \"WallpaperEngine/Data/Builders/ColorBuilder.h\"\n#include \"WallpaperEngine/Data/Builders/VectorBuilder.h\""
    color_builder_source
    "${color_builder_source}"
)
set(color_builder_integer_before [=[	const auto final = vectorSize == 3 ? glm::ivec4 (VectorBuilder::parse<glm::ivec3> (copy), alpha * 255)
					   : VectorBuilder::parse<glm::ivec4> (copy);

	return { final.r / 255.0f, final.g / 255.0f, final.b / 255.0f, final.a / 255.0f };]=])
set(color_builder_integer_after [=[	const auto final = vectorSize == 3 ? glm::ivec4 (VectorBuilder::parse<glm::ivec3> (copy), alpha * 255)
					   : VectorBuilder::parse<glm::ivec4> (copy);
	const bool normalized = final.r >= 0 && final.r <= 1 && final.g >= 0 && final.g <= 1 && final.b >= 0
	    && final.b <= 1 && (vectorSize == 3 || (final.a >= 0 && final.a <= 1));
	if (normalized) {
	    return { static_cast<float> (final.r), static_cast<float> (final.g), static_cast<float> (final.b),
		     vectorSize == 3 ? alpha : static_cast<float> (final.a) };
	}

	return { final.r / 255.0f, final.g / 255.0f, final.b / 255.0f, final.a / 255.0f };]=])
string(REPLACE
    "${color_builder_integer_before}"
    "${color_builder_integer_after}"
    color_builder_source
    "${color_builder_source}"
)
fresco_require_generated_patch(
    color_builder_source
    "const bool normalized"
    "normalized integer color parsing"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/ColorBuilder.cpp"
    color_builder_source
)

file(READ
    "${upstream}/src/WallpaperEngine/Data/Parsers/DynamicValueParser.cpp"
    dynamic_value_parser_source
)
string(REPLACE
    "#include \"DynamicValueParser.h\""
    "#include \"DynamicValueParser.h\"\n#include \"FrescoScene/DynamicValueAnimation.h\""
    dynamic_value_parser_source
    "${dynamic_value_parser_source}"
)
string(REPLACE
    "    auto value = std::make_unique<DynamicValue> ();"
    "    const auto animation = data.is_object () ? data.optional (\"animation\") : std::nullopt;\n    auto value = FrescoScene::makeDynamicValue (animation.has_value () ? &animation.value () : nullptr);"
    dynamic_value_parser_source
    "${dynamic_value_parser_source}"
)
fresco_require_generated_patch(
    dynamic_value_parser_source
    "FrescoScene::makeDynamicValue"
    "dynamic-value animation ownership"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/DynamicValueParser.cpp"
    dynamic_value_parser_source
)

file(READ
    "${upstream}/src/WallpaperEngine/Render/CTexture.h"
    video_texture_header
)
string(REPLACE
    "#include \"Helpers/ContextAware.h\""
    "#include \"WallpaperEngine/Render/Helpers/ContextAware.h\""
    video_texture_header
    "${video_texture_header}"
)
string(REPLACE
    "#include \"TextureProvider.h\""
    "#include \"WallpaperEngine/Render/TextureProvider.h\""
    video_texture_header
    "${video_texture_header}"
)
string(REPLACE
    "    bool isReady () const override;"
    "    bool isReady () const override;\n    [[nodiscard]] GLPlayer* getVideoPlayer () const;\n    [[nodiscard]] bool isVideoTexture () const;"
    video_texture_header
    "${video_texture_header}"
)
fresco_require_generated_patch(
    video_texture_header
    "getVideoPlayer"
    "video texture player control access"
)
file(MAKE_DIRECTORY
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Render/CTexture.h"
    video_texture_header
)

file(READ
    "${upstream}/src/WallpaperEngine/Render/CTexture.cpp"
    video_texture_source
)
string(REPLACE
    "#include \"CTexture.h\""
    "#include \"WallpaperEngine/Render/CTexture.h\""
    video_texture_source
    "${video_texture_source}"
)
string(REPLACE
    "#include \"RenderContext.h\""
    "#include \"WallpaperEngine/Render/RenderContext.h\""
    video_texture_source
    "${video_texture_source}"
)
string(APPEND video_texture_source [=[

WallpaperEngine::VideoPlayback::MPV::GLPlayer* CTexture::getVideoPlayer () const {
    return this->m_player.get ();
}

bool CTexture::isVideoTexture () const { return this->m_player != nullptr; }
]=])
fresco_require_generated_patch(
    video_texture_source
    "CTexture::getVideoPlayer"
    "video texture player control implementation"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/CTexture.cpp"
    video_texture_source
)

file(READ
    "${upstream}/src/WallpaperEngine/Render/FBOProvider.cpp"
    fbo_provider_source
)
string(REPLACE
    "#include \"FBOProvider.h\""
    "#include \"WallpaperEngine/Render/FBOProvider.h\"\n#include \"FrescoScene/RenderAllocationEvidence.h\""
    fbo_provider_source
    "${fbo_provider_source}"
)
set(effect_fbo_create_before [=[std::shared_ptr<CFBO> FBOProvider::create (const FBO& base, uint32_t flags, const glm::vec2 size) {
    return this->m_fbos[base.name] = std::make_shared<CFBO> (
	       base.name,
	       // TODO: PROPERLY DETERMINE FBO FORMAT BASED ON THE STRING
	       TextureFormat_ARGB8888, flags, base.scale, size.x / base.scale, size.y / base.scale, size.x / base.scale,
	       size.y / base.scale
	   );
}]=])
set(effect_fbo_create_after [=[std::shared_ptr<CFBO> FBOProvider::create (const FBO& base, uint32_t flags, const glm::vec2 size) {
    auto intermediate = std::shared_ptr<CFBO> (
	new CFBO (
	    base.name,
	    // TODO: PROPERLY DETERMINE FBO FORMAT BASED ON THE STRING
	    TextureFormat_ARGB8888, flags, base.scale, size.x / base.scale,
	    size.y / base.scale, size.x / base.scale, size.y / base.scale
	),
	[] (CFBO* value) noexcept {
	    delete value;
	    FrescoScene::recordRenderDeallocation (
		FrescoScene::RenderAllocationKind::intermediateFramebuffer
	    );
	    FrescoScene::recordRenderDeallocation (
		FrescoScene::RenderAllocationKind::intermediateTexture
	    );
	}
    );
    FrescoScene::recordRenderAllocation (
	FrescoScene::RenderAllocationKind::intermediateFramebuffer
    );
    FrescoScene::recordRenderAllocation (
	FrescoScene::RenderAllocationKind::intermediateTexture
    );
    return this->m_fbos[base.name] = std::move (intermediate);
}]=])
string(REPLACE
    "${effect_fbo_create_before}"
    "${effect_fbo_create_after}"
    fbo_provider_source
    "${fbo_provider_source}"
)
fresco_require_generated_patch_count(
    fbo_provider_source
    "RenderAllocationKind::intermediateFramebuffer"
    2
    "physical effect intermediate framebuffer lifetime evidence"
)
fresco_require_generated_patch_count(
    fbo_provider_source
    "RenderAllocationKind::intermediateTexture"
    2
    "physical effect intermediate texture lifetime evidence"
)
fresco_write_generated(
    "${CMAKE_CURRENT_BINARY_DIR}/generated/FBOProvider.cpp"
    fbo_provider_source
)

include(${CMAKE_CURRENT_SOURCE_DIR}/PuppetIntegration.cmake)
