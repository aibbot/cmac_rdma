#ifndef RRDMA_HOST_APP_RFSO_HPP_
#define RRDMA_HOST_APP_RFSO_HPP_

#include <array>
#include <cstddef>
#include <chrono>
#include <cstdint>
#include <span>
#include <type_traits>

#include "rrdma/byte_order.hpp"
#include "rrdma/session.hpp"

// RFSO 是可选的应用层 consumer；核心库本身不依赖任何数据包格式。
namespace rrdma {

struct RfsoHeaderWire {
  wire::Be32 magic{};
  wire::Be32 sequence{};
  wire::Be16 version{};
  wire::Be16 header_length{};
  wire::Be32 payload_length{};
  std::array<std::byte, 8U> reserved{};
};

static_assert(sizeof(RfsoHeaderWire) == 24U);
static_assert(alignof(RfsoHeaderWire) == 1U);
static_assert(std::is_standard_layout_v<RfsoHeaderWire>);
static_assert(std::is_trivially_copyable_v<RfsoHeaderWire>);
static_assert(offsetof(RfsoHeaderWire, magic) == 0U);
static_assert(offsetof(RfsoHeaderWire, sequence) == 4U);
static_assert(offsetof(RfsoHeaderWire, version) == 8U);
static_assert(offsetof(RfsoHeaderWire, header_length) == 10U);
static_assert(offsetof(RfsoHeaderWire, payload_length) == 12U);
static_assert(offsetof(RfsoHeaderWire, reserved) == 16U);

struct RfsoStats {
  // 累计包、字节、序列错误和 ring 覆盖统计。
  // 已检查的 4096 字节包数和对应数据字节数。
  HostCount packets{};
  ByteCount bytes{};
  // sequence 不连续与 magic 非法的独立计数。
  HostCount discontinuities{};
  HostCount invalid_headers{};
  // batch 长度不满足 4096 字节包边界的次数。
  HostCount overruns{};
  // 最新 producer commit sequence 和累计发布字节数。
  CommitSequence commits{};
  ByteCount published_bytes{};
};

struct RateSample {
  // 从最近一次 ResetRateBaseline() 到采样时刻的增量。
  // 采样窗口秒数。
  double seconds{};
  // 窗口内新增字节、包和 commit sequence 增量。
  ByteCount bytes{};
  HostCount packets{};
  CommitSequence commits{};
  // 窗口内新增的不连续和非法头计数。
  HostCount discontinuities{};
  HostCount invalid_headers{};
};

class RfsoConsumer {
 public:
  // stop_on_invalid=true 时首个非法头或序列跳变会请求 ABORT。
  explicit RfsoConsumer(bool stop_on_invalid = true) noexcept
      : stop_on_invalid_(stop_on_invalid),
        rate_time_(std::chrono::steady_clock::now()) {}

  // 校验当前 commit 的单一连续 span，并更新统计。
  [[nodiscard]] BatchAction OnCommit(const CommitBatch &batch) noexcept;
  // 返回单线程累计统计的只读视图。
  [[nodiscard]] const RfsoStats &Stats() const noexcept { return stats_; }
  // 计算速率窗口，不修改累计统计。
  [[nodiscard]] RateSample Sample(
      std::chrono::steady_clock::time_point now) const noexcept;
  // 将当前累计值设为下一次速率窗口的起点。
  void ResetRateBaseline(std::chrono::steady_clock::time_point now) noexcept;
  // 正常安全关闭后复扫最近一个 ring 大小的 RFSO 数据窗口。
  [[nodiscard]] bool Verify(const SessionReport &report) const noexcept;

 private:
  bool InspectPacket(const std::byte *packet, std::uint32_t expected) noexcept;

  bool stop_on_invalid_;
  RfsoStats stats_{};
  std::chrono::steady_clock::time_point rate_time_{};
  RfsoStats rate_origin_{};
};

}  // namespace rrdma

#endif  // RRDMA_HOST_APP_RFSO_HPP_
