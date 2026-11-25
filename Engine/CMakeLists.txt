# CMake configuration for the CPU and CUDA variants.
cmake_minimum_required(VERSION 3.21)
project(nbody_gpu VERSION 0.1.0 LANGUAGES CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}")

add_library(nbody_common
    src/common/state.cpp
    src/common/diagnostics.cpp
    src/common/initial_conditions.cpp
    src/common/benchmark.cpp)
target_include_directories(nbody_common PUBLIC include)
target_compile_features(nbody_common PUBLIC cxx_std_17)
set_target_properties(nbody_common PROPERTIES CXX_EXTENSIONS OFF)

add_library(nbody_simulation
    src/common/live.cpp
    src/common/simulation.cpp)
target_link_libraries(nbody_simulation PUBLIC nbody_common)
set_target_properties(nbody_simulation PROPERTIES CXX_EXTENSIONS OFF)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(nbody_common PRIVATE -Wall -Wextra -Wpedantic -ffp-contract=off)
    target_compile_options(nbody_simulation PRIVATE -Wall -Wextra -Wpedantic -ffp-contract=off)
endif()
add_executable(nbody_cpu src/main.cpp src/cpu/coalesced_access.cpp)
target_link_libraries(nbody_cpu PRIVATE nbody_simulation)
add_executable(nbody_cpu_naive src/cpu/naive.cpp)
target_link_libraries(nbody_cpu_naive PRIVATE nbody_common)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(nbody_cpu PRIVATE -Wall -Wextra -Wpedantic -ffp-contract=off)
    target_compile_options(nbody_cpu_naive PRIVATE -Wall -Wextra -Wpedantic -ffp-contract=off)
endif()

include(CheckLanguage)
# A previous configure may have run before CUDA was installed.
if(CMAKE_CUDA_COMPILER MATCHES "NOTFOUND$")
    unset(CMAKE_CUDA_COMPILER CACHE)
endif()
check_language(CUDA)
set(cuda_variants coalesced_access optim advanced_optim)
if(CMAKE_CUDA_COMPILER)
    enable_language(CUDA)
    set(CMAKE_CUDA_STANDARD 17)
    set(CMAKE_CUDA_STANDARD_REQUIRED YES)
    set(CMAKE_CUDA_EXTENSIONS OFF)

    foreach(variant IN LISTS cuda_variants)
        set(target "nbody_gpu_${variant}")
        string(REPLACE "_" "-" algo "${variant}")
        # This main is used for CUDA variants that only calculate forces.
        add_library("${target}_runner" STATIC src/main.cpp)
        target_compile_definitions("${target}_runner" PRIVATE "NBODY_GPU_FORCE_VARIANT=\"gpu-${algo}\"")
        target_link_libraries("${target}_runner" PUBLIC nbody_simulation)
        add_executable("${target}" "src/gpu/${variant}.cu")
        target_link_libraries("${target}" PRIVATE "${target}_runner")
    endforeach()

    add_executable(nbody_gpu_naive src/gpu/naive.cu)
    target_link_libraries(nbody_gpu_naive PRIVATE nbody_common)
else()
    foreach(variant IN ITEMS ${cuda_variants} naive)
        add_custom_target("nbody_gpu_${variant}"
            COMMAND "${CMAKE_COMMAND}" -E echo "CUDA compiler not found. Install the NVIDIA CUDA Toolkit to build this GPU variant."
            COMMAND "${CMAKE_COMMAND}" -E false
            VERBATIM)
    endforeach()
endif()
