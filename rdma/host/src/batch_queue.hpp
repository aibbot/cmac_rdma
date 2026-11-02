#ifndef RRDMA_SRC_BATCH_QUEUE_HPP_
#define RRDMA_SRC_BATCH_QUEUE_HPP_

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "rrdma/session.hpp"

namespace rrdma::detail {

// 有界 SPSC 无锁队列：生产者发布 CommitBatch，消费者完成 callback
// 和 CONSUME 后推进 reclaimed_，从而对 ring credit 形成背压。低 63 位状态
// 保存发布游标，最高位保存关闭标志，atomic::wait 仅负责空队列休眠。
class BatchQueue {
 public:
  // capacity 固定后整个 session 不再为 descriptor 分配内存。
  explicit BatchQueue(HostCount capacity);

  BatchQueue(const BatchQueue &) = delete;
  BatchQueue &operator=(const BatchQueue &) = delete;

  // 队列未满时发布一份不含 payload 拷贝的 descriptor。
  [[nodiscard]] bool TryPush(const CommitBatch &batch) noexcept;
  // 阻塞等待队首 descriptor；关闭后仍先返回所有已发布项目。
  [[nodiscard]] bool WaitForFront(CommitBatch *&batch) noexcept;
  // callback 和 CONSUME 成功后释放当前队首槽位。
  void ReleaseFront() noexcept;
  // 唤醒等待者并禁止新的 push。
  void Close() noexcept;

  [[nodiscard]] bool Closed() const noexcept;
  [[nodiscard]] QueueIndex Published() const noexcept;
  [[nodiscard]] QueueIndex Reclaimed() const noexcept;

 private:
  static constexpr HostCount kCacheLineBytes{64U};
  static constexpr QueueIndex kClosedBit{
    QueueIndex{1} << (sizeof(QueueIndex) * 8U - 1U)};
  static constexpr QueueIndex kIndexMask{kClosedBit - 1U};

  std::vector<CommitBatch> slots_;
  // 生产者写 state_，消费者写 reclaimed_；分离缓存行避免伪共享。
  alignas(kCacheLineBytes) std::atomic<QueueIndex> state_{};
  alignas(kCacheLineBytes) std::atomic<QueueIndex> reclaimed_{};
};

static_assert(std::atomic<QueueIndex>::is_always_lock_free,
              "BatchQueue requires lock-free 64-bit atomics");
static_assert(sizeof(QueueIndex) == sizeof(std::uint64_t),
              "BatchQueue close bit requires 64-bit queue indices");

} // namespace rrdma::detail

#endif // RRDMA_SRC_BATCH_QUEUE_HPP_
