set(fresco_scene_audio_sources
    src/AudioContext.cpp
    src/AVAudioPlayerBackend.mm
)
add_library(fresco-scene-audio STATIC ${fresco_scene_audio_sources})
set_source_files_properties(src/AVAudioPlayerBackend.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_include_directories(fresco-scene-audio PUBLIC compat)
target_link_libraries(fresco-scene-audio PUBLIC
    "-framework AVFAudio" "-framework Foundation")

set(fresco_scene_media_sources
    src/MediaArtwork.mm
    src/MediaPlaybackClock.cpp
    src/MediaSession.cpp
    src/MediaVideoDecoder.mm
)
add_library(fresco-scene-media STATIC ${fresco_scene_media_sources})
target_include_directories(fresco-scene-media PUBLIC include)
target_compile_options(fresco-scene-media PRIVATE
    -Wall -Wextra -Werror -Wpedantic
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc;-Wno-deprecated-declarations>)
target_link_libraries(fresco-scene-media PUBLIC
    "-framework AVFoundation"
    "-framework CoreGraphics"
    "-framework CoreMedia"
    "-framework CoreVideo"
    "-framework Foundation"
    "-framework ImageIO"
)

set(fresco_scene_particle_compatibility_sources
    src/ParticleCompatibility.cpp)
add_library(fresco-scene-particle-compatibility STATIC
    ${fresco_scene_particle_compatibility_sources})
target_include_directories(fresco-scene-particle-compatibility PUBLIC
    include compat)
target_compile_options(fresco-scene-particle-compatibility PRIVATE
    -Wall -Wextra -Werror -Wpedantic)

set(fresco_scene_scheduler_sources
    src/FrameScheduler.cpp
    src/RendererClock.cpp
    src/RuntimeFrameCoordinator.cpp
    src/SessionActivityGate.cpp)
set(fresco_scene_change_index_sources
    src/ChangeIndex.cpp)
set(fresco_scene_evidence_sources
    src/EffectRenderEvidence.cpp
    src/PuppetRenderEvidence.cpp)
set(fresco_scene_script_system_sources
    src/DynamicValueAnimation.cpp
    src/SceneEventCompatibility.cpp
    src/SceneAnimationLayerSemanticCapability.cpp
    src/SceneScript2DCapability.cpp
    src/SceneScriptLayerGraph.cpp
    src/SceneScriptQuickJS.cpp
    src/SceneScriptStorage.cpp
    src/SceneScriptStoragePool.cpp
    src/ScriptableObject.cpp
    src/SceneScriptCompatibility.cpp
    src/SharedScriptDependency.cpp
    src/SceneScriptEngine.cpp
    src/TextureAnimationScript.cpp)
set(fresco_scene_audio_system_sources
    src/CSound.cpp
    src/SceneAudioVector.cpp
    src/SceneSoundCompatibility.cpp
    src/SoundScriptBridge.cpp)
set(fresco_scene_media_system_sources
    src/GLPlayerVideoTextureControl.cpp
    src/MediaTexturePlayer.mm
    src/RuntimeMediaSource.cpp
    src/SceneVideoTextureControlProvider.cpp
    src/VideoTextureControl.cpp)
set(fresco_scene_particle_system_sources
    src/ParticleBlueprintAsset.cpp
    src/ParticleBlueprintCache.cpp
    src/ParticleChildRuntime.cpp)
set(fresco_scene_puppet_system_sources
    src/PuppetModel.cpp
    src/PuppetRuntimeMesh.cpp
    src/PuppetSecondaryMotion.cpp
    src/PuppetLayerSemantics.cpp)
set(fresco_scene_text_effect_system_sources
    src/MacSystemFontResolver.mm
    src/TextEffectChainDecision.cpp
    src/TextEffectRenderer.cpp
    src/TextCodepoints.cpp
    src/TextEffectRegistry.cpp
    src/TextRasterSize.cpp
    src/TextWidthLimit.cpp)
set(fresco_scene_effect_system_sources
    src/Camera2DControl.cpp
    src/OpenGLStencilStateAPI.cpp
    src/PassthroughLayerSemantics.cpp
    src/ProceduralEffectCompositing.cpp
    src/SceneZoomControl.cpp
    src/ScopedStencilState.cpp)
set(fresco_scene_we_import_sources
    ${upstream}/src/WallpaperEngine/Logging/Log.cpp
    ${upstream}/src/WallpaperEngine/Assets/AssetLoadException.cpp
    ${upstream}/src/WallpaperEngine/Assets/AssetLocator.cpp
    ${upstream}/src/WallpaperEngine/FileSystem/Container.cpp
    ${upstream}/src/WallpaperEngine/FileSystem/Adapters/Directory.cpp
    ${upstream}/src/WallpaperEngine/FileSystem/Adapters/Package.cpp
    ${upstream}/src/WallpaperEngine/Media/MediaSource.cpp
    ${upstream}/src/WallpaperEngine/Input/InputContext.cpp
    ${upstream}/src/WallpaperEngine/Data/Model/DynamicValue.cpp
    ${upstream}/src/WallpaperEngine/Data/Utils/BinaryReader.cpp
    ${upstream}/src/WallpaperEngine/Data/Parsers/EffectParser.cpp
    ${upstream}/src/WallpaperEngine/Data/Parsers/ModelParser.cpp
    ${upstream}/src/WallpaperEngine/Data/Parsers/PackageParser.cpp
    ${upstream}/src/WallpaperEngine/Data/Parsers/ProjectParser.cpp
    ${upstream}/src/WallpaperEngine/Data/Parsers/PropertyParser.cpp
    ${upstream}/src/WallpaperEngine/Data/Parsers/ShaderConstantParser.cpp
    ${upstream}/src/WallpaperEngine/Data/Parsers/TextureParser.cpp
    ${upstream}/src/WallpaperEngine/Data/Parsers/UserSettingParser.cpp
    ${upstream}/src/WallpaperEngine/Data/Builders/VectorBuilder.cpp
    ${upstream}/src/WallpaperEngine/Maths.cpp)
set(fresco_scene_we_generated_sources
    ${CMAKE_CURRENT_BINARY_DIR}/generated/Virtual.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/FBOProvider.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/CTexture.cpp
    ${wallpaper_renderer_source}
    ${CMAKE_CURRENT_BINARY_DIR}/generated/CParticle.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/CText.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/CPass.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/Shader.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/ShaderUnit.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/GLSLContext.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/CScene.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/JSON.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/DynamicValueParser.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/MaterialParser.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/ObjectParser.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/WallpaperParser.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/ColorBuilder.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/generated/CImage.cpp)
set(fresco_scene_legacy_gl_sources
    ${upstream}/src/WallpaperEngine/Render/Drivers/VideoDriver.cpp
    ${upstream}/src/WallpaperEngine/Render/Drivers/Output/Output.cpp
    ${upstream}/src/WallpaperEngine/Render/RenderContext.cpp
    ${upstream}/src/WallpaperEngine/Render/Camera.cpp
    ${upstream}/src/WallpaperEngine/Render/Helpers/ContextAware.cpp
    ${upstream}/src/WallpaperEngine/Render/CFBO.cpp
    ${upstream}/src/WallpaperEngine/Render/CObject.cpp
    ${upstream}/src/WallpaperEngine/Render/WallpaperState.cpp
    ${upstream}/src/WallpaperEngine/Render/Objects/CRenderable.cpp
    ${upstream}/src/WallpaperEngine/Render/Shaders/Variables/ShaderVariable.cpp
    ${upstream}/src/WallpaperEngine/Render/Shaders/Variables/ShaderVariableFloat.cpp
    ${upstream}/src/WallpaperEngine/Render/Shaders/Variables/ShaderVariableInteger.cpp
    ${upstream}/src/WallpaperEngine/Render/Shaders/Variables/ShaderVariableVector2.cpp
    ${upstream}/src/WallpaperEngine/Render/Shaders/Variables/ShaderVariableVector3.cpp
    ${upstream}/src/WallpaperEngine/Render/Shaders/Variables/ShaderVariableVector4.cpp
    src/TextureCache.cpp
    src/RenderProgramCache.cpp
    src/ShaderTranslationCache.cpp)

set(fresco_scene_gpl_private_includes
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_BINARY_DIR}/generated/include
    ${CMAKE_CURRENT_SOURCE_DIR}/compat
    ${upstream}/src
    ${upstream}/src/WallpaperEngine/Data/Parsers
    ${upstream}/src/WallpaperEngine/Render/Objects/Effects
    ${upstream}/src/WallpaperEngine/Render/Shaders
    ${upstream}/src/External/json/include
    ${upstream}/src/External/stb
    ${upstream}/src/External/glslang-WallpaperEngine
    ${upstream}/src/External/SPIRV-Cross-WallpaperEngine)

function(fresco_scene_configure_gpl_consumer target)
    target_include_directories(${target} PRIVATE
        ${fresco_scene_gpl_private_includes})
    if(FRESCO_SCENE_RENDER_BACKEND MATCHES "^angle-")
        target_include_directories(${target} BEFORE PRIVATE
            ${FRESCO_SCENE_ANGLE_INCLUDE_DIR})
        target_compile_definitions(${target} PRIVATE FRESCO_SCENE_GLES=1)
    endif()
    target_link_libraries(${target} PRIVATE
        glm::glm
        PkgConfig::LZ4
        Freetype::Freetype
        qjs
        glslang
        spirv-cross-glsl)
endfunction()

function(fresco_scene_configure_renderer_object target)
    fresco_scene_configure_gpl_consumer(${target})
    target_compile_definitions(${target} PRIVATE NDEBUG=1)
    target_compile_options(${target} PRIVATE
        -Wno-deprecated-declarations
        -Wno-c++11-narrowing
        -Wno-unused-parameter
        -Wno-unused-variable
        -Wno-unused-private-field)
endfunction()

function(fresco_scene_add_renderer_object target)
    add_library(${target} OBJECT ${ARGN})
    fresco_scene_configure_renderer_object(${target})
endfunction()

fresco_scene_add_renderer_object(fresco-scene-scheduler
    ${fresco_scene_scheduler_sources})
fresco_scene_add_renderer_object(fresco-scene-change-index
    ${fresco_scene_change_index_sources})
target_include_directories(fresco-scene-change-index PUBLIC include)
add_library(fresco-scene-draw-contract INTERFACE)
fresco_scene_add_renderer_object(fresco-scene-evidence
    ${fresco_scene_evidence_sources})
fresco_scene_add_renderer_object(fresco-scene-system-script
    ${fresco_scene_script_system_sources})
fresco_scene_add_renderer_object(fresco-scene-system-audio
    ${fresco_scene_audio_system_sources})
fresco_scene_add_renderer_object(fresco-scene-system-media
    ${fresco_scene_media_system_sources})
fresco_scene_add_renderer_object(fresco-scene-system-particles
    ${fresco_scene_particle_system_sources})
fresco_scene_add_renderer_object(fresco-scene-system-puppet
    ${fresco_scene_puppet_system_sources})
fresco_scene_add_renderer_object(fresco-scene-system-text-effects
    ${fresco_scene_text_effect_system_sources})
fresco_scene_add_renderer_object(fresco-scene-system-effects
    ${fresco_scene_effect_system_sources})
add_library(fresco-scene-systems INTERFACE)
target_link_libraries(fresco-scene-systems INTERFACE
    fresco-scene-audio
    fresco-scene-media
    fresco-scene-particle-compatibility
    fresco-scene-sound-semantic
    fresco-scene-system-script
    fresco-scene-system-audio
    fresco-scene-system-media
    fresco-scene-system-particles
    fresco-scene-system-puppet
    fresco-scene-system-text-effects
    fresco-scene-system-effects)
fresco_scene_add_renderer_object(fresco-scene-we-import
    ${fresco_scene_we_import_sources})
fresco_scene_add_renderer_object(fresco-scene-we-generated
    ${fresco_scene_we_generated_sources})
fresco_scene_add_renderer_object(fresco-scene-legacy-gl
    ${fresco_scene_legacy_gl_sources})

if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "native-opengl")
    fresco_scene_add_renderer_object(fresco-scene-surface-opengl
        src/RenderBackend.cpp src/NativeOpenGLSurface.mm)
    set(fresco_scene_surface_target fresco-scene-surface-opengl)
    set_source_files_properties(src/NativeOpenGLSurface.mm
        PROPERTIES COMPILE_OPTIONS
        "-fobjc-arc;-Wno-deprecated-declarations")
elseif(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
    fresco_scene_add_renderer_object(fresco-scene-surface-angle
        src/RenderBackend.cpp src/AngleMetalSurface.mm)
    target_compile_definitions(fresco-scene-surface-angle PRIVATE
        FRESCO_SCENE_ANGLE_RUNTIME=1)
    set(fresco_scene_surface_target fresco-scene-surface-angle)
    set_source_files_properties(src/AngleMetalSurface.mm
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
else()
    fresco_scene_add_renderer_object(fresco-scene-surface-angle
        src/RenderBackend.cpp)
    set(fresco_scene_surface_target fresco-scene-surface-angle)
endif()

add_library(fresco-scene-we-runtime INTERFACE)
target_link_libraries(fresco-scene-we-runtime INTERFACE
    fresco-scene-we-import
    fresco-scene-we-generated
    fresco-scene-legacy-gl
    ${fresco_scene_surface_target})

add_library(fresco-scene-renderer-core STATIC
    $<TARGET_OBJECTS:fresco-scene-scheduler>
    $<TARGET_OBJECTS:fresco-scene-change-index>
    $<TARGET_OBJECTS:fresco-scene-evidence>
    $<TARGET_OBJECTS:fresco-scene-system-script>
    $<TARGET_OBJECTS:fresco-scene-system-audio>
    $<TARGET_OBJECTS:fresco-scene-system-media>
    $<TARGET_OBJECTS:fresco-scene-system-particles>
    $<TARGET_OBJECTS:fresco-scene-system-puppet>
    $<TARGET_OBJECTS:fresco-scene-system-text-effects>
    $<TARGET_OBJECTS:fresco-scene-system-effects>
    $<TARGET_OBJECTS:fresco-scene-we-import>
    $<TARGET_OBJECTS:fresco-scene-we-generated>
    $<TARGET_OBJECTS:fresco-scene-legacy-gl>
    $<TARGET_OBJECTS:${fresco_scene_surface_target}>)
target_include_directories(fresco-scene-renderer-core PUBLIC include)
target_link_libraries(fresco-scene-renderer-core PRIVATE
    fresco-scene-audio
    fresco-scene-media
    fresco-scene-particle-compatibility
    fresco-scene-sound-semantic
    glm::glm
    PkgConfig::LZ4
    Freetype::Freetype
    qjs
    glslang
    spirv-cross-glsl
    "-framework AppKit"
    "-framework CoreText")
if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "native-opengl")
    target_link_libraries(fresco-scene-renderer-core PRIVATE
        "-framework OpenGL")
elseif(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
    target_link_libraries(fresco-scene-renderer-core PRIVATE
        "${FRESCO_SCENE_ANGLE_LIBRARY_DIR}/libEGL.dylib"
        "${FRESCO_SCENE_ANGLE_LIBRARY_DIR}/libGLESv2.dylib"
        "-framework QuartzCore")
endif()

add_library(fresco-scene-session OBJECT src/RendererSession.mm)
fresco_scene_configure_renderer_object(fresco-scene-session)
target_link_libraries(fresco-scene-session PRIVATE
    fresco-scene-scheduler
    fresco-scene-evidence
    fresco-scene-draw-contract
    fresco-scene-change-index
    fresco-scene-systems
    fresco-scene-we-runtime)
target_compile_options(fresco-scene-session PRIVATE -fobjc-arc)
if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
    target_compile_definitions(fresco-scene-session PRIVATE
        FRESCO_SCENE_ANGLE_RUNTIME=1)
endif()

target_include_directories(fresco-scene-helper-main PRIVATE
    ${fresco_scene_gpl_private_includes})
target_compile_definitions(fresco-scene-helper-main PRIVATE
    FRESCO_SCENE_RENDERER_AVAILABLE=1)
target_link_libraries(fresco-scene-helper-main PRIVATE
    fresco-scene-protocol
    fresco-scene-session)
if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
    target_include_directories(fresco-scene-helper-main BEFORE PRIVATE
        ${FRESCO_SCENE_ANGLE_INCLUDE_DIR})
    target_compile_definitions(fresco-scene-helper-main PRIVATE
        FRESCO_SCENE_ANGLE_RUNTIME=1
        FRESCO_SCENE_GLES=1)
endif()
target_sources(fresco-scene PRIVATE
    $<TARGET_OBJECTS:fresco-scene-session>)
target_link_libraries(fresco-scene PRIVATE
    fresco-scene-protocol
    fresco-scene-renderer-core)
if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
    set_target_properties(fresco-scene PROPERTIES
        BUILD_RPATH "${FRESCO_SCENE_ANGLE_LIBRARY_DIR}")
endif()

if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "native-opengl")
    add_executable(fresco-scene-render-smoke src/smoke.mm)
    fresco_scene_configure_gpl_consumer(fresco-scene-render-smoke)
    target_compile_options(fresco-scene-render-smoke PRIVATE
        -Wno-deprecated-declarations
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    target_link_libraries(fresco-scene-render-smoke PRIVATE
        fresco-scene-renderer-core)

    if(BUILD_TESTING)
        add_executable(fresco-scene-renderer-backend-contract
            tests/backend_contract_test.cpp
            src/RenderBackend.cpp)
        target_include_directories(
            fresco-scene-renderer-backend-contract PRIVATE
            include
            ${CMAKE_CURRENT_BINARY_DIR}/generated/include)
        add_test(NAME fresco-scene-renderer-backend-contract
            COMMAND fresco-scene-renderer-backend-contract)
    endif()
else()
    add_custom_target(fresco-scene-renderer-gles-compile
        DEPENDS fresco-scene-renderer-core)
endif()
