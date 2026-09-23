#include <arpa/inet.h>

#include <bit>
#include <chrono>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>

#include "detail.hpp"

namespace rrdma::detail {
namespace {

// 将配置错误统一标记为调用者可修正的 invalid-configuration。
[[nodiscard]] Error InvalidConfig(std::string message) {
  return MakeError(ErrorCode::kInvalidConfiguration, std::move(message));
}

// 所有时间窗口都必须为正，避免状态机出现零时长忙循环。
[[nodiscard]] bool IsPositive(std::chrono::milliseconds value) noexcept {
  return value.count() > 0;
}

// 只接受 IPv4 文本，实际 netdev 匹配由 QueryNetdev 再次确认。
[[nodiscard]] bool IsValidIpv4(const std::string &text) noexcept {
  in_addr address{};
  return ::inet_pton(AF_INET, text.c_str(), &address) == 1;
}

// 检查掩码是否为连续的高位 1、低位 0，拒绝非标准掩码。
[[nodiscard]] bool IsContiguousNetmask(const std::string &text) noexcept {
  in_addr address{};
  if (::inet_pton(AF_INET, text.c_str(), &address) != 1) {
    return false;
  }
  const auto value = ntohl(address.s_addr);
  bool saw_zero{};
  for (int bit = 31; bit >= 0; --bit) {
    const bool is_one = (value & (1U << bit)) != 0U;
    if (!is_one) {
      saw_zero = true;
    } else if (saw_zero) {
      return false;
    }
  }
  return true;
}

} // namespace

Outcome<void> ValidateConfig(const ReceiverConfig &config) {
  // 在创建 socket、MR 或 QP 前集中校验几何、地址、队列和定时参数，
  // 让硬件侧只接收语义完整的 RDCP CONFIG。
  const auto &network = config.network;
  // 网络字段决定控制通道和 GID 选择，先检查空值/端口/地址。
  if (network.device_name.empty() || network.netdev_name.empty() || network.fpga_ipv4.empty()) {
    return Outcome<void>{
      InvalidConfig("device, netdev and FPGA IPv4 must be specified")};
  }
  if (network.control_port == 0U || network.rdma_port == 0U || network.minimum_mtu == 0U || network.minimum_mtu > static_cast<std::uint32_t>(std::numeric_limits<int>::max()) || (network.gid_index.has_value() && *network.gid_index < 0)) {
    return Outcome<void>{InvalidConfig(
      "control port, RDMA port, GID index or minimum MTU is invalid")};
  }
  if (!IsValidIpv4(network.fpga_ipv4) || (!network.local_ipv4.empty() && !IsValidIpv4(network.local_ipv4)) || (!network.required_netmask.empty() && !IsContiguousNetmask(network.required_netmask))) {
    return Outcome<void>{
      InvalidConfig("network IPv4 configuration is invalid")};
  }

  const auto &session = config.session;
  // ring 几何必须按 4096 字节对齐，且 WR/通知区间不能超过 ring。
  if (session.ring_bytes == 0U || session.ring_bytes > std::numeric_limits<std::uint32_t>::max() || session.ring_bytes % kPacketBytes != 0U || session.wr_bytes == 0U || session.wr_bytes % kPacketBytes != 0U || session.notify_interval_bytes == 0U || session.notify_interval_bytes % kPacketBytes != 0U || session.wr_bytes > session.ring_bytes || session.notify_interval_bytes > session.ring_bytes) {
    return Outcome<void>{InvalidConfig(
      "ring, WR and notification sizes must be aligned and fit the ring")};
  }
  if (session.local_base % protocol::kLocalBaseAlignment != 0U || session.local_base >= protocol::kRemoteAddressLimit || session.local_base > protocol::kRemoteAddressLimit - session.ring_bytes) {
    return Outcome<void>{InvalidConfig(
      "local_base must be FPGA-aligned and fit the 48-bit address range")};
  }
  if (session.notification == NotificationMode::kWriteWithImm && (session.receive_depth == 0U || config.verbs.max_receive_wr <= 0 || session.receive_depth > static_cast<std::uint32_t>(config.verbs.max_receive_wr))) {
    return Outcome<void>{
      InvalidConfig("Immediate mode receive depth exceeds max_receive_wr")};
  }

  const auto &verbs = config.verbs;
  // verbs 上限需要同时满足 provider 能力和 immediate RQ 深度。
  if (verbs.max_send_wr <= 0 || verbs.max_receive_wr <= 0 || verbs.completion_queue_slack < 0 || verbs.minimum_active_mtu_bytes == 0U || verbs.minimum_active_mtu_bytes > protocol::kPmtuBytes) {
    return Outcome<void>{
      InvalidConfig("verbs queue dimensions or active MTU are invalid")};
  }
  if (verbs.session_id.has_value() && *verbs.session_id == 0U) {
    return Outcome<void>{InvalidConfig("session_id must be non-zero")};
  }
  if (verbs.transaction_seed.has_value() && (*verbs.transaction_seed == 0U || (*verbs.transaction_seed & 0x7fffffffU) == 0U)) {
    return Outcome<void>{
      InvalidConfig("transaction seed must have a non-zero 31-bit value")};
  }
  if (verbs.fpga_tx_psn.has_value() && (*verbs.fpga_tx_psn == 0U || *verbs.fpga_tx_psn > 0x00ffffffU)) {
    return Outcome<void>{
      InvalidConfig("FPGA PSN must be a non-zero 24-bit value")};
  }
  if (verbs.host_tx_psn.has_value() && (*verbs.host_tx_psn == 0U || *verbs.host_tx_psn > 0x00ffffffU)) {
    return Outcome<void>{
      InvalidConfig("host PSN must be a non-zero 24-bit value")};
  }

  const auto &polling = config.polling;
  // 有界 descriptor 队列不能容纳超过一整 ring 的未释放 commit。
  if (polling.consumer_queue_depth == 0U || polling.completion_batch == 0U || polling.spin_iterations == 0U || polling.completion_batch > static_cast<std::size_t>(std::numeric_limits<int>::max()) || (polling.mode != PollingMode::kBusy && polling.idle_sleep.count() <= 0)) {
    return Outcome<void>{
      InvalidConfig("queue and polling dimensions are invalid")};
  }
  if (polling.consumer_queue_depth > session.ring_bytes / session.notify_interval_bytes) {
    return Outcome<void>{
      InvalidConfig("consumer queue depth must fit within one ring of "
                    "committed intervals")};
  }

  const auto &memory = config.memory;
  // 双映射要求可重复 mmap 的文件后备；默认 memfd 不接受非零偏移。
  if (memory.backing_file_descriptor < -1 || (memory.backing_file_descriptor < 0 && memory.backing_offset_bytes != 0U)) {
    return Outcome<void>{
      InvalidConfig("memory backing descriptor or offset is invalid")};
  }
  std::uint64_t mapping_page_bytes{};
  switch (memory.page_mode) {
  case MemoryPageMode::kHugeTlb:
    // 显式 hugetlb 需要幂次页大小；ring 和文件偏移必须落在大页边界，
    // 否则 MAP_FIXED 的第二个别名无法保证连续且不会跨页错位。
    if (memory.huge_page_bytes < kPacketBytes || !std::has_single_bit(memory.huge_page_bytes) || session.ring_bytes % memory.huge_page_bytes != 0U || memory.backing_offset_bytes % memory.huge_page_bytes != 0U) {
      return Outcome<void>{InvalidConfig(
        "hugetlb page size, ring size or backing offset is invalid")};
    }
    mapping_page_bytes = memory.huge_page_bytes;
    break;
  case MemoryPageMode::kRegular:
    // 目标 Linux 主机使用 4096 字节基础页；RingStorage 仍会用 sysconf
    // 复核实际页大小后再创建任何映射。
    if (memory.backing_offset_bytes % kPacketBytes != 0U) {
      return Outcome<void>{
        InvalidConfig("regular-page backing offset is not page aligned")};
    }
    mapping_page_bytes = kPacketBytes;
    break;
  default:
    return Outcome<void>{InvalidConfig("memory page mode is invalid")};
  }

  // 后备文件包含 ring 和紧随其后的 64 字节 commit；hugetlb 模式还需按
  // 大页向上取整。该检查保证后续偏移、ftruncate 和 mmap 不会溢出。
  const auto logical_storage_bytes = session.ring_bytes + kCommitBytes;
  const auto storage_remainder = logical_storage_bytes % mapping_page_bytes;
  const auto storage_padding =
    memory.page_mode == MemoryPageMode::kHugeTlb && storage_remainder != 0U ? mapping_page_bytes - storage_remainder : 0U;
  if (logical_storage_bytes > std::numeric_limits<std::uint64_t>::max() - storage_padding || memory.backing_offset_bytes > std::numeric_limits<std::uint64_t>::max() - logical_storage_bytes - storage_padding) {
    return Outcome<void>{
      InvalidConfig("aligned ring backing range overflows uint64")};
  }

  const auto &timing = config.timing;
  // 低频控制和恢复定时器不能配置为非正值。
  if (!IsPositive(timing.discovery_window) || !IsPositive(timing.command_window) || !IsPositive(timing.status_timeout) || !IsPositive(timing.status_interval) || !IsPositive(timing.shutdown_window) || !IsPositive(timing.retry_interval) || timing.progress_retry_interval.count() <= 0 || !IsPositive(timing.recovery_warning_interval) || !IsPositive(polling.housekeeping_interval)) {
    return Outcome<void>{InvalidConfig("timing values must be positive")};
  }
  return {};
}

} // namespace rrdma::detail
