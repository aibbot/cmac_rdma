#include "rdma_host_runtime.hpp"

#include <net/if.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <random>
#include <sstream>
#include <stdexcept>
#include <utility>

namespace rdma_host {
namespace {

constexpr std::uint8_t kRdmaPort{1U};
constexpr std::uint32_t kProductHostIpv4{0xc0a8110aU};
constexpr std::uint32_t kProductHostNetmask{0xffffff00U};

class FileDescriptor {
public:
  explicit FileDescriptor(int fd = -1) noexcept : fd_(fd) {}
  ~FileDescriptor() {
    if (fd_ >= 0) {
      ::close(fd_);
    }
  }

  FileDescriptor(const FileDescriptor &) = delete;
  FileDescriptor &operator=(const FileDescriptor &) = delete;

  int get() const noexcept { return fd_; }
  int release() noexcept { return std::exchange(fd_, -1); }

private:
  int fd_;
};

struct DeviceListDeleter {
  void operator()(ibv_device **devices) const noexcept {
    if (devices != nullptr) {
      ibv_free_device_list(devices);
    }
  }
};

using DeviceListPtr = std::unique_ptr<ibv_device *, DeviceListDeleter>;

bool gid_matches_ipv4(const ibv_gid &gid, const in_addr &ipv4) {
  constexpr std::array<std::uint8_t, 12> prefix{0, 0, 0, 0, 0,    0,
                                                0, 0, 0, 0, 0xff, 0xff};

  return std::memcmp(gid.raw, prefix.data(), prefix.size()) == 0 &&
         std::memcmp(&gid.raw[12], &ipv4.s_addr, sizeof(ipv4.s_addr)) == 0;
}

std::mt19937_64 &random_engine() {
  static std::mt19937_64 engine{std::random_device{}()};
  return engine;
}

} // namespace

UdpControlTransport::UdpControlTransport(const std::string &netdev_name,
                                         const in_addr &local_ip,
                                         const in_addr &fpga_ip) {
  FileDescriptor socket{::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)};
  if (socket.get() < 0) {
    throw std::runtime_error(std::string{"control socket: "} +
                             std::strerror(errno));
  }
  if (::setsockopt(socket.get(), SOL_SOCKET, SO_BINDTODEVICE,
                   netdev_name.c_str(),
                   static_cast<socklen_t>(netdev_name.size() + 1U)) != 0) {
    throw std::runtime_error(std::string{"SO_BINDTODEVICE: "} +
                             std::strerror(errno));
  }

  sockaddr_in local{};
  local.sin_family = AF_INET;
  local.sin_addr = local_ip;
  if (::bind(socket.get(), reinterpret_cast<const sockaddr *>(&local),
             sizeof(local)) != 0) {
    throw std::runtime_error(std::string{"control bind: "} +
                             std::strerror(errno));
  }

  sockaddr_in remote{};
  remote.sin_family = AF_INET;
  remote.sin_port = htons(rdcp::kControlPort);
  remote.sin_addr = fpga_ip;
  if (::connect(socket.get(), reinterpret_cast<const sockaddr *>(&remote),
                sizeof(remote)) != 0) {
    throw std::runtime_error(std::string{"control connect: "} +
                             std::strerror(errno));
  }
  socket_fd_ = socket.release();
}

UdpControlTransport::~UdpControlTransport() {
  if (socket_fd_ >= 0) {
    ::close(socket_fd_);
  }
}

bool UdpControlTransport::send(const std::vector<std::uint8_t> &request) {
  const auto sent = ::send(socket_fd_, request.data(), request.size(), 0);
  if (sent == static_cast<ssize_t>(request.size())) {
    return true;
  }
  if (sent < 0) {
    std::perror("RDCP send");
  } else {
    std::cerr << "RDCP short datagram send\n";
  }
  return false;
}

bool UdpControlTransport::receive(std::vector<std::uint8_t> &response,
                                  std::chrono::milliseconds timeout) {
  pollfd descriptor{};
  descriptor.fd = socket_fd_;
  descriptor.events = POLLIN;
  const auto bounded_timeout =
      std::min<std::int64_t>(timeout.count(), std::numeric_limits<int>::max());
  const int poll_result =
      ::poll(&descriptor, 1, static_cast<int>(bounded_timeout));
  if (poll_result <= 0 || (descriptor.revents & POLLIN) == 0) {
    return false;
  }

  std::array<std::uint8_t, 2048> bytes{};
  const auto received = ::recv(socket_fd_, bytes.data(), bytes.size(), 0);
  if (received <= 0) {
    return false;
  }
  response.assign(bytes.begin(), bytes.begin() + received);
  return true;
}

void ContextDeleter::operator()(ibv_context *context) const noexcept {
  if (context != nullptr) {
    ibv_close_device(context);
  }
}

void ProtectionDomainDeleter::operator()(
    ibv_pd *protection_domain) const noexcept {
  if (protection_domain != nullptr) {
    ibv_dealloc_pd(protection_domain);
  }
}

void CompletionQueueDeleter::operator()(
    ibv_cq *completion_queue) const noexcept {
  if (completion_queue != nullptr) {
    ibv_destroy_cq(completion_queue);
  }
}

void QueuePairDeleter::operator()(ibv_qp *queue_pair) const noexcept {
  if (queue_pair != nullptr) {
    ibv_destroy_qp(queue_pair);
  }
}

void MemoryRegionDeleter::operator()(ibv_mr *memory_region) const noexcept {
  if (memory_region != nullptr) {
    ibv_dereg_mr(memory_region);
  }
}

AlignedBuffer::AlignedBuffer(std::size_t size) : size_(size) {
  void *allocation{};
  const int result = ::posix_memalign(&allocation, kMemoryAlignment, size_);
  if (result != 0) {
    throw std::runtime_error(std::string{"posix_memalign ring: "} +
                             std::strerror(result));
  }
  storage_ = static_cast<std::uint8_t *>(allocation);
  std::memset(storage_, 0, size_);
}

AlignedBuffer::~AlignedBuffer() { std::free(storage_); }

bool query_netdev(const std::string &name, NetdevInfo &info) {
  FileDescriptor socket{::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)};
  if (socket.get() < 0) {
    std::perror("socket");
    return false;
  }

  ifreq request{};
  std::strncpy(request.ifr_name, name.c_str(), IFNAMSIZ - 1);
  request.ifr_name[IFNAMSIZ - 1] = '\0';
  if (::ioctl(socket.get(), SIOCGIFADDR, &request) != 0 ||
      request.ifr_addr.sa_family != AF_INET) {
    std::perror("SIOCGIFADDR");
    return false;
  }
  info.ipv4 = reinterpret_cast<sockaddr_in *>(&request.ifr_addr)->sin_addr;

  if (::ioctl(socket.get(), SIOCGIFNETMASK, &request) != 0) {
    std::perror("SIOCGIFNETMASK");
    return false;
  }
  info.netmask =
      reinterpret_cast<sockaddr_in *>(&request.ifr_netmask)->sin_addr;

  if (::ioctl(socket.get(), SIOCGIFHWADDR, &request) != 0) {
    std::perror("SIOCGIFHWADDR");
    return false;
  }
  std::memcpy(info.mac.data(), request.ifr_hwaddr.sa_data, info.mac.size());

  if (::ioctl(socket.get(), SIOCGIFMTU, &request) != 0) {
    std::perror("SIOCGIFMTU");
    return false;
  }
  info.mtu = request.ifr_mtu;

  if (::ioctl(socket.get(), SIOCGIFFLAGS, &request) != 0) {
    std::perror("SIOCGIFFLAGS");
    return false;
  }
  if ((request.ifr_flags & IFF_UP) == 0) {
    std::cerr << "netdev " << name << " is not up\n";
    return false;
  }

  info.ifindex = ::if_nametoindex(name.c_str());
  if (info.ifindex == 0) {
    std::cerr << "cannot resolve netdev index for " << name << '\n';
    return false;
  }
  if (info.mtu < 9000) {
    std::cerr << "netdev " << name << " MTU is " << info.mtu
              << "; 9000 or greater is required\n";
    return false;
  }
  if (ntohl(info.ipv4.s_addr) != kProductHostIpv4 ||
      ntohl(info.netmask.s_addr) != kProductHostNetmask) {
    std::cerr << "netdev " << name
              << " must be configured as 192.168.17.10/24\n";
    return false;
  }
  return true;
}

bool check_memlock_limit(std::uint64_t required_bytes) {
  rlimit limit{};
  if (::getrlimit(RLIMIT_MEMLOCK, &limit) != 0) {
    std::perror("getrlimit RLIMIT_MEMLOCK");
    return false;
  }
  if (limit.rlim_cur != RLIM_INFINITY &&
      required_bytes > static_cast<std::uint64_t>(limit.rlim_cur)) {
    std::cerr << "memlock soft limit "
              << static_cast<std::uint64_t>(limit.rlim_cur)
              << " is below required registered memory " << required_bytes
              << "; raise ulimit -l first\n";
    return false;
  }
  return true;
}

ContextPtr open_device(const std::string &name) {
  int device_count{};
  DeviceListPtr devices{ibv_get_device_list(&device_count)};
  if (!devices) {
    std::perror("ibv_get_device_list");
    return {};
  }

  ContextPtr context;
  for (int index = 0; index < device_count; ++index) {
    ibv_device *device = devices.get()[index];
    const char *device_name = ibv_get_device_name(device);

    std::cerr << "device: " << device_name << '\n';
    if (name == device_name) {
      context.reset(ibv_open_device(device));
      break;
    }
  }
  if (!context) {
    std::cerr << "cannot open RDMA device " << name << '\n';
  }
  return context;
}

bool select_rocev2_gid(ibv_context *context, const NetdevInfo &netdev,
                       int &gid_index, ibv_gid &gid) {
  ibv_port_attr port_attr{};

  if (ibv_query_port(context, kRdmaPort, &port_attr) != 0) {
    std::perror("ibv_query_port");
    return false;
  }
  if (port_attr.state != IBV_PORT_ACTIVE) {
    std::cerr << "RDMA port " << static_cast<unsigned int>(kRdmaPort)
              << " is not active\n";
    return false;
  }
  if (port_attr.active_mtu < IBV_MTU_4096) {
    std::cerr << "RDMA port " << static_cast<unsigned int>(kRdmaPort)
              << " active MTU is smaller than 4096\n";
    return false;
  }
  for (int index = 0; index < port_attr.gid_tbl_len; ++index) {
    ibv_gid_entry entry{};

    if (ibv_query_gid_ex(context, kRdmaPort, index, &entry, 0) != 0) {
      continue;
    }
    if (entry.gid_type != IBV_GID_TYPE_ROCE_V2 ||
        entry.ndev_ifindex != netdev.ifindex ||
        !gid_matches_ipv4(entry.gid, netdev.ipv4)) {
      continue;
    }
    gid_index = index;
    gid = entry.gid;
    return true;
  }
  std::cerr << "no RoCEv2 GID on port " << static_cast<unsigned int>(kRdmaPort)
            << " matches the selected netdev and its IPv4 address\n";
  return false;
}

ibv_gid ipv4_mapped_gid(const in_addr &ipv4) {
  ibv_gid result{};
  result.raw[10] = 0xff;
  result.raw[11] = 0xff;
  std::memcpy(&result.raw[12], &ipv4.s_addr, sizeof(ipv4.s_addr));
  return result;
}

bool modify_qp_to_rts(ibv_qp *queue_pair, int gid_index,
                      const ibv_gid &fpga_gid, std::uint32_t fpga_tx_psn,
                      std::uint32_t host_tx_psn) {
  ibv_qp_attr attr{};
  int mask{};

  attr.qp_state = IBV_QPS_INIT;
  attr.pkey_index = 0;
  attr.port_num = kRdmaPort;
  attr.qp_access_flags = IBV_ACCESS_REMOTE_WRITE;
  mask = IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS;
  if (ibv_modify_qp(queue_pair, &attr, mask) != 0) {
    std::perror("ibv_modify_qp INIT");
    return false;
  }

  attr = {};
  attr.qp_state = IBV_QPS_RTR;
  attr.path_mtu = IBV_MTU_4096;
  attr.dest_qp_num = rdcp::kLocalQpn;
  attr.rq_psn = fpga_tx_psn;
  attr.max_dest_rd_atomic = 1;
  attr.min_rnr_timer = 12;
  attr.ah_attr.is_global = 1;
  attr.ah_attr.port_num = kRdmaPort;
  attr.ah_attr.grh.dgid = fpga_gid;
  attr.ah_attr.grh.sgid_index = gid_index;
  attr.ah_attr.grh.hop_limit = 1;
  mask = IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN |
         IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER;
  if (ibv_modify_qp(queue_pair, &attr, mask) != 0) {
    std::perror("ibv_modify_qp RTR");
    return false;
  }

  attr = {};
  attr.qp_state = IBV_QPS_RTS;
  attr.sq_psn = host_tx_psn;
  attr.timeout = 20;
  attr.retry_cnt = 7;
  attr.rnr_retry = 7;
  attr.max_rd_atomic = 1;
  mask = IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY |
         IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC;
  if (ibv_modify_qp(queue_pair, &attr, mask) != 0) {
    std::perror("ibv_modify_qp RTS");
    return false;
  }
  return true;
}

bool post_receive(ibv_qp *queue_pair, const ibv_mr *memory_region,
                  const void *scratch, std::uint32_t scratch_bytes,
                  std::uint64_t work_request_id) {
  ibv_sge scatter_gather{};
  ibv_recv_wr receive{};
  ibv_recv_wr *bad_work_request{};

  scatter_gather.addr = reinterpret_cast<std::uintptr_t>(scratch);
  scatter_gather.length = scratch_bytes;
  scatter_gather.lkey = memory_region->lkey;
  receive.wr_id = work_request_id;
  receive.sg_list = &scatter_gather;
  receive.num_sge = 1;
  if (ibv_post_recv(queue_pair, &receive, &bad_work_request) != 0) {
    std::perror("ibv_post_recv");
    return false;
  }
  return true;
}

std::string format_mac(const std::array<std::uint8_t, 6> &mac) {
  std::ostringstream output;
  output << std::hex << std::nouppercase << std::setfill('0');
  for (std::size_t index = 0; index < mac.size(); ++index) {
    if (index != 0) {
      output << ':';
    }
    output << std::setw(2) << static_cast<unsigned int>(mac[index]);
  }
  return output.str();
}

std::string format_gid(const ibv_gid &gid) {
  std::ostringstream output;
  output << std::hex << std::nouppercase << std::setfill('0');
  for (const auto byte : gid.raw) {
    output << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return output.str();
}

std::uint64_t random_nonzero_u64() {
  std::uint64_t value{};
  while (value == 0U) {
    value = random_engine()();
  }
  return value;
}

std::uint32_t random_nonzero_u32() {
  std::uint32_t value{};
  while (value == 0U) {
    value = static_cast<std::uint32_t>(random_engine()());
  }
  return value;
}

std::uint32_t random_nonzero_psn() {
  std::uint32_t value{};
  while (value == 0U) {
    value = static_cast<std::uint32_t>(random_engine()()) & 0xffffffU;
  }
  return value;
}

} // namespace rdma_host
