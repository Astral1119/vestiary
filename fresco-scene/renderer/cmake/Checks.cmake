function(fresco_scene_assert_unique_source_ownership)
    set(owned_sources)
    foreach(assignment IN LISTS ARGN)
        string(REPLACE "|" ";" fields "${assignment}")
        list(GET fields 0 owner)
        list(GET fields 1 source)
        cmake_path(ABSOLUTE_PATH source
            BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
            NORMALIZE OUTPUT_VARIABLE absolute_source)
        list(FIND owned_sources "${absolute_source}" existing_index)
        if(NOT existing_index EQUAL -1)
            list(GET owned_sources ${existing_index} existing_source)
            message(FATAL_ERROR
                "production source has duplicate ownership: ${source} in ${owner}; normalized source already assigned as ${existing_source}")
        endif()
        list(APPEND owned_sources "${absolute_source}")
    endforeach()
endfunction()

set(fresco_scene_production_assignments
    "fresco-scene-helper-main|../src/main.mm"
    "fresco-scene-session|src/RendererSession.mm")
foreach(source IN LISTS fresco_scene_audio_sources)
    list(APPEND fresco_scene_production_assignments
        "fresco-scene-audio|${source}")
endforeach()
foreach(source IN LISTS fresco_scene_media_sources)
    list(APPEND fresco_scene_production_assignments
        "fresco-scene-media|${source}")
endforeach()
foreach(source IN LISTS fresco_scene_particle_compatibility_sources)
    list(APPEND fresco_scene_production_assignments
        "fresco-scene-particle-compatibility|${source}")
endforeach()
foreach(source IN LISTS fresco_scene_sound_semantic_sources)
    list(APPEND fresco_scene_production_assignments
        "fresco-scene-sound-semantic|${source}")
endforeach()
foreach(source IN LISTS fresco_scene_scheduler_sources)
    list(APPEND fresco_scene_production_assignments
        "fresco-scene-scheduler|${source}")
endforeach()
foreach(source IN LISTS fresco_scene_change_index_sources)
    list(APPEND fresco_scene_production_assignments
        "fresco-scene-change-index|${source}")
endforeach()
foreach(source IN LISTS fresco_scene_evidence_sources)
    list(APPEND fresco_scene_production_assignments
        "fresco-scene-evidence|${source}")
endforeach()
foreach(group IN ITEMS
    script audio media particle puppet text_effect effect)
    foreach(source IN LISTS fresco_scene_${group}_system_sources)
        list(APPEND fresco_scene_production_assignments
            "fresco-scene-system-${group}|${source}")
    endforeach()
endforeach()
foreach(source IN LISTS fresco_scene_we_import_sources)
    list(APPEND fresco_scene_production_assignments
        "fresco-scene-we-import|${source}")
endforeach()
foreach(source IN LISTS fresco_scene_we_generated_sources)
    list(APPEND fresco_scene_production_assignments
        "fresco-scene-we-generated|${source}")
endforeach()
foreach(source IN LISTS fresco_scene_legacy_gl_sources)
    list(APPEND fresco_scene_production_assignments
        "fresco-scene-legacy-gl|${source}")
endforeach()
list(APPEND fresco_scene_production_assignments
    "${fresco_scene_surface_target}|src/RenderBackend.cpp")
if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "native-opengl")
    list(APPEND fresco_scene_production_assignments
        "fresco-scene-surface-opengl|src/NativeOpenGLSurface.mm")
elseif(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
    list(APPEND fresco_scene_production_assignments
        "fresco-scene-surface-angle|src/AngleMetalSurface.mm")
endif()
fresco_scene_assert_unique_source_ownership(
    ${fresco_scene_production_assignments})

function(fresco_scene_assert_boundary_source source)
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/${source}" contents)
    if(contents MATCHES
       "#[ \t]*include[ \t]*[<\"]WallpaperEngine/|generated/include|#[ \t]*include[ \t]*[<\"]compat/")
        message(FATAL_ERROR
            "boundary source includes GPL compatibility material: ${source}")
    endif()
endfunction()
foreach(source IN LISTS
    fresco_scene_scheduler_sources
    fresco_scene_change_index_sources
    fresco_scene_evidence_sources)
    fresco_scene_assert_boundary_source("${source}")
endforeach()

foreach(target IN ITEMS
    fresco-scene-helper-main
    fresco-scene-protocol
    fresco-scene-session
    fresco-scene-scheduler
    fresco-scene-change-index
    fresco-scene-draw-contract
    fresco-scene-evidence
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
    fresco-scene-system-effects
    fresco-scene-systems
    fresco-scene-we-import
    fresco-scene-we-generated
    fresco-scene-we-runtime
    fresco-scene-legacy-gl
    ${fresco_scene_surface_target}
    fresco-scene-renderer-core)
    get_target_property(provenance ${target} FRESCO_SCENE_PROVENANCE)
    if(NOT provenance)
        message(FATAL_ERROR "focused target lacks provenance: ${target}")
    endif()
endforeach()

function(fresco_scene_assert_exact_internal_edges target property)
    set(expected ${ARGN})
    get_target_property(dependencies ${target} ${property})
    if(NOT dependencies)
        set(dependencies)
    endif()
    set(actual)
    foreach(dependency IN LISTS dependencies)
        if(dependency MATCHES "^fresco-scene-")
            list(APPEND actual "${dependency}")
        endif()
    endforeach()
    list(SORT actual)
    list(SORT expected)
    if(NOT "${actual}" STREQUAL "${expected}")
        message(FATAL_ERROR
            "unexpected internal edges for ${target}: expected [${expected}], found [${actual}]")
    endif()
endfunction()

fresco_scene_assert_exact_internal_edges(
    fresco-scene-helper-main LINK_LIBRARIES
    fresco-scene-protocol
    fresco-scene-session)
fresco_scene_assert_exact_internal_edges(
    fresco-scene-session LINK_LIBRARIES
    fresco-scene-change-index
    fresco-scene-draw-contract
    fresco-scene-evidence
    fresco-scene-scheduler
    fresco-scene-systems
    fresco-scene-we-runtime)
fresco_scene_assert_exact_internal_edges(
    fresco-scene-systems INTERFACE_LINK_LIBRARIES
    fresco-scene-audio
    fresco-scene-media
    fresco-scene-particle-compatibility
    fresco-scene-sound-semantic
    fresco-scene-system-audio
    fresco-scene-system-effects
    fresco-scene-system-media
    fresco-scene-system-particles
    fresco-scene-system-puppet
    fresco-scene-system-script
    fresco-scene-system-text-effects)
fresco_scene_assert_exact_internal_edges(
    fresco-scene-we-runtime INTERFACE_LINK_LIBRARIES
    fresco-scene-legacy-gl
    fresco-scene-we-generated
    fresco-scene-we-import
    ${fresco_scene_surface_target})

function(fresco_scene_assert_exact_object_expansion target)
    set(expected ${ARGN})
    get_target_property(sources ${target} SOURCES)
    set(actual)
    foreach(source IN LISTS sources)
        if(source MATCHES "^\\$<TARGET_OBJECTS:")
            list(APPEND actual "${source}")
        endif()
    endforeach()
    list(SORT actual)
    list(SORT expected)
    if(NOT "${actual}" STREQUAL "${expected}")
        message(FATAL_ERROR
            "unexpected object expansion for ${target}: expected [${expected}], found [${actual}]")
    endif()
endfunction()

fresco_scene_assert_exact_object_expansion(fresco-scene-renderer-core
    "$<TARGET_OBJECTS:fresco-scene-scheduler>"
    "$<TARGET_OBJECTS:fresco-scene-change-index>"
    "$<TARGET_OBJECTS:fresco-scene-evidence>"
    "$<TARGET_OBJECTS:fresco-scene-system-script>"
    "$<TARGET_OBJECTS:fresco-scene-system-audio>"
    "$<TARGET_OBJECTS:fresco-scene-system-media>"
    "$<TARGET_OBJECTS:fresco-scene-system-particles>"
    "$<TARGET_OBJECTS:fresco-scene-system-puppet>"
    "$<TARGET_OBJECTS:fresco-scene-system-text-effects>"
    "$<TARGET_OBJECTS:fresco-scene-system-effects>"
    "$<TARGET_OBJECTS:fresco-scene-we-import>"
    "$<TARGET_OBJECTS:fresco-scene-we-generated>"
    "$<TARGET_OBJECTS:fresco-scene-legacy-gl>"
    "$<TARGET_OBJECTS:${fresco_scene_surface_target}>")
fresco_scene_assert_exact_object_expansion(fresco-scene
    "$<TARGET_OBJECTS:fresco-scene-helper-main>"
    "$<TARGET_OBJECTS:fresco-scene-session>")

foreach(target IN ITEMS fresco-scene-systems fresco-scene-we-runtime)
    get_target_property(role ${target} FRESCO_SCENE_TARGET_ROLE)
    if(NOT role STREQUAL "non-owning-object-group")
        message(FATAL_ERROR
            "object grouping target must declare its non-owning role: ${target}")
    endif()
endforeach()

get_target_property(core_interface_includes
    fresco-scene-renderer-core INTERFACE_INCLUDE_DIRECTORIES)
foreach(include IN LISTS core_interface_includes)
    if(include MATCHES "WallpaperEngine|generated|/compat($|/)")
        message(FATAL_ERROR
            "renderer-core exports a GPL implementation include: ${include}")
    endif()
endforeach()
