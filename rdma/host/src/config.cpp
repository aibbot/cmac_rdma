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

[[nodiscard]] Error InvalidConfig(std::string message) {
  return MakeError(ErrorCode::kInvalidConfiguration, std::move(message));
}

[[nodiscard]] bool IsPositive(std::chrono::milliseconds value) noexcept {
  return value.count() > 0;
}

[[nodiscard]] bool IsValidIpv4(const std::string &text) noexcept {
  in_addr address{};
  return ::inet_pton(AF_INET, text.c_str(), &address) == 1;
}

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

[[nodiscard]] Outcome<void> ValidateNetwork(const NetworkConfig &network) {
  if (network.device_name.empty() || network.netdev_name.empty() ||
      network.fpga_ipv4.empty()) {
    return Outcome<void>{InvalidConfig(
        "device, netdev and FPGA IPv4 must be specified")};
  }
  if (network.control_port == 0U || network.rdma_port == 0U ||
      network.minimum_mtu == 0U ||
      network.minimum_mtu >
          static_cast<ByteCount>(std::numeric_limits<int>::max()) ||
      (network.gid_index && *network.gid_index < 0)) {
    return Outcome<void>{InvalidConfig(
        "control port, RDMA port, GID index or minimum MTU is invalid")};
  }
  if (!IsValidIpv4(network.fpga_ipv4) ||
      (!network.local_ipv4.empty() && !IsValidIpv4(network.local_ipv4)) ||
      (!network.required_netmask.empty() &&
       !IsContiguousNetmask(network.required_netmask))) {
    return Outcome<void>{InvalidConfig("network IPv4 configuration is invalid")};
  }
  return {};
}

[[nodiscard]] Outcome<void> ValidateSession(const SessionOptions &config) {
  const auto &session = config.session;
  if (session.ring_bytes == 0U ||
      session.ring_bytes > std::numeric_limits<std::uint32_t>::max() ||
      session.ring_bytes % kPacketBytes != 0U || session.wr_bytes == 0U ||
      session.wr_bytes % kPacketBytes != 0U ||
      session.notify_interval_bytes == 0U ||
      session.notify_interval_bytes % kPacketBytes != 0U ||
      session.wr_bytes > session.ring_bytes ||
      session.notify_interval_bytes > session.ring_bytes) {
    return Outcome<void>{InvalidConfig(
        "ring, WR and notification sizes must be aligned and fit the ring")};
  }
  if (session.local_base % protocol::kLocalBaseAlignment != 0U ||
      session.local_base >= protocol::kRemoteAddressLimit ||
      session.local_base > protocol::kRemoteAddressLimit - session.ring_bytes) {
    return Outcome<void>{InvalidConfig(
        "local_base must be FPGA-aligned and fit the 48-bit address range")};
  }
  if (session.notification == NotificationMode::kWriteWithImm &&
      (session.receive_depth == 0U || config.verbs.max_receive_wr == 0U ||
       session.receive_depth > config.verbs.max_receive_wr)) {
    return Outcome<void>{InvalidConfig(
        "Immediate mode receive depth exceeds max_receive_wr")};
  }
  return {};
}

[[nodiscard]] Outcome<void> ValidateVerbs(const VerbsConfig &verbs) {
  if (verbs.max_send_wr == 0U || verbs.max_receive_wr == 0U ||
      verbs.max_send_wr > std::numeric_limits<std::uint32_t>::max() ||
      verbs.max_receive_wr > std::numeric_limits<std::uint32_t>::max() ||
      verbs.minimum_active_mtu_bytes == 0U ||
      verbs.minimum_active_mtu_bytes > protocol::kPmtuBytes) {
    return Outcome<void>{InvalidConfig(
        "verbs queue dimensions or active MTU are invalid")};
  }
  if (verbs.session_id && *verbs.session_id == 0U) {
    return Outcome<void>{InvalidConfig("session_id must be non-zero")};
  }
  if (verbs.transaction_seed &&
      (*verbs.transaction_seed == 0U ||
       (*verbs.transaction_seed & 0x7fffffffU) == 0U)) {
    return Outcome<void>{InvalidConfig(
        "transaction seed must have a non-zero 31-bit value")};
  }
  if (verbs.fpga_tx_psn &&
      (*verbs.fpga_tx_psn == 0U || *verbs.fpga_tx_psn > 0x00ffffffU)) {
    return Outcome<void>{InvalidConfig(
        "FPGA PSN must be a non-zero 24-bit value")};
  }
  if (verbs.host_tx_psn &&
      (*verbs.host_tx_psn == 0U || *verbs.host_tx_psn > 0x00ffffffU)) {
    return Outcome<void>{InvalidConfig(
        "host PSN must be a non-zero 24-bit value")};
  }
  return {};
}

[[nodiscard]] Outcome<void> ValidatePolling(const SessionOptions &config) {
  const auto &polling = config.polling;
  if (polling.consumer_queue_depth == 0U || polling.completion_batch == 0U ||
      polling.spin_iterations == 0U ||
      polling.completion_batch >
          static_cast<HostCount>(std::numeric_limits<int>::max()) ||
      (polling.mode != PollingMode::kBusy && polling.idle_sleep.count() <= 0)) {
    return Outcome<void>{InvalidConfig(
        "queue and polling dimensions are invalid")};
  }
  if (polling.consumer_queue_depth >
      config.session.ring_bytes / config.session.notify_interval_bytes) {
    return Outcome<void>{InvalidConfig(
        "consumer queue depth must fit within one ring of committed intervals")};
  }
  return {};
}

[[nodiscard]] Outcome<void> ValidateMemory(const SessionOptions &config) {
  const auto &memory = config.memory;
  if (memory.backing_file_descriptor < -1 ||
      (memory.backing_file_descriptor < 0 && memory.backing_offset_bytes != 0U)) {
    return Outcome<void>{InvalidConfig(
        "memory backing descriptor or offset is invalid")};
  }

  ByteCount page_bytes{};
  switch (memory.page_mode) {
    case MemoryPageMode::kHugeTlb:
      if (memory.huge_page_bytes < kPacketBytes ||
          !std::has_single_bit(memory.huge_page_bytes) ||
          config.session.ring_bytes % memory.huge_page_bytes != 0U ||
          memory.backing_offset_bytes % memory.huge_page_bytes != 0U) {
        return Outcome<void>{InvalidConfig(
            "hugetlb page size, ring size or backing offset is invalid")};
      }
      page_bytes = memory.huge_page_bytes;
      break;
    case MemoryPageMode::kRegular:
      if (memory.backing_offset_bytes % kPacketBytes != 0U) {
        return Outcome<void>{InvalidConfig(
            "regular-page backing offset is not page aligned")};
      }
      page_bytes = kPacketBytes;
      break;
    default:
      return Outcome<void>{InvalidConfig("memory page mode is invalid")};
  }

  const auto logical_bytes = config.session.ring_bytes + kCommitBytes;
  const auto remainder = logical_bytes % page_bytes;
  const auto padding = memory.page_mode == MemoryPageMode::kHugeTlb && remainder
                           ? page_bytes - remainder
                           : 0U;
  if (logical_bytes > std::numeric_limits<ByteCount>::max() - padding ||
      memory.backing_offset_bytes >
          std::numeric_limits<ByteCount>::max() - logical_bytes - padding) {
    return Outcome<void>{InvalidConfig(
        "aligned ring backing range overflows uint64")};
  }
  return {};
}

[[nodiscard]] Outcome<void> ValidateTiming(const SessionOptions &config) {
  const auto &timing = config.timing;
  if (!IsPositive(timing.discovery_window) ||
      !IsPositive(timing.command_window) ||
      !IsPositive(timing.status_timeout) ||
      !IsPositive(timing.status_interval) ||
      !IsPositive(timing.shutdown_window) ||
      !IsPositive(timing.retry_interval) ||
      timing.progress_retry_interval.count() <= 0 ||
      !IsPositive(timing.recovery_warning_interval) ||
      !IsPositive(config.polling.housekeeping_interval)) {
    return Outcome<void>{InvalidConfig("timing values must be positive")};
  }
  return {};
}

}  // namespace

Outcome<void> ValidateConfig(const SessionOptions &config) {
  if (auto result = ValidateNetwork(config.network); !result) {
    return result;
  }
  if (auto result = ValidateSession(config); !result) {
    return result;
  }
  if (auto result = ValidateVerbs(config.verbs); !result) {
    return result;
  }
  if (auto result = ValidatePolling(config); !result) {
    return result;
  }
  if (auto result = ValidateMemory(config); !result) {
    return result;
  }
  return ValidateTiming(config);
}

}  // namespace rrdma::detail
