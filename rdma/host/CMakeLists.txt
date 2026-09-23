cmake_minimum_required(VERSION 3.20)
project(rrdma VERSION 2.0.0 LANGUAGES CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
include(CTest)

find_package(PkgConfig REQUIRED)
find_package(Threads REQUIRED)
pkg_check_modules(IBVERBS REQUIRED IMPORTED_TARGET libibverbs)

add_library(rrdma STATIC
  src/batch_queue.cpp
  src/config.cpp
  src/consumer_path.cpp
  src/control_client.cpp
  src/protocol.cpp
  src/receiver.cpp
  src/rfso.cpp
  src/ring.cpp
  src/udp_channel.cpp
  src/verbs_runtime.cpp
)
add_library(rrdma::core ALIAS rrdma)
target_compile_features(rrdma PUBLIC cxx_std_20)
set_target_properties(rrdma PROPERTIES CXX_EXTENSIONS OFF)
set_target_properties(rrdma PROPERTIES EXPORT_NAME core)
target_include_directories(rrdma
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_compile_options(rrdma PRIVATE -Wall -Wextra -Werror)
target_link_libraries(rrdma PUBLIC PkgConfig::IBVERBS Threads::Threads)

add_executable(rdma_ring_receiver app/rdma_ring_receiver.cpp)
target_compile_features(rdma_ring_receiver PRIVATE cxx_std_20)
set_target_properties(rdma_ring_receiver PROPERTIES CXX_EXTENSIONS OFF)
target_compile_options(rdma_ring_receiver PRIVATE -Wall -Wextra -Werror)
target_link_libraries(rdma_ring_receiver PRIVATE rrdma::core)

install(TARGETS rrdma rdma_ring_receiver
  EXPORT rrdmaTargets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT rrdmaTargets
  FILE rrdmaTargets.cmake
  NAMESPACE rrdma::
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/rrdma
)

configure_package_config_file(
  ${CMAKE_CURRENT_SOURCE_DIR}/cmake/rrdmaConfig.cmake.in
  ${CMAKE_CURRENT_BINARY_DIR}/rrdmaConfig.cmake
  INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/rrdma
)
write_basic_package_version_file(
  ${CMAKE_CURRENT_BINARY_DIR}/rrdmaConfigVersion.cmake
  COMPATIBILITY SameMajorVersion
)
install(FILES
  ${CMAKE_CURRENT_BINARY_DIR}/rrdmaConfig.cmake
  ${CMAKE_CURRENT_BINARY_DIR}/rrdmaConfigVersion.cmake
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/rrdma
)

if(BUILD_TESTING)
  find_program(BASH_EXECUTABLE bash REQUIRED)

  function(add_rrdma_test target source)
    add_executable(${target} ${source})
    target_compile_features(${target} PRIVATE cxx_std_20)
    set_target_properties(${target} PROPERTIES CXX_EXTENSIONS OFF)
    target_include_directories(${target} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
    target_compile_options(${target} PRIVATE -Wall -Wextra -Werror -UNDEBUG)
    target_link_libraries(${target} PRIVATE rrdma::core)
    add_test(NAME ${target} COMMAND ${target})
  endfunction()

  add_rrdma_test(rrdma_tests tests/rrdma_tests.cpp)

  add_test(
    NAME collect_roce_snapshot_test
    COMMAND ${BASH_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/collect_roce_snapshot_test.sh
  )
  add_test(
    NAME watch_roce_flow_control_test
    COMMAND ${BASH_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/watch_roce_flow_control_test.sh
  )
endif()
