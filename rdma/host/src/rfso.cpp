#include "rrdma/rfso.hpp"

#include <arpa/inet.h>

#include <algorithm>
#include <cstring>
#include <limits>

namespace rrdma {
namespace {

constexpr std::uint32_t kRfsoMagic{0x5246534fU};

// RFSO 头部采用网络字节序，独立于 RDCP 的 little-endian commit 格式。
[[nodiscard]] std::uint32_t LoadNetwork32(const std::byte *bytes) noexcept {
  std::uint32_t wire{};
  std::memcpy(&wire, bytes, sizeof wire);
  return ntohl(wire);
}

[[nodiscard]] bool IsRfsoPacket(const std::byte *packet,
                                std::uint32_t expected_sequence) noexcept {
  // 同时检查 magic 和绝对 packet sequence，检测丢包/重复包。
  return packet != nullptr
         && LoadNetwork32(packet) == kRfsoMagic
         && LoadNetwork32(packet + 4U) == expected_sequence;
}

[[nodiscard]] bool VerifyPackets(std::span<const std::byte> packets,
                                 std::uint64_t begin_bytes) noexcept {
  // 双映射已展开回绕，只需顺序复扫一个连续 span。
  for (std::size_t offset{}; offset < packets.size(); offset += kPacketBytes) {
    const auto absolute_offset = begin_bytes + offset;
    if (!IsRfsoPacket(packets.data() + offset,
                      static_cast<std::uint32_t>(absolute_offset / kPacketBytes))) {
      return false;
    }
  }
  return true;
}

} // namespace

bool RfsoConsumer::InspectPacket(const std::byte *packet,
                                 std::uint32_t expected) noexcept {
  // 只更新 RFSO 统计，不触碰 ring 或控制通道。
  if (packet == nullptr || LoadNetwork32(packet) != kRfsoMagic) {
    ++stats_.invalid_headers;
    return false;
  }
  if (LoadNetwork32(packet + 4U) != expected) {
    ++stats_.discontinuities;
    return false;
  }
  return true;
}

BatchAction RfsoConsumer::OnCommit(const CommitBatch &batch) noexcept {
  // RFSO 校验只在消费者线程执行；双映射已经把 ring 回绕展开成单 span。
  // callback 返回成功后上层才会发送累计 CONSUME。
  if (batch.commit.published_bytes < stats_.published_bytes
      || batch.commit.published_bytes % kPacketBytes != 0U
      || stats_.published_bytes % kPacketBytes != 0U
      || batch.data.size() != batch.commit.published_bytes - stats_.published_bytes) {
    ++stats_.overruns;
    return stop_on_invalid_ ? BatchAction::kAbort : BatchAction::kContinueReceiving;
  }

  const auto begin_bytes = stats_.published_bytes;
  // 保持协议统计语义：commits 记录 FPGA producer sequence；轮询跨过中间
  // commit 时可见跳变，而不是误报为一个 host callback。
  stats_.commits = std::max(stats_.commits, batch.commit.sequence);
  stats_.published_bytes = batch.commit.published_bytes;

  bool batch_valid{true};
  for (std::size_t offset{}; offset < batch.data.size(); offset += kPacketBytes) {
    const auto absolute_offset = begin_bytes + offset;
    const auto expected = static_cast<std::uint32_t>(absolute_offset / kPacketBytes);
    ++stats_.packets;
    stats_.bytes += kPacketBytes;

    if (!InspectPacket(batch.data.data() + offset, expected)) {
      batch_valid = false;
    }
  }

  if (!batch_valid) {
    return stop_on_invalid_ ? BatchAction::kAbort : BatchAction::kContinueReceiving;
  }
  return BatchAction::kContinueReceiving;
}

RateSample RfsoConsumer::Sample(std::chrono::steady_clock::time_point now) const noexcept {
  // 以当前累计值减去 baseline 计算窗口增量，避免并发原子开销。
  if (rate_time_ == std::chrono::steady_clock::time_point{} || now <= rate_time_) {
    return {};
  }
  return {std::chrono::duration<double>(now - rate_time_).count(),
          stats_.bytes - rate_origin_.bytes,
          stats_.packets - rate_origin_.packets,
          stats_.commits - rate_origin_.commits,
          stats_.discontinuities - rate_origin_.discontinuities,
          stats_.invalid_headers - rate_origin_.invalid_headers};
}

void RfsoConsumer::ResetRateBaseline(std::chrono::steady_clock::time_point now) noexcept {
  // 在首个有效 commit 或每秒打印后重新开始速率窗口。
  rate_time_ = now;
  rate_origin_ = stats_;
}

bool RfsoConsumer::Verify(const SessionReport &report) const noexcept {
  // 正常关闭后只复扫最新 ring-sized 窗口，覆盖环绕区域但不扩大驻留时间。
  if (report.ring.empty() || !report.final_commit.final
      || report.ring_bytes == 0U
      || report.ring_bytes > std::numeric_limits<std::size_t>::max() / 2U
      || report.ring.size() != static_cast<std::size_t>(report.ring_bytes * 2U)) {
    return false;
  }
  const auto ring_size = report.ring_bytes;
  if (ring_size == 0U || ring_size % kPacketBytes != 0U
      || report.final_commit.published_bytes % kPacketBytes != 0U
      || report.final_commit.ring_end_offset >= ring_size
      || report.final_commit.ring_end_offset != report.final_commit.published_bytes % ring_size) {
    return false;
  }

  const auto bytes_to_check = std::min(report.final_commit.published_bytes, ring_size);
  if (bytes_to_check == 0U) {
    // 保持旧验证器语义：没有任何已发布 packet 时不能宣称 RFSO 复扫成功。
    return false;
  }

  const auto begin_bytes = report.final_commit.published_bytes - bytes_to_check;
  const auto begin_offset = begin_bytes % ring_size;
  const auto packets = report.ring.subspan(static_cast<std::size_t>(begin_offset),
                                           static_cast<std::size_t>(bytes_to_check));

  return VerifyPackets(packets, begin_bytes);
}

} // namespace rrdma
