#ifndef RRDMA_INCLUDE_RRDMA_TYPES_HPP_
#define RRDMA_INCLUDE_RRDMA_TYPES_HPP_

#include <cstddef>
#include <cstdint>

namespace rrdma {

// Host-side byte and element counts map directly to span/container sizes.
using ByteCount = std::size_t;
using HostCount = std::size_t;
using QueueIndex = std::size_t;

// Control/session identifiers retain their RDCP widths while naming their role.
using SessionId = std::uint64_t;
using TransactionId = std::uint32_t;
using CommitSequence = std::uint64_t;

// Host virtual addresses and FPGA-visible addresses are distinct concepts.
using HostAddress = std::uintptr_t;
using RemoteAddress = std::uint64_t;

static_assert(sizeof(ByteCount) == sizeof(std::uint64_t),
              "RDMA host requires 64-bit size_t");
static_assert(sizeof(HostAddress) == sizeof(RemoteAddress),
              "host and remote RDMA addresses must have equal width");

}  // namespace rrdma

#endif  // RRDMA_INCLUDE_RRDMA_TYPES_HPP_
