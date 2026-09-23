#ifndef RRDMA_SRC_CONSUMER_PATH_HPP_
#define RRDMA_SRC_CONSUMER_PATH_HPP_

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>

#include "control_client.hpp"
#include "rrdma/receiver.hpp"

namespace rrdma::detail {

struct BatchConsumeResult {
  // callback 的继续/正常停止决定，由协调器在当前 credit 确认后处理。
  BatchAction action{BatchAction::kContinueReceiving};
  // FPGA 对累计 CONSUME 的完整状态响应。
  protocol::Status status{};
};

// 执行单个 batch 的消费事务：先调用应用，再公布本地可释放前沿，最后在
// 控制锁内发送累计 CONSUME。callback 请求 ABORT 时不会发送任何 credit。
[[nodiscard]] Outcome<BatchConsumeResult> ProcessCommittedBatch(
    const CommitBatch &batch, CommitCallback callback, ControlClient &control,
    std::mutex &control_mutex, std::atomic<std::uint64_t> &released_frontier,
    std::atomic<bool> &control_priority_waiting,
    const std::atomic<bool> &abort_requested,
    std::chrono::milliseconds command_window);

}  // namespace rrdma::detail

#endif  // RRDMA_SRC_CONSUMER_PATH_HPP_
