if(BUILD_TESTING)
    add_executable(
        fresco-scene-renderer-scene-object-visibility
        tests/scene_object_visibility_test.cpp
    )
    target_include_directories(
        fresco-scene-renderer-scene-object-visibility PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-scene-object-visibility PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-scene-object-visibility
        COMMAND fresco-scene-renderer-scene-object-visibility
    )
    add_executable(
        fresco-scene-renderer-scene-object-transform
        tests/scene_object_transform_test.cpp
    )
    target_include_directories(
        fresco-scene-renderer-scene-object-transform PRIVATE include
    )
    target_link_libraries(
        fresco-scene-renderer-scene-object-transform PRIVATE glm::glm
    )
    target_compile_options(
        fresco-scene-renderer-scene-object-transform PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-scene-object-transform
        COMMAND fresco-scene-renderer-scene-object-transform
    )
    add_executable(
        fresco-scene-renderer-clock
        tests/renderer_clock_test.cpp
        src/RendererClock.cpp
    )
    target_include_directories(fresco-scene-renderer-clock PRIVATE include)
    target_compile_options(
        fresco-scene-renderer-clock PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-clock
        COMMAND fresco-scene-renderer-clock
    )
    add_executable(
        fresco-scene-renderer-change-index
        tests/change_index_test.cpp
    )
    target_link_libraries(
        fresco-scene-renderer-change-index PRIVATE fresco-scene-change-index
    )
    target_compile_options(
        fresco-scene-renderer-change-index PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-change-index
        COMMAND fresco-scene-renderer-change-index
    )
    add_executable(
        fresco-scene-renderer-frame-scheduler
        tests/frame_scheduler_test.cpp
    )
    target_link_libraries(
        fresco-scene-renderer-frame-scheduler PRIVATE
        fresco-scene-scheduler
        fresco-scene-change-index
    )
    target_compile_options(
        fresco-scene-renderer-frame-scheduler PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-frame-scheduler
        COMMAND fresco-scene-renderer-frame-scheduler
    )
    add_executable(
        fresco-scene-renderer-runtime-frame-coordinator
        tests/runtime_frame_coordinator_test.cpp
    )
    target_link_libraries(
        fresco-scene-renderer-runtime-frame-coordinator PRIVATE
        fresco-scene-scheduler
        fresco-scene-change-index
    )
    target_compile_options(
        fresco-scene-renderer-runtime-frame-coordinator PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-runtime-frame-coordinator
        COMMAND fresco-scene-renderer-runtime-frame-coordinator
    )
    add_executable(
        fresco-scene-renderer-scoped-stencil-state
        tests/scoped_stencil_state_test.cpp
        src/ScopedStencilState.cpp
    )
    target_include_directories(
        fresco-scene-renderer-scoped-stencil-state PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-scoped-stencil-state PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-scoped-stencil-state
        COMMAND fresco-scene-renderer-scoped-stencil-state
    )

    add_executable(
        fresco-scene-renderer-opengl-stencil-state-api
        tests/opengl_stencil_state_api_compile_test.cpp
    )
    target_link_libraries(
        fresco-scene-renderer-opengl-stencil-state-api PRIVATE
        fresco-scene-renderer-core
    )
    target_compile_options(
        fresco-scene-renderer-opengl-stencil-state-api PRIVATE
        -Wall -Wextra -Werror -Wpedantic
    )
    if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
        set_target_properties(
            fresco-scene-renderer-opengl-stencil-state-api PROPERTIES
            BUILD_RPATH "${FRESCO_SCENE_ANGLE_LIBRARY_DIR}"
        )
    endif()
    add_test(
        NAME fresco-scene-renderer-opengl-stencil-state-api
        COMMAND fresco-scene-renderer-opengl-stencil-state-api
    )
    if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
        set_tests_properties(
            fresco-scene-renderer-opengl-stencil-state-api PROPERTIES
            WORKING_DIRECTORY "${FRESCO_SCENE_ANGLE_LIBRARY_DIR}"
        )
    endif()

    add_executable(
        fresco-scene-renderer-session-activity-gate
        tests/session_activity_gate_test.cpp
        src/SessionActivityGate.cpp
    )
    target_include_directories(
        fresco-scene-renderer-session-activity-gate PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-session-activity-gate PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
        -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-session-activity-gate
        COMMAND fresco-scene-renderer-session-activity-gate
    )

    add_executable(
        fresco-scene-renderer-procedural-effect-compositing
        tests/procedural_effect_compositing_test.cpp
        src/ProceduralEffectCompositing.cpp
    )
    target_include_directories(
        fresco-scene-renderer-procedural-effect-compositing PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-procedural-effect-compositing PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-procedural-effect-compositing
        COMMAND fresco-scene-renderer-procedural-effect-compositing
    )

    add_executable(
        fresco-scene-renderer-passthrough-layer-semantics
        tests/passthrough_layer_semantics_test.cpp
        src/PassthroughLayerSemantics.cpp
    )
    target_include_directories(
        fresco-scene-renderer-passthrough-layer-semantics PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-passthrough-layer-semantics PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-passthrough-layer-semantics
        COMMAND fresco-scene-renderer-passthrough-layer-semantics
    )

    add_executable(
        fresco-scene-renderer-mac-system-font-resolver
        tests/mac_system_font_resolver_test.cpp
        src/MacSystemFontResolver.mm
    )
    target_include_directories(
        fresco-scene-renderer-mac-system-font-resolver PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-mac-system-font-resolver PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    target_link_libraries(
        fresco-scene-renderer-mac-system-font-resolver PRIVATE
        "-framework CoreText"
        "-framework CoreFoundation"
    )
    add_test(
        NAME fresco-scene-renderer-mac-system-font-resolver
        COMMAND fresco-scene-renderer-mac-system-font-resolver
    )

    add_executable(
        fresco-scene-renderer-text-effect-chain-decision
        tests/text_effect_chain_decision_test.cpp
        src/TextEffectChainDecision.cpp
    )
    target_include_directories(
        fresco-scene-renderer-text-effect-chain-decision PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-text-effect-chain-decision PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-text-effect-chain-decision
        COMMAND fresco-scene-renderer-text-effect-chain-decision
    )

    add_executable(
        fresco-scene-renderer-dynamic-value-animation
        tests/dynamic_value_animation_test.cpp
    )
    fresco_scene_configure_gpl_consumer(
        fresco-scene-renderer-dynamic-value-animation
    )
    target_link_libraries(
        fresco-scene-renderer-dynamic-value-animation PRIVATE
        fresco-scene-renderer-core
    )
    target_compile_options(
        fresco-scene-renderer-dynamic-value-animation PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
        -Wno-unused-parameter
    )
    if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
        set_target_properties(
            fresco-scene-renderer-dynamic-value-animation PROPERTIES
            BUILD_RPATH "${FRESCO_SCENE_ANGLE_LIBRARY_DIR}"
        )
        add_custom_command(
            TARGET fresco-scene-renderer-dynamic-value-animation POST_BUILD
            COMMAND "${CMAKE_INSTALL_NAME_TOOL}"
                -change ./libEGL.dylib @rpath/libEGL.dylib
                "$<TARGET_FILE:fresco-scene-renderer-dynamic-value-animation>"
            COMMAND "${CMAKE_INSTALL_NAME_TOOL}"
                -change ./libGLESv2.dylib @rpath/libGLESv2.dylib
                "$<TARGET_FILE:fresco-scene-renderer-dynamic-value-animation>"
            VERBATIM
        )
    endif()
    add_test(
        NAME fresco-scene-renderer-dynamic-value-animation
        COMMAND fresco-scene-renderer-dynamic-value-animation
    )

    add_executable(
        fresco-scene-renderer-text-codepoints
        tests/text_codepoints_test.cpp
        src/TextCodepoints.cpp
    )
    target_include_directories(
        fresco-scene-renderer-text-codepoints PRIVATE include
    )
    add_test(
        NAME fresco-scene-renderer-text-codepoints
        COMMAND fresco-scene-renderer-text-codepoints
    )

    add_executable(
        fresco-scene-renderer-text-raster-size
        tests/text_raster_size_test.cpp
        src/TextRasterSize.cpp
    )
    target_include_directories(
        fresco-scene-renderer-text-raster-size PRIVATE include
    )
    add_test(
        NAME fresco-scene-renderer-text-raster-size
        COMMAND fresco-scene-renderer-text-raster-size
    )

    add_executable(
        fresco-scene-renderer-text-width-limit
        tests/text_width_limit_test.cpp
        src/TextWidthLimit.cpp
    )
    target_include_directories(
        fresco-scene-renderer-text-width-limit PRIVATE include
    )
    add_test(
        NAME fresco-scene-renderer-text-width-limit
        COMMAND fresco-scene-renderer-text-width-limit
    )

    add_executable(
        fresco-scene-renderer-color-builder
        tests/color_builder_test.cpp
        "${CMAKE_CURRENT_BINARY_DIR}/generated/ColorBuilder.cpp"
        "${upstream}/src/WallpaperEngine/Data/Builders/VectorBuilder.cpp"
        "${upstream}/src/WallpaperEngine/Logging/Log.cpp"
    )
    target_include_directories(
        fresco-scene-renderer-color-builder PRIVATE "${upstream}/src"
    )
    target_compile_options(
        fresco-scene-renderer-color-builder PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
        -Wno-unused-parameter
    )
    target_link_libraries(
        fresco-scene-renderer-color-builder PRIVATE glm::glm
    )
    add_test(
        NAME fresco-scene-renderer-color-builder
        COMMAND fresco-scene-renderer-color-builder
    )

    add_executable(
        fresco-scene-renderer-sound-compatibility
        tests/scene_sound_compatibility_test.cpp
        src/SceneSoundCompatibility.cpp
    )
    target_include_directories(
        fresco-scene-renderer-sound-compatibility PRIVATE include
    )
    target_link_libraries(
        fresco-scene-renderer-sound-compatibility PRIVATE
        fresco-scene-sound-semantic
    )
    add_test(
        NAME fresco-scene-renderer-sound-compatibility
        COMMAND fresco-scene-renderer-sound-compatibility
    )

    add_executable(
        fresco-scene-renderer-particle-compatibility
        tests/particle_compatibility_test.cpp
    )
    target_link_libraries(
        fresco-scene-renderer-particle-compatibility PRIVATE
        fresco-scene-particle-compatibility
    )
    target_compile_options(
        fresco-scene-renderer-particle-compatibility PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-particle-compatibility
        COMMAND fresco-scene-renderer-particle-compatibility
    )

    add_executable(
        fresco-scene-renderer-particle-blueprint-cache
        tests/particle_blueprint_cache_test.cpp
        src/ParticleBlueprintCache.cpp
    )
    target_include_directories(
        fresco-scene-renderer-particle-blueprint-cache PRIVATE
        include
        ${upstream}/src
        ${upstream}/src/External/json/include
    )
    target_compile_options(
        fresco-scene-renderer-particle-blueprint-cache PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
        -Wno-unused-parameter
    )
    target_link_libraries(
        fresco-scene-renderer-particle-blueprint-cache PRIVATE glm::glm
    )
    add_test(
        NAME fresco-scene-renderer-particle-blueprint-cache
        COMMAND fresco-scene-renderer-particle-blueprint-cache
    )

    add_executable(
        fresco-scene-renderer-program-cache
        tests/render_program_cache_test.cpp
        src/RenderProgramCache.cpp
    )
    target_include_directories(
        fresco-scene-renderer-program-cache PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-program-cache PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-program-cache
        COMMAND fresco-scene-renderer-program-cache
    )

    add_executable(
        fresco-scene-renderer-allocation-evidence
        tests/render_allocation_evidence_test.cpp
    )
    target_include_directories(
        fresco-scene-renderer-allocation-evidence PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-allocation-evidence PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-allocation-evidence
        COMMAND fresco-scene-renderer-allocation-evidence
    )

    add_executable(
        fresco-scene-renderer-shader-translation-cache
        tests/shader_translation_cache_test.cpp
        src/ShaderTranslationCache.cpp
    )
    target_include_directories(
        fresco-scene-renderer-shader-translation-cache PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-shader-translation-cache PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-shader-translation-cache
        COMMAND fresco-scene-renderer-shader-translation-cache
    )

    add_executable(
        fresco-scene-renderer-media-session
        tests/media_session_test.cpp
        src/RuntimeMediaSource.cpp
        ${upstream}/src/WallpaperEngine/Media/MediaSource.cpp
    )
    target_include_directories(
        fresco-scene-renderer-media-session PRIVATE
        src
        ${upstream}/src
    )
    target_link_libraries(
        fresco-scene-renderer-media-session PRIVATE fresco-scene-media
    )
    add_test(
        NAME fresco-scene-renderer-media-session
        COMMAND fresco-scene-renderer-media-session
    )

    add_executable(
        fresco-scene-renderer-script-storage
        tests/scene_script_storage_test.cpp
        src/SceneScriptStorage.cpp
        src/SceneScriptStoragePool.cpp
    )
    target_include_directories(
        fresco-scene-renderer-script-storage PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-script-storage PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-script-storage
        COMMAND fresco-scene-renderer-script-storage
    )

    add_executable(
        fresco-scene-renderer-script-quickjs-ownership
        tests/scene_script_quickjs_ownership_test.cpp
        src/SceneScriptQuickJS.cpp
    )
    target_include_directories(
        fresco-scene-renderer-script-quickjs-ownership PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-script-quickjs-ownership PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
    )
    target_link_libraries(
        fresco-scene-renderer-script-quickjs-ownership PRIVATE qjs
    )
    add_test(
        NAME fresco-scene-renderer-script-quickjs-ownership
        COMMAND fresco-scene-renderer-script-quickjs-ownership
    )

    add_executable(
        fresco-scene-renderer-texture-animation-script-teardown
        tests/texture_animation_script_teardown_test.cpp
        src/TextureAnimationScript.cpp
    )
    target_include_directories(
        fresco-scene-renderer-texture-animation-script-teardown PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-texture-animation-script-teardown PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-texture-animation-script-teardown
        COMMAND fresco-scene-renderer-texture-animation-script-teardown
    )

    add_executable(
        fresco-scene-renderer-media-artwork
        tests/media_artwork_test.cpp
    )
    target_link_libraries(
        fresco-scene-renderer-media-artwork PRIVATE fresco-scene-media
    )
    add_test(
        NAME fresco-scene-renderer-media-artwork
        COMMAND fresco-scene-renderer-media-artwork
    )

    add_executable(
        fresco-scene-renderer-media-playback-clock
        tests/media_playback_clock_test.cpp
    )
    target_link_libraries(
        fresco-scene-renderer-media-playback-clock PRIVATE fresco-scene-media
    )
    add_test(
        NAME fresco-scene-renderer-media-playback-clock
        COMMAND fresco-scene-renderer-media-playback-clock
    )
    add_executable(
        fresco-scene-renderer-media-frame-preparation
        tests/media_frame_preparation_test.cpp
    )
    target_include_directories(
        fresco-scene-renderer-media-frame-preparation PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-media-frame-preparation PRIVATE
        -Wall -Wextra -Werror -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-media-frame-preparation
        COMMAND fresco-scene-renderer-media-frame-preparation
    )
    add_executable(
        fresco-scene-renderer-media-lifecycle-classifier
        tests/media_lifecycle_classifier_test.cpp
    )
    target_include_directories(
        fresco-scene-renderer-media-lifecycle-classifier PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-media-lifecycle-classifier PRIVATE
        -Wall -Wextra -Werror -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-media-lifecycle-classifier
        COMMAND fresco-scene-renderer-media-lifecycle-classifier
    )
    add_executable(
        fresco-scene-renderer-audio-lifecycle-classifier
        tests/audio_lifecycle_classifier_test.cpp
    )
    target_include_directories(
        fresco-scene-renderer-audio-lifecycle-classifier PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-audio-lifecycle-classifier PRIVATE
        -Wall -Wextra -Werror -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-audio-lifecycle-classifier
        COMMAND fresco-scene-renderer-audio-lifecycle-classifier
    )

    add_executable(
        fresco-scene-renderer-script-compatibility
        tests/scene_script_compatibility_test.cpp
        src/SceneEventCompatibility.cpp
        src/SceneScript2DCapability.cpp
        src/SceneScriptCompatibility.cpp
    )
    target_include_directories(
        fresco-scene-renderer-script-compatibility PRIVATE include
    )
    add_test(
        NAME fresco-scene-renderer-script-compatibility
        COMMAND fresco-scene-renderer-script-compatibility
    )

    add_executable(
        fresco-scene-renderer-scene-event-boundary
        tests/scene_event_compatibility_boundary_test.cpp
        src/SceneEventCompatibility.cpp
    )
    target_include_directories(
        fresco-scene-renderer-scene-event-boundary PRIVATE include
    )
    add_test(
        NAME fresco-scene-renderer-scene-event-boundary
        COMMAND fresco-scene-renderer-scene-event-boundary
    )

    add_executable(
        fresco-scene-renderer-scene-animation-layer-semantic-capability
        tests/scene_animation_layer_semantic_capability_test.cpp
        src/SceneAnimationLayerSemanticCapability.cpp
    )
    target_include_directories(
        fresco-scene-renderer-scene-animation-layer-semantic-capability
        PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-scene-animation-layer-semantic-capability PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-scene-animation-layer-semantic-capability
        COMMAND fresco-scene-renderer-scene-animation-layer-semantic-capability
    )

    add_executable(
        fresco-scene-renderer-shared-dependency
        tests/persona_shared_dependency_contract_test.cpp
        src/SceneEventCompatibility.cpp
        src/SceneScript2DCapability.cpp
        src/SceneScriptCompatibility.cpp
        src/SharedScriptDependency.cpp
    )
    target_include_directories(
        fresco-scene-renderer-shared-dependency PRIVATE include
    )
    add_test(
        NAME fresco-scene-renderer-shared-dependency
        COMMAND fresco-scene-renderer-shared-dependency
    )

    add_executable(
        fresco-scene-renderer-elaina-script-compatibility
        tests/elaina_scenescript_compatibility_test.cpp
        src/SceneEventCompatibility.cpp
        src/SceneScript2DCapability.cpp
        src/SceneScriptCompatibility.cpp
    )
    target_include_directories(
        fresco-scene-renderer-elaina-script-compatibility PRIVATE include
    )
    add_test(
        NAME fresco-scene-renderer-elaina-script-compatibility
        COMMAND fresco-scene-renderer-elaina-script-compatibility
    )

    add_executable(
        fresco-scene-renderer-audio-spectrum
        tests/audio_spectrum_test.cpp
    )
    target_include_directories(
        fresco-scene-renderer-audio-spectrum PRIVATE compat
    )
    target_link_libraries(
        fresco-scene-renderer-audio-spectrum PRIVATE fresco-scene-audio
    )
    add_test(
        NAME fresco-scene-renderer-audio-spectrum
        COMMAND fresco-scene-renderer-audio-spectrum
    )

    add_executable(
        fresco-scene-renderer-sound-registry
        tests/sound_registry_test.cpp
    )
    target_link_libraries(
        fresco-scene-renderer-sound-registry PRIVATE fresco-scene-audio
    )
    add_test(
        NAME fresco-scene-renderer-sound-registry
        COMMAND fresco-scene-renderer-sound-registry
    )

    add_executable(
        fresco-scene-renderer-sound-script-bridge
        tests/sound_script_bridge_test.cpp
        src/SoundScriptBridge.cpp
    )
    target_include_directories(
        fresco-scene-renderer-sound-script-bridge PRIVATE src
    )
    target_link_libraries(
        fresco-scene-renderer-sound-script-bridge PRIVATE fresco-scene-audio qjs
    )
    add_test(
        NAME fresco-scene-renderer-sound-script-bridge
        COMMAND fresco-scene-renderer-sound-script-bridge
    )

    add_executable(
        fresco-scene-renderer-sound-decode-probe
        tests/sound_decode_probe.mm
    )
    target_compile_options(
        fresco-scene-renderer-sound-decode-probe PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
    )
    target_link_libraries(
        fresco-scene-renderer-sound-decode-probe PRIVATE fresco-scene-audio
    )

    add_executable(
        fresco-scene-renderer-media-video-probe
        tests/media_video_probe.mm
    )
    target_compile_options(
        fresco-scene-renderer-media-video-probe PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
    )
    target_link_libraries(
        fresco-scene-renderer-media-video-probe PRIVATE fresco-scene-media
    )
    add_test(
        NAME fresco-scene-renderer-media-video-contract
        COMMAND fresco-scene-renderer-media-video-probe
    )
    add_executable(
        fresco-scene-renderer-media-fixture-generator
        tests/media_fixture_generator.mm
    )
    target_compile_options(
        fresco-scene-renderer-media-fixture-generator PRIVATE
        -Wall -Wextra -Werror -Wpedantic
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
    )
    target_link_libraries(
        fresco-scene-renderer-media-fixture-generator PRIVATE
        "-framework AVFoundation"
        "-framework CoreMedia"
        "-framework CoreVideo"
        "-framework Foundation"
    )

    add_executable(
        fresco-scene-renderer-scene-audio-vector
        tests/scene_audio_vector_test.cpp
        src/SceneAudioVector.cpp
    )
    target_include_directories(
        fresco-scene-renderer-scene-audio-vector PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-scene-audio-vector PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-scene-audio-vector
        COMMAND fresco-scene-renderer-scene-audio-vector
    )

    add_executable(
        fresco-scene-renderer-video-texture-control
        tests/video_texture_control_test.cpp
        src/VideoTextureControl.cpp
    )
    target_include_directories(
        fresco-scene-renderer-video-texture-control PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-video-texture-control PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-video-texture-control
        COMMAND fresco-scene-renderer-video-texture-control
    )

    add_executable(
        fresco-scene-renderer-scene-video-texture-control-provider
        tests/scene_video_texture_control_provider_test.cpp
        src/SceneVideoTextureControlProvider.cpp
        src/VideoTextureControl.cpp
    )
    target_include_directories(
        fresco-scene-renderer-scene-video-texture-control-provider PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-scene-video-texture-control-provider PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wpedantic
    )
    add_test(
        NAME fresco-scene-renderer-scene-video-texture-control-provider
        COMMAND fresco-scene-renderer-scene-video-texture-control-provider
    )
endif()

set(FRESCO_SCENE_ASSETS "" CACHE PATH "Official Wallpaper Engine assets root")
set(FRESCO_SCENE_WORKSHOP_ROOT "" CACHE PATH "Wallpaper Engine Workshop content root")
if(NOT FRESCO_SCENE_ASSETS AND APPLE AND DEFINED ENV{HOME})
    set(candidate_assets "$ENV{HOME}/Library/Application Support/Fresco/Wallpaper Engine/assets")
    if(IS_DIRECTORY "${candidate_assets}")
        set(FRESCO_SCENE_ASSETS "${candidate_assets}")
    endif()
endif()
if(NOT FRESCO_SCENE_WORKSHOP_ROOT AND APPLE AND DEFINED ENV{HOME})
    set(candidate_workshop "$ENV{HOME}/Library/Application Support/Steam/steamapps/workshop/content/431960")
    if(IS_DIRECTORY "${candidate_workshop}")
        set(FRESCO_SCENE_WORKSHOP_ROOT "${candidate_workshop}")
    endif()
endif()

if(BUILD_TESTING
   AND FRESCO_SCENE_RUNTIME_AVAILABLE
   AND FRESCO_SCENE_ASSETS
   AND FRESCO_SCENE_RENDER_BACKEND MATCHES "^(native-opengl|angle-metal)$")
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "native-opengl")
        set(fresco_scene_harness_candidate "opengl-4.1-2d")
    else()
        set(fresco_scene_harness_candidate "angle-metal-es3-2d")
    endif()
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../angle/REVISION"
        fresco_scene_angle_revision)
    string(STRIP "${fresco_scene_angle_revision}"
        fresco_scene_angle_revision)
    set(fresco_scene_harness_source_manifest
        "${CMAKE_CURRENT_BINARY_DIR}/common-harness-source-manifest.json")
    set(fresco_scene_harness_source_digest
        "${CMAKE_CURRENT_BINARY_DIR}/common-harness-source-manifest.sha256")
    set(fresco_scene_harness_deployment_target
        "${CMAKE_OSX_DEPLOYMENT_TARGET}")
    if(NOT fresco_scene_harness_deployment_target)
        set(fresco_scene_harness_deployment_target unspecified)
    endif()
    set(fresco_scene_harness_build_type "${CMAKE_BUILD_TYPE}")
    if(NOT fresco_scene_harness_build_type)
        set(fresco_scene_harness_build_type unspecified)
    endif()
    set(fresco_scene_harness_external_arguments
        --external-file angle/REVISION
        "${CMAKE_CURRENT_SOURCE_DIR}/../angle/REVISION"
    )
    set(fresco_scene_harness_external_dependencies
        "${CMAKE_CURRENT_SOURCE_DIR}/../angle/REVISION"
    )
    if(FRESCO_SCENE_RENDER_BACKEND MATCHES "^angle-")
        file(GLOB_RECURSE fresco_scene_angle_headers
            CONFIGURE_DEPENDS LIST_DIRECTORIES false
            "${FRESCO_SCENE_ANGLE_INCLUDE_DIR}/*"
        )
        foreach(angle_header IN LISTS fresco_scene_angle_headers)
            file(RELATIVE_PATH angle_header_relative
                "${FRESCO_SCENE_ANGLE_INCLUDE_DIR}" "${angle_header}")
            list(APPEND fresco_scene_harness_external_arguments
                --external-file "angle/include/${angle_header_relative}"
                "${angle_header}")
            list(APPEND fresco_scene_harness_external_dependencies
                "${angle_header}")
        endforeach()
    endif()
    if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
        foreach(angle_library IN ITEMS libEGL.dylib libGLESv2.dylib)
            set(angle_library_path
                "${FRESCO_SCENE_ANGLE_LIBRARY_DIR}/${angle_library}")
            list(APPEND fresco_scene_harness_external_arguments
                --external-file "angle/lib/${angle_library}"
                "${angle_library_path}")
            list(APPEND fresco_scene_harness_external_dependencies
                "${angle_library_path}")
        endforeach()
    endif()
    set(fresco_scene_renderer_submodules
        src/External/SPIRV-Cross-WallpaperEngine
        src/External/glslang-WallpaperEngine
        src/External/json
        src/External/quickjs
        src/External/stb
    )
    set(fresco_scene_harness_pinned_arguments
        --pinned-checkout renderer "${upstream}"
            "${FRESCO_SCENE_RENDERER_COMMIT}"
        --pinned-checkout glm "${glm_SOURCE_DIR}" "${FRESCO_SCENE_GLM_COMMIT}"
    )
    foreach(renderer_submodule IN LISTS fresco_scene_renderer_submodules)
        list(APPEND fresco_scene_harness_pinned_arguments
            --required-renderer-submodule "${renderer_submodule}")
    endforeach()
    set(fresco_scene_harness_manifest_command
        "${Python3_EXECUTABLE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/../tools/common-harness/source_manifest.py"
        --source-root "${CMAKE_CURRENT_SOURCE_DIR}/.."
        --output "${fresco_scene_harness_source_manifest}"
        --digest-output "${fresco_scene_harness_source_digest}"
        --backend "${FRESCO_SCENE_RENDER_BACKEND}"
        --renderer-commit "${FRESCO_SCENE_RENDERER_COMMIT}"
        --glm-commit "${FRESCO_SCENE_GLM_COMMIT}"
        --angle-revision "${fresco_scene_angle_revision}"
        --compiler-id "${CMAKE_CXX_COMPILER_ID}"
        --compiler-version "${CMAKE_CXX_COMPILER_VERSION}"
        --system-name "${CMAKE_SYSTEM_NAME}"
        --system-version "${CMAKE_SYSTEM_VERSION}"
        --system-processor "${CMAKE_SYSTEM_PROCESSOR}"
        --deployment-target "${fresco_scene_harness_deployment_target}"
        --generator "${CMAKE_GENERATOR}"
        --build-type "${fresco_scene_harness_build_type}"
        ${fresco_scene_harness_external_arguments}
        ${fresco_scene_harness_pinned_arguments}
    )
    execute_process(
        COMMAND ${fresco_scene_harness_manifest_command}
        RESULT_VARIABLE fresco_scene_harness_manifest_result
        OUTPUT_VARIABLE fresco_scene_harness_source_sha256
        ERROR_VARIABLE fresco_scene_harness_manifest_error
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if(NOT fresco_scene_harness_manifest_result EQUAL 0)
        message(FATAL_ERROR
            "common harness source manifest failed: ${fresco_scene_harness_manifest_error}")
    endif()
    file(GLOB_RECURSE fresco_scene_harness_manifest_sources
        CONFIGURE_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/../include/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/../src/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/cmake/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/compat/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/include/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/src/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/tests/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/../tests/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/../tools/common-harness/*"
    )
    file(GLOB_RECURSE fresco_scene_harness_pinned_dependency_sources
        CONFIGURE_DEPENDS LIST_DIRECTORIES false
        "${upstream}/*"
        "${glm_SOURCE_DIR}/*"
    )
    list(FILTER fresco_scene_harness_manifest_sources EXCLUDE REGEX
        "(__pycache__|\\.pyc$)")
    list(APPEND fresco_scene_harness_manifest_sources
        "${CMAKE_CURRENT_SOURCE_DIR}/../CMakeLists.txt"
        "${CMAKE_CURRENT_SOURCE_DIR}/../PROTOCOL.md"
        "${CMAKE_CURRENT_SOURCE_DIR}/CMakeLists.txt"
        "${CMAKE_CURRENT_SOURCE_DIR}/PuppetIntegration.cmake"
    )
    add_custom_command(
        OUTPUT
            "${fresco_scene_harness_source_manifest}"
            "${fresco_scene_harness_source_digest}"
        COMMAND ${fresco_scene_harness_manifest_command}
        DEPENDS
            ${fresco_scene_harness_manifest_sources}
            ${fresco_scene_harness_external_dependencies}
            ${fresco_scene_harness_pinned_dependency_sources}
        VERBATIM
    )
    add_custom_target(fresco-scene-common-harness-source-manifest
        DEPENDS
            "${fresco_scene_harness_source_manifest}"
            "${fresco_scene_harness_source_digest}"
    )
    add_dependencies(fresco-scene fresco-scene-common-harness-source-manifest)
    string(CONCAT
        fresco_scene_harness_environment
        "PYTHONDONTWRITEBYTECODE=1;FRESCO_SCENE_AUDIO_DISABLED=1;"
        "FRESCO_SCENE_SOUND_EXPERIMENTAL=0"
    )
    add_dependencies(
        fresco-scene fresco-scene-renderer-media-fixture-generator
    )
    foreach(workload IN ITEMS
        static-no-media continuous-animation script-heavy particle-heavy
        media-video audio-reactive masks-effects resource-reload)
        add_test(
            NAME fresco-scene-common-harness-${workload}
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/../tools/common-harness/integration_test.py"
                "$<TARGET_FILE:fresco-scene>"
                "${FRESCO_SCENE_ASSETS}"
                "${FRESCO_SCENE_RENDER_BACKEND}"
                "${fresco_scene_harness_candidate}"
                "${fresco_scene_harness_source_manifest}"
                "${fresco_scene_harness_source_digest}"
                "${workload}"
                "$<TARGET_FILE:fresco-scene-renderer-media-fixture-generator>"
        )
        set_tests_properties(
            fresco-scene-common-harness-${workload} PROPERTIES
                TIMEOUT 120
                RUN_SERIAL TRUE
                ENVIRONMENT "${fresco_scene_harness_environment}"
        )
    endforeach()
    add_test(
        NAME fresco-scene-renderer-invalid-shader-rollback
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/invalid_shader_transaction_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_ASSETS}"
            "${CMAKE_CURRENT_SOURCE_DIR}/../tools/common-harness"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-invalid-shader-rollback PROPERTIES
            TIMEOUT 120
            RUN_SERIAL TRUE
            ENVIRONMENT "${fresco_scene_harness_environment}"
    )
    add_test(
        NAME fresco-scene-common-harness-resource-lifecycle
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/../tools/common-harness/lifecycle_integration_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
            "${fresco_scene_harness_candidate}"
            "${fresco_scene_harness_source_manifest}"
            "${fresco_scene_harness_source_digest}"
            "lifecycle-${FRESCO_SCENE_RENDER_BACKEND}"
            "--gate"
    )
    set_tests_properties(
        fresco-scene-common-harness-resource-lifecycle PROPERTIES
            TIMEOUT 120
            RUN_SERIAL TRUE
            ENVIRONMENT "${fresco_scene_harness_environment}"
    )
    add_test(
        NAME fresco-scene-common-harness-resource-lifecycle-evidence
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/../tools/common-harness/lifecycle_integration_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
            "${fresco_scene_harness_candidate}"
            "${fresco_scene_harness_source_manifest}"
            "${fresco_scene_harness_source_digest}"
            "lifecycle-${FRESCO_SCENE_RENDER_BACKEND}"
            "--evidence"
    )
    set_tests_properties(
        fresco-scene-common-harness-resource-lifecycle-evidence PROPERTIES
            TIMEOUT 120
            RUN_SERIAL TRUE
            ENVIRONMENT "${fresco_scene_harness_environment}"
    )
endif()

if(BUILD_TESTING
   AND FRESCO_SCENE_RUNTIME_AVAILABLE
   AND FRESCO_SCENE_ASSETS
   AND FRESCO_SCENE_WORKSHOP_ROOT)
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    add_test(
        NAME fresco-scene-renderer-scene-object-visibility-source-contract
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/scene_object_visibility_source_contract_test.py"
            "${CMAKE_CURRENT_BINARY_DIR}/generated/CScene.cpp"
    )
    add_test(
        NAME fresco-scene-renderer-generated-patch-reproducibility-contract
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/generated_patch_reproducibility_contract_test.py"
            "${CMAKE_CURRENT_SOURCE_DIR}"
            "${CMAKE_CURRENT_SOURCE_DIR}/PuppetIntegration.cmake"
    )
    add_test(
        NAME fresco-scene-renderer-parent-transform-contract
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/parent_transform_contract_test.py"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${CMAKE_CURRENT_BINARY_DIR}/generated/CText.cpp"
            "${CMAKE_CURRENT_SOURCE_DIR}/src/ScriptableObject.cpp"
            "${CMAKE_CURRENT_SOURCE_DIR}/PuppetIntegration.cmake"
            "${CMAKE_CURRENT_BINARY_DIR}/generated/CScene.cpp"
            "${CMAKE_CURRENT_SOURCE_DIR}/src/SceneScriptEngine.cpp"
            "${CMAKE_CURRENT_BINARY_DIR}/generated/CImage.cpp"
    )
    add_test(
        NAME fresco-scene-renderer-passthrough-copy-background-contract
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/passthrough_copy_background_contract_test.py"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${CMAKE_CURRENT_BINARY_DIR}/generated/include/WallpaperEngine/Data/Model/Object.h"
            "${CMAKE_CURRENT_BINARY_DIR}/generated/ObjectParser.cpp"
            "${CMAKE_CURRENT_BINARY_DIR}/generated/CImage.cpp"
    )
    add_test(
        NAME fresco-scene-renderer-performance-promotion-policy
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/performance_promotion_policy_test.py"
    )
    add_test(
        NAME fresco-scene-renderer-dynamic-value-animation-corpus
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/dynamic_value_animation_corpus_test.py"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
    )
    add_test(
        NAME fresco-scene-renderer-gbc-named-animation-corpus
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/gbc_named_animation_corpus_test.py"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
    )
    add_test(
        NAME fresco-scene-renderer-elaina-missing-animation-layer-corpus
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/elaina_missing_animation_layer_corpus_test.py"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
    )
    add_test(
        NAME fresco-scene-renderer-procedural-quad-boundary
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/procedural_quad_boundary_test.py"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
    )
    if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "native-opengl")
        add_test(
            NAME fresco-scene-renderer-baselines
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/renderer_smoke_test.py"
                "$<TARGET_FILE:fresco-scene-render-smoke>"
                "${FRESCO_SCENE_WORKSHOP_ROOT}"
                "${FRESCO_SCENE_ASSETS}"
        )
        add_test(
            NAME fresco-scene-renderer-particle-audio-ab
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/particle_audio_ab_test.py"
                "$<TARGET_FILE:fresco-scene-render-smoke>"
                "${FRESCO_SCENE_WORKSHOP_ROOT}"
                "${FRESCO_SCENE_ASSETS}"
        )
        set_tests_properties(
            fresco-scene-renderer-particle-audio-ab PROPERTIES TIMEOUT 70
        )
    endif()
    add_test(
        NAME fresco-scene-renderer-elaina-text-width-contract
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/elaina_text_width_contract_test.py"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
    )
    add_test(
        NAME fresco-scene-renderer-elaina-video-temporal
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/elaina_video_temporal_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-elaina-video-temporal PROPERTIES TIMEOUT 120
    )
    add_test(
        NAME fresco-scene-renderer-elaina-text-width-runtime
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/elaina_text_width_runtime_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-elaina-text-width-runtime PROPERTIES TIMEOUT 120
    )
    add_test(
        NAME fresco-scene-renderer-elaina-deterministic-promotion-lifecycle
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/elaina_deterministic_promotion_lifecycle_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-elaina-deterministic-promotion-lifecycle
        PROPERTIES TIMEOUT 180
    )
    add_test(
        NAME fresco-scene-renderer-elaina-scenescript-runtime
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/elaina_scenescript_runtime_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-elaina-scenescript-runtime PROPERTIES TIMEOUT 180
    )
    add_test(
        NAME fresco-scene-renderer-hidden-lifecycle
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/hidden_lifecycle_regression_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-hidden-lifecycle PROPERTIES TIMEOUT 180
    )
    add_test(
        NAME fresco-scene-renderer-helper
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/helper_render_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-static-scheduling
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/static_scheduling_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-static-scheduling PROPERTIES TIMEOUT 60
    )
    add_test(
        NAME fresco-scene-renderer-media-text-script
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/media_text_script_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-media-artwork-render
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/media_artwork_render_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-media-artwork-render PROPERTIES TIMEOUT 120
    )
    add_test(
        NAME fresco-scene-renderer-effect-property-script
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/effect_property_script_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-texture-frame-script
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/texture_frame_script_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-shared-state-script
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/shared_state_script_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-user-property-scalar-script
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/user_property_scalar_script_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-persona-scene-zoom
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/persona_scene_zoom_runtime_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-persona-scene-zoom PROPERTIES TIMEOUT 120
    )
    add_test(
        NAME fresco-scene-renderer-cursor-drag-script
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/cursor_drag_script_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-lonely-promotion-gate
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/lonely_promotion_gate_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-lonely-promotion-gate PROPERTIES
            TIMEOUT 600
            RUN_SERIAL TRUE
    )
    add_test(
        NAME fresco-scene-renderer-arknights-promotion-gate
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/arknights_promotion_gate_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-arknights-promotion-gate PROPERTIES
            TIMEOUT 900
            RUN_SERIAL TRUE
    )
    foreach(FRESCO_SCENE_STRETCH_FIXTURE IN ITEMS elaina hyuga persona)
        add_test(
            NAME fresco-scene-renderer-${FRESCO_SCENE_STRETCH_FIXTURE}-promotion-gate
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/stretch_fixture_promotion_gate_test.py"
                "$<TARGET_FILE:fresco-scene>"
                "${FRESCO_SCENE_WORKSHOP_ROOT}"
                "${FRESCO_SCENE_ASSETS}"
                "${FRESCO_SCENE_RENDER_BACKEND}"
                "${FRESCO_SCENE_STRETCH_FIXTURE}"
        )
        set_tests_properties(
            fresco-scene-renderer-${FRESCO_SCENE_STRETCH_FIXTURE}-promotion-gate
            PROPERTIES TIMEOUT 900 RUN_SERIAL TRUE
        )
    endforeach()
    add_test(
        NAME fresco-scene-renderer-lonely-font-runtime
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/lonely_font_runtime_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-lonely-font-runtime PROPERTIES TIMEOUT 180
    )
    add_test(
        NAME fresco-scene-renderer-procedural-effect-quad
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/procedural_effect_quad_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-procedural-effect-quad PROPERTIES
            TIMEOUT 180
            RUN_SERIAL TRUE
    )
    if(TARGET fresco-scene-render-smoke)
        add_test(
            NAME fresco-scene-renderer-procedural-effect-compositing-render
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/procedural_effect_compositing_render_test.py"
                "$<TARGET_FILE:fresco-scene-render-smoke>"
                "${FRESCO_SCENE_WORKSHOP_ROOT}"
                "${FRESCO_SCENE_ASSETS}"
        )
        set_tests_properties(
            fresco-scene-renderer-procedural-effect-compositing-render
            PROPERTIES TIMEOUT 420
        )
        add_test(
            NAME fresco-scene-renderer-arknights-particle-promotion
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/arknights_particle_promotion_test.py"
                "$<TARGET_FILE:fresco-scene-render-smoke>"
                "${FRESCO_SCENE_WORKSHOP_ROOT}"
                "${FRESCO_SCENE_ASSETS}"
        )
        set_tests_properties(
            fresco-scene-renderer-arknights-particle-promotion
            PROPERTIES TIMEOUT 420
        )
        add_test(
            NAME fresco-scene-renderer-lonely-parent-image-render
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/lonely_parent_image_render_test.py"
                "$<TARGET_FILE:fresco-scene-render-smoke>"
                "${FRESCO_SCENE_WORKSHOP_ROOT}"
                "${FRESCO_SCENE_ASSETS}"
        )
        set_tests_properties(
            fresco-scene-renderer-lonely-parent-image-render
            PROPERTIES TIMEOUT 180
        )
        add_test(
            NAME fresco-scene-renderer-persona-hidden-at-construction-render
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/persona_hidden_at_construction_render_test.py"
                "$<TARGET_FILE:fresco-scene-render-smoke>"
                "${FRESCO_SCENE_WORKSHOP_ROOT}"
                "${FRESCO_SCENE_ASSETS}"
        )
        set_tests_properties(
            fresco-scene-renderer-persona-hidden-at-construction-render
            PROPERTIES TIMEOUT 300
        )
        add_test(
            NAME fresco-scene-renderer-persona-text-authored-z-render
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/persona_text_authored_z_render_test.py"
                "$<TARGET_FILE:fresco-scene-render-smoke>"
                "${FRESCO_SCENE_WORKSHOP_ROOT}"
                "${FRESCO_SCENE_ASSETS}"
        )
        set_tests_properties(
            fresco-scene-renderer-persona-text-authored-z-render
            PROPERTIES TIMEOUT 300
        )
        add_test(
            NAME fresco-scene-renderer-persona-dependency-render-order
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/persona_dependency_render_order_test.py"
                "$<TARGET_FILE:fresco-scene-render-smoke>"
                "${FRESCO_SCENE_WORKSHOP_ROOT}"
                "${FRESCO_SCENE_ASSETS}"
                "${CMAKE_CURRENT_BINARY_DIR}/evidence/persona-dependency-render-order"
        )
        set_tests_properties(
            fresco-scene-renderer-persona-dependency-render-order
            PROPERTIES TIMEOUT 300
        )
        add_test(
            NAME fresco-scene-renderer-persona-composition-layer-resolution-render
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/persona_composition_layer_resolution_render_test.py"
                "$<TARGET_FILE:fresco-scene-render-smoke>"
                "${FRESCO_SCENE_WORKSHOP_ROOT}"
                "${FRESCO_SCENE_ASSETS}"
        )
        set_tests_properties(
            fresco-scene-renderer-persona-composition-layer-resolution-render
            PROPERTIES TIMEOUT 600
        )
    endif()
    add_test(
        NAME fresco-scene-renderer-gbc-cursor-transform-script
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/gbc_cursor_transform_script_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-gbc-named-animation-script
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/gbc_named_animation_script_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-gbc-promotion-readiness
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/gbc_promotion_readiness_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
            --require-promotable
    )
    set_tests_properties(
        fresco-scene-renderer-gbc-promotion-readiness PROPERTIES
            TIMEOUT 900
            RUN_SERIAL TRUE
    )
    add_test(
        NAME fresco-scene-renderer-gbc-camera-2d-control
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/gbc_camera_2d_control_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-media-thumbnail-animation-script
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/media_thumbnail_animation_script_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-text-effect-render
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/text_effect_render_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-text-effect-chain-boundary
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/text_effect_chain_boundary_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-text-effect-construction-unwind
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/text_effect_construction_unwind_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-project-user-property-routing
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/project_user_property_routing_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-project-user-property-contract
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/project_user_property_contract_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    add_test(
        NAME fresco-scene-renderer-puppet-temporal
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/puppet_temporal_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-puppet-temporal PROPERTIES
            TIMEOUT 120
            ENVIRONMENT
                "FRESCO_SCENE_AUDIO_DISABLED=1;FRESCO_SCENE_SOUND_EXPERIMENTAL=0"
    )
    add_executable(
        fresco-scene-renderer-puppet-layer-semantics
        tests/puppet_layer_semantics_test.cpp
        src/PuppetLayerSemantics.cpp
    )
    target_include_directories(
        fresco-scene-renderer-puppet-layer-semantics PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-puppet-layer-semantics PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-puppet-layer-semantics
        COMMAND fresco-scene-renderer-puppet-layer-semantics
    )
    add_executable(
        fresco-scene-renderer-puppet-secondary-motion
        tests/puppet_secondary_motion_test.cpp
        src/PuppetSecondaryMotion.cpp
    )
    target_include_directories(
        fresco-scene-renderer-puppet-secondary-motion PRIVATE include
    )
    target_compile_options(
        fresco-scene-renderer-puppet-secondary-motion PRIVATE
        -Wall -Wextra -Werror -Wpedantic -UNDEBUG
    )
    add_test(
        NAME fresco-scene-renderer-puppet-secondary-motion
        COMMAND fresco-scene-renderer-puppet-secondary-motion
    )
    add_test(
        NAME fresco-scene-renderer-puppet-model
        COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/puppet_model_test.sh"
    )
    set_tests_properties(
        fresco-scene-renderer-puppet-model PROPERTIES
            TIMEOUT 120
            ENVIRONMENT "FRESCO_WORKSHOP_ROOT=${FRESCO_SCENE_WORKSHOP_ROOT}"
    )
    add_test(
        NAME fresco-scene-renderer-performance
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/performance_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
    )
    set_tests_properties(
        fresco-scene-renderer-performance PROPERTIES
            TIMEOUT 30
            RUN_SERIAL TRUE
    )
    function(fresco_add_performance_promotion_test fixture fixture_id)
        add_test(
            NAME fresco-scene-renderer-performance-promotion-${fixture}
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/performance_promotion_runner.py"
                "$<TARGET_FILE:fresco-scene>"
                "${FRESCO_SCENE_WORKSHOP_ROOT}"
                "${FRESCO_SCENE_ASSETS}"
                "${FRESCO_SCENE_RENDER_BACKEND}"
                "${fixture_id}"
        )
        set_tests_properties(
            fresco-scene-renderer-performance-promotion-${fixture} PROPERTIES
                TIMEOUT 180
                RUN_SERIAL TRUE
                ENVIRONMENT
                    "FRESCO_SCENE_AUDIO_DISABLED=1;FRESCO_SCENE_SOUND_EXPERIMENTAL=0"
        )
    endfunction()
    fresco_add_performance_promotion_test(arknights 3460973721)
    fresco_add_performance_promotion_test(gbc 3448290956)
    fresco_add_performance_promotion_test(lonely 3299228616)
    option(
        FRESCO_SCENE_ENABLE_REACH_PERFORMANCE_GATES
        "Register assertion-style performance gates for reach fixtures"
        OFF
    )
    if(FRESCO_SCENE_ENABLE_REACH_PERFORMANCE_GATES)
        fresco_add_performance_promotion_test(elaina 3326873240)
        fresco_add_performance_promotion_test(hyuga 3479521040)
        fresco_add_performance_promotion_test(persona 3151551777)
    endif()
    add_test(
        NAME fresco-scene-renderer-sound-corpus
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/sound_corpus_test.py"
            "$<TARGET_FILE:fresco-scene-renderer-sound-decode-probe>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
    )
    add_test(
        NAME fresco-scene-renderer-sound-restart
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/sound_restart_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-sound-restart PROPERTIES TIMEOUT 120
    )
    add_test(
        NAME fresco-scene-renderer-sound-av-lifecycle
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/sound_av_lifecycle_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-sound-av-lifecycle PROPERTIES TIMEOUT 120
    )
    add_test(
        NAME fresco-scene-renderer-physical-sound-promotion
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/physical_sound_promotion_regression_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-physical-sound-promotion PROPERTIES
            TIMEOUT 900
            RUN_SERIAL TRUE
    )
    add_test(
        NAME fresco-scene-renderer-session-lifetime-ownership
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/session_lifetime_ownership_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-session-lifetime-ownership PROPERTIES
            TIMEOUT 180
            RUN_SERIAL TRUE
    )
    add_test(
        NAME fresco-scene-renderer-script-storage-integration
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/scene_script_storage_integration_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-script-storage-integration PROPERTIES
            TIMEOUT 180
            RUN_SERIAL TRUE
    )
    add_test(
        NAME fresco-scene-renderer-script-graph-construction-unwind
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/scene_script_graph_construction_unwind_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-script-graph-construction-unwind PROPERTIES
            TIMEOUT 180
            RUN_SERIAL TRUE
    )
    add_test(
        NAME fresco-scene-renderer-media-video-corpus
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/media_video_corpus_test.py"
            "$<TARGET_FILE:fresco-scene-renderer-media-video-probe>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
    )
    add_test(
        NAME fresco-scene-renderer-media-session-protocol
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/media_session_protocol_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
    )
    add_test(
        NAME fresco-scene-renderer-media-session-corpus
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/media_session_corpus_test.py"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
    )
    add_test(
        NAME fresco-scene-renderer-stretch-particle-corpus
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/stretch_particle_corpus_test.py"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
    )
    add_test(
        NAME fresco-scene-renderer-particle-audio-render
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/particle_audio_render_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
    )
    add_test(
        NAME fresco-scene-renderer-particle-child-render
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/particle_child_render_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
    )
    set_tests_properties(
        fresco-scene-renderer-particle-child-render PROPERTIES TIMEOUT 130
    )
    add_test(
        NAME fresco-scene-renderer-particle-child-ownership-soak
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/particle_child_ownership_soak_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-particle-child-ownership-soak PROPERTIES
            TIMEOUT 900
            RUN_SERIAL TRUE
    )
    add_test(
        NAME fresco-scene-renderer-particle-child-visual-ab
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/particle_child_visual_ab_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${FRESCO_SCENE_WORKSHOP_ROOT}"
            "${FRESCO_SCENE_ASSETS}"
            "${FRESCO_SCENE_RENDER_BACKEND}"
    )
    set_tests_properties(
        fresco-scene-renderer-particle-child-visual-ab PROPERTIES TIMEOUT 190
    )
    set_tests_properties(
        fresco-scene-renderer-particle-audio-render PROPERTIES
            TIMEOUT 70
            ENVIRONMENT
                "FRESCO_SCENE_AUDIO_DISABLED=1;FRESCO_SCENE_SOUND_EXPERIMENTAL=0"
    )
    set_tests_properties(
        fresco-scene-renderer-media-video-corpus PROPERTIES TIMEOUT 100
    )
    set_tests_properties(
        fresco-scene-renderer-helper
        fresco-scene-renderer-media-text-script
        fresco-scene-renderer-performance
        PROPERTIES ENVIRONMENT
            "FRESCO_SCENE_AUDIO_DISABLED=1;FRESCO_SCENE_SOUND_EXPERIMENTAL=0"
    )
    if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "native-opengl")
        set_tests_properties(
            fresco-scene-renderer-baselines
            PROPERTIES ENVIRONMENT
                "FRESCO_SCENE_AUDIO_DISABLED=1;FRESCO_SCENE_SOUND_EXPERIMENTAL=0"
        )
    endif()
    if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
        add_test(
            NAME fresco-scene-renderer-angle-temporal
            COMMAND
                "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/angle_temporal_test.py"
                "$<TARGET_FILE:fresco-scene>"
                "${FRESCO_SCENE_WORKSHOP_ROOT}"
                "${FRESCO_SCENE_ASSETS}"
                "${CMAKE_CURRENT_SOURCE_DIR}/../../fresco/tests/scene-fixtures.json"
        )
        set_tests_properties(
            fresco-scene-renderer-angle-temporal PROPERTIES
                TIMEOUT 270
                ENVIRONMENT
                    "FRESCO_SCENE_AUDIO_DISABLED=1;FRESCO_SCENE_SOUND_EXPERIMENTAL=0"
        )
    endif()
endif()
