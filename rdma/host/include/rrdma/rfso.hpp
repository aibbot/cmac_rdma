#ifndef RRDMA_INCLUDE_RRDMA_RFSO_HPP_
#define RRDMA_INCLUDE_RRDMA_RFSO_HPP_

#include <chrono>
#include <cstdint>

#include "rrdma/receiver.hpp"

// RFSO 是可选的应用层 consumer；核心库本身不依赖任何数据包格式。
namespace rrdma {

struct RfsoStats {
  // 累计包、字节、序列错误和 ring 覆盖统计。
  // 已检查的 4096 字节包数和对应数据字节数。
  std::uint64_t packets{};
  std::uint64_t bytes{};
  // sequence 不连续与 magic 非法的独立计数。
  std::uint64_t discontinuities{};
  std::uint64_t invalid_headers{};
  // batch 长度不满足 4096 字节包边界的次数。
  std::uint64_t overruns{};
  // 最新 producer commit sequence 和累计发布字节数。
  std::uint64_t commits{};
  std::uint64_t published_bytes{};
};

struct RateSample {
  // 从最近一次 ResetRateBaseline() 到采样时刻的增量。
  // 采样窗口秒数。
  double seconds{};
  // 窗口内新增字节、包和 commit sequence 增量。
  std::uint64_t bytes{};
  std::uint64_t packets{};
  std::uint64_t commits{};
  // 窗口内新增的不连续和非法头计数。
  std::uint64_t discontinuities{};
  std::uint64_t invalid_headers{};
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

#endif  // RRDMA_INCLUDE_RRDMA_RFSO_HPP_
