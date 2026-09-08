cmake_minimum_required(VERSION 3.20)

project(udp_benchmark_receiver LANGUAGES CXX)

set(
    UDP_BENCHMARK_CONFIGURATION ""
    CACHE STRING "Configuration selected by build.ps1"
)

if(CMAKE_CONFIGURATION_TYPES)
    set(
        CMAKE_CONFIGURATION_TYPES
        Debug Release RelWithDebInfo MinSizeRel
        CACHE STRING "Build configurations" FORCE
    )
elseif(UDP_BENCHMARK_CONFIGURATION)
    set(
        CMAKE_BUILD_TYPE "${UDP_BENCHMARK_CONFIGURATION}"
        CACHE STRING "Build type" FORCE
    )
elseif(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

add_executable(udp_benchmark_receiver udp_benchmark_receiver.cpp)
target_compile_features(udp_benchmark_receiver PRIVATE cxx_std_17)
if(WIN32)
    target_compile_definitions(
        udp_benchmark_receiver
        PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX
    )
    target_link_libraries(udp_benchmark_receiver PRIVATE Ws2_32)
endif()

if(MSVC)
    target_compile_options(udp_benchmark_receiver PRIVATE /W4 /permissive-)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(udp_benchmark_receiver PRIVATE -Wall -Wextra -Wpedantic)
endif()
