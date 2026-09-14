cmake_minimum_required(VERSION 3.20)
project(rdma_ring_receiver LANGUAGES CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(IBVERBS REQUIRED IMPORTED_TARGET libibverbs)

add_executable(rdma_ring_receiver rdma_ring_receiver.cpp)
target_compile_features(rdma_ring_receiver PRIVATE cxx_std_17)
set_target_properties(rdma_ring_receiver PROPERTIES CXX_EXTENSIONS OFF)
target_compile_options(rdma_ring_receiver PRIVATE -Wall -Wextra -Werror)
target_link_libraries(rdma_ring_receiver PRIVATE PkgConfig::IBVERBS)

include(CTest)
if(BUILD_TESTING)
  add_executable(rdma_benchmark_header_test rdma_benchmark_header_test.cpp)
  target_compile_features(rdma_benchmark_header_test PRIVATE cxx_std_17)
  set_target_properties(rdma_benchmark_header_test PROPERTIES CXX_EXTENSIONS OFF)
  target_compile_options(rdma_benchmark_header_test PRIVATE -Wall -Wextra -Werror)
  add_test(NAME rdma_benchmark_header_test COMMAND rdma_benchmark_header_test)
endif()
