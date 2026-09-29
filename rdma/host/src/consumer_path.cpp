#include "consumer_path.hpp"

#include <utility>

namespace rrdma::detail {
namespace {

class PriorityWaitGuard {
 public:
  explicit PriorityWaitGuard(std::atomic<bool> &waiting) noexcept
   : waiting_(waiting) {
    waiting_.store(true, std::memory_order_release);
  }

  ~PriorityWaitGuard() {
    waiting_.store(false, std::memory_order_release);
  }

  PriorityWaitGuard(const PriorityWaitGuard &) = delete;
  PriorityWaitGuard &operator=(const PriorityWaitGuard &) = delete;

 private:
  std::atomic<bool> &waiting_;
};

[[nodiscard]] Error ConsumeRejectedError(const protocol::Status &status) {
  // 把 wire status 原值保留到公共 Error，便于应用区分永久进度拒绝和故障。
  Error error = MakeError(ErrorCode::kRemoteRejected,
                          "FPGA CONSUME rejected committed progress");
  error.remote_result = static_cast<std::uint16_t>(status.result);
  error.remote_state = static_cast<std::uint8_t>(status.state);
  error.remote_reason = status.reason;
  return error;
}

} // namespace

Outcome<BatchConsumeResult> ProcessCommittedBatch(const CommitBatch &batch,
                                                  CommitCallback callback,
                                                  ControlClient &control,
                                                  std::mutex &control_mutex,
                                                  std::atomic<ByteCount> &released_frontier,
                                                  std::atomic<bool> &control_priority_waiting,
                                                  const std::atomic<bool> &abort_requested,
                                                  std::chrono::milliseconds command_window) {
  // callback 完成前 ring 数据仍归应用使用，任何路径都不能提前返还 credit。
  const auto action = callback.Invoke(batch);
  if (action == BatchAction::kAbort) {
    return Failure<BatchConsumeResult>(MakeError(
      ErrorCode::kCallbackRejected, "consumer callback requested ABORT"));
  }
  if (abort_requested.load(std::memory_order_acquire)) {
    return Failure<BatchConsumeResult>(MakeError(
      ErrorCode::kStopped, "session ABORT requested before CONSUME"));
  }

  const auto consumed_bytes = batch.commit.published_bytes;
  PriorityWaitGuard priority_guard(control_priority_waiting);
  auto consume_reply = [&] {
    std::scoped_lock lock(control_mutex);
    // 等待 STATUS/STOP 释放控制锁期间可能发生 producer fault。发送门必须在
    // 同一锁域内重新检查 ABORT；检查通过即线性化为本批先于后续 ABORT。
    if (abort_requested.load(std::memory_order_acquire)) {
      return Failure<ControlClient::Reply>(MakeError(
        ErrorCode::kStopped, "session ABORT requested before CONSUME"));
    }
    // callback 已结束且发送门已通过。先推进本地安全前沿，覆盖“FPGA 已处理
    // CONSUME 但 UDP 响应尚未到达”的窗口；队列槽位仍等待响应后才回收。
    released_frontier.store(consumed_bytes, std::memory_order_release);
    return control.ConsumeWithProgressRetry(consumed_bytes, command_window,
                                            &abort_requested);
  }();

  if (!consume_reply) {
    return Failure<BatchConsumeResult>(consume_reply.GetError());
  }
  const auto &status = consume_reply.Value().status;

  if (status.result != protocol::Result::kOk
      || status.consumed_bytes != consumed_bytes) {
    return Failure<BatchConsumeResult>(
      ConsumeRejectedError(status));
  }

  return BatchConsumeResult{action, status};
}

} // namespace rrdma::detail
