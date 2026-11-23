# Build the CPU engine, optional CUDA executable, and local tests when available.
cmake_minimum_required(VERSION 3.21)
project(nbody_gpu VERSION 0.1.0 LANGUAGES CXX)
include(CTest)
option(NBODY_SANITIZERS "Enable address and undefined-behavior sanitizers" OFF)
option(NBODY_CUDA "Build the CUDA benchmark" OFF)

add_library(nbody_common
    src/common/state.cpp
    src/common/diagnostics.cpp
    src/common/initial_conditions.cpp
    src/common/benchmark.cpp)
target_include_directories(nbody_common PUBLIC include)
target_compile_features(nbody_common PUBLIC cxx_std_17)
set_target_properties(nbody_common PROPERTIES CXX_EXTENSIONS OFF)

add_library(nbody_cpu_engine
    src/common/live.cpp
    src/cpu/forces.cpp
    src/cpu/simulation.cpp)
target_link_libraries(nbody_cpu_engine PUBLIC nbody_common)
set_target_properties(nbody_cpu_engine PROPERTIES CXX_EXTENSIONS OFF)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(nbody_common PRIVATE -Wall -Wextra -Wpedantic -ffp-contract=off)
    target_compile_options(nbody_cpu_engine PRIVATE -Wall -Wextra -Wpedantic -ffp-contract=off)
endif()
if(NBODY_SANITIZERS)
    if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
        message(FATAL_ERROR "NBODY_SANITIZERS requires Clang or GCC")
    endif()
    target_compile_options(nbody_common PUBLIC -fsanitize=address,undefined -fno-omit-frame-pointer)
    target_link_options(nbody_common PUBLIC -fsanitize=address,undefined)
endif()
add_executable(nbody_cpu src/cpu/main.cpp)
target_link_libraries(nbody_cpu PRIVATE nbody_cpu_engine)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(nbody_cpu PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(NBODY_CUDA)
    if(NBODY_SANITIZERS)
        message(FATAL_ERROR "Use the CPU sanitizer preset for AddressSanitizer and UBSan")
    endif()
    enable_language(CUDA)
    add_executable(nbody_gpu_naive src/gpu/naive.cu)
    target_link_libraries(nbody_gpu_naive PRIVATE nbody_common)
    set_target_properties(nbody_gpu_naive PROPERTIES CUDA_STANDARD 17 CUDA_STANDARD_REQUIRED YES CUDA_EXTENSIONS OFF)
endif()

if(BUILD_TESTING AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/CMakeLists.txt")
    add_subdirectory(tests)
endif()
