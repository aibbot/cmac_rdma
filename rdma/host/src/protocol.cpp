#include "rrdma/protocol.hpp"

#include <cstring>
#include <utility>

namespace rrdma::protocol {
namespace {

void WriteHeader(WirePacket &packet, Opcode opcode, SessionId session_id,
                 TransactionId transaction_id, ByteCount payload_size) noexcept {
  const wire::Header header{
    wire::Be32{kMagic},
    kVersion,
    static_cast<std::uint8_t>(opcode),
    wire::Be16{static_cast<std::uint16_t>(payload_size)},
    wire::Be64{session_id},
    wire::Be32{transaction_id}};
  std::memcpy(packet.storage.data(), &header, sizeof header);
  packet.size = kHeaderBytes + payload_size;
}

} // namespace

// RDCP 响应 opcode 等于请求 opcode 加响应标志位。
std::uint8_t ResponseOpcode(Opcode opcode) noexcept {
  return static_cast<std::uint8_t>(opcode) | 0x80U;
}

WirePacket MakeRequest(Opcode opcode, SessionId session_id,
                       TransactionId transaction_id,
                       std::span<const std::byte> payload) noexcept {
  WirePacket packet{};
  if (payload.size() > packet.storage.size() - kHeaderBytes) {
    return packet;
  }

  WriteHeader(packet, opcode, session_id,
              transaction_id, payload.size());
  if (!payload.empty()) {
    std::memcpy(packet.storage.data() + kHeaderBytes, payload.data(),
                payload.size());
  }
  return packet;
}

WirePacket MakeConfigRequest(SessionId session_id, TransactionId transaction_id,
                             const Config &config) noexcept {
  WirePacket packet{};
  WriteHeader(packet, Opcode::kConfig, session_id, transaction_id,
              kConfigBytes);
  const wire::Config payload{
    wire::Be32{config.remote_qpn},
    wire::Be32{config.local_psn},
    wire::Be64{config.remote_base},
    wire::Be32{config.rkey},
    wire::Be32{config.ring_size},
    wire::Be32{config.wr_size},
    wire::Be32{config.notify_interval},
    wire::Be64{config.local_base},
    wire::Be64{config.commit_address},
    wire::Be32{config.flags},
    wire::Be32{0U}};
  std::memcpy(packet.storage.data() + kHeaderBytes, &payload, sizeof payload);
  return packet;
}

WirePacket MakeConsumeRequest(SessionId session_id, TransactionId transaction_id,
                              ByteCount consumed_bytes) noexcept {
  WirePacket packet{};
  WriteHeader(packet, Opcode::kConsume, session_id, transaction_id,
              kConsumeBytes);
  const wire::Consume payload{wire::Be64{consumed_bytes}};
  std::memcpy(packet.storage.data() + kHeaderBytes, &payload, sizeof payload);
  return packet;
}

bool DecodeStatus(std::span<const std::byte> bytes, Opcode opcode,
                  SessionId session_id, TransactionId transaction_id,
                  Status &status) noexcept {
  if (bytes.size() != kHeaderBytes + kStatusBytes) {
    return false;
  }

  wire::Header header{};
  wire::Status payload{};
  std::memcpy(&header, bytes.data(), sizeof header);
  std::memcpy(&payload, bytes.data() + kHeaderBytes, sizeof payload);

  if (header.magic != kMagic || header.version != kVersion
      || header.opcode != ResponseOpcode(opcode)
      || header.payload_length != kStatusBytes || header.session_id != session_id
      || header.transaction_id != transaction_id || payload.reserved != 0U) {
    return false;
  }

  const auto result = payload.result.value();
  const auto state = payload.state;
  if (result > static_cast<std::uint16_t>(Result::kInternalFault)
      || state > static_cast<std::uint8_t>(State::kFaulted)) {
    return false;
  }

  status.result = static_cast<Result>(result);
  status.state = static_cast<State>(state);
  status.reason = payload.reason;
  status.status_bits = payload.status_bits;
  status.local_qpn = payload.local_qpn;
  status.current_psn = payload.current_psn;
  status.config_generation = payload.config_generation;
  status.issued_bytes = payload.issued_bytes;
  status.acked_bytes = payload.acked_bytes;
  status.published_bytes = payload.published_bytes;
  status.consumed_bytes = payload.consumed_bytes;
  status.capabilities = payload.capabilities;
  status.pmtu_bytes = payload.pmtu_bytes;
  return true;
}

bool ActiveSessionRequiresAbort(const Status &status) noexcept {
  // RUNNING/STOPPING/CLOSED 之外的活动态或 fault 位都要求进入 ABORT。
  const bool lifecycle_state = status.state == State::kRunning
                               || status.state == State::kStopping
                               || status.state == State::kClosed;
  return status.result != Result::kOk
         || !lifecycle_state
         || (status.status_bits & kStatusFault) != 0U;
}

bool ReleaseGate::NormalReleaseReady() const noexcept {
  // 正常释放必须同时看到 final commit 与 FPGA CLOSED/safe_to_release。
  return final_commit_seen_
         && status_.result == Result::kOk
         && status_.state == State::kClosed
         && (status_.status_bits & kStatusSafeToRelease) != 0U;
}

bool ReleaseGate::FaultReleaseReady() const noexcept {
  // 故障路径只接受 FPGA 明确进入 FAULTED 且允许释放资源。
  return status_.result == Result::kOk
         && status_.state == State::kFaulted
         && (status_.status_bits & kStatusSafeToRelease) != 0U;
}

Transaction::Transaction(Opcode opcode, SessionId session_id,
                         TransactionId transaction_id,
                         std::span<const std::byte> payload) noexcept
 : opcode_(opcode),
   session_id_(session_id),
   transaction_id_(transaction_id),
   request_(MakeRequest(opcode, session_id, transaction_id, payload)) {
}

Transaction::Transaction(Opcode opcode, SessionId session_id,
                         TransactionId transaction_id,
                         WirePacket request) noexcept
 : opcode_(opcode),
   session_id_(session_id),
   transaction_id_(transaction_id),
   request_(std::move(request)) {
}

bool Transaction::Accept(std::span<const std::byte> response,
                         Status &status) const noexcept {
  // 重试复用同一请求字节；响应必须匹配原 opcode/session/transaction。
  return DecodeStatus(response, opcode_, session_id_, transaction_id_, status);
}

} // namespace rrdma::protocol
