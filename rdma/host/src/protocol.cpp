#include "rrdma/protocol.hpp"

#include <algorithm>
#include <cstring>

namespace rrdma::protocol {

// 从 RDCP 大端字段读取 16 位整数。
std::uint16_t ReadBe16(const std::byte *bytes) noexcept {
  return static_cast<std::uint16_t>(
    (static_cast<std::uint16_t>(std::to_integer<unsigned char>(bytes[0]))
     << 8U)
    | std::to_integer<unsigned char>(bytes[1]));
}

// 从 RDCP 大端字段读取 32 位整数。
std::uint32_t ReadBe32(const std::byte *bytes) noexcept {
  return (static_cast<std::uint32_t>(std::to_integer<unsigned char>(bytes[0]))
          << 24U)
         | (static_cast<std::uint32_t>(std::to_integer<unsigned char>(bytes[1]))
            << 16U)
         | (static_cast<std::uint32_t>(std::to_integer<unsigned char>(bytes[2]))
            << 8U)
         | std::to_integer<unsigned char>(bytes[3]);
}

// 组合两个大端 32 位字段读取 64 位整数。
std::uint64_t ReadBe64(const std::byte *bytes) noexcept {
  return (static_cast<std::uint64_t>(ReadBe32(bytes)) << 32U) | ReadBe32(bytes + 4U);
}

// 将 16 位整数按网络字节序写入固定报文。
void WriteBe16(std::byte *bytes, std::uint16_t value) noexcept {
  bytes[0] = static_cast<std::byte>(value >> 8U);
  bytes[1] = static_cast<std::byte>(value);
}

// 将 32 位整数按网络字节序写入固定报文。
void WriteBe32(std::byte *bytes, std::uint32_t value) noexcept {
  bytes[0] = static_cast<std::byte>(value >> 24U);
  bytes[1] = static_cast<std::byte>(value >> 16U);
  bytes[2] = static_cast<std::byte>(value >> 8U);
  bytes[3] = static_cast<std::byte>(value);
}

// 将 64 位整数拆分为两个连续的大端 32 位字段。
void WriteBe64(std::byte *bytes, std::uint64_t value) noexcept {
  WriteBe32(bytes, static_cast<std::uint32_t>(value >> 32U));
  WriteBe32(bytes + 4U, static_cast<std::uint32_t>(value));
}

// RDCP 响应 opcode 等于请求 opcode 加响应标志位。
std::uint8_t ResponseOpcode(Opcode opcode) noexcept {
  return static_cast<std::uint8_t>(opcode) | 0x80U;
}

WirePacket MakeRequest(Opcode opcode, std::uint64_t session_id,
                       std::uint32_t transaction_id,
                       std::span<const std::byte> payload) noexcept {
  // RDCP 报文必须一次写入固定数组，失败时返回 size=0 的空包。
  WirePacket packet{};
  if (payload.size() > packet.storage.size() - kHeaderBytes) {
    return packet;
  }
  const auto payload_size = payload.size();
  WriteBe32(packet.storage.data(), kMagic);
  packet.storage[4] = static_cast<std::byte>(kVersion);
  packet.storage[5] = static_cast<std::byte>(opcode);
  WriteBe16(packet.storage.data() + 6U,
            static_cast<std::uint16_t>(payload_size));
  WriteBe64(packet.storage.data() + 8U, session_id);
  WriteBe32(packet.storage.data() + 16U, transaction_id);
  if (payload_size != 0U) {
    std::memcpy(packet.storage.data() + kHeaderBytes, payload.data(),
                payload_size);
  }
  packet.size = kHeaderBytes + payload_size;
  return packet;
}

WirePacket MakeConfigRequest(std::uint64_t session_id,
                             std::uint32_t transaction_id,
                             const Config &config) noexcept {
  // CONFIG payload 按 FPGA 规定的 56 字节顺序逐字段编码，保留字节置零。
  WirePacket packet = MakeRequest(Opcode::kConfig, session_id, transaction_id);
  auto *payload = packet.storage.data() + kHeaderBytes;
  WriteBe32(payload, config.remote_qpn);
  WriteBe32(payload + 4U, config.local_psn);
  WriteBe64(payload + 8U, config.remote_base);
  WriteBe32(payload + 16U, config.rkey);
  WriteBe32(payload + 20U, config.ring_size);
  WriteBe32(payload + 24U, config.wr_size);
  WriteBe32(payload + 28U, config.notify_interval);
  WriteBe64(payload + 32U, config.local_base);
  WriteBe64(payload + 40U, config.commit_address);
  WriteBe32(payload + 48U, config.flags);
  WriteBe32(payload + 52U, 0U);
  packet.size = kHeaderBytes + kConfigBytes;
  WriteBe16(packet.storage.data() + 6U, kConfigBytes);
  return packet;
}

WirePacket MakeConsumeRequest(std::uint64_t session_id,
                              std::uint32_t transaction_id,
                              std::uint64_t consumed_bytes) noexcept {
  // CONSUME 只携带累计消费游标，不发送环形区间或指针。
  WirePacket packet = MakeRequest(Opcode::kConsume, session_id, transaction_id);
  WriteBe64(packet.storage.data() + kHeaderBytes, consumed_bytes);
  packet.size = kHeaderBytes + kConsumeBytes;
  WriteBe16(packet.storage.data() + 6U, kConsumeBytes);
  return packet;
}

bool DecodeStatus(std::span<const std::byte> bytes, Opcode opcode,
                  std::uint64_t session_id, std::uint32_t transaction_id,
                  Status &status) noexcept {
  // 先完整校验 magic、版本、事务和保留字节，再写入状态字段，避免
  // 将畸形或过期响应暴露给会话状态机。
  if (bytes.size() != kHeaderBytes + kStatusBytes
      || ReadBe32(bytes.data()) != kMagic
      || std::to_integer<unsigned char>(bytes[4]) != kVersion
      || std::to_integer<unsigned char>(bytes[5]) != ResponseOpcode(opcode)
      || ReadBe16(bytes.data() + 6U) != kStatusBytes
      || ReadBe64(bytes.data() + 8U) != session_id
      || ReadBe32(bytes.data() + 16U) != transaction_id
      || std::to_integer<unsigned char>(bytes[23]) != 0U) {
    return false;
  }
  const auto result = ReadBe16(bytes.data() + 20U);
  const auto state = std::to_integer<unsigned char>(bytes[22]);
  if (result > static_cast<std::uint16_t>(Result::kInternalFault)
      || state > static_cast<std::uint8_t>(State::kFaulted)) {
    return false;
  }
  status.result = static_cast<Result>(result);
  status.state = static_cast<State>(state);
  status.reason = ReadBe32(bytes.data() + 24U);
  status.status_bits = ReadBe32(bytes.data() + 28U);
  status.local_qpn = ReadBe32(bytes.data() + 32U);
  status.current_psn = ReadBe32(bytes.data() + 36U);
  status.config_generation = ReadBe32(bytes.data() + 40U);
  status.issued_bytes = ReadBe64(bytes.data() + 44U);
  status.acked_bytes = ReadBe64(bytes.data() + 52U);
  status.published_bytes = ReadBe64(bytes.data() + 60U);
  status.consumed_bytes = ReadBe64(bytes.data() + 68U);
  status.capabilities = ReadBe32(bytes.data() + 76U);
  status.pmtu_bytes = ReadBe32(bytes.data() + 80U);
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

// 事务对象保存完整请求，保证底层重试不重新生成 transaction。
Transaction::Transaction(Opcode opcode, std::uint64_t session_id,
                         std::uint32_t transaction_id,
                         std::span<const std::byte> payload) noexcept
 : opcode_(opcode),
   session_id_(session_id),
   transaction_id_(transaction_id),
   request_(MakeRequest(opcode, session_id, transaction_id, payload)) {
}

bool Transaction::Accept(std::span<const std::byte> response,
                         Status &status) const noexcept {
  // 重试复用同一请求字节；响应必须匹配原 opcode/session/transaction。
  return DecodeStatus(response, opcode_, session_id_, transaction_id_, status);
}

} // namespace rrdma::protocol
