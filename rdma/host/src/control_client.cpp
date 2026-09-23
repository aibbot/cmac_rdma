#include "control_client.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <limits>
#include <optional>
#include <thread>
#include <utility>

namespace rrdma::detail {
namespace {

using Clock = std::chrono::steady_clock;
constexpr std::chrono::milliseconds kInterruptPollInterval{1};

[[nodiscard]] bool IsInterrupted(
    const std::atomic<bool> *interrupt_requested) noexcept {
  // STATUS 等低优先级请求可被消费者的 credit 返还抢占。
  return interrupt_requested != nullptr &&
         interrupt_requested->load(std::memory_order_acquire);
}

[[nodiscard]] Outcome<ControlClient::Reply> InterruptedTransaction() {
  // 将主动中断转换成普通 Outcome，调用方无需捕获异常。
  return Failure<ControlClient::Reply>(
      MakeError(ErrorCode::kStopped, "control transaction interrupted"));
}

[[nodiscard]] Error RemoteStatusError(const protocol::Status &status,
                                      std::string message) {
  // 将 CONFIG/START 的 wire 状态完整映射到公共错误对象。
  Error error = MakeError(ErrorCode::kRemoteRejected, std::move(message));
  error.remote_result = static_cast<std::uint16_t>(status.result);
  error.remote_state = static_cast<std::uint8_t>(status.state);
  error.remote_reason = status.reason;
  return error;
}

}  // namespace

ControlClient::ControlClient(DatagramChannel &channel,
                             const TimingConfig &timing,
                             std::uint64_t session_id,
                             std::uint32_t transaction_seed) noexcept
    : channel_(channel),
      timing_(timing),
      session_id_(session_id),
      next_transaction_(NormalizeTransactionSeed(transaction_seed)) {}

// 为普通 opcode 分配一个新的事务并进入固定字节传输流程。
Outcome<ControlClient::Reply> ControlClient::Request(
    protocol::Opcode opcode, std::span<const std::byte> payload,
    std::chrono::milliseconds window) {
  auto transaction_id = AllocateTransaction();
  if (!transaction_id) {
    return Failure<Reply>(transaction_id.GetError());
  }
  const protocol::Transaction transaction{opcode, session_id_,
                                          transaction_id.Value(), payload};
  return Transact(transaction, window, nullptr);
}

// 与 Request 相同，但在每次收发等待期间检查外部停止标志。
Outcome<ControlClient::Reply> ControlClient::RequestInterruptible(
    protocol::Opcode opcode, std::span<const std::byte> payload,
    std::chrono::milliseconds window,
    const std::atomic<bool> &interrupt_requested) {
  auto transaction_id = AllocateTransaction();
  if (!transaction_id) {
    return Failure<Reply>(transaction_id.GetError());
  }
  const protocol::Transaction transaction{opcode, session_id_,
                                          transaction_id.Value(), payload};
  return Transact(transaction, window, &interrupt_requested);
}

// 构造 CONFIG 的固定 payload；事务 ID 只分配一次。
Outcome<ControlClient::Reply> ControlClient::RequestConfig(
    const protocol::Config &config, std::chrono::milliseconds window) {
  auto transaction_id = AllocateTransaction();
  if (!transaction_id) {
    return Failure<Reply>(transaction_id.GetError());
  }
  const auto packet =
      protocol::MakeConfigRequest(session_id_, transaction_id.Value(), config);
  const protocol::Transaction transaction{
      protocol::Opcode::kConfig, session_id_, transaction_id.Value(),
      packet.Bytes().subspan(protocol::kHeaderBytes)};
  return TransactPacket(transaction, packet, window, nullptr);
}

// 构造累计 CONSUME 请求，消费游标不会回退。
Outcome<ControlClient::Reply> ControlClient::RequestConsume(
    std::uint64_t consumed_bytes, std::chrono::milliseconds window,
    const std::atomic<bool> *interrupt_requested) {
  auto transaction_id = AllocateTransaction();
  if (!transaction_id) {
    return Failure<Reply>(transaction_id.GetError());
  }
  const auto packet = protocol::MakeConsumeRequest(
      session_id_, transaction_id.Value(), consumed_bytes);
  const protocol::Transaction transaction{
      protocol::Opcode::kConsume, session_id_, transaction_id.Value(),
      packet.Bytes().subspan(protocol::kHeaderBytes)};
  return TransactPacket(transaction, packet, window, interrupt_requested);
}

Outcome<ControlClient::Reply> ControlClient::ConsumeWithProgressRetry(
    std::uint64_t consumed_bytes, std::chrono::milliseconds window,
    const std::atomic<bool> *interrupt_requested) {
  // FPGA 可能在发布进度前短暂返回 reason=2；仅对这一种暂态错误
  // 创建新事务重试，永久错误和传输错误立即交给状态机处理。
  const auto deadline = Clock::now() + window;
  while (Clock::now() < deadline) {
    if (IsInterrupted(interrupt_requested)) {
      return InterruptedTransaction();
    }
    const auto remaining =
        std::chrono::duration_cast<std::chrono::milliseconds>(deadline -
                                                              Clock::now());
    // FPGA 会缓存每个 CONSUME 响应；ahead-of-published 暂态拒绝必须使用新
    // transaction，而 TransactPacket 内部的纯传输重试仍复用完全相同的报文。
    auto reply = RequestConsume(
        consumed_bytes, std::max(std::chrono::milliseconds{1}, remaining),
        interrupt_requested);
    if (!reply ||
        reply.Value().status.result != protocol::Result::kInvalidProgress ||
        reply.Value().status.reason != 2U) {
      return reply;
    }
    if (IsInterrupted(interrupt_requested)) {
      return InterruptedTransaction();
    }
    const auto pause =
        std::min(timing_.progress_retry_interval,
                 std::chrono::duration_cast<std::chrono::microseconds>(
                     deadline - Clock::now()));
    if (pause.count() > 0) {
      std::this_thread::sleep_for(pause);
    }
  }
  return Failure<Reply>(
      MakeError(ErrorCode::kTimeout, "CONSUME progress retry window expired"));
}

bool ControlClient::AbortUntilSafe(const TimingConfig &timing,
                                   EventSink events) {
  // ABORT/STATUS 采用独立恢复循环；在 FPGA 明确 safe_to_release 前，
  // 调用方不得销毁 QP、CQ 或 MR。
  auto next_warning = Clock::now() + timing.recovery_warning_interval;
  while (true) {
    protocol::ReleaseGate gate;
    auto abort_reply =
        Request(protocol::Opcode::kAbort, {}, timing.command_window);
    if (abort_reply) {
      gate.ObserveStatus(abort_reply.Value().status);
      if (gate.FaultReleaseReady()) {
        return true;
      }
    }
    auto status_reply =
        Request(protocol::Opcode::kStatus, {}, timing.status_timeout);
    if (status_reply) {
      gate.ObserveStatus(status_reply.Value().status);
      if (gate.FaultReleaseReady()) {
        return true;
      }
    }
    const auto now = Clock::now();
    if (now >= next_warning) {
      events.Emit(
          {Event::Level::kWarning,
           "FPGA has not reached FAULTED + safe_to_release; retrying ABORT"});
      next_warning = now + timing.recovery_warning_interval;
    }
    std::this_thread::sleep_for(timing.retry_interval);
  }
}

Outcome<protocol::Status> ConfigureAndStartSession(
    ControlClient &control, const protocol::Config &config,
    const TimingConfig &timing, EventSink events, bool &session_armed) {
  // CONFIG 一旦开始发送，异常和超时都可能表示 FPGA 已接收请求，因此先把
  // 本地资源置于 armed 状态；调用方只能在本函数安全失败后销毁 QP/MR。
  session_armed = true;
  auto config_reply = control.RequestConfig(config, timing.command_window);
  if (!config_reply) {
    auto error = config_reply.GetError();
    (void)control.AbortUntilSafe(timing, events);
    session_armed = false;
    return Failure<protocol::Status>(std::move(error));
  }

  const auto config_status = config_reply.Value().status;
  if (config_status.result != protocol::Result::kOk ||
      config_status.state != protocol::State::kReady) {
    // 明确拒绝证明本 session 未激活；ABORT 可能干扰 FPGA 上的其他 session。
    session_armed = false;
    return Failure<protocol::Status>(
        RemoteStatusError(config_status, "FPGA CONFIG rejected"));
  }

  auto start_reply =
      control.Request(protocol::Opcode::kStart, {}, timing.command_window);
  if (!start_reply ||
      start_reply.Value().status.result != protocol::Result::kOk ||
      start_reply.Value().status.state != protocol::State::kRunning) {
    auto error = start_reply ? RemoteStatusError(start_reply.Value().status,
                                                 "FPGA START failed")
                             : start_reply.GetError();
    (void)control.AbortUntilSafe(timing, events);
    session_armed = false;
    return Failure<protocol::Status>(std::move(error));
  }
  return start_reply.Value().status;
}

std::uint32_t ControlClient::NormalizeTransactionSeed(
    std::uint32_t seed) noexcept {
  // RDCP 事务空间使用低 31 位，零值保留给未初始化状态。
  seed &= 0x7fffffffU;
  return seed == 0U ? 1U : seed;
}

Outcome<std::uint32_t> ControlClient::AllocateTransaction() {
  // 单线程控制协调器递增事务号，耗尽时显式失败而不回绕复用。
  if (next_transaction_ == 0U || next_transaction_ > 0x7fffffffU) {
    return Failure<std::uint32_t>(
        MakeError(ErrorCode::kProtocolError,
                  "RDCP transaction ID space exhausted for this session"));
  }
  return next_transaction_++;
}

Outcome<ControlClient::Reply> ControlClient::Transact(
    const protocol::Transaction &transaction, std::chrono::milliseconds window,
    const std::atomic<bool> *interrupt_requested) {
  // 把 Transaction 的只读 span 拷贝到栈上固定数组，避免请求生命周期
  // 依赖调用者的临时 payload。
  protocol::WirePacket packet{};
  const auto request = transaction.Request();
  if (request.size() > packet.storage.size()) {
    return Failure<Reply>(
        MakeError(ErrorCode::kProtocolError,
                  "control request exceeds fixed wire buffer"));
  }
  packet.size = request.size();
  std::memcpy(packet.storage.data(), request.data(), request.size());
  return TransactPacket(transaction, packet, window, interrupt_requested);
}

Outcome<ControlClient::Reply> ControlClient::TransactPacket(
    const protocol::Transaction &transaction,
    const protocol::WirePacket &packet, std::chrono::milliseconds window,
    const std::atomic<bool> *interrupt_requested) {
  // 同一事务的超时重试发送完全相同的固定字节，避免 FPGA 把重试误判
  // 为新的事务；只有 CONSUME 的 reason=2 由上层分配新事务。
  if (window.count() <= 0) {
    return Failure<Reply>(
        MakeError(ErrorCode::kTimeout, "control transaction window is empty"));
  }

  std::array<std::byte, protocol::kMaxDatagramBytes> response{};
  // 每次 attempt 在同一 deadline 内重发同一 packet，收到不匹配响应时继续等待。
  const auto deadline = Clock::now() + window;
  std::optional<Error> last_error;
  while (Clock::now() < deadline) {
    if (IsInterrupted(interrupt_requested)) {
      return InterruptedTransaction();
    }
    const auto attempt_deadline =
        std::min(deadline, Clock::now() + timing_.retry_interval);
    const auto sent = channel_.Send(packet.Bytes());
    if (!sent) {
      last_error = sent.GetError();
    } else if (sent.Value() != packet.size) {
      last_error = MakeError(ErrorCode::kTransportError,
                             "control channel sent a short datagram");
    } else {
      while (Clock::now() < attempt_deadline) {
        if (IsInterrupted(interrupt_requested)) {
          return InterruptedTransaction();
        }
        auto wait =
            std::max(std::chrono::milliseconds{1},
                     std::chrono::duration_cast<std::chrono::milliseconds>(
                         attempt_deadline - Clock::now()));
        if (interrupt_requested != nullptr) {
          wait = std::min(wait, kInterruptPollInterval);
        }
        auto received = channel_.Receive(response, wait);
        if (!received) {
          if (IsInterrupted(interrupt_requested)) {
            return InterruptedTransaction();
          }
          if (interrupt_requested != nullptr &&
              received.GetError().code == ErrorCode::kTimeout &&
              Clock::now() < attempt_deadline) {
            continue;
          }
          if (received.GetError().code != ErrorCode::kTimeout) {
            last_error = received.GetError();
          }
          break;
        }
        if (received.Value() == 0U || received.Value() > response.size()) {
          return Failure<Reply>(
              MakeError(ErrorCode::kTransportError,
                        "control channel returned an invalid datagram length"));
        }
        Reply reply{};
        if (transaction.Accept(
                std::span<const std::byte>{response.data(), received.Value()},
                reply.status)) {
          return reply;
        }
      }
    }
    if (IsInterrupted(interrupt_requested)) {
      return InterruptedTransaction();
    }
    if (Clock::now() < attempt_deadline) {
      std::this_thread::sleep_until(attempt_deadline);
    }
  }
  if (last_error.has_value()) {
    return Failure<Reply>(std::move(*last_error));
  }
  return Failure<Reply>(
      MakeError(ErrorCode::kTimeout, "control transaction timed out"));
}

}  // namespace rrdma::detail
