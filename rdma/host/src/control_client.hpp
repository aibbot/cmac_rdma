#ifndef RRDMA_SRC_CONTROL_CLIENT_HPP_
#define RRDMA_SRC_CONTROL_CLIENT_HPP_

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <span>

#include "rrdma/protocol.hpp"
#include "rrdma/session.hpp"
#include "rrdma/transport.hpp"

namespace rrdma::detail {

// RDCP 控制客户端：串行化一个 session 的 transaction 分配和响应匹配，
// 但不阻塞数据面消费者之外的状态读取策略。
class ControlClient {
 public:
  struct Reply {
    // 当前请求对应的完整 STATUS 快照。
    protocol::Status status{};
  };

  // transaction_seed 只使用低 31 位，零值会被规范化为 1。
  ControlClient(DatagramChannel &channel,
                const TimingConfig &timing,
                SessionId session_id,
                TransactionId transaction_seed) noexcept;

  void SetSession(SessionId session_id) noexcept {
    // HELLO 使用零 session；配置前切换到本次随机 session。
    session_id_ = session_id;
  }

  // 普通请求：传输超时重用同一 transaction bytes。
  [[nodiscard]] Outcome<Reply> Request(protocol::Opcode opcode,
                                       std::span<const std::byte> payload,
                                       std::chrono::milliseconds window);
  // 可被 consumer/coordinator 的停止标志中断的低优先级请求。
  [[nodiscard]] Outcome<Reply> RequestInterruptible(
    protocol::Opcode opcode, std::span<const std::byte> payload,
    std::chrono::milliseconds window,
    const std::atomic<bool> &interrupt_requested);
  // 编码 CONFIG 固定 payload。
  [[nodiscard]] Outcome<Reply> RequestConfig(const protocol::Config &config,
                                             std::chrono::milliseconds window);
  // 编码累计 CONSUME 进度。
  [[nodiscard]] Outcome<Reply> RequestConsume(
    ByteCount consumed_bytes, std::chrono::milliseconds window,
    const std::atomic<bool> *interrupt_requested = nullptr);
  // 只对 FPGA reason=2 的暂态进度错误创建新 transaction 重试；ABORT
  // 一旦置位，不再发送新的 CONSUME，也会中断当前事务的响应等待。
  [[nodiscard]] Outcome<Reply> ConsumeWithProgressRetry(
    ByteCount consumed_bytes, std::chrono::milliseconds window,
    const std::atomic<bool> *interrupt_requested = nullptr);
  // 持续 ABORT/STATUS，直到 FPGA 宣布 FAULTED + safe_to_release。
  [[nodiscard]] bool AbortUntilSafe(const TimingConfig &timing,
                                    EventSink events);

 private:
  [[nodiscard]] static TransactionId NormalizeTransactionSeed(
    TransactionId seed) noexcept;
  [[nodiscard]] Outcome<TransactionId> AllocateTransaction();
  [[nodiscard]] Outcome<Reply> RequestImpl(
    protocol::Opcode opcode, std::span<const std::byte> payload,
    std::chrono::milliseconds window,
    const std::atomic<bool> *interrupt_requested);
  [[nodiscard]] Outcome<Reply> Transact(
    const protocol::Transaction &transaction,
    std::chrono::milliseconds window,
    const std::atomic<bool> *interrupt_requested);

  DatagramChannel &channel_;
  const TimingConfig &timing_;
  SessionId session_id_{};
  TransactionId next_transaction_{};
};

// 在已建立 QP/MR 后执行 CONFIG -> START。超时或 START 失败具有会话歧义，
// 必须在返回失败前完成 ABORT-until-safe；明确 CONFIG 拒绝不会发送 ABORT。
[[nodiscard]] Outcome<protocol::Status> ConfigureAndStartSession(
  ControlClient &control, const protocol::Config &config,
  const TimingConfig &timing, EventSink events, bool &session_armed);

} // namespace rrdma::detail

#endif // RRDMA_SRC_CONTROL_CLIENT_HPP_
