set(FRESCO_SCENE_RENDERER_COMMIT b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d)
set(FRESCO_SCENE_GLM_COMMIT 0af55ccecd98d4e5a8d1fad7de25ba429d60e863)
set(upstream "${FRESCO_SCENE_RENDERER_UPSTREAM}")

include(FetchContent)
if(NOT upstream)
    FetchContent_Declare(
        linux_wallpaperengine
        GIT_REPOSITORY https://github.com/Almamu/linux-wallpaperengine.git
        GIT_TAG ${FRESCO_SCENE_RENDERER_COMMIT}
        GIT_SHALLOW FALSE
        GIT_SUBMODULES
            src/External/SPIRV-Cross-WallpaperEngine
            src/External/glslang-WallpaperEngine
            src/External/json
            src/External/quickjs
            src/External/stb
        GIT_SUBMODULES_RECURSE FALSE
        SOURCE_SUBDIR fresco-scene-no-upstream-root-target
    )
    FetchContent_MakeAvailable(linux_wallpaperengine)
    set(upstream "${linux_wallpaperengine_SOURCE_DIR}")
endif()

if(NOT EXISTS "${upstream}/src/WallpaperEngine/Render/Objects/CImage.cpp")
    message(FATAL_ERROR "FRESCO_SCENE_RENDERER_UPSTREAM is not a linux-wallpaperengine checkout")
endif()

execute_process(
    COMMAND git -C "${upstream}" rev-parse HEAD
    OUTPUT_VARIABLE upstream_commit
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE upstream_git_result
)
if(NOT upstream_git_result EQUAL 0 OR
   NOT upstream_commit STREQUAL FRESCO_SCENE_RENDERER_COMMIT)
    message(FATAL_ERROR
        "renderer proof requires linux-wallpaperengine ${FRESCO_SCENE_RENDERER_COMMIT}; found ${upstream_commit}")
endif()

set(FRESCO_SCENE_RUNTIME_AVAILABLE false)

if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "native-opengl")
    set(FRESCO_SCENE_BACKEND_ID native-opengl)
    set(FRESCO_SCENE_RENDERER_ID opengl-4.1-2d)
    set(FRESCO_SCENE_GRAPHICS_API "OpenGL 4.1 core")
    set(FRESCO_SCENE_SHADER_VERSION 410)
    set(FRESCO_SCENE_SHADER_ES false)
    set(FRESCO_SCENE_RUNTIME_AVAILABLE true)
elseif(FRESCO_SCENE_RENDER_BACKEND MATCHES "^angle-")
    if(NOT EXISTS "${FRESCO_SCENE_ANGLE_INCLUDE_DIR}/GLES3/gl3.h")
        message(FATAL_ERROR
            "ANGLE builds require FRESCO_SCENE_ANGLE_INCLUDE_DIR containing GLES3/gl3.h")
    endif()
    set(FRESCO_SCENE_SHADER_VERSION 300)
    set(FRESCO_SCENE_SHADER_ES true)
    if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
        if(NOT EXISTS "${FRESCO_SCENE_ANGLE_LIBRARY_DIR}/libEGL.dylib" OR
           NOT EXISTS "${FRESCO_SCENE_ANGLE_LIBRARY_DIR}/libGLESv2.dylib")
            message(FATAL_ERROR
                "angle-metal requires FRESCO_SCENE_ANGLE_LIBRARY_DIR containing libEGL.dylib and libGLESv2.dylib")
        endif()
        set(FRESCO_SCENE_BACKEND_ID angle-metal)
        set(FRESCO_SCENE_RENDERER_ID angle-metal-es3-2d)
        set(FRESCO_SCENE_GRAPHICS_API "OpenGL ES 3.0 via ANGLE Metal")
        set(FRESCO_SCENE_RUNTIME_AVAILABLE true)
    else()
        set(FRESCO_SCENE_BACKEND_ID angle-gles-compile)
        set(FRESCO_SCENE_RENDERER_ID unavailable)
        set(FRESCO_SCENE_GRAPHICS_API "OpenGL ES 3.0 compile gate")
    endif()
else()
    message(FATAL_ERROR
        "unknown FRESCO_SCENE_RENDER_BACKEND: ${FRESCO_SCENE_RENDER_BACKEND}")
endif()
set(FRESCO_SCENE_SHADER_LANGUAGE GLSL)
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated/include")
configure_file(
    src/RenderBackendConfiguration.h.in
    generated/include/RenderBackendConfiguration.h
    @ONLY
)

function(fresco_require_generated_patch source_variable marker description)
    string(FIND "${${source_variable}}" "${marker}" patch_position)
    if(patch_position EQUAL -1)
        message(FATAL_ERROR
            "cannot apply pinned renderer compatibility patch: ${description}")
    endif()
endfunction()

function(fresco_require_generated_patch_count source_variable marker expected description)
    string(REGEX MATCHALL "${marker}" patch_matches "${${source_variable}}")
    list(LENGTH patch_matches patch_count)
    if(NOT patch_count EQUAL expected)
        message(FATAL_ERROR
            "pinned renderer compatibility patch count mismatch for ${description}: expected ${expected}, found ${patch_count}")
    endif()
endfunction()

function(fresco_write_generated output source_variable)
    set(contents "${${source_variable}}")
    unset(existing)
    if(EXISTS "${output}")
        file(READ "${output}" existing)
    endif()
    if(NOT DEFINED existing OR NOT existing STREQUAL contents)
        file(WRITE "${output}" "${contents}")
    endif()
endfunction()

FetchContent_Declare(
    glm
    GIT_REPOSITORY https://github.com/g-truc/glm.git
    GIT_TAG ${FRESCO_SCENE_GLM_COMMIT}
    GIT_SHALLOW FALSE
)
FetchContent_MakeAvailable(glm)

set(ENABLE_GLSLANG_BINARIES OFF CACHE BOOL "" FORCE)
set(ENABLE_SPVREMAPPER OFF CACHE BOOL "" FORCE)
set(ENABLE_OPT OFF CACHE BOOL "" FORCE)
set(GLSLANG_TESTS OFF CACHE BOOL "" FORCE)
set(GLSLANG_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_CLI OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_HLSL OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_MSL OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_CPP OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_REFLECT OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_C_API OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_UTIL OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_SKIP_INSTALL ON CACHE BOOL "" FORCE)
add_subdirectory(
    ${upstream}/src/External/glslang-WallpaperEngine
    ${CMAKE_CURRENT_BINARY_DIR}/glslang
    EXCLUDE_FROM_ALL
)
add_subdirectory(
    ${upstream}/src/External/SPIRV-Cross-WallpaperEngine
    ${CMAKE_CURRENT_BINARY_DIR}/spirv-cross
    EXCLUDE_FROM_ALL
)
set(QJS_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(QJS_BUILD_WERROR OFF CACHE BOOL "" FORCE)
add_subdirectory(
    ${upstream}/src/External/quickjs
    ${CMAKE_CURRENT_BINARY_DIR}/quickjs
    EXCLUDE_FROM_ALL
)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LZ4 REQUIRED IMPORTED_TARGET liblz4)
find_package(Freetype REQUIRED)
