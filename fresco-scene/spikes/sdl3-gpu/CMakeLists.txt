find_package(Python3 REQUIRED COMPONENTS Interpreter)

set(generated_header "${CMAKE_CURRENT_BINARY_DIR}/generated/FixtureData.h")
add_custom_command(
    OUTPUT "${generated_header}"
    COMMAND "${Python3_EXECUTABLE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/generate_fixture_header.py"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/common-harness/workloads/minimal-3d/fixture-v1.json"
        "${generated_header}"
    DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/generate_fixture_header.py"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/common-harness/workloads/minimal-3d/fixture-v1.json"
    VERBATIM
)

add_executable(fresco-scene-sdl3-gpu-spike
    main.cpp
    "${generated_header}"
)
target_include_directories(fresco-scene-sdl3-gpu-spike PRIVATE
    "${CMAKE_CURRENT_BINARY_DIR}/generated"
)
target_compile_definitions(fresco-scene-sdl3-gpu-spike PRIVATE
    FRESCO_SDL3_GPU_SHADER_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/shaders"
)
target_compile_options(fresco-scene-sdl3-gpu-spike PRIVATE
    -Wall -Wextra -Werror -Wpedantic
)
target_link_libraries(fresco-scene-sdl3-gpu-spike PRIVATE SDL3::SDL3-static)

add_executable(fresco-scene-sdl3-presentation-spike
    PresentationScheduler.cpp
    presentation.cpp
)
target_compile_options(fresco-scene-sdl3-presentation-spike PRIVATE
    -Wall -Wextra -Werror -Wpedantic
)
target_link_libraries(fresco-scene-sdl3-presentation-spike PRIVATE
    SDL3::SDL3-static
)

if(BUILD_TESTING)
    add_test(
        NAME fresco-scene-sdl3-gpu-depth-probe
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/sdl3_gpu_spike_test.py"
            --mode probe
            --executable $<TARGET_FILE:fresco-scene-sdl3-gpu-spike>
            --reference-root
                "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/common-harness/workloads/minimal-3d"
    )
    add_test(
        NAME fresco-scene-sdl3-gpu-correctness
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/sdl3_gpu_spike_test.py"
            --mode gate
            --executable $<TARGET_FILE:fresco-scene-sdl3-gpu-spike>
            --reference-root
                "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/common-harness/workloads/minimal-3d"
    )
    add_test(
        NAME fresco-scene-sdl3-gpu-evidence-archive
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/test_sdl3_gpu_evidence_archive.py"
    )
    add_test(
        NAME fresco-scene-sdl3-presentation-correctness
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/sdl3_presentation_test_v3.py"
            --executable $<TARGET_FILE:fresco-scene-sdl3-presentation-spike>
            --reference-root
                "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/common-harness/workloads"
    )
    add_test(
        NAME fresco-scene-sdl3-presentation-hostile
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/test_sdl3_presentation_evidence_v3.py"
            --executable $<TARGET_FILE:fresco-scene-sdl3-presentation-spike>
            --reference-root
                "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/common-harness/workloads"
    )
    add_test(
        NAME fresco-scene-sdl3-presentation-evidence-archive
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/test_sdl3_presentation_evidence_archive.py"
    )
    add_test(
        NAME fresco-scene-sdl3-presentation-evidence-archive-v2
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/test_sdl3_presentation_evidence_archive_v2.py"
    )
    add_test(
        NAME fresco-scene-sdl3-presentation-evidence-archive-v3
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/test_sdl3_presentation_evidence_archive_v3.py"
    )
    set_tests_properties(
        fresco-scene-sdl3-gpu-depth-probe
        fresco-scene-sdl3-gpu-correctness
        fresco-scene-sdl3-gpu-evidence-archive
        fresco-scene-sdl3-presentation-correctness
        fresco-scene-sdl3-presentation-hostile
        fresco-scene-sdl3-presentation-evidence-archive
        fresco-scene-sdl3-presentation-evidence-archive-v2
        fresco-scene-sdl3-presentation-evidence-archive-v3
        PROPERTIES ENVIRONMENT "PYTHONDONTWRITEBYTECODE=1"
    )
endif()
