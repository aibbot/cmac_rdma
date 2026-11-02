#include <linux/memfd.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <future>
#include <limits>
#include <mutex>
#include <span>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

#include "batch_queue.hpp"
#include "consumer_path.hpp"
#include "control_client.hpp"
#include "detail.hpp"
#include "rrdma/protocol.hpp"
#include "rrdma/session.hpp"
#include "rfso.hpp"

namespace {

static_assert(sizeof(rrdma::ByteCount) == sizeof(std::uint64_t));
static_assert(sizeof(rrdma::HostAddress) == sizeof(std::uint64_t));
static_assert(std::is_same_v<decltype(rrdma::SessionConfig{}.ring_bytes),
                             rrdma::ByteCount>);
static_assert(std::is_same_v<decltype(rrdma::SessionConfig{}.receive_depth),
                             rrdma::HostCount>);
static_assert(std::is_same_v<decltype(rrdma::CommitMetadata{}.sequence),
                             rrdma::CommitSequence>);
static_assert(std::is_same_v<decltype(rrdma::protocol::WirePacket{}.size),
                             rrdma::ByteCount>);

// 测试辅助函数以 little-endian 写入模拟 FPGA commit record。
void WriteLe32(std::byte *bytes, std::uint32_t value) noexcept {
  bytes[0] = static_cast<std::byte>(value);
  bytes[1] = static_cast<std::byte>(value >> 8U);
  bytes[2] = static_cast<std::byte>(value >> 16U);
  bytes[3] = static_cast<std::byte>(value >> 24U);
}

void WriteLe64(std::byte *bytes, std::uint64_t value) noexcept {
  WriteLe32(bytes, static_cast<std::uint32_t>(value));
  WriteLe32(bytes + 4U, static_cast<std::uint32_t>(value >> 32U));
}

template <std::size_t Size>
bool BytesEqual(std::span<const std::byte> actual,
                const std::array<std::uint8_t, Size> &expected) noexcept {
  if (actual.size() != expected.size()) {
    return false;
  }
  for (rrdma::HostCount index{}; index < expected.size(); ++index) {
    if (std::to_integer<std::uint8_t>(actual[index]) != expected[index]) {
      return false;
    }
  }
  return true;
}

// 构造与 FPGA RDCP v2 完全一致的 STATUS 响应，用于 golden/malformed 测试。
rrdma::protocol::WirePacket MakeStatusResponse(
  rrdma::protocol::Opcode opcode, std::uint64_t session_id,
  std::uint32_t transaction_id,
  const rrdma::protocol::Status &status) noexcept {
  rrdma::protocol::WirePacket packet{};
  packet.size = rrdma::protocol::kHeaderBytes + rrdma::protocol::kStatusBytes;
  const rrdma::protocol::wire::Header header{
      rrdma::wire::Be32{rrdma::protocol::kMagic},
      rrdma::protocol::kVersion,
      rrdma::protocol::ResponseOpcode(opcode),
      rrdma::wire::Be16{static_cast<std::uint16_t>(rrdma::protocol::kStatusBytes)},
      rrdma::wire::Be64{session_id},
      rrdma::wire::Be32{transaction_id}};
  rrdma::protocol::wire::Status payload{};
  payload.result = static_cast<std::uint16_t>(status.result);
  payload.state = static_cast<std::uint8_t>(status.state);
  payload.reason = status.reason;
  payload.status_bits = status.status_bits;
  payload.local_qpn = status.local_qpn;
  payload.current_psn = status.current_psn;
  payload.config_generation = status.config_generation;
  payload.issued_bytes = status.issued_bytes;
  payload.acked_bytes = status.acked_bytes;
  payload.published_bytes = status.published_bytes;
  payload.consumed_bytes = status.consumed_bytes;
  payload.capabilities = status.capabilities;
  payload.pmtu_bytes = status.pmtu_bytes;
  std::memcpy(packet.storage.data(), &header, sizeof header);
  std::memcpy(packet.storage.data() + rrdma::protocol::kHeaderBytes,
              &payload, sizeof payload);
  return packet;
}

[[nodiscard]] rrdma::protocol::wire::Header ReadHeader(
    const rrdma::protocol::WirePacket &packet) noexcept {
  rrdma::protocol::wire::Header header{};
  std::memcpy(&header, packet.storage.data(), sizeof header);
  return header;
}

void WriteHeader(rrdma::protocol::WirePacket &packet,
                 const rrdma::protocol::wire::Header &header) noexcept {
  std::memcpy(packet.storage.data(), &header, sizeof header);
}

[[nodiscard]] rrdma::protocol::wire::Status ReadStatus(
    const rrdma::protocol::WirePacket &packet) noexcept {
  rrdma::protocol::wire::Status status{};
  std::memcpy(&status, packet.storage.data() + rrdma::protocol::kHeaderBytes,
              sizeof status);
  return status;
}

void WriteStatus(rrdma::protocol::WirePacket &packet,
                 const rrdma::protocol::wire::Status &status) noexcept {
  std::memcpy(packet.storage.data() + rrdma::protocol::kHeaderBytes, &status,
              sizeof status);
}

// 返回满足活动 session 约束的基础状态快照。
rrdma::protocol::Status RunningStatus() noexcept {
  rrdma::protocol::Status status{};
  status.result = rrdma::protocol::Result::kOk;
  status.state = rrdma::protocol::State::kRunning;
  status.local_qpn = rrdma::protocol::kFpgaQpn;
  status.capabilities = rrdma::protocol::kCapabilitiesV2;
  status.pmtu_bytes = rrdma::protocol::kPmtuBytes;
  return status;
}

// 按预设状态序列响应请求，并保存发送字节供事务重试断言。
class ScriptedChannel final : public rrdma::DatagramChannel {
 public:
  explicit ScriptedChannel(
    std::vector<rrdma::protocol::Status> responses,
    rrdma::HostCount timeouts_before_response = 0U,
    const std::atomic<rrdma::ByteCount> *released_frontier = nullptr,
    std::atomic<bool> *interrupt_after_first_response = nullptr)
   : responses_(std::move(responses)),
     timeouts_before_response_(timeouts_before_response),
     released_frontier_(released_frontier),
     interrupt_after_first_response_(interrupt_after_first_response) {
  }

  rrdma::Outcome<rrdma::ByteCount> Send(
    std::span<const std::byte> bytes) noexcept override {
    try {
      if (!frontier_captured_ && released_frontier_ != nullptr) {
        frontier_at_first_send_ =
          released_frontier_->load(std::memory_order_acquire);
        frontier_captured_ = true;
      }
      sent_packets_.emplace_back(bytes.begin(), bytes.end());
      return bytes.size();
    } catch (...) {
      return rrdma::Failure<rrdma::ByteCount>(
        rrdma::MakeError(rrdma::ErrorCode::kAllocationFailed,
                         "scripted channel cannot record datagram"));
    }
  }

  rrdma::Outcome<rrdma::ByteCount> Receive(
    std::span<std::byte> buffer,
    std::chrono::milliseconds /*timeout*/) noexcept override {
    if (timeouts_before_response_ != 0U) {
      --timeouts_before_response_;
      return rrdma::Failure<rrdma::ByteCount>(rrdma::MakeError(
        rrdma::ErrorCode::kTimeout, "scripted receive timeout"));
    }
    if (next_response_ >= responses_.size() || sent_packets_.empty()) {
      return rrdma::Failure<rrdma::ByteCount>(
        rrdma::MakeError(rrdma::ErrorCode::kTimeout, "no scripted response"));
    }
    const auto &request = sent_packets_.back();
    if (request.size() < rrdma::protocol::kHeaderBytes) {
      return rrdma::Failure<rrdma::ByteCount>(
        rrdma::MakeError(rrdma::ErrorCode::kProtocolError,
                         "scripted request is shorter than the RDCP header"));
    }
    const auto opcode = static_cast<rrdma::protocol::Opcode>(
      std::to_integer<std::uint8_t>(request[5]));
    rrdma::protocol::wire::Header header{};
    std::memcpy(&header, request.data(), sizeof header);
    const auto session_id = header.session_id.value();
    const auto transaction_id = header.transaction_id.value();
    const auto response = MakeStatusResponse(opcode, session_id, transaction_id,
                                             responses_[next_response_++]);
    if (buffer.size() < response.size) {
      return rrdma::Failure<rrdma::ByteCount>(
        rrdma::MakeError(rrdma::ErrorCode::kInvalidConfiguration,
                         "scripted response buffer is too small"));
    }
    std::memcpy(buffer.data(), response.storage.data(), response.size);
    if (next_response_ == 1U && interrupt_after_first_response_ != nullptr) {
      interrupt_after_first_response_->store(true, std::memory_order_release);
    }
    return response.size;
  }

  [[nodiscard]] const std::vector<std::vector<std::byte>> &SentPackets()
    const noexcept {
    return sent_packets_;
  }
  [[nodiscard]] rrdma::ByteCount FrontierAtFirstSend() const noexcept {
    return frontier_at_first_send_;
  }

 private:
  std::vector<rrdma::protocol::Status> responses_;
  rrdma::HostCount timeouts_before_response_{};
  rrdma::HostCount next_response_{};
  std::vector<std::vector<std::byte>> sent_packets_;
  const std::atomic<rrdma::ByteCount> *released_frontier_{};
  std::atomic<bool> *interrupt_after_first_response_{};
  rrdma::ByteCount frontier_at_first_send_{};
  bool frontier_captured_{};
};

// 按 opcode 返回生命周期状态，用于验证 CONFIG/START/ABORT 的组合事务。
class LifecycleChannel final : public rrdma::DatagramChannel {
 public:
  enum class Mode : std::uint8_t {
    kSuccess,
    kConfigTimeout,
    kConfigReject,
    kStartReject,
  };

  explicit LifecycleChannel(Mode mode) noexcept : mode_(mode) {
  }

  rrdma::Outcome<rrdma::ByteCount> Send(
    std::span<const std::byte> bytes) noexcept override {
    try {
      if (bytes.size() < rrdma::protocol::kHeaderBytes) {
        return rrdma::Failure<rrdma::ByteCount>(rrdma::MakeError(
          rrdma::ErrorCode::kProtocolError, "lifecycle request too short"));
      }
      last_request_.assign(bytes.begin(), bytes.end());
      opcodes_.push_back(static_cast<rrdma::protocol::Opcode>(
        std::to_integer<std::uint8_t>(bytes[5])));
      return bytes.size();
    } catch (...) {
      return rrdma::Failure<rrdma::ByteCount>(
        rrdma::MakeError(rrdma::ErrorCode::kAllocationFailed,
                         "lifecycle channel cannot record request"));
    }
  }

  rrdma::Outcome<rrdma::ByteCount> Receive(
    std::span<std::byte> buffer,
    std::chrono::milliseconds /*timeout*/) noexcept override {
    if (opcodes_.empty() || last_request_.size() < rrdma::protocol::kHeaderBytes) {
      return rrdma::Failure<rrdma::ByteCount>(rrdma::MakeError(
        rrdma::ErrorCode::kTimeout, "lifecycle channel has no request"));
    }
    const auto opcode = opcodes_.back();
    if (mode_ == Mode::kConfigTimeout && opcode == rrdma::protocol::Opcode::kConfig) {
      return rrdma::Failure<rrdma::ByteCount>(rrdma::MakeError(
        rrdma::ErrorCode::kTimeout, "scripted CONFIG timeout"));
    }

    auto status = StatusFor(opcode);
    rrdma::protocol::wire::Header header{};
    std::memcpy(&header, last_request_.data(), sizeof header);
    const auto response = MakeStatusResponse(
      opcode, header.session_id.value(), header.transaction_id.value(), status);
    if (buffer.size() < response.size) {
      return rrdma::Failure<rrdma::ByteCount>(
        rrdma::MakeError(rrdma::ErrorCode::kInvalidConfiguration,
                         "lifecycle response buffer is too small"));
    }
    std::memcpy(buffer.data(), response.storage.data(), response.size);
    return response.size;
  }

  [[nodiscard]] rrdma::HostCount Count(rrdma::protocol::Opcode opcode) const {
    return std::count(opcodes_.begin(), opcodes_.end(), opcode);
  }

 private:
  [[nodiscard]] rrdma::protocol::Status StatusFor(
    rrdma::protocol::Opcode opcode) const noexcept {
    auto status = RunningStatus();
    if (opcode == rrdma::protocol::Opcode::kConfig) {
      status.state = rrdma::protocol::State::kReady;
      if (mode_ == Mode::kConfigReject) {
        status.result = rrdma::protocol::Result::kInvalidConfig;
        status.state = rrdma::protocol::State::kIdle;
      }
    } else if (opcode == rrdma::protocol::Opcode::kStart && mode_ == Mode::kStartReject) {
      status.result = rrdma::protocol::Result::kInvalidState;
      status.state = rrdma::protocol::State::kReady;
    } else if (opcode == rrdma::protocol::Opcode::kAbort) {
      status.state = rrdma::protocol::State::kFaultQuiescing;
    } else if (opcode == rrdma::protocol::Opcode::kStatus) {
      status.state = rrdma::protocol::State::kFaulted;
      status.status_bits = rrdma::protocol::kStatusSafeToRelease;
    }
    return status;
  }

  Mode mode_;
  std::vector<std::byte> last_request_;
  std::vector<rrdma::protocol::Opcode> opcodes_;
};

// 模拟 datagram 长度超过接收缓冲区的错误通道。
class OversizedDatagramChannel final : public rrdma::DatagramChannel {
 public:
  rrdma::Outcome<rrdma::ByteCount> Send(
    std::span<const std::byte> bytes) noexcept override {
    return bytes.size();
  }

  rrdma::Outcome<rrdma::ByteCount> Receive(
    std::span<std::byte> buffer,
    std::chrono::milliseconds /*timeout*/) noexcept override {
    return buffer.size() + 1U;
  }
};

// 模拟持续超时，用于验证低优先级 STATUS 可被 CONSUME 抢占。
class InterruptingChannel final : public rrdma::DatagramChannel {
 public:
  explicit InterruptingChannel(std::atomic<bool> &interrupt_requested) noexcept
   : interrupt_requested_(interrupt_requested) {
  }

  rrdma::Outcome<rrdma::ByteCount> Send(
    std::span<const std::byte> bytes) noexcept override {
    ++send_count_;
    return bytes.size();
  }

  rrdma::Outcome<rrdma::ByteCount> Receive(
    std::span<std::byte> /*buffer*/,
    std::chrono::milliseconds /*timeout*/) noexcept override {
    interrupt_requested_.store(true, std::memory_order_release);
    return rrdma::Failure<rrdma::ByteCount>(rrdma::MakeError(
      rrdma::ErrorCode::kTimeout, "scripted receive timeout"));
  }

  [[nodiscard]] rrdma::HostCount SendCount() const noexcept {
    return send_count_;
  }

 private:
  std::atomic<bool> &interrupt_requested_;
  rrdma::HostCount send_count_{};
};

// 缩短控制面窗口，使单元测试无需等待产品级超时。
rrdma::TimingConfig FastTiming() noexcept {
  rrdma::TimingConfig timing{};
  timing.retry_interval = std::chrono::milliseconds{1};
  timing.progress_retry_interval = std::chrono::microseconds{1};
  return timing;
}

// 生成通过本地校验的最小 SessionOptions 基线。
rrdma::SessionOptions ValidConfig() {
  rrdma::SessionOptions config{};
  config.network.device_name = "device";
  config.network.netdev_name = "netdev";
  return config;
}

// 校验 CONFIG/CONSUME 请求的每个 wire 字节与 RDCP v2 golden 值一致。
void TestProtocolGoldenRequests() {
  rrdma::protocol::Config config{};
  config.remote_qpn = 0x01020304U;
  config.local_psn = 0x00050607U;
  config.remote_base = 0x0000000011223344ULL;
  config.rkey = 0x55667788U;
  config.ring_size = 0x40000000U;
  config.wr_size = 0x00a00000U;
  config.notify_interval = 0x00a00000U;
  config.local_base = 0U;
  config.commit_address = 0x0000000055667788ULL;
  config.flags = 1U;
  const auto config_packet = rrdma::protocol::MakeConfigRequest(
    0x0102030405060708ULL, 0x090a0b0cU, config);
  constexpr std::array<std::uint8_t, 76> kExpectedConfig{
    0x52, 0x44, 0x43, 0x50, 0x02, 0x02, 0x00, 0x38, 0x01, 0x02, 0x03,
    0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x01, 0x02,
    0x03, 0x04, 0x00, 0x05, 0x06, 0x07, 0x00, 0x00, 0x00, 0x00, 0x11,
    0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x40, 0x00, 0x00, 0x00,
    0x00, 0xa0, 0x00, 0x00, 0x00, 0xa0, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x55, 0x66,
    0x77, 0x88, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00};
  assert(BytesEqual(config_packet.Bytes(), kExpectedConfig));

  const auto consume_packet = rrdma::protocol::MakeConsumeRequest(
    0x0102030405060708ULL, 0x090a0b0cU, 0x1122334455667788ULL);
  constexpr std::array<std::uint8_t, 28> kExpectedConsume{
    0x52, 0x44, 0x43, 0x50, 0x02, 0x07, 0x00, 0x08, 0x01, 0x02,
    0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88};
  assert(BytesEqual(consume_packet.Bytes(), kExpectedConsume));
}

// 校验合法 STATUS 解码以及长度/opcode/session/transaction/保留位拒绝。
void TestProtocolGoldenStatusAndMalformedPackets() {
  constexpr std::uint64_t kSessionId{0x0102030405060708ULL};
  constexpr std::uint32_t kTransactionId{0x090a0b0cU};
  constexpr std::array<std::uint8_t, 84> kGoldenStatus{
    0x52, 0x44, 0x43, 0x50, 0x02, 0x86, 0x00, 0x40, 0x01, 0x02, 0x03, 0x04,
    0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x00, 0x00, 0x03, 0x00,
    0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x53, 0x00, 0x00, 0x00, 0x01,
    0x00, 0xab, 0xcd, 0xef, 0x01, 0x02, 0x03, 0x04, 0x11, 0x12, 0x13, 0x14,
    0x15, 0x16, 0x17, 0x18, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
    0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x41, 0x42, 0x43, 0x44,
    0x45, 0x46, 0x47, 0x48, 0x00, 0x00, 0x00, 0x0f, 0x00, 0x00, 0x10, 0x00};
  rrdma::protocol::WirePacket packet{};
  packet.size = kGoldenStatus.size();
  for (rrdma::HostCount index{}; index < kGoldenStatus.size(); ++index) {
    packet.storage[index] = static_cast<std::byte>(kGoldenStatus[index]);
  }

  rrdma::protocol::Status status{};
  assert(rrdma::protocol::DecodeStatus(packet.Bytes(),
                                       rrdma::protocol::Opcode::kStatus,
                                       kSessionId, kTransactionId, status));
  assert(status.result == rrdma::protocol::Result::kOk);
  assert(status.state == rrdma::protocol::State::kRunning);
  assert(status.reason == 0x11223344U);
  assert(status.status_bits == 0x53U);
  assert(status.local_qpn == 1U);
  assert(status.current_psn == 0x00abcdefU);
  assert(status.config_generation == 0x01020304U);
  assert(status.issued_bytes == 0x1112131415161718ULL);
  assert(status.acked_bytes == 0x2122232425262728ULL);
  assert(status.published_bytes == 0x3132333435363738ULL);
  assert(status.consumed_bytes == 0x4142434445464748ULL);
  assert(status.capabilities == 0x0fU);
  assert(status.pmtu_bytes == 4096U);

  auto malformed = packet;
  auto malformed_header = ReadHeader(malformed);
  malformed_header.payload_length = 63U;
  WriteHeader(malformed, malformed_header);
  assert(!rrdma::protocol::DecodeStatus(malformed.Bytes(),
                                        rrdma::protocol::Opcode::kStatus,
                                        kSessionId, kTransactionId, status));
  malformed = packet;
  malformed.storage[5] = static_cast<std::byte>(0x85U);
  assert(!rrdma::protocol::DecodeStatus(malformed.Bytes(),
                                        rrdma::protocol::Opcode::kStatus,
                                        kSessionId, kTransactionId, status));
  malformed = packet;
  malformed.storage[23] = static_cast<std::byte>(1U);
  assert(!rrdma::protocol::DecodeStatus(malformed.Bytes(),
                                        rrdma::protocol::Opcode::kStatus,
                                        kSessionId, kTransactionId, status));
  malformed = packet;
  malformed_header = ReadHeader(malformed);
  malformed_header.session_id = kSessionId + 1U;
  WriteHeader(malformed, malformed_header);
  assert(!rrdma::protocol::DecodeStatus(malformed.Bytes(),
                                        rrdma::protocol::Opcode::kStatus,
                                        kSessionId, kTransactionId, status));
  malformed = packet;
  malformed_header = ReadHeader(malformed);
  malformed_header.transaction_id = kTransactionId + 1U;
  WriteHeader(malformed, malformed_header);
  assert(!rrdma::protocol::DecodeStatus(malformed.Bytes(),
                                        rrdma::protocol::Opcode::kStatus,
                                        kSessionId, kTransactionId, status));
  malformed = packet;
  auto malformed_payload = ReadStatus(malformed);
  malformed_payload.result = 12U;
  WriteStatus(malformed, malformed_payload);
  assert(!rrdma::protocol::DecodeStatus(malformed.Bytes(),
                                        rrdma::protocol::Opcode::kStatus,
                                        kSessionId, kTransactionId, status));
  malformed = packet;
  malformed.storage[22] = static_cast<std::byte>(8U);
  assert(!rrdma::protocol::DecodeStatus(malformed.Bytes(),
                                        rrdma::protocol::Opcode::kStatus,
                                        kSessionId, kTransactionId, status));
  assert(!rrdma::protocol::DecodeStatus(packet.Bytes().first(packet.size - 1U),
                                        rrdma::protocol::Opcode::kStatus,
                                        kSessionId, kTransactionId, status));

  const rrdma::protocol::Transaction transaction{
    rrdma::protocol::Opcode::kStatus, kSessionId, kTransactionId};
  assert(transaction.Accept(packet.Bytes(), status));
}

// 验证传输重试复用同一 transaction ID 和完全相同的报文字节。
void TestControlRetryReusesTransactionBytes() {
  ScriptedChannel channel{{RunningStatus()}, 1U};
  const auto timing = FastTiming();
  rrdma::detail::ControlClient client{channel, timing, 0x1234U, 17U};
  const auto reply = client.Request(rrdma::protocol::Opcode::kStatus, {},
                                    std::chrono::milliseconds{20});
  assert(reply);
  assert(channel.SentPackets().size() == 2U);
  assert(channel.SentPackets()[0] == channel.SentPackets()[1]);
  rrdma::protocol::wire::Header header{};
  std::memcpy(&header, channel.SentPackets()[0].data(), sizeof header);
  assert(header.transaction_id == 17U);
}

// 验证仅 invalid_progress reason=2 分配新事务重试 CONSUME。
void TestConsumeProgressRetryTransactions() {
  constexpr rrdma::ByteCount kConsumedBytes{0x00100000ULL};
  auto transient = RunningStatus();
  transient.result = rrdma::protocol::Result::kInvalidProgress;
  transient.reason = 2U;
  auto accepted = RunningStatus();
  accepted.consumed_bytes = kConsumedBytes;
  ScriptedChannel retry_channel{{transient, accepted}};
  const auto timing = FastTiming();
  rrdma::detail::ControlClient retry_client{retry_channel, timing, 0x9876U,
                                            30U};
  const auto retried = retry_client.ConsumeWithProgressRetry(
    kConsumedBytes, std::chrono::milliseconds{20});
  assert(retried);
  assert(retried.Value().status.result == rrdma::protocol::Result::kOk);
  assert(retry_channel.SentPackets().size() == 2U);
  rrdma::protocol::wire::Header first_header{};
  rrdma::protocol::wire::Header second_header{};
  std::memcpy(&first_header, retry_channel.SentPackets()[0].data(),
              sizeof first_header);
  std::memcpy(&second_header, retry_channel.SentPackets()[1].data(),
              sizeof second_header);
  assert(first_header.transaction_id == 30U);
  assert(second_header.transaction_id == 31U);
  assert(std::equal(
    retry_channel.SentPackets()[0].begin() + rrdma::protocol::kHeaderBytes,
    retry_channel.SentPackets()[0].end(),
    retry_channel.SentPackets()[1].begin() + rrdma::protocol::kHeaderBytes));

  auto permanent = RunningStatus();
  permanent.result = rrdma::protocol::Result::kInvalidProgress;
  permanent.reason = 1U;
  ScriptedChannel reject_channel{{permanent}};
  rrdma::detail::ControlClient reject_client{reject_channel, timing, 0x9876U,
                                             40U};
  const auto rejected = reject_client.ConsumeWithProgressRetry(
    kConsumedBytes, std::chrono::milliseconds{20});
  assert(rejected);
  assert(rejected.Value().status.result == rrdma::protocol::Result::kInvalidProgress);
  assert(reject_channel.SentPackets().size() == 1U);

  // 第一次暂态拒绝返回后触发 ABORT，不能再分配或发送第二个 CONSUME。
  std::atomic<bool> abort_requested{};
  ScriptedChannel interrupted_channel{
    {transient, accepted}, 0U, nullptr, &abort_requested};
  rrdma::detail::ControlClient interrupted_client{interrupted_channel, timing,
                                                  0x9876U, 50U};
  const auto interrupted = interrupted_client.ConsumeWithProgressRetry(
    kConsumedBytes, std::chrono::milliseconds{20}, &abort_requested);
  assert(!interrupted);
  assert(interrupted.GetError().code == rrdma::ErrorCode::kStopped);
  assert(interrupted_channel.SentPackets().size() == 1U);
}

// 验证 callback、累计 credit 和 STOP/ABORT 决策的严格先后关系。
void TestConsumerBatchTransactionOrder() {
  constexpr rrdma::ByteCount kConsumedBytes{2U * rrdma::kPacketBytes};
  rrdma::CommitBatch batch{};
  batch.commit.sequence = 7U;
  batch.commit.published_bytes = kConsumedBytes;

  auto accepted = RunningStatus();
  accepted.consumed_bytes = kConsumedBytes;
  std::atomic<rrdma::ByteCount> released_frontier{};
  std::atomic<bool> control_priority_waiting{};
  std::atomic<bool> abort_requested{};
  std::mutex control_mutex;
  ScriptedChannel channel{{accepted}, 0U, &released_frontier};
  const auto timing = FastTiming();
  rrdma::detail::ControlClient control{channel, timing, 9U, 1U};
  bool callback_called{};
  auto continue_callback = [&](const rrdma::CommitBatch &observed) noexcept {
    // 应用完成处理前不能发布本地覆盖前沿，也不能发送 CONSUME。
    assert(observed.commit.sequence == batch.commit.sequence);
    assert(released_frontier.load(std::memory_order_acquire) == 0U);
    assert(channel.SentPackets().empty());
    callback_called = true;
    return rrdma::BatchAction::kContinueReceiving;
  };
  const auto consumed = rrdma::detail::ProcessCommittedBatch(
    batch, rrdma::CommitCallback::Bind(continue_callback), control,
    control_mutex, released_frontier, control_priority_waiting,
    abort_requested, std::chrono::milliseconds{20});
  assert(consumed);
  assert(callback_called);
  assert(consumed.Value().action == rrdma::BatchAction::kContinueReceiving);
  assert(released_frontier.load(std::memory_order_acquire) == kConsumedBytes);
  assert(channel.FrontierAtFirstSend() == kConsumedBytes);
  assert(!control_priority_waiting.load(std::memory_order_acquire));
  assert(channel.SentPackets().size() == 1U);
  rrdma::protocol::wire::Header consume_header{};
  rrdma::protocol::wire::Consume consume_payload{};
  std::memcpy(&consume_header, channel.SentPackets()[0].data(),
              sizeof consume_header);
  std::memcpy(&consume_payload,
              channel.SentPackets()[0].data() + rrdma::protocol::kHeaderBytes,
              sizeof consume_payload);
  assert(consume_header.opcode ==
         static_cast<std::uint8_t>(rrdma::protocol::Opcode::kConsume));
  assert(consume_payload.consumed_bytes == kConsumedBytes);

  std::atomic<rrdma::ByteCount> stop_frontier{};
  std::atomic<bool> stop_priority{};
  std::atomic<bool> stop_abort{};
  std::mutex stop_mutex;
  ScriptedChannel stop_channel{{accepted}, 0U, &stop_frontier};
  rrdma::detail::ControlClient stop_control{stop_channel, timing, 10U, 1U};
  auto stop_callback = [](const rrdma::CommitBatch &) noexcept {
    return rrdma::BatchAction::kStopAfterConsume;
  };
  const auto stopped = rrdma::detail::ProcessCommittedBatch(
    batch, rrdma::CommitCallback::Bind(stop_callback), stop_control,
    stop_mutex, stop_frontier, stop_priority, stop_abort,
    std::chrono::milliseconds{20});
  assert(stopped);
  assert(stopped.Value().action == rrdma::BatchAction::kStopAfterConsume);
  assert(stop_channel.SentPackets().size() == 1U);

  std::atomic<rrdma::ByteCount> abort_frontier{};
  std::atomic<bool> abort_priority{};
  std::atomic<bool> callback_abort_requested{};
  std::mutex abort_mutex;
  ScriptedChannel abort_channel{{}};
  rrdma::detail::ControlClient abort_control{abort_channel, timing, 11U, 1U};
  auto abort_callback = [](const rrdma::CommitBatch &) noexcept {
    return rrdma::BatchAction::kAbort;
  };
  const auto aborted = rrdma::detail::ProcessCommittedBatch(
    batch, rrdma::CommitCallback::Bind(abort_callback), abort_control,
    abort_mutex, abort_frontier, abort_priority, callback_abort_requested,
    std::chrono::milliseconds{20});
  assert(!aborted);
  assert(aborted.GetError().code == rrdma::ErrorCode::kCallbackRejected);
  assert(abort_frontier.load(std::memory_order_acquire) == 0U);
  assert(abort_channel.SentPackets().empty());

  callback_abort_requested.store(true, std::memory_order_release);
  auto ignored_callback = [](const rrdma::CommitBatch &) noexcept {
    return rrdma::BatchAction::kContinueReceiving;
  };
  const auto externally_aborted = rrdma::detail::ProcessCommittedBatch(
    batch, rrdma::CommitCallback::Bind(ignored_callback), abort_control,
    abort_mutex, abort_frontier, abort_priority, callback_abort_requested,
    std::chrono::milliseconds{20});
  assert(!externally_aborted);
  assert(externally_aborted.GetError().code == rrdma::ErrorCode::kStopped);
  assert(abort_frontier.load(std::memory_order_acquire) == 0U);
  assert(abort_channel.SentPackets().empty());

  // 模拟 callback 已成功、consumer 正等待控制锁时 producer 才请求 ABORT。
  // 解锁后必须在锁内发送门拒绝该批，不能推进前沿或发送 CONSUME。
  std::atomic<rrdma::ByteCount> raced_frontier{};
  std::atomic<bool> raced_priority{};
  std::atomic<bool> raced_abort{};
  std::mutex raced_mutex;
  std::unique_lock held_control_lock(raced_mutex);
  ScriptedChannel raced_channel{{accepted}, 0U, &raced_frontier};
  rrdma::detail::ControlClient raced_control{raced_channel, timing, 12U, 1U};
  auto raced_callback = [](const rrdma::CommitBatch &) noexcept {
    return rrdma::BatchAction::kContinueReceiving;
  };
  auto raced_consume = std::async(std::launch::async, [&] {
    return rrdma::detail::ProcessCommittedBatch(
      batch, rrdma::CommitCallback::Bind(raced_callback), raced_control,
      raced_mutex, raced_frontier, raced_priority, raced_abort,
      std::chrono::milliseconds{20});
  });
  const auto wait_deadline =
    std::chrono::steady_clock::now() + std::chrono::seconds{5};
  while (!raced_priority.load(std::memory_order_acquire) && std::chrono::steady_clock::now() < wait_deadline) {
    std::this_thread::yield();
  }
  assert(raced_priority.load(std::memory_order_acquire));
  raced_abort.store(true, std::memory_order_release);
  held_control_lock.unlock();
  assert(raced_consume.wait_for(std::chrono::seconds{5}) == std::future_status::ready);
  const auto raced_result = raced_consume.get();
  assert(!raced_result);
  assert(raced_result.GetError().code == rrdma::ErrorCode::kStopped);
  assert(raced_frontier.load(std::memory_order_acquire) == 0U);
  assert(raced_channel.SentPackets().empty());
}

// 覆盖事务空间耗尽、CONFIG 超时和明确配置拒绝的不同语义。
void TestControlTransactionExhaustionAndConfigOutcomes() {
  ScriptedChannel channel{{RunningStatus()}};
  const auto timing = FastTiming();
  rrdma::detail::ControlClient client{
    channel, timing, 1U, std::numeric_limits<std::uint32_t>::max() >> 1U};
  assert(client.Request(rrdma::protocol::Opcode::kStatus, {},
                        std::chrono::milliseconds{20}));
  const auto exhausted = client.Request(rrdma::protocol::Opcode::kStatus, {},
                                        std::chrono::milliseconds{20});
  assert(!exhausted);
  assert(exhausted.GetError().code == rrdma::ErrorCode::kProtocolError);
  assert(channel.SentPackets().size() == 1U);

  rrdma::protocol::Config config{};
  ScriptedChannel timeout_channel{std::vector<rrdma::protocol::Status>{}};
  rrdma::detail::ControlClient timeout_client{timeout_channel, timing, 2U, 1U};
  const auto timed_out =
    timeout_client.RequestConfig(config, std::chrono::milliseconds{3});
  assert(!timed_out);
  assert(timed_out.GetError().code == rrdma::ErrorCode::kTimeout);

  auto invalid = RunningStatus();
  invalid.result = rrdma::protocol::Result::kInvalidConfig;
  invalid.state = rrdma::protocol::State::kIdle;
  ScriptedChannel reject_channel{{invalid}};
  rrdma::detail::ControlClient reject_client{reject_channel, timing, 2U, 1U};
  const auto rejected =
    reject_client.RequestConfig(config, std::chrono::milliseconds{20});
  assert(rejected);
  assert(rejected.Value().status.result == rrdma::protocol::Result::kInvalidConfig);
}

// 验证真实 session 启动函数在歧义失败时先 ABORT 到 safe，明确拒绝不 ABORT。
void TestConfigureAndStartLifecycle() {
  auto timing = FastTiming();
  timing.command_window = std::chrono::milliseconds{3};
  timing.status_timeout = std::chrono::milliseconds{3};
  rrdma::protocol::Config config{};

  LifecycleChannel success_channel{LifecycleChannel::Mode::kSuccess};
  rrdma::detail::ControlClient success_control{success_channel, timing, 20U,
                                               1U};
  bool success_armed{};
  const auto started = rrdma::detail::ConfigureAndStartSession(
    success_control, config, timing, {}, success_armed);
  assert(started);
  assert(success_armed);
  assert(started.Value().state == rrdma::protocol::State::kRunning);
  assert(success_channel.Count(rrdma::protocol::Opcode::kConfig) == 1U);
  assert(success_channel.Count(rrdma::protocol::Opcode::kStart) == 1U);
  assert(success_channel.Count(rrdma::protocol::Opcode::kAbort) == 0U);

  LifecycleChannel timeout_channel{LifecycleChannel::Mode::kConfigTimeout};
  rrdma::detail::ControlClient timeout_control{timeout_channel, timing, 21U,
                                               1U};
  bool timeout_armed{};
  const auto timed_out = rrdma::detail::ConfigureAndStartSession(
    timeout_control, config, timing, {}, timeout_armed);
  assert(!timed_out);
  assert(timed_out.GetError().code == rrdma::ErrorCode::kTimeout);
  assert(!timeout_armed);
  assert(timeout_channel.Count(rrdma::protocol::Opcode::kConfig) >= 1U);
  assert(timeout_channel.Count(rrdma::protocol::Opcode::kStart) == 0U);
  assert(timeout_channel.Count(rrdma::protocol::Opcode::kAbort) == 1U);
  assert(timeout_channel.Count(rrdma::protocol::Opcode::kStatus) == 1U);

  LifecycleChannel reject_channel{LifecycleChannel::Mode::kConfigReject};
  rrdma::detail::ControlClient reject_control{reject_channel, timing, 22U, 1U};
  bool reject_armed{};
  const auto rejected = rrdma::detail::ConfigureAndStartSession(
    reject_control, config, timing, {}, reject_armed);
  assert(!rejected);
  assert(rejected.GetError().code == rrdma::ErrorCode::kRemoteRejected);
  assert(rejected.GetError().remote_result == static_cast<std::uint16_t>(rrdma::protocol::Result::kInvalidConfig));
  assert(!reject_armed);
  assert(reject_channel.Count(rrdma::protocol::Opcode::kConfig) == 1U);
  assert(reject_channel.Count(rrdma::protocol::Opcode::kStart) == 0U);
  assert(reject_channel.Count(rrdma::protocol::Opcode::kAbort) == 0U);

  LifecycleChannel start_reject_channel{LifecycleChannel::Mode::kStartReject};
  rrdma::detail::ControlClient start_reject_control{start_reject_channel,
                                                    timing, 23U, 1U};
  bool start_reject_armed{};
  const auto start_rejected = rrdma::detail::ConfigureAndStartSession(
    start_reject_control, config, timing, {}, start_reject_armed);
  assert(!start_rejected);
  assert(start_rejected.GetError().code == rrdma::ErrorCode::kRemoteRejected);
  assert(!start_reject_armed);
  assert(start_reject_channel.Count(rrdma::protocol::Opcode::kConfig) == 1U);
  assert(start_reject_channel.Count(rrdma::protocol::Opcode::kStart) == 1U);
  assert(start_reject_channel.Count(rrdma::protocol::Opcode::kAbort) == 1U);
  assert(start_reject_channel.Count(rrdma::protocol::Opcode::kStatus) == 1U);
}

// 拒绝底层通道报告的超大 datagram，防止解析截断响应。
void TestControlRejectsOversizedDatagram() {
  OversizedDatagramChannel channel;
  const auto timing = FastTiming();
  rrdma::detail::ControlClient client{channel, timing, 1U, 1U};
  const auto reply = client.Request(rrdma::protocol::Opcode::kStatus, {},
                                    std::chrono::milliseconds{2});
  assert(!reply);
  assert(reply.GetError().code == rrdma::ErrorCode::kTransportError);
}

// 验证消费者等待返还 credit 时能中断低优先级控制请求。
void TestLowPriorityControlCanBeInterrupted() {
  std::atomic<bool> interrupt_requested{};
  InterruptingChannel channel{interrupt_requested};
  const auto timing = FastTiming();
  rrdma::detail::ControlClient client{channel, timing, 1U, 1U};
  const auto reply = client.RequestInterruptible(
    rrdma::protocol::Opcode::kStatus, {}, std::chrono::milliseconds{20},
    interrupt_requested);
  assert(!reply);
  assert(reply.GetError().code == rrdma::ErrorCode::kStopped);
  assert(channel.SendCount() == 1U);
}

// 覆盖 ring 几何、地址范围、Immediate RQ 深度和外部内存约束。
void TestConfigurationValidation() {
  auto config = ValidConfig();
  assert(rrdma::detail::ValidateConfig(config));

  config.session.notify_interval_bytes = 123U;
  assert(!rrdma::detail::ValidateConfig(config));
  config = ValidConfig();
  config.network.gid_index = -1;
  assert(!rrdma::detail::ValidateConfig(config));
  config = ValidConfig();
  config.network.required_netmask = "255.0.255.0";
  assert(!rrdma::detail::ValidateConfig(config));
  config = ValidConfig();
  config.session.local_base = rrdma::protocol::kRemoteAddressLimit;
  assert(!rrdma::detail::ValidateConfig(config));
  config = ValidConfig();
  config.session.notification = rrdma::NotificationMode::kWriteWithImm;
  config.session.receive_depth = 17U;
  config.verbs.max_receive_wr = 16;
  assert(!rrdma::detail::ValidateConfig(config));
  config = ValidConfig();
  config.session.notification = rrdma::NotificationMode::kWriteWithImm;
  config.session.receive_depth = 16U;
  config.polling.completion_batch = 17U;
  assert(rrdma::detail::ValidateConfig(config));
  config = ValidConfig();
  config.polling.consumer_queue_depth =
    config.session.ring_bytes / config.session.notify_interval_bytes + 1U;
  assert(!rrdma::detail::ValidateConfig(config));
  config = ValidConfig();
  config.memory.backing_file_descriptor = -2;
  assert(!rrdma::detail::ValidateConfig(config));
  config = ValidConfig();
  config.memory.backing_offset_bytes = 1U;
  assert(!rrdma::detail::ValidateConfig(config));
}

// 默认内存策略必须使用显式 hugetlb，且 ring/offset 与所选大页严格对齐。
void TestHugePageConfigurationValidation() {
  auto config = ValidConfig();
  assert(config.memory.page_mode == rrdma::MemoryPageMode::kHugeTlb);
  assert(config.memory.huge_page_bytes == rrdma::kDefaultHugePageBytes);
  assert(rrdma::detail::ValidateConfig(config));

  config.session.ring_bytes -= rrdma::kPacketBytes;
  assert(!rrdma::detail::ValidateConfig(config));
  config = ValidConfig();
  config.memory.huge_page_bytes = 3U * 1024U * 1024U;
  assert(!rrdma::detail::ValidateConfig(config));
  config = ValidConfig();
  config.memory.backing_file_descriptor = 0;
  config.memory.backing_offset_bytes = rrdma::kPacketBytes;
  assert(!rrdma::detail::ValidateConfig(config));
  config = ValidConfig();
  config.memory.page_mode =
    static_cast<rrdma::MemoryPageMode>(std::numeric_limits<std::uint8_t>::max());
  assert(!rrdma::detail::ValidateConfig(config));

  // 普通页模式必须显式选择，主要供没有 hugetlb 池的测试/开发环境使用。
  config = ValidConfig();
  config.memory.page_mode = rrdma::MemoryPageMode::kRegular;
  config.memory.huge_page_bytes = 0U;
  assert(rrdma::detail::ValidateConfig(config));
}

// 正常路径必须 final+CLOSED+safe，故障路径必须 FAULTED+safe。
void TestReleaseGates() {
  rrdma::protocol::ReleaseGate gate;
  rrdma::protocol::Status closed{};
  closed.result = rrdma::protocol::Result::kOk;
  closed.state = rrdma::protocol::State::kClosed;
  closed.status_bits = rrdma::protocol::kStatusSafeToRelease;
  gate.ObserveStatus(closed);
  assert(!gate.NormalReleaseReady());
  gate.ObserveFinalCommit();
  assert(gate.NormalReleaseReady());
  assert(!gate.FaultReleaseReady());

  rrdma::protocol::Status faulted{};
  faulted.result = rrdma::protocol::Result::kOk;
  faulted.state = rrdma::protocol::State::kFaulted;
  assert(!gate.FaultReleaseReady());
  faulted.status_bits = rrdma::protocol::kStatusSafeToRelease;
  gate.ObserveStatus(faulted);
  assert(gate.FaultReleaseReady());
}

// 模拟 commit 撕裂、magic 错误、重复 sequence、回退和合法跨越。
void TestCommitSeqlockAndProgressClassification() {
  alignas(rrdma::kCommitBytes) rrdma::detail::CommitRecord record{};
  auto *bytes = reinterpret_cast<std::byte *>(&record);
  WriteLe64(bytes, 3U * rrdma::kPacketBytes);
  WriteLe32(bytes + 8U, 3U * rrdma::kPacketBytes);
  WriteLe32(bytes + 12U, 2U * rrdma::kPacketBytes);
  WriteLe32(bytes + 20U, 0x52444d41U);
  WriteLe64(bytes + 40U, 5U);
  assert(rrdma::detail::ReadCommitSequence(&record) == 5U);
  rrdma::CommitMetadata metadata{};
  assert(rrdma::detail::ReadCommit(&record, metadata));
  assert(metadata.sequence == 5U);
  assert(metadata.published_bytes == 3U * rrdma::kPacketBytes);
  WriteLe64(bytes + 40U, 0U);
  assert(!rrdma::detail::ReadCommit(&record, metadata));
  WriteLe64(bytes + 40U, 5U);
  WriteLe32(bytes + 20U, 0U);
  assert(!rrdma::detail::ReadCommit(&record, metadata));

  rrdma::CommitMetadata previous{};
  previous.sequence = 5U;
  previous.published_bytes = 2U * rrdma::kPacketBytes;
  previous.interval_bytes = rrdma::kPacketBytes;
  auto current = previous;
  current.published_bytes = 3U * rrdma::kPacketBytes;
  assert(rrdma::detail::ClassifyCommit(previous, current,
                                       2U * rrdma::kPacketBytes)
         == rrdma::detail::CommitDisposition::kUnchanged);
  current.sequence = 4U;
  assert(rrdma::detail::ClassifyCommit(previous, current,
                                       2U * rrdma::kPacketBytes)
         == rrdma::detail::CommitDisposition::kInvalid);
  current.sequence = 8U;
  current.published_bytes = 5U * rrdma::kPacketBytes;
  assert(rrdma::detail::ClassifyCommit(previous, current,
                                       2U * rrdma::kPacketBytes)
         == rrdma::detail::CommitDisposition::kReady);
  // STOP 可能覆盖刚发布的普通 commit；final interval 为 0，但绝对游标中
  // 仍包含 producer 尚未观察和交付的数据。
  current.sequence = 9U;
  current.published_bytes = 6U * rrdma::kPacketBytes;
  current.interval_bytes = 0U;
  current.final = true;
  assert(rrdma::detail::ClassifyCommit(previous, current,
                                       2U * rrdma::kPacketBytes)
         == rrdma::detail::CommitDisposition::kReady);
  current.sequence = 6U;
  current.published_bytes = previous.published_bytes;
  current.interval_bytes = 0U;
  current.final = true;
  assert(rrdma::detail::ClassifyCommit(previous, current,
                                       2U * rrdma::kPacketBytes)
         == rrdma::detail::CommitDisposition::kReady);
  current.final = false;
  assert(rrdma::detail::ClassifyCommit(previous, current,
                                       2U * rrdma::kPacketBytes)
         == rrdma::detail::CommitDisposition::kInvalid);
}

// 覆盖线性区间、ring 环绕、零长度 final 和未释放数据覆盖。
void TestRingBatchBoundariesAndOverrun() {
  constexpr rrdma::ByteCount kRingBytes = rrdma::kPacketBytes * 4U;
  std::vector<std::byte> mirrored_ring(kRingBytes * 2U);
  rrdma::CommitMetadata linear{};
  linear.sequence = 1U;
  linear.published_bytes = rrdma::kPacketBytes * 2U;
  linear.ring_end_offset = rrdma::kPacketBytes * 2U;
  linear.interval_bytes = rrdma::kPacketBytes * 2U;
  const auto linear_batch =
    rrdma::detail::MakeBatch(mirrored_ring, kRingBytes, 0U, 0U, linear);
  assert(linear_batch);
  assert(linear_batch.Value().commit.sequence == linear.sequence);
  assert(linear_batch.Value().data.size() == rrdma::kPacketBytes * 2U);
  assert(linear_batch.Value().data.data() == mirrored_ring.data());

  rrdma::CommitMetadata wrapped{};
  wrapped.sequence = 2U;
  wrapped.published_bytes = rrdma::kPacketBytes * 6U;
  wrapped.ring_end_offset = rrdma::kPacketBytes * 2U;
  wrapped.interval_bytes = rrdma::kPacketBytes;
  const auto wrapped_batch = rrdma::detail::MakeBatch(
    mirrored_ring, kRingBytes, rrdma::kPacketBytes * 3U,
    rrdma::kPacketBytes * 2U, wrapped);
  assert(wrapped_batch);
  assert(wrapped_batch.Value().data.size() == rrdma::kPacketBytes * 3U);
  assert(wrapped_batch.Value().data.data() == mirrored_ring.data() + rrdma::kPacketBytes * 3U);

  rrdma::CommitMetadata final = wrapped;
  final.sequence = 3U;
  final.interval_bytes = 0U;
  final.final = true;
  const auto empty_final =
    rrdma::detail::MakeBatch(mirrored_ring, kRingBytes, final.published_bytes,
                             rrdma::kPacketBytes * 3U, final);
  assert(empty_final);
  assert(empty_final.Value().data.empty());

  // 漏读前一个普通 commit 后，零 interval final 必须把累计未读区间作为
  // 单一 span 交付，CommitMetadata 仍保留 final/sequence 等完整信息。
  final.sequence = 4U;
  final.published_bytes += rrdma::kPacketBytes;
  final.ring_end_offset = final.published_bytes % kRingBytes;
  const auto accumulated_final = rrdma::detail::MakeBatch(
    mirrored_ring, kRingBytes, wrapped.published_bytes,
    rrdma::kPacketBytes * 3U, final);
  assert(accumulated_final);
  assert(accumulated_final.Value().commit.sequence == final.sequence);
  assert(accumulated_final.Value().commit.final);
  assert(accumulated_final.Value().data.size() == rrdma::kPacketBytes);

  const auto overrun =
    rrdma::detail::MakeBatch(mirrored_ring, kRingBytes, 0U, 0U, wrapped);
  assert(!overrun);
  assert(overrun.GetError().code == rrdma::ErrorCode::kSessionFault);
  assert(overrun.GetError().overrun_count == 1U);

  const auto queued_data_overwritten = rrdma::detail::MakeBatch(
    mirrored_ring, kRingBytes, rrdma::kPacketBytes * 3U, rrdma::kPacketBytes,
    wrapped);
  assert(!queued_data_overwritten);
  assert(queued_data_overwritten.GetError().code == rrdma::ErrorCode::kSessionFault);
  final.ring_end_offset = 1U;
  assert(!rrdma::detail::MakeBatch(mirrored_ring, kRingBytes,
                                   final.published_bytes,
                                   rrdma::kPacketBytes * 3U, final));
  assert(!rrdma::detail::MakeBatch(
    std::span<const std::byte>{mirrored_ring}.first(kRingBytes), kRingBytes,
    0U, 0U, linear));
}

// 验证共享后备文件、双映射别名和 commit slot 单独清零行为。
void TestMirroredMemoryMapping() {
  constexpr rrdma::ByteCount kRingBytes = rrdma::kPacketBytes * 4U;
  constexpr rrdma::ByteCount kTotalBytes = kRingBytes + rrdma::kCommitBytes;
  const int backing_file = static_cast<int>(
    ::syscall(SYS_memfd_create, "rrdma-test-ring", MFD_CLOEXEC));
  assert(backing_file >= 0);
  assert(::ftruncate(backing_file, static_cast<off_t>(kTotalBytes - 1U)) == 0);
  rrdma::MemoryConfig config{};
  config.page_mode = rrdma::MemoryPageMode::kRegular;
  config.backing_file_descriptor = backing_file;
  assert(!rrdma::detail::RingStorage::Create(config, kRingBytes));
  assert(::ftruncate(backing_file, static_cast<off_t>(kTotalBytes)) == 0);

  void *seed = ::mmap(nullptr, kTotalBytes, PROT_READ | PROT_WRITE, MAP_SHARED,
                      backing_file, 0);
  assert(seed != MAP_FAILED);
  std::memset(seed, 0xa5, kTotalBytes);
  assert(::munmap(seed, kTotalBytes) == 0);

  auto storage = rrdma::detail::RingStorage::Create(config, kRingBytes);
  assert(storage);
  assert(storage.Value()->Storage().size() == kTotalBytes);
  assert(storage.Value()->MirroredRing().size() == kRingBytes * 2U);
  auto ring = storage.Value()->Ring();
  const auto mirrored = storage.Value()->MirroredRing();
  assert(ring[0] == static_cast<std::byte>(0xa5));
  for (rrdma::ByteCount index{}; index < rrdma::kCommitBytes; ++index) {
    assert(storage.Value()->Storage()[kRingBytes + index] == std::byte{});
  }

  ring[0] = static_cast<std::byte>(0x11U);
  ring[kRingBytes - 1U] = static_cast<std::byte>(0x22U);
  assert(mirrored[0] == static_cast<std::byte>(0x11U));
  assert(mirrored[kRingBytes] == static_cast<std::byte>(0x11U));
  assert(mirrored[kRingBytes - 1U] == static_cast<std::byte>(0x22U));
  assert(mirrored[kRingBytes * 2U - 1U] == static_cast<std::byte>(0x22U));
  storage.Value().reset();
  assert(::close(backing_file) == 0);

  // 库内普通页路径同样必须创建 memfd 和双映射，不依赖外部后备文件。
  rrdma::MemoryConfig default_config{};
  default_config.page_mode = rrdma::MemoryPageMode::kRegular;
  auto default_storage =
    rrdma::detail::RingStorage::Create(default_config, kRingBytes);
  assert(default_storage);
  default_storage.Value()->Ring()[0] = static_cast<std::byte>(0x33U);
  assert(default_storage.Value()->MirroredRing()[kRingBytes] == static_cast<std::byte>(0x33U));

  // 镜像窗口必须在 START 前完成 populate，避免 callback 首轮扫描逐页缺页。
  const auto mirrored_default = default_storage.Value()->MirroredRing();
  const long page_size = ::sysconf(_SC_PAGESIZE);
  assert(page_size > 0);
  const auto page_bytes = static_cast<rrdma::ByteCount>(page_size);
  const auto residency_bytes =
    (mirrored_default.size() + page_bytes - 1U) / page_bytes;
  std::vector<unsigned char> residency(residency_bytes);
  assert(::mincore(const_cast<std::byte *>(mirrored_default.data()),
                   mirrored_default.size(), residency.data())
         == 0);
  assert(std::all_of(residency.begin(), residency.end(),
                     [](unsigned char page) { return (page & 1U) != 0U; }));
}

// hugetlb 模式必须拒绝普通 memfd，避免配置看似启用大页却静默退化。
void TestHugeTlbRejectsRegularBackingFile() {
  constexpr rrdma::ByteCount kRingBytes = rrdma::kDefaultHugePageBytes;
  constexpr rrdma::ByteCount kBackingBytes = 2U * rrdma::kDefaultHugePageBytes;
  const int backing_file = static_cast<int>(
    ::syscall(SYS_memfd_create, "rrdma-regular-backing", MFD_CLOEXEC));
  assert(backing_file >= 0);
  assert(::ftruncate(backing_file, static_cast<off_t>(kBackingBytes)) == 0);

  rrdma::MemoryConfig config{};
  config.backing_file_descriptor = backing_file;
  const auto storage = rrdma::detail::RingStorage::Create(config, kRingBytes);
  assert(!storage);
  assert(storage.GetError().code == rrdma::ErrorCode::kInvalidConfiguration);
  assert(::close(backing_file) == 0);
}

// 验证库内 hugetlb memfd 的主映射和两个别名确实共享同一组大页。
void TestHugeTlbMirroredMemoryMapping() {
  constexpr rrdma::ByteCount kRingBytes = rrdma::kDefaultHugePageBytes;
  rrdma::MemoryConfig config{};
  auto storage = rrdma::detail::RingStorage::Create(config, kRingBytes);
  assert(storage);
  assert(storage.Value()->Storage().size() == kRingBytes + rrdma::kCommitBytes);
  assert(storage.Value()->MirroredRing().size() == 2U * kRingBytes);

  auto ring = storage.Value()->Ring();
  const auto mirrored = storage.Value()->MirroredRing();
  ring.front() = static_cast<std::byte>(0x31U);
  ring.back() = static_cast<std::byte>(0x42U);
  assert(mirrored.front() == static_cast<std::byte>(0x31U));
  assert(mirrored[kRingBytes] == static_cast<std::byte>(0x31U));
  assert(mirrored[kRingBytes - 1U] == static_cast<std::byte>(0x42U));
  assert(mirrored.back() == static_cast<std::byte>(0x42U));
}

// 写入测试用 RFSO magic 与绝对 packet sequence。
void WriteRfsoHeader(std::byte *packet, std::uint32_t sequence) noexcept {
  rrdma::RfsoHeaderWire header{};
  header.magic = 0x5246534fU;
  header.sequence = sequence;
  header.version = 1U;
  header.header_length = 24U;
  header.payload_length = rrdma::kPacketBytes - sizeof(header);
  std::memcpy(packet, &header, sizeof header);
}

// 校验 RFSO 统计、环绕扫描、最终复扫和非法头处理。
void TestRfsoStatisticsAndVerification() {
  constexpr rrdma::ByteCount kPacketBytes = rrdma::kPacketBytes;
  std::vector<std::byte> invalid_ring(kPacketBytes * 4U);
  for (std::uint32_t index{}; index < 4U; ++index) {
    WriteRfsoHeader(invalid_ring.data() + kPacketBytes * index, index);
  }
  auto invalid_header = rrdma::RfsoHeaderWire{};
  std::memcpy(&invalid_header, invalid_ring.data() + kPacketBytes,
              sizeof invalid_header);
  invalid_header.magic = 0U;
  std::memcpy(invalid_ring.data() + kPacketBytes, &invalid_header,
              sizeof invalid_header);
  WriteRfsoHeader(invalid_ring.data() + kPacketBytes * 2U, 99U);
  rrdma::CommitBatch invalid_batch{};
  invalid_batch.commit.sequence = 7U;
  invalid_batch.commit.published_bytes = kPacketBytes * 4U;
  invalid_batch.data = invalid_ring;
  rrdma::RfsoConsumer invalid_consumer;
  assert(invalid_consumer.OnCommit(invalid_batch) == rrdma::BatchAction::kAbort);
  assert(invalid_consumer.Stats().packets == 4U);
  assert(invalid_consumer.Stats().bytes == kPacketBytes * 4U);
  assert(invalid_consumer.Stats().invalid_headers == 1U);
  assert(invalid_consumer.Stats().discontinuities == 1U);
  assert(invalid_consumer.Stats().commits == 7U);
  assert(invalid_consumer.Stats().published_bytes == kPacketBytes * 4U);

  std::vector<std::byte> ring(kPacketBytes * 4U);
  WriteRfsoHeader(ring.data() + kPacketBytes * 2U, 2U);
  WriteRfsoHeader(ring.data() + kPacketBytes * 3U, 3U);
  WriteRfsoHeader(ring.data(), 4U);
  WriteRfsoHeader(ring.data() + kPacketBytes, 5U);
  std::vector<std::byte> mirrored_ring(kPacketBytes * 8U);
  std::copy(ring.begin(), ring.end(), mirrored_ring.begin());
  std::copy(ring.begin(), ring.end(), mirrored_ring.begin() + ring.size());
  std::vector<std::byte> contiguous(kPacketBytes * 3U);
  WriteRfsoHeader(contiguous.data(), 0U);
  WriteRfsoHeader(contiguous.data() + kPacketBytes, 1U);
  WriteRfsoHeader(contiguous.data() + kPacketBytes * 2U, 2U);
  rrdma::CommitBatch batch{};
  batch.commit.sequence = 11U;
  batch.commit.published_bytes = kPacketBytes * 3U;
  batch.data = contiguous;
  rrdma::RfsoConsumer consumer;
  assert(consumer.OnCommit(batch) == rrdma::BatchAction::kContinueReceiving);
  assert(consumer.Stats().packets == 3U);
  assert(consumer.Stats().commits == 11U);

  rrdma::SessionReport report{};
  report.ring = mirrored_ring;
  report.ring_bytes = ring.size();
  report.final_commit.sequence = 11U;
  report.final_commit.published_bytes = kPacketBytes * 6U;
  report.final_commit.ring_end_offset = kPacketBytes * 2U;
  report.final_commit.final = true;
  assert(consumer.Verify(report));

  // FPGA RFSO sequence is a wrapping 32-bit packet counter; host absolute
  // byte positions must preserve the wrap at UINT32_MAX -> 0.
  constexpr rrdma::ByteCount kRingWrapBytes = kPacketBytes * 2U;
  constexpr rrdma::ByteCount kWrapPublishedPackets =
    static_cast<rrdma::ByteCount>(std::numeric_limits<std::uint32_t>::max())
    + 2U;
  std::vector<std::byte> wrap_mirrored(kRingWrapBytes * 2U);
  WriteRfsoHeader(
    wrap_mirrored.data() + kPacketBytes,
    std::numeric_limits<std::uint32_t>::max());
  WriteRfsoHeader(wrap_mirrored.data() + kRingWrapBytes, 0U);
  rrdma::SessionReport wrap_report{};
  wrap_report.ring = wrap_mirrored;
  wrap_report.ring_bytes = kRingWrapBytes;
  wrap_report.final_commit.final = true;
  wrap_report.final_commit.published_bytes =
    kWrapPublishedPackets * kPacketBytes;
  wrap_report.final_commit.ring_end_offset = kPacketBytes;
  rrdma::RfsoConsumer wrap_consumer;
  assert(wrap_consumer.Verify(wrap_report));

  rrdma::SessionReport empty_report{};
  empty_report.ring = mirrored_ring;
  empty_report.ring_bytes = ring.size();
  empty_report.final_commit.final = true;
  assert(!consumer.Verify(empty_report));

  auto malformed = batch;
  malformed.data =
    std::span<const std::byte>{contiguous}.first(contiguous.size() - 1U);
  assert(consumer.OnCommit(malformed) == rrdma::BatchAction::kAbort);
  assert(consumer.Stats().overruns == 1U);
}

// 验证有界 descriptor 队列顺序、满队列背压和关闭后排空。
void TestBatchQueueOrderAndDrain() {
  rrdma::detail::BatchQueue queue{2U};
  rrdma::CommitBatch first{};
  first.commit.published_bytes = 1U;
  rrdma::CommitBatch second{};
  second.commit.published_bytes = 2U;
  rrdma::CommitBatch third{};
  third.commit.published_bytes = 3U;
  assert(queue.TryPush(first));
  assert(queue.TryPush(second));
  assert(!queue.TryPush(third));

  rrdma::CommitBatch *batch{};
  assert(queue.WaitForFront(batch));
  assert(batch->commit.published_bytes == 1U);
  queue.ReleaseFront();
  assert(queue.TryPush(third));
  queue.Close();
  assert(queue.WaitForFront(batch));
  assert(batch->commit.published_bytes == 2U);
  queue.ReleaseFront();
  assert(queue.WaitForFront(batch));
  assert(batch->commit.published_bytes == 3U);
  queue.ReleaseFront();
  assert(!queue.WaitForFront(batch));
  assert(queue.Closed());
  assert(queue.Published() == 3U);
  assert(queue.Reclaimed() == 3U);
  assert(!queue.TryPush(first));
  queue.Close();
}

// 验证 Close/发布都能正确唤醒阻塞消费者。
void TestBatchQueueWakeups() {
  using namespace std::chrono_literals;

  rrdma::detail::BatchQueue queue{1U};
  std::promise<void> pop_started;
  auto started = pop_started.get_future();
  auto popped = std::async(std::launch::async, [&] {
    pop_started.set_value();
    rrdma::CommitBatch *batch{};
    return queue.WaitForFront(batch) ? batch->commit.published_bytes : 0U;
  });
  started.wait();
  rrdma::CommitBatch batch{};
  batch.commit.published_bytes = 42U;
  assert(queue.TryPush(batch));
  assert(popped.wait_for(5s) == std::future_status::ready);
  assert(popped.get() == 42U);

  rrdma::detail::BatchQueue closing_queue{1U};
  std::promise<void> close_pop_started;
  auto close_started = close_pop_started.get_future();
  auto closed = std::async(std::launch::async, [&] {
    close_pop_started.set_value();
    rrdma::CommitBatch *unused{};
    return closing_queue.WaitForFront(unused);
  });
  close_started.wait();
  closing_queue.Close();
  assert(closed.wait_for(5s) == std::future_status::ready);
  assert(!closed.get());
}

// 并发推进大量 descriptor，验证 SPSC 无锁游标不会乱序或覆盖未回收槽位。
void TestBatchQueueConcurrentSpsc() {
  constexpr rrdma::HostCount kBatchCount{100'000U};
  rrdma::detail::BatchQueue queue{64U};
  std::thread producer([&] {
    for (rrdma::HostCount index{}; index < kBatchCount; ++index) {
      rrdma::CommitBatch batch{};
      batch.commit.published_bytes = index + 1U;
      while (!queue.TryPush(batch)) {
        std::this_thread::yield();
      }
    }
    queue.Close();
  });

  for (rrdma::HostCount index{}; index < kBatchCount; ++index) {
    rrdma::CommitBatch *batch{};
    assert(queue.WaitForFront(batch));
    assert(batch->commit.published_bytes == index + 1U);
    queue.ReleaseFront();
  }
  rrdma::CommitBatch *unused{};
  assert(!queue.WaitForFront(unused));
  producer.join();
  assert(queue.Published() == kBatchCount);
  assert(queue.Reclaimed() == kBatchCount);
}

// 验证 Immediate completion 批量重建 receive WR 链及容量保护。
void TestImmediateReceiveChain() {
  std::array<ibv_recv_wr, 3> work_requests{};
  std::array<ibv_sge, 3> scatter_gather_entries{};
  std::array<ibv_wc, 3> completions{};
  completions[0].wr_id = 10U;
  completions[1].wr_id = 20U;
  completions[2].wr_id = 30U;
  constexpr std::uintptr_t kAddress{0x12345000U};
  constexpr std::uint32_t kLength{64U};
  constexpr std::uint32_t kLocalKey{0xabcdef01U};
  assert(rrdma::detail::BuildReceiveChain(work_requests, scatter_gather_entries,
                                          completions, kAddress, kLength,
                                          kLocalKey));
  for (rrdma::HostCount index{}; index < completions.size(); ++index) {
    assert(work_requests[index].wr_id == completions[index].wr_id);
    assert(work_requests[index].sg_list == &scatter_gather_entries[index]);
    assert(work_requests[index].num_sge == 1);
    assert(scatter_gather_entries[index].addr == kAddress);
    assert(scatter_gather_entries[index].length == kLength);
    assert(scatter_gather_entries[index].lkey == kLocalKey);
  }
  assert(work_requests[0].next == &work_requests[1]);
  assert(work_requests[1].next == &work_requests[2]);
  assert(work_requests[2].next == nullptr);
  assert(!rrdma::detail::BuildReceiveChain(
    std::span<ibv_recv_wr>{work_requests}.first(2U), scatter_gather_entries,
    completions, kAddress, kLength, kLocalKey));

  struct PostObservation {
    rrdma::HostCount calls{};
    ibv_qp *queue_pair{};
    ibv_recv_wr *first_work_request{};
    int result{};
  };
  auto post_receive = [](void *context, ibv_qp *queue_pair,
                         ibv_recv_wr *first_work_request,
                         ibv_recv_wr **bad_work_request) noexcept {
    auto &observation = *static_cast<PostObservation *>(context);
    ++observation.calls;
    observation.queue_pair = queue_pair;
    observation.first_work_request = first_work_request;
    if (bad_work_request != nullptr) {
      *bad_work_request =
        observation.result == 0 ? nullptr : first_work_request;
    }
    return observation.result;
  };
  ibv_qp queue_pair{};
  PostObservation observation{};
  assert(rrdma::detail::PostReceiveBatch(&queue_pair, work_requests,
                                         &observation, post_receive));
  assert(observation.calls == 1U);
  assert(observation.queue_pair == &queue_pair);
  assert(observation.first_work_request == work_requests.data());

  observation.result = 7;
  const auto post_failure = rrdma::detail::PostReceiveBatch(
    &queue_pair, work_requests, &observation, post_receive);
  assert(!post_failure);
  assert(post_failure.GetError().code == rrdma::ErrorCode::kVerbsError);
  assert(post_failure.GetError().verbs_status == 7);
  const auto calls_before_empty = observation.calls;
  assert(rrdma::detail::PostReceiveBatch(&queue_pair, std::span<ibv_recv_wr>{},
                                         &observation, post_receive));
  assert(observation.calls == calls_before_empty);
}

// 验证成员方法和 callable 两类零分配 callback 适配器。
void TestCallbackBindings() {
  rrdma::CommitBatch batch{};
  auto callback = [](const rrdma::CommitBatch &) noexcept {
    return rrdma::BatchAction::kStopAfterConsume;
  };
  const auto callback_ref = rrdma::CommitCallback::Bind(callback);
  assert(callback_ref.Invoke(batch) == rrdma::BatchAction::kStopAfterConsume);

  bool event_seen{};
  auto event_callback = [&event_seen](const rrdma::Event &) noexcept {
    event_seen = true;
  };
  const auto event_ref = rrdma::EventSink::Bind(event_callback);
  event_ref.Emit({rrdma::Event::Level::kInfo, "test"});
  assert(event_seen);

  bool producer_seen{};
  bool consumer_seen{};
  auto thread_start = [&](rrdma::ThreadRole role) noexcept {
    producer_seen = producer_seen || role == rrdma::ThreadRole::kProducer;
    consumer_seen = consumer_seen || role == rrdma::ThreadRole::kConsumer;
  };
  const auto thread_hook = rrdma::ThreadStartHook::Bind(thread_start);
  thread_hook.Invoke(rrdma::ThreadRole::kProducer);
  thread_hook.Invoke(rrdma::ThreadRole::kConsumer);
  assert(producer_seen && consumer_seen);
}

} // namespace

int main() {
  // 保持测试显式顺序，任何 assert 失败都会立即终止并由 CTest 报告。
  TestProtocolGoldenRequests();
  TestProtocolGoldenStatusAndMalformedPackets();
  TestControlRetryReusesTransactionBytes();
  TestConsumeProgressRetryTransactions();
  TestConsumerBatchTransactionOrder();
  TestControlTransactionExhaustionAndConfigOutcomes();
  TestConfigureAndStartLifecycle();
  TestControlRejectsOversizedDatagram();
  TestLowPriorityControlCanBeInterrupted();
  TestConfigurationValidation();
  TestHugePageConfigurationValidation();
  TestReleaseGates();
  TestCommitSeqlockAndProgressClassification();
  TestRingBatchBoundariesAndOverrun();
  TestMirroredMemoryMapping();
  TestHugeTlbRejectsRegularBackingFile();
  TestHugeTlbMirroredMemoryMapping();
  TestRfsoStatisticsAndVerification();
  TestBatchQueueOrderAndDrain();
  TestBatchQueueWakeups();
  TestBatchQueueConcurrentSpsc();
  TestImmediateReceiveChain();
  TestCallbackBindings();
  return 0;
}
