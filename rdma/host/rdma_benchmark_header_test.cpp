#include "rdma_benchmark_header.hpp"

#include <array>
#include <cstdint>
#include <iostream>
#include <vector>

namespace {

void write_be32(std::uint8_t* data, std::uint32_t value) {
    data[0] = static_cast<std::uint8_t>(value >> 24U);
    data[1] = static_cast<std::uint8_t>(value >> 16U);
    data[2] = static_cast<std::uint8_t>(value >> 8U);
    data[3] = static_cast<std::uint8_t>(value);
}

bool expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
    }
    return condition;
}

}  // namespace

int main() {
    std::array<std::uint8_t, rdma_benchmark::kHeaderBytes> header{};
    write_be32(header.data(), rdma_benchmark::kMagic);

    write_be32(header.data() + 4, 0U);
    const auto first = rdma_benchmark::observe_sequence(header.data(), 0U);
    if (!expect(first.valid_magic && !first.discontinuity && first.actual == 0U,
                "first sequence was rejected")) {
        return 1;
    }

    write_be32(header.data() + 4, 1U);
    const auto second = rdma_benchmark::observe_sequence(header.data(), 1U);
    if (!expect(second.valid_magic && !second.discontinuity &&
                    second.expected == 1U && second.actual == 1U,
                "continuous sequence was rejected")) {
        return 1;
    }

    write_be32(header.data() + 4, 3U);
    const auto jump = rdma_benchmark::observe_sequence(header.data(), 2U);
    if (!expect(jump.valid_magic && jump.discontinuity &&
                    jump.expected == 2U && jump.actual == 3U,
                "sequence jump was not detected")) {
        return 1;
    }

    header[0] = 0U;
    const auto invalid = rdma_benchmark::observe_sequence(header.data(), 4U);
    if (!expect(!invalid.valid_magic, "invalid magic was accepted")) {
        return 1;
    }

    write_be32(header.data(), rdma_benchmark::kMagic);
    write_be32(header.data() + 4, 4U);
    const auto after_invalid = rdma_benchmark::observe_sequence(header.data(), 4U);
    if (!expect(after_invalid.valid_magic && !after_invalid.discontinuity,
                "invalid magic changed sequence state")) {
        return 1;
    }

    write_be32(header.data() + 4, 0xffffffffU);
    const auto before_wrap =
        rdma_benchmark::observe_sequence(header.data(), 0xffffffffU);
    if (!expect(before_wrap.valid_magic && !before_wrap.discontinuity,
                "sequence before wrap was rejected")) {
        return 1;
    }
    write_be32(header.data() + 4, 0U);
    const auto wrap = rdma_benchmark::observe_sequence(header.data(), 0U);
    if (!expect(wrap.valid_magic && !wrap.discontinuity && wrap.expected == 0U,
                "32-bit sequence wrap was rejected")) {
        return 1;
    }

    constexpr std::uint64_t ring_size = rdma_benchmark::kPacketBytes * 4U;
    std::vector<std::uint8_t> ring(ring_size, 0U);
    const auto put_packet = [&](std::uint64_t packet_number,
                                std::uint32_t sequence) {
        const auto offset = static_cast<std::size_t>(
            packet_number % (ring_size / rdma_benchmark::kPacketBytes)) *
            rdma_benchmark::kPacketBytes;
        write_be32(ring.data() + offset, rdma_benchmark::kMagic);
        write_be32(ring.data() + offset + 4U, sequence);
    };
    std::vector<std::uint64_t> issues;
    const auto report_issue =
        [&](std::uint64_t offset,
            const rdma_benchmark::SequenceObservation&) {
            issues.push_back(offset);
        };

    rdma_benchmark::ScanStats scan_stats{};
    std::uint64_t scanned_bytes = 0;
    put_packet(0, 0);
    put_packet(1, 1);
    auto scan = rdma_benchmark::scan_committed_headers(
        ring.data(), ring_size, 2U * rdma_benchmark::kPacketBytes,
        2U * rdma_benchmark::kPacketBytes, scanned_bytes, scan_stats,
        report_issue);
    if (!expect(scan.error == rdma_benchmark::ScanError::none &&
                    !scan.overrun && scanned_bytes == 2U * rdma_benchmark::kPacketBytes &&
                    scan_stats.packets == 2U && scan_stats.discontinuities == 0U &&
                    scan_stats.invalid_headers == 0U,
                "initial committed scan failed")) {
        return 1;
    }

    put_packet(2, 2);
    put_packet(3, 3);
    put_packet(4, 4);
    put_packet(5, 5);
    scan = rdma_benchmark::scan_committed_headers(
        ring.data(), ring_size, 6U * rdma_benchmark::kPacketBytes,
        2U * rdma_benchmark::kPacketBytes, scanned_bytes, scan_stats,
        report_issue);
    if (!expect(scan.error == rdma_benchmark::ScanError::none &&
                    scanned_bytes == 6U * rdma_benchmark::kPacketBytes &&
                    scan_stats.packets == 6U && scan_stats.discontinuities == 0U,
                "cross-ring committed scan failed")) {
        return 1;
    }

    put_packet(6, 6);
    put_packet(7, 99);
    scanned_bytes = 0;
    scan_stats = {};
    issues.clear();
    scan = rdma_benchmark::scan_committed_headers(
        ring.data(), ring_size, 8U * rdma_benchmark::kPacketBytes, 0U,
        scanned_bytes, scan_stats, report_issue);
    if (!expect(scan.error == rdma_benchmark::ScanError::none && scan.overrun &&
                    scan_stats.overruns == 1U && scan_stats.packets == 4U &&
                    scan_stats.discontinuities == 1U && scanned_bytes ==
                    8U * rdma_benchmark::kPacketBytes,
                "full-ring overrun or absolute sequence check failed")) {
        return 1;
    }

    scanned_bytes = 0;
    scan_stats = {};
    scan = rdma_benchmark::scan_committed_headers(
        ring.data(), ring_size, 2U * rdma_benchmark::kPacketBytes,
        0U, scanned_bytes, scan_stats, report_issue);
    if (!expect(scan.error == rdma_benchmark::ScanError::invalid_ring_offset,
                "invalid ring offset was accepted")) {
        return 1;
    }

    scanned_bytes = rdma_benchmark::kPacketBytes;
    scan_stats = {};
    scan = rdma_benchmark::scan_committed_headers(
        ring.data(), ring_size, 0U, 0U, scanned_bytes, scan_stats,
        report_issue);
    if (!expect(scan.error == rdma_benchmark::ScanError::counter_moved_backwards,
                "backward published counter was accepted")) {
        return 1;
    }

    std::cout << "rdma_benchmark_header_test PASS\n";
    return 0;
}
