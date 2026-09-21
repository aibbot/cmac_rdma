#include "rdma_ring_consumer.hpp"

#include <endian.h>

#include <atomic>
#include <cstring>
#include <iomanip>
#include <iostream>

namespace rdma_ring {
namespace {

constexpr std::uint32_t kCommitMagic{0x52444d41U};
constexpr std::uint64_t kMaxReportedHeaderErrors{10U};
constexpr double kBytesPerMiB{1024.0 * 1024.0};
constexpr double kBitsPerGigabit{1000.0 * 1000.0 * 1000.0};

void report_sequence_discontinuity(
    std::uint64_t count, std::uint64_t published_offset,
    const rdma_benchmark::SequenceObservation &observation) {
  if (count <= kMaxReportedHeaderErrors) {
    std::cerr << "Sequence discontinuity: offset=" << published_offset
              << " expected=0x" << std::hex << observation.expected
              << " actual=0x" << observation.actual << std::dec << '\n';
  } else if (count == kMaxReportedHeaderErrors + 1U) {
    std::cerr
        << "Further discontinuity details suppressed; counting continues\n";
  }
}

void report_invalid_header(std::uint64_t count, std::uint64_t published_offset,
                           std::uint32_t magic) {
  if (count <= kMaxReportedHeaderErrors) {
    std::cerr << "Invalid RFSO header: offset=" << published_offset
              << " magic=0x" << std::hex << magic << std::dec << '\n';
  } else if (count == kMaxReportedHeaderErrors + 1U) {
    std::cerr
        << "Further invalid-header details suppressed; counting continues\n";
  }
}

} // namespace

bool read_commit(const volatile CommitRecord *record,
                 CommitSnapshot &snapshot) {
  CommitRecord local{};
  const auto first_sequence =
      __atomic_load_n(&record->producer_sequence, __ATOMIC_ACQUIRE);
  if (first_sequence == 0U) {
    return false;
  }
  std::atomic_thread_fence(std::memory_order_acquire);
  std::memcpy(
      &local,
      const_cast<const void *>(static_cast<const volatile void *>(record)),
      sizeof(local));
  std::atomic_thread_fence(std::memory_order_acquire);
  const auto second_sequence =
      __atomic_load_n(&record->producer_sequence, __ATOMIC_ACQUIRE);
  if (first_sequence != second_sequence ||
      le64toh(local.producer_sequence) != second_sequence ||
      le32toh(local.magic) != kCommitMagic) {
    return false;
  }
  snapshot.sequence = second_sequence;
  snapshot.published_bytes = le64toh(local.published_bytes);
  snapshot.ring_end_offset = le32toh(local.ring_end_offset);
  snapshot.interval_bytes = le32toh(local.interval_bytes);
  snapshot.final = le32toh(local.final) != 0U;
  return true;
}

bool is_valid_commit_interval(const CommitSnapshot &snapshot,
                              std::uint32_t maximum_interval_bytes) noexcept {
  const bool aligned =
      (snapshot.interval_bytes % rdma_benchmark::kPacketBytes) == 0U;
  return maximum_interval_bytes != 0U && aligned &&
         snapshot.interval_bytes <= maximum_interval_bytes &&
         (snapshot.final || snapshot.interval_bytes != 0U);
}

bool scan_benchmark_headers(const volatile std::uint8_t *ring,
                            std::uint64_t ring_size,
                            const CommitSnapshot &snapshot,
                            std::uint64_t &scanned_bytes,
                            BenchmarkStats &stats) {
  const std::uint64_t initial_discontinuities = stats.discontinuities;
  const std::uint64_t initial_invalid_headers = stats.invalid_headers;
  const std::uint64_t initial_overruns = stats.overruns;
  const auto report_issue =
      [&](std::uint64_t offset,
          const rdma_benchmark::SequenceObservation &observation) {
        if (!observation.valid_magic) {
          report_invalid_header(stats.invalid_headers, offset,
                                observation.magic);
        } else {
          report_sequence_discontinuity(stats.discontinuities, offset,
                                        observation);
        }
      };
  const auto result = rdma_benchmark::scan_committed_headers(
      ring, ring_size, snapshot.published_bytes, snapshot.ring_end_offset,
      scanned_bytes, stats, report_issue);
  stats.commits = snapshot.sequence;
  stats.published_bytes = snapshot.published_bytes;
  switch (result.error) {
  case rdma_benchmark::ScanError::none:
    if (result.overrun) {
      std::cerr << "benchmark ring overrun: unread=" << result.unread_bytes
                << " ring=" << ring_size
                << "; sequence validation is no longer complete\n";
    }
    return stats.discontinuities == initial_discontinuities &&
           stats.invalid_headers == initial_invalid_headers &&
           stats.overruns == initial_overruns;
  case rdma_benchmark::ScanError::invalid_ring_size:
    std::cerr << "invalid benchmark ring size " << ring_size << '\n';
    break;
  case rdma_benchmark::ScanError::invalid_ring_offset:
    std::cerr << "invalid published ring offset " << snapshot.ring_end_offset
              << " for " << snapshot.published_bytes << " bytes\n";
    break;
  case rdma_benchmark::ScanError::counter_moved_backwards:
    std::cerr << "published byte counter moved backwards: previous="
              << scanned_bytes << " current=" << snapshot.published_bytes
              << '\n';
    break;
  case rdma_benchmark::ScanError::unaligned_counter:
    std::cerr << "published byte counter is not 4096-byte aligned: current="
              << snapshot.published_bytes << " scanned=" << scanned_bytes
              << '\n';
    break;
  }
  return false;
}

void report_rate(const BenchmarkStats &stats,
                 std::chrono::steady_clock::time_point now,
                 RateBaseline &baseline) {
  const double seconds =
      std::chrono::duration<double>(now - baseline.time).count();
  if (seconds <= 0.0) {
    return;
  }

  const std::uint64_t interval_bytes = stats.bytes - baseline.bytes;
  const std::uint64_t interval_packets = stats.packets - baseline.packets;
  const std::uint64_t interval_commits = stats.commits - baseline.commits;
  const std::uint64_t interval_discontinuities =
      stats.discontinuities - baseline.discontinuities;
  const std::uint64_t interval_invalid =
      stats.invalid_headers - baseline.invalid_headers;
  const double mib_per_second =
      static_cast<double>(interval_bytes) / kBytesPerMiB / seconds;
  const double gbits_per_second =
      static_cast<double>(interval_bytes) * 8.0 / kBitsPerGigabit / seconds;
  const double packets_per_second =
      static_cast<double>(interval_packets) / seconds;
  const double commits_per_second =
      static_cast<double>(interval_commits) / seconds;

  std::cout << "Rate=" << std::fixed << std::setprecision(2) << mib_per_second
            << " MiB/s (" << std::setprecision(3) << gbits_per_second
            << " Gbps) packets=" << std::setprecision(2) << packets_per_second
            << "/s commits=" << commits_per_second
            << "/s discontinuities=" << stats.discontinuities << " (+"
            << interval_discontinuities << ") invalid=" << stats.invalid_headers
            << " (+" << interval_invalid << ")\n"
            << std::flush;

  baseline.time = now;
  baseline.packets = stats.packets;
  baseline.bytes = stats.bytes;
  baseline.discontinuities = stats.discontinuities;
  baseline.invalid_headers = stats.invalid_headers;
  baseline.commits = stats.commits;
}

bool verify_ring_headers(const volatile std::uint8_t *ring,
                         const CommitSnapshot &snapshot,
                         std::uint64_t ring_size) {
  if (snapshot.published_bytes == 0U) {
    std::cerr << "no published bytes to verify\n";
    return false;
  }

  const std::uint64_t bytes_to_check = snapshot.published_bytes < ring_size
                                           ? snapshot.published_bytes
                                           : ring_size;
  std::uint64_t scanned_bytes = snapshot.published_bytes - bytes_to_check;
  BenchmarkStats stats{};
  if (!scan_benchmark_headers(ring, ring_size, snapshot, scanned_bytes,
                              stats) ||
      stats.invalid_headers != 0U || stats.discontinuities != 0U ||
      stats.overruns != 0U) {
    std::cerr << "ring RFSO header verification failed\n";
    return false;
  }

  std::cout << "ring header verification passed: packets=" << stats.packets
            << " bytes=" << stats.bytes << " sequence=" << snapshot.sequence
            << '\n';
  return true;
}

} // namespace rdma_ring
