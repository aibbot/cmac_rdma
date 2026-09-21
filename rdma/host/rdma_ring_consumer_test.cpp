#include "rdma_ring_consumer.hpp"

#include <endian.h>

#include <array>
#include <cstdint>
#include <iostream>
#include <vector>

namespace {

void write_be32(std::uint8_t *bytes, std::uint32_t value) {
  bytes[0] = static_cast<std::uint8_t>(value >> 24U);
  bytes[1] = static_cast<std::uint8_t>(value >> 16U);
  bytes[2] = static_cast<std::uint8_t>(value >> 8U);
  bytes[3] = static_cast<std::uint8_t>(value);
}

bool expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << message << '\n';
  }
  return condition;
}

} // namespace

int main() {
  rdma_ring::CommitRecord record{};
  record.published_bytes = htole64(8192U);
  record.ring_end_offset = htole32(8192U);
  record.interval_bytes = htole32(8192U);
  record.magic = htole32(0x52444d41U);
  record.producer_sequence = htole64(1U);

  rdma_ring::CommitSnapshot snapshot{};
  if (!expect(rdma_ring::read_commit(&record, snapshot),
              "valid commit record was rejected") ||
      !expect(snapshot.sequence == 1U && snapshot.published_bytes == 8192U &&
                  snapshot.ring_end_offset == 8192U &&
                  snapshot.interval_bytes == 8192U && !snapshot.final,
              "commit record fields were decoded incorrectly")) {
    return 1;
  }

  snapshot.interval_bytes = rdma_benchmark::kPacketBytes;
  if (!expect(rdma_ring::is_valid_commit_interval(snapshot, 8192U),
              "short physical-message commit was rejected")) {
    return 1;
  }
  snapshot.interval_bytes = 0U;
  if (!expect(!rdma_ring::is_valid_commit_interval(snapshot, 8192U),
              "zero-byte non-final commit was accepted")) {
    return 1;
  }
  snapshot.interval_bytes = rdma_benchmark::kPacketBytes + 1U;
  if (!expect(!rdma_ring::is_valid_commit_interval(snapshot, 8192U),
              "unaligned commit interval was accepted")) {
    return 1;
  }
  snapshot.interval_bytes = 12288U;
  if (!expect(!rdma_ring::is_valid_commit_interval(snapshot, 8192U),
              "oversized commit interval was accepted")) {
    return 1;
  }
  snapshot.interval_bytes = 0U;
  snapshot.final = true;
  if (!expect(rdma_ring::is_valid_commit_interval(snapshot, 8192U),
              "zero-byte final commit was rejected")) {
    return 1;
  }
  snapshot.interval_bytes = 8192U;
  snapshot.final = false;

  constexpr std::uint64_t ring_size = 4U * rdma_benchmark::kPacketBytes;
  std::vector<std::uint8_t> ring(ring_size, 0U);
  const auto put_packet = [&](std::uint64_t packet_number) {
    const auto offset = static_cast<std::size_t>(
        (packet_number * rdma_benchmark::kPacketBytes) % ring_size);
    write_be32(ring.data() + offset, rdma_benchmark::kMagic);
    write_be32(ring.data() + offset + 4U,
               static_cast<std::uint32_t>(packet_number));
  };

  put_packet(0U);
  put_packet(1U);
  std::uint64_t scanned_bytes{};
  rdma_ring::BenchmarkStats stats{};
  if (!expect(rdma_ring::scan_benchmark_headers(ring.data(), ring_size,
                                                snapshot, scanned_bytes, stats),
              "initial committed range was rejected") ||
      !expect(scanned_bytes == 8192U && stats.packets == 2U,
              "initial committed range was not fully scanned")) {
    return 1;
  }

  put_packet(2U);
  put_packet(3U);
  put_packet(4U);
  put_packet(5U);
  snapshot.sequence = 2U;
  snapshot.published_bytes = 6U * rdma_benchmark::kPacketBytes;
  snapshot.ring_end_offset = 2U * rdma_benchmark::kPacketBytes;
  snapshot.interval_bytes = 4U * rdma_benchmark::kPacketBytes;
  if (!expect(rdma_ring::scan_benchmark_headers(ring.data(), ring_size,
                                                snapshot, scanned_bytes, stats),
              "wrapped committed range was rejected") ||
      !expect(scanned_bytes == snapshot.published_bytes &&
                  stats.packets == 6U && stats.discontinuities == 0U &&
                  stats.invalid_headers == 0U && stats.overruns == 0U,
              "wrapped committed range was not validated exactly once")) {
    return 1;
  }

  std::vector<std::uint8_t> bad_ring(ring_size, 0U);
  snapshot.sequence = 1U;
  snapshot.published_bytes = rdma_benchmark::kPacketBytes;
  snapshot.ring_end_offset = rdma_benchmark::kPacketBytes;
  snapshot.interval_bytes = rdma_benchmark::kPacketBytes;
  scanned_bytes = 0U;
  stats = {};
  if (!expect(!rdma_ring::scan_benchmark_headers(
                  bad_ring.data(), ring_size, snapshot, scanned_bytes, stats),
              "invalid magic was accepted as consumable") ||
      !expect(stats.invalid_headers == 1U,
              "invalid magic was not counted")) {
    return 1;
  }

  write_be32(bad_ring.data(), rdma_benchmark::kMagic);
  write_be32(bad_ring.data() + 4U, 9U);
  scanned_bytes = 0U;
  stats = {};
  if (!expect(!rdma_ring::scan_benchmark_headers(
                  bad_ring.data(), ring_size, snapshot, scanned_bytes, stats),
              "sequence discontinuity was accepted as consumable") ||
      !expect(stats.discontinuities == 1U,
              "sequence discontinuity was not counted")) {
    return 1;
  }

  for (std::uint64_t packet = 1U; packet <= 4U; ++packet) {
    const auto offset = static_cast<std::size_t>(
        (packet * rdma_benchmark::kPacketBytes) % ring_size);
    write_be32(bad_ring.data() + offset, rdma_benchmark::kMagic);
    write_be32(bad_ring.data() + offset + 4U,
               static_cast<std::uint32_t>(packet));
  }
  snapshot.published_bytes = 5U * rdma_benchmark::kPacketBytes;
  snapshot.ring_end_offset = rdma_benchmark::kPacketBytes;
  snapshot.interval_bytes = ring_size;
  scanned_bytes = 0U;
  stats = {};
  if (!expect(!rdma_ring::scan_benchmark_headers(
                  bad_ring.data(), ring_size, snapshot, scanned_bytes, stats),
              "ring overrun was accepted as consumable") ||
      !expect(stats.overruns == 1U, "ring overrun was not counted")) {
    return 1;
  }

  std::cout << "rdma_ring_consumer_test PASS\n";
  return 0;
}
