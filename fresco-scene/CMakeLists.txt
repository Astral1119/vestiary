cmake_minimum_required(VERSION 3.25)

project(fresco-scene VERSION 0.1.0 LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(FRESCO_SCENE_RENDER_BACKEND native-opengl CACHE STRING
    "Scene renderer build backend")
set_property(CACHE FRESCO_SCENE_RENDER_BACKEND PROPERTY STRINGS
    native-opengl angle-gles-compile angle-metal)
set(valid_render_backends native-opengl angle-gles-compile angle-metal)
if(NOT FRESCO_SCENE_RENDER_BACKEND IN_LIST valid_render_backends)
    message(FATAL_ERROR
        "unknown FRESCO_SCENE_RENDER_BACKEND: ${FRESCO_SCENE_RENDER_BACKEND}")
endif()

set(FRESCO_SCENE_RENDERER_UPSTREAM "" CACHE PATH
    "Pinned linux-wallpaperengine checkout used by the renderer proof")
option(FRESCO_SCENE_BUILD_RENDERER "Build the pinned 2D renderer proof" OFF)
option(FRESCO_SCENE_BUILD_SDL3_GPU_SPIKE
    "Build the isolated SDL3 GPU architecture spike" OFF)
set(FRESCO_SCENE_ANGLE_INCLUDE_DIR "" CACHE PATH
    "ANGLE include directory")
set(FRESCO_SCENE_ANGLE_LIBRARY_DIR "" CACHE PATH
    "ANGLE library directory used by the opt-in runtime build")

if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
    if(NOT FRESCO_SCENE_BUILD_RENDERER AND NOT FRESCO_SCENE_RENDERER_UPSTREAM)
        message(FATAL_ERROR
            "angle-metal requires FRESCO_SCENE_BUILD_RENDERER=ON")
    endif()
    if(NOT EXISTS "${FRESCO_SCENE_ANGLE_INCLUDE_DIR}/GLES3/gl3.h")
        message(FATAL_ERROR
            "angle-metal requires FRESCO_SCENE_ANGLE_INCLUDE_DIR containing GLES3/gl3.h")
    endif()
    if(NOT EXISTS "${FRESCO_SCENE_ANGLE_LIBRARY_DIR}/libEGL.dylib" OR
       NOT EXISTS "${FRESCO_SCENE_ANGLE_LIBRARY_DIR}/libGLESv2.dylib")
        message(FATAL_ERROR
            "angle-metal requires FRESCO_SCENE_ANGLE_LIBRARY_DIR containing libEGL.dylib and libGLESv2.dylib")
    endif()
endif()

add_library(fresco-scene-helper-main OBJECT
    src/main.mm
)
add_library(fresco-scene-protocol INTERFACE)
target_sources(fresco-scene-protocol INTERFACE
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/PROTOCOL.md>"
)

add_executable(fresco-scene
    $<TARGET_OBJECTS:fresco-scene-helper-main>
)

set(fresco_scene_sound_semantic_sources
    ${CMAKE_CURRENT_SOURCE_DIR}/renderer/src/SceneSoundSemanticCapability.cpp
)
add_library(fresco-scene-sound-semantic STATIC
    ${fresco_scene_sound_semantic_sources}
)
target_include_directories(fresco-scene-sound-semantic PUBLIC
    include
    renderer/include
)
target_compile_options(fresco-scene-sound-semantic PRIVATE
    -Wall
    -Wextra
    -Werror
    -Wpedantic
)

target_include_directories(fresco-scene-helper-main PRIVATE
    include
    renderer/include
    upstream/src
)
target_include_directories(fresco-scene PRIVATE include upstream/src)
target_compile_options(fresco-scene-helper-main PRIVATE
    -Wall
    -Wextra
    -Werror
    -Wpedantic
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
)
target_compile_options(fresco-scene PRIVATE
    -Wall
    -Wextra
    -Werror
    -Wpedantic
)
set_source_files_properties(
    upstream/src/WallpaperEngine/Data/Parsers/PackageParser.cpp
    upstream/src/WallpaperEngine/Logging/Log.cpp
    PROPERTIES COMPILE_OPTIONS -Wno-unused-parameter
)
target_compile_options(fresco-scene-helper-main PRIVATE
    -Wno-deprecated-declarations
)
target_link_libraries(fresco-scene PRIVATE
    "-framework AppKit"
)
if(NOT FRESCO_SCENE_BUILD_RENDERER AND NOT FRESCO_SCENE_RENDERER_UPSTREAM)
    target_sources(fresco-scene PRIVATE
        upstream/src/WallpaperEngine/Data/Parsers/PackageParser.cpp
        upstream/src/WallpaperEngine/Data/Utils/BinaryReader.cpp
        upstream/src/WallpaperEngine/Logging/Log.cpp
        renderer/src/SceneEventCompatibility.cpp
        renderer/src/SceneScript2DCapability.cpp
        renderer/src/SceneScriptCompatibility.cpp
    )
    target_link_libraries(fresco-scene PRIVATE fresco-scene-sound-semantic)
endif()
if(NOT FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
    target_link_libraries(fresco-scene PRIVATE "-framework OpenGL")
else()
    target_compile_definitions(fresco-scene PRIVATE FRESCO_SCENE_ANGLE_RUNTIME=1)
endif()

if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
    install(CODE [[
        message(FATAL_ERROR
            "angle-metal installation is unsupported until its runtime libraries and licenses are packaged")
    ]])
else()
    install(TARGETS fresco-scene RUNTIME DESTINATION bin)
endif()

include(CTest)
if(FRESCO_SCENE_BUILD_SDL3_GPU_SPIKE)
    if(NOT APPLE)
        message(FATAL_ERROR
            "the first SDL3 GPU spike slice is intentionally Metal-only")
    endif()
    if(NOT CMAKE_C_COMPILER_ID STREQUAL "AppleClang" OR
       NOT CMAKE_CXX_COMPILER_ID STREQUAL "AppleClang")
        message(FATAL_ERROR
            "the SDL3 Metal spike requires Apple Clang; configure C and CXX with /usr/bin/clang and /usr/bin/clang++")
    endif()
    include(FetchContent)
    set(SDL_SHARED OFF CACHE BOOL "" FORCE)
    set(SDL_STATIC ON CACHE BOOL "" FORCE)
    set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
    set(SDL_TESTS OFF CACHE BOOL "" FORCE)
    set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(SDL_INSTALL OFF CACHE BOOL "" FORCE)
    FetchContent_Declare(
        fresco_scene_sdl3
        URL https://github.com/libsdl-org/SDL/releases/download/release-3.4.10/SDL3-3.4.10.tar.gz
        URL_HASH SHA256=12b34280415ec8418c864408b93d008a20a6530687ee613d60bfbd20411f2785
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    )
    FetchContent_MakeAvailable(fresco_scene_sdl3)
    add_subdirectory(spikes/sdl3-gpu)
endif()
if(FRESCO_SCENE_BUILD_RENDERER OR FRESCO_SCENE_RENDERER_UPSTREAM)
    add_subdirectory(renderer)
endif()
if(FRESCO_SCENE_RENDER_BACKEND STREQUAL "angle-metal")
    add_custom_command(TARGET fresco-scene POST_BUILD
        COMMAND "${CMAKE_INSTALL_NAME_TOOL}"
            -change ./libEGL.dylib @rpath/libEGL.dylib
            "$<TARGET_FILE:fresco-scene>"
        COMMAND "${CMAKE_INSTALL_NAME_TOOL}"
            -change ./libGLESv2.dylib @rpath/libGLESv2.dylib
            "$<TARGET_FILE:fresco-scene>"
        VERBATIM
    )
endif()

if(BUILD_TESTING)
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    add_executable(
        fresco-scene-sound-semantic-test
        renderer/tests/scene_sound_semantic_capability_test.cpp
    )
    target_link_libraries(
        fresco-scene-sound-semantic-test PRIVATE fresco-scene-sound-semantic
    )
    add_test(
        NAME fresco-scene-sound-semantic
        COMMAND fresco-scene-sound-semantic-test
    )
    add_test(
        NAME fresco-scene-protocol
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/protocol_test.py"
            "$<TARGET_FILE:fresco-scene>"
            "${CMAKE_CURRENT_SOURCE_DIR}/../fresco/tests/scene-fixtures.json"
    )
    add_test(
        NAME fresco-scene-common-harness-contract
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tools/common-harness/test_contract.py"
    )
    add_test(
        NAME fresco-scene-common-harness-adapter
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tools/common-harness/test_adapter.py"
    )
    add_test(
        NAME fresco-scene-common-harness-minimal-3d-contract
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tools/common-harness/test_minimal_3d_contract.py"
    )
    # The profiling sampler's parsers are pure functions over powermetrics,
    # pmset, vm_stat, ps and sysctl output, so they are testable against
    # fixtures without root and belong in the ordinary suite. They arrived on a
    # branch that registered nothing, and went unrun here for a week.
    add_test(
        NAME fresco-scene-common-harness-profiling
        COMMAND
            "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/tools/common-harness/test_profiling.py"
    )
    set_tests_properties(
        fresco-scene-common-harness-contract PROPERTIES
            ENVIRONMENT "PYTHONDONTWRITEBYTECODE=1"
    )
    set_tests_properties(
        fresco-scene-common-harness-profiling PROPERTIES
            ENVIRONMENT "PYTHONDONTWRITEBYTECODE=1"
    )
    set_tests_properties(
        fresco-scene-common-harness-adapter PROPERTIES
            TIMEOUT 60
            ENVIRONMENT "PYTHONDONTWRITEBYTECODE=1"
    )
    set_tests_properties(
        fresco-scene-common-harness-minimal-3d-contract PROPERTIES
            ENVIRONMENT "PYTHONDONTWRITEBYTECODE=1"
    )
endif()
