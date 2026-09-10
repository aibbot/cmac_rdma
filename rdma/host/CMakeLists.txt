cmake_minimum_required(VERSION 3.20)
project(rdma_ring_receiver C)

find_package(PkgConfig REQUIRED)
pkg_check_modules(IBVERBS REQUIRED IMPORTED_TARGET libibverbs)

add_executable(rdma_ring_receiver rdma_ring_receiver.c)
target_compile_features(rdma_ring_receiver PRIVATE c_std_11)
target_compile_options(rdma_ring_receiver PRIVATE -Wall -Wextra -Werror)
target_link_libraries(rdma_ring_receiver PRIVATE PkgConfig::IBVERBS)
