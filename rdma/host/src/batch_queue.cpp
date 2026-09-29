#include "batch_queue.hpp"

namespace rrdma::detail {

// 预分配固定 descriptor 槽位，运行期间只更新原子游标。
BatchQueue::BatchQueue(HostCount capacity) : slots_(capacity) {
}

bool BatchQueue::TryPush(const CommitBatch &batch) noexcept {
  // 生产者只发布固定大小的 descriptor；队列满时返回 false，让上游
  // 暂停提交而不是复制 payload 或越过消费者的释放边界。
  if (slots_.empty()) {
    return false;
  }
  auto state = state_.load(std::memory_order_relaxed);
  if ((state & kClosedBit) != 0U) {
    return false;
  }
  const auto write_index = state & kIndexMask;
  if (write_index - reclaimed_.load(std::memory_order_acquire) >= slots_.size()
      || write_index == kIndexMask) {
    return false;
  }

  slots_[write_index % slots_.size()] = batch;
  if (!state_.compare_exchange_strong(state, write_index + 1U,
                                      std::memory_order_release,
                                      std::memory_order_acquire)) {
    return false;
  }
  // Notify only when the consumer had caught up with the old tail. If it
  // drains the old item concurrently, this post-publish acquire still sees
  // the old index and preserves the wakeup edge without waking a busy reader.
  if (reclaimed_.load(std::memory_order_acquire) == write_index) {
    state_.notify_one();
  }
  return true;
}

bool BatchQueue::WaitForFront(CommitBatch *&batch) noexcept {
  // reclaimed_ 就是消费者独占的读游标；关闭后仍会排空已发布的批次。
  const auto read_index = reclaimed_.load(std::memory_order_relaxed);
  while (true) {
    const auto state = state_.load(std::memory_order_acquire);
    if (read_index < (state & kIndexMask)) {
      batch = &slots_[read_index % slots_.size()];
      return true;
    }
    if ((state & kClosedBit) != 0U) {
      return false;
    }
    state_.wait(state, std::memory_order_acquire);
  }
}

void BatchQueue::ReleaseFront() noexcept {
  // 只有 callback 成功且 CONSUME 已确认后才能推进回收前沿。
  const auto read_index = reclaimed_.load(std::memory_order_relaxed);
  reclaimed_.store(read_index + 1U, std::memory_order_release);
}

void BatchQueue::Close() noexcept {
  // 原子设置关闭位并唤醒空队列等待者；已发布 descriptor 仍可继续排空。
  if ((state_.load(std::memory_order_acquire) & kClosedBit) != 0U) {
    return;
  }
  const auto previous = state_.fetch_or(kClosedBit, std::memory_order_release);
  if ((previous & kClosedBit) == 0U) {
    state_.notify_all();
  }
}

bool BatchQueue::Closed() const noexcept {
  // acquire 保证消费者看到 Close 前已发布的 descriptor。
  return (state_.load(std::memory_order_acquire) & kClosedBit) != 0U;
}

QueueIndex BatchQueue::Published() const noexcept {
  // 返回生产者已经写入的单调发布序号。
  return state_.load(std::memory_order_acquire) & kIndexMask;
}

QueueIndex BatchQueue::Reclaimed() const noexcept {
  // 返回消费者已确认 CONSUME 的单调回收序号。
  return reclaimed_.load(std::memory_order_acquire);
}

} // namespace rrdma::detail
