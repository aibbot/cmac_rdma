#ifndef RDMA_BENCHMARK_HEADER_HPP
#define RDMA_BENCHMARK_HEADER_HPP

#include <cstddef>
#include <cstdint>
#include <utility>

namespace rdma_benchmark {

inline constexpr std::size_t kHeaderBytes{24};
inline constexpr std::size_t kPacketBytes{4096};
inline constexpr std::uint32_t kMagic{0x5246534fU};

inline std::uint32_t read_be32(const volatile std::uint8_t* data) noexcept {
    return (static_cast<std::uint32_t>(data[0]) << 24U) |
           (static_cast<std::uint32_t>(data[1]) << 16U) |
           (static_cast<std::uint32_t>(data[2]) << 8U) |
           static_cast<std::uint32_t>(data[3]);
}

struct SequenceObservation {
    bool valid_magic{};
    bool discontinuity{};
    std::uint32_t magic{};
    std::uint32_t expected{};
    std::uint32_t actual{};
};

[[nodiscard]] inline SequenceObservation observe_sequence(
    const volatile std::uint8_t* header,
    std::uint32_t expected) noexcept {
    SequenceObservation observation{};
    observation.magic = read_be32(header);
    observation.expected = expected;
    if (observation.magic != kMagic) {
        return observation;
    }

    observation.valid_magic = true;
    observation.actual = read_be32(header + 4);
    observation.discontinuity = observation.actual != expected;
    return observation;
}

struct ScanStats {
    std::uint64_t packets{};
    std::uint64_t bytes{};
    std::uint64_t discontinuities{};
    std::uint64_t invalid_headers{};
    std::uint64_t overruns{};
    std::uint64_t commits{};
    std::uint64_t published_bytes{};
};

enum class ScanError {
    none,
    invalid_ring_size,
    invalid_ring_offset,
    counter_moved_backwards,
    unaligned_counter,
};

struct ScanResult {
    ScanError error{ScanError::none};
    std::uint64_t unread_bytes{};
    std::uint64_t expected_ring_offset{};
    bool overrun{};
};

template <typename IssueReporter>
[[nodiscard]] ScanResult scan_committed_headers(
    const volatile std::uint8_t* ring,
    std::uint64_t ring_size,
    std::uint64_t published_bytes,
    std::uint64_t published_ring_offset,
    std::uint64_t& scanned_bytes,
    ScanStats& stats,
    IssueReporter&& report_issue) {
    ScanResult result{};
    if (ring == nullptr || ring_size == 0 ||
        (ring_size % kPacketBytes) != 0) {
        result.error = ScanError::invalid_ring_size;
        return result;
    }

    result.expected_ring_offset = published_bytes % ring_size;
    if (published_ring_offset >= ring_size ||
        published_ring_offset != result.expected_ring_offset) {
        result.error = ScanError::invalid_ring_offset;
        return result;
    }
    if (published_bytes < scanned_bytes) {
        result.error = ScanError::counter_moved_backwards;
        return result;
    }
    if ((published_bytes % kPacketBytes) != 0 ||
        (scanned_bytes % kPacketBytes) != 0) {
        result.error = ScanError::unaligned_counter;
        return result;
    }

    result.unread_bytes = published_bytes - scanned_bytes;
    if (result.unread_bytes > ring_size) {
        ++stats.overruns;
        result.overrun = true;
        scanned_bytes = published_bytes - ring_size;
    }

    while (scanned_bytes < published_bytes) {
        const std::uint64_t ring_offset = scanned_bytes % ring_size;
        const std::uint32_t expected_sequence = static_cast<std::uint32_t>(
            scanned_bytes / kPacketBytes);
        const auto observation =
            observe_sequence(ring + ring_offset, expected_sequence);
        ++stats.packets;
        stats.bytes += kPacketBytes;
        if (!observation.valid_magic) {
            ++stats.invalid_headers;
            std::forward<IssueReporter>(report_issue)(scanned_bytes,
                                                      observation);
        } else if (observation.discontinuity) {
            ++stats.discontinuities;
            std::forward<IssueReporter>(report_issue)(scanned_bytes,
                                                      observation);
        }
        scanned_bytes += kPacketBytes;
    }
    return result;
}

}  // namespace rdma_benchmark

#endif
