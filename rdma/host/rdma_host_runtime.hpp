#ifndef RDMA_HOST_RUNTIME_HPP
#define RDMA_HOST_RUNTIME_HPP

#include "rdcp_client.hpp"

#include <arpa/inet.h>
#include <infiniband/verbs.h>

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace rdma_host {

inline constexpr std::size_t kMemoryAlignment{4096U};

struct NetdevInfo {
  in_addr ipv4{};
  in_addr netmask{};
  std::array<std::uint8_t, 6> mac{};
  int mtu{};
  unsigned int ifindex{};
};

class UdpControlTransport final : public rdcp::DatagramTransport {
public:
  UdpControlTransport(const std::string &netdev_name, const in_addr &local_ip,
                      const in_addr &fpga_ip);
  ~UdpControlTransport() override;

  UdpControlTransport(const UdpControlTransport &) = delete;
  UdpControlTransport &operator=(const UdpControlTransport &) = delete;

  bool send(const std::vector<std::uint8_t> &request) override;
  bool receive(std::vector<std::uint8_t> &response,
               std::chrono::milliseconds timeout) override;

private:
  int socket_fd_{-1};
};

struct ContextDeleter {
  void operator()(ibv_context *context) const noexcept;
};

struct ProtectionDomainDeleter {
  void operator()(ibv_pd *protection_domain) const noexcept;
};

struct CompletionQueueDeleter {
  void operator()(ibv_cq *completion_queue) const noexcept;
};

struct QueuePairDeleter {
  void operator()(ibv_qp *queue_pair) const noexcept;
};

struct MemoryRegionDeleter {
  void operator()(ibv_mr *memory_region) const noexcept;
};

using ContextPtr = std::unique_ptr<ibv_context, ContextDeleter>;
using ProtectionDomainPtr = std::unique_ptr<ibv_pd, ProtectionDomainDeleter>;
using CompletionQueuePtr = std::unique_ptr<ibv_cq, CompletionQueueDeleter>;
using QueuePairPtr = std::unique_ptr<ibv_qp, QueuePairDeleter>;
using MemoryRegionPtr = std::unique_ptr<ibv_mr, MemoryRegionDeleter>;

class AlignedBuffer {
public:
  explicit AlignedBuffer(std::size_t size);
  ~AlignedBuffer();

  AlignedBuffer(const AlignedBuffer &) = delete;
  AlignedBuffer &operator=(const AlignedBuffer &) = delete;
  AlignedBuffer(AlignedBuffer &&) = delete;
  AlignedBuffer &operator=(AlignedBuffer &&) = delete;

  std::uint8_t *data() noexcept { return storage_; }
  const std::uint8_t *data() const noexcept { return storage_; }
  std::size_t size() const noexcept { return size_; }

private:
  std::uint8_t *storage_{};
  std::size_t size_{};
};

bool query_netdev(const std::string &name, NetdevInfo &info);
bool check_memlock_limit(std::uint64_t required_bytes);
ContextPtr open_device(const std::string &name);
bool select_rocev2_gid(ibv_context *context, const NetdevInfo &netdev,
                       int &gid_index, ibv_gid &gid);
ibv_gid ipv4_mapped_gid(const in_addr &ipv4);
bool modify_qp_to_rts(ibv_qp *queue_pair, int gid_index,
                      const ibv_gid &fpga_gid, std::uint32_t fpga_tx_psn,
                      std::uint32_t host_tx_psn);
bool post_receive(ibv_qp *queue_pair, const ibv_mr *memory_region,
                  const void *scratch, std::uint32_t scratch_bytes,
                  std::uint64_t work_request_id);

std::string format_mac(const std::array<std::uint8_t, 6> &mac);
std::string format_gid(const ibv_gid &gid);
std::uint64_t random_nonzero_u64();
std::uint32_t random_nonzero_u32();
std::uint32_t random_nonzero_psn();

} // namespace rdma_host

#endif
