#ifndef RDMA_RING_CONSUMER_HPP
#define RDMA_RING_CONSUMER_HPP

#include "rdma_benchmark_header.hpp"

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace rdma_ring {

inline constexpr std::size_t kCommitBytes{64U};

struct alignas(kCommitBytes) CommitRecord {
  std::uint64_t published_bytes;
  std::uint32_t ring_end_offset;
  std::uint32_t interval_bytes;
  std::uint32_t final;
  std::uint32_t magic;
  std::array<std::uint8_t, 16> reserved_before_sequence;
  std::uint64_t producer_sequence;
  std::array<std::uint8_t, 16> reserved_after_sequence;
};

static_assert(sizeof(CommitRecord) == kCommitBytes,
              "commit record must be exactly 64 bytes");
static_assert(offsetof(CommitRecord, producer_sequence) == 40U,
              "commit release sequence offset must match the FPGA RTL");
static_assert(std::is_trivially_copyable_v<CommitRecord>,
              "commit record must remain trivially copyable");

struct CommitSnapshot {
  std::uint64_t sequence{};
  std::uint64_t published_bytes{};
  std::uint32_t ring_end_offset{};
  std::uint32_t interval_bytes{};
  bool final{};
};

using BenchmarkStats = rdma_benchmark::ScanStats;

struct RateBaseline {
  std::chrono::steady_clock::time_point time{};
  std::uint64_t packets{};
  std::uint64_t bytes{};
  std::uint64_t discontinuities{};
  std::uint64_t invalid_headers{};
  std::uint64_t commits{};
};

bool read_commit(const volatile CommitRecord *record, CommitSnapshot &snapshot);
bool is_valid_commit_interval(const CommitSnapshot &snapshot,
                              std::uint32_t maximum_interval_bytes) noexcept;
bool scan_benchmark_headers(const volatile std::uint8_t *ring,
                            std::uint64_t ring_size,
                            const CommitSnapshot &snapshot,
                            std::uint64_t &scanned_bytes,
                            BenchmarkStats &stats);
void report_rate(const BenchmarkStats &stats,
                 std::chrono::steady_clock::time_point now,
                 RateBaseline &baseline);
bool verify_ring_headers(const volatile std::uint8_t *ring,
                         const CommitSnapshot &snapshot,
                         std::uint64_t ring_size);

} // namespace rdma_ring

#endif
