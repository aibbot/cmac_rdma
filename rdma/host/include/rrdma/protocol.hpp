#ifndef RRDMA_INCLUDE_RRDMA_PROTOCOL_HPP_
#define RRDMA_INCLUDE_RRDMA_PROTOCOL_HPP_

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

#include "rrdma/types.hpp"

// RDCP v2 的公共 wire 层定义。这里的字段顺序和宽度直接对应 FPGA 报文，
// 不要用编译器布局或主机字节序替代显式编解码。
namespace rrdma::protocol {

// 固定协议参数：RDCP 使用大端字段，控制面默认监听 UDP/4792。
inline constexpr std::uint32_t kMagic{0x52444350U};
inline constexpr std::uint8_t kVersion{2U};
inline constexpr std::uint16_t kControlPort{4792U};
inline constexpr std::uint32_t kFpgaQpn{1U};
inline constexpr std::uint32_t kPmtuBytes{4096U};
inline constexpr std::uint64_t kRemoteAddressLimit{1ULL << 48U};
inline constexpr std::uint64_t kLocalBaseAlignment{8U};
inline constexpr ByteCount kHeaderBytes{20U};
inline constexpr ByteCount kConfigBytes{56U};
inline constexpr ByteCount kConsumeBytes{8U};
inline constexpr ByteCount kStatusBytes{64U};
inline constexpr ByteCount kMaxDatagramBytes{128U};

static_assert(kHeaderBytes + kConfigBytes <= kMaxDatagramBytes);
static_assert(kHeaderBytes + kConsumeBytes <= kMaxDatagramBytes);
static_assert(kHeaderBytes + kStatusBytes <= kMaxDatagramBytes);

enum class Opcode : std::uint8_t {
  // 请求 opcode；响应 opcode 由 ResponseOpcode() 设置最高位。
  kHello = 1U,
  kConfig = 2U,
  kStart = 3U,
  kStop = 4U,
  kAbort = 5U,
  kStatus = 6U,
  kConsume = 7U,
};

enum class Result : std::uint16_t {
  // FPGA 对请求的处理结果，数值必须与 RDCP v2 保持一致。
  kOk = 0U,
  kBadVersion = 1U,
  kBadOpcode = 2U,
  kBadLength = 3U,
  kBadSession = 4U,
  kBadSource = 5U,
  kOldTransaction = 6U,
  kBusy = 7U,
  kInvalidConfig = 8U,
  kInvalidState = 9U,
  kInvalidProgress = 10U,
  kInternalFault = 11U,
};

enum class State : std::uint8_t {
  // FPGA session engine 的生命周期状态。
  kIdle = 0U,
  kConfiguring = 1U,
  kReady = 2U,
  kRunning = 3U,
  kStopping = 4U,
  kClosed = 5U,
  kFaultQuiescing = 6U,
  kFaulted = 7U,
};

inline constexpr std::uint32_t kStatusConfigured{1U << 0U};
inline constexpr std::uint32_t kStatusActive{1U << 1U};
inline constexpr std::uint32_t kStatusDrained{1U << 2U};
inline constexpr std::uint32_t kStatusFault{1U << 3U};
inline constexpr std::uint32_t kStatusSafeToRelease{1U << 4U};
inline constexpr std::uint32_t kStatusFinalCommitAcked{1U << 5U};
inline constexpr std::uint32_t kStatusCreditStalled{1U << 6U};

inline constexpr std::uint32_t kCapabilityImmediate{1U << 0U};
inline constexpr std::uint32_t kCapabilityFlowControlledRing{1U << 1U};
inline constexpr std::uint32_t kCapabilityAbortQuiesce{1U << 2U};
inline constexpr std::uint32_t kCapabilitySequenceRecovery{1U << 3U};
inline constexpr std::uint32_t kCapabilitiesV2{
    kCapabilityImmediate | kCapabilityFlowControlledRing |
    kCapabilityAbortQuiesce | kCapabilitySequenceRecovery};

struct Config {
  // CONFIG payload 的固定字段，所有地址均为 FPGA 看到的远端地址。
  // Host RC QP 编号，供 FPGA 设置目标 QP。
  std::uint32_t remote_qpn{};
  // FPGA 发送方向的初始 PSN，Host RTR 时使用同一值。
  std::uint32_t local_psn{};
  // Host 注册 ring 的起始虚拟地址。
  std::uint64_t remote_base{};
  // MR 的 remote-write key。
  std::uint32_t rkey{};
  // 数据 ring 容量，不包含 64 字节 commit record。
  std::uint32_t ring_size{};
  // FPGA 逻辑 WR 的目标字节数。
  std::uint32_t wr_size{};
  // FPGA 发布 commit 的目标字节间隔。
  std::uint32_t notify_interval{};
  // FPGA 本地源地址基址。
  std::uint64_t local_base{};
  // Host commit record 地址，恒等于 remote_base + ring_size。
  std::uint64_t commit_address{};
  // bit0 选择 WRITE_WITH_IMM，其余位必须为零。
  std::uint32_t flags{};
};

struct Status {
  // 所有 RDCP 响应共用的 64 字节状态 payload。
  // 请求处理结果和当前 session 生命周期状态。
  Result result{Result::kInternalFault};
  State state{State::kIdle};
  // FPGA 提供的具体拒绝或故障原因。
  std::uint32_t reason{};
  // configured/active/safe_to_release 等状态位。
  std::uint32_t status_bits{};
  // FPGA 固定 QPN 与当前发送 PSN。
  std::uint32_t local_qpn{};
  std::uint32_t current_psn{};
  // 每次成功 CONFIG 后递增的配置代次。
  std::uint32_t config_generation{};
  // FPGA 已发起、已确认、已发布以及 Host 已消费的累计字节游标。
  std::uint64_t issued_bytes{};
  std::uint64_t acked_bytes{};
  std::uint64_t published_bytes{};
  std::uint64_t consumed_bytes{};
  // FPGA 支持的 RDCP v2 能力位和活动 PMTU。
  std::uint32_t capabilities{};
  std::uint32_t pmtu_bytes{};
};

struct WirePacket {
  // 固定容量报文，避免控制面重试和 commit 热路径分配 vector。
  std::array<std::byte, kMaxDatagramBytes> storage{};
  ByteCount size{};

  [[nodiscard]] std::span<const std::byte> Bytes() const noexcept {
    // 只暴露已写入的前 size 字节，尾部容量不参与 send。
    return {storage.data(), size};
  }
};

[[nodiscard]] std::uint8_t ResponseOpcode(Opcode opcode) noexcept;
// 将请求头、session、transaction 和 payload 编码为一份不可变报文。
// 按 RDCP v2 固定头布局构造请求；固定容量保证热路径不触发堆分配。
[[nodiscard]] WirePacket MakeRequest(
    Opcode opcode, std::uint64_t session_id, std::uint32_t transaction_id,
    std::span<const std::byte> payload = {}) noexcept;
[[nodiscard]] WirePacket MakeConfigRequest(std::uint64_t session_id,
                                           std::uint32_t transaction_id,
                                           const Config &config) noexcept;
// 编码累计消费字节数；FPGA 以此值推进 ring credit。
[[nodiscard]] WirePacket MakeConsumeRequest(
    std::uint64_t session_id, std::uint32_t transaction_id,
    std::uint64_t consumed_bytes) noexcept;
// 严格校验响应长度和事务字段后解码 RDCP 状态块。
[[nodiscard]] bool DecodeStatus(std::span<const std::byte> bytes, Opcode opcode,
                                std::uint64_t session_id,
                                std::uint32_t transaction_id,
                                Status &status) noexcept;

[[nodiscard]] bool ActiveSessionRequiresAbort(const Status &status) noexcept;

// 记录 final commit 与最新状态，集中判定资源何时可以安全释放。
class ReleaseGate {
 public:
  // final commit 已经交付给消费者时调用。
  void ObserveFinalCommit() noexcept { final_commit_seen_ = true; }
  // 每次 RDCP 响应都刷新状态快照。
  void ObserveStatus(const Status &status) noexcept { status_ = status; }
  [[nodiscard]] bool NormalReleaseReady() const noexcept;
  [[nodiscard]] bool FaultReleaseReady() const noexcept;

 private:
  bool final_commit_seen_{};
  Status status_{};
};

class Transaction {
 public:
  // 构造后 request 字节保持不变，可在传输超时期间重复发送。
  Transaction(Opcode opcode, std::uint64_t session_id,
              std::uint32_t transaction_id,
              std::span<const std::byte> payload = {}) noexcept;
  Transaction(Opcode opcode, std::uint64_t session_id,
              std::uint32_t transaction_id, WirePacket request) noexcept;

  [[nodiscard]] std::span<const std::byte> Request() const noexcept {
    // 返回固定报文的只读视图，不转移所有权。
    return request_.Bytes();
  }
  [[nodiscard]] bool Accept(std::span<const std::byte> response,
                            Status &status) const noexcept;

 private:
  Opcode opcode_;
  std::uint64_t session_id_;
  std::uint32_t transaction_id_;
  WirePacket request_;
};

}  // namespace rrdma::protocol

#endif  // RRDMA_INCLUDE_RRDMA_PROTOCOL_HPP_
