#include <arpa/inet.h>
#include <fcntl.h>
#include <net/if.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/random.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <exception>
#include <limits>
#include <new>
#include <string>
#include <utility>

#include "detail.hpp"
#include "unique_fd.hpp"

namespace rrdma::detail {
namespace {

// 保存 errno 并转换为通用系统错误。
[[nodiscard]] Error SystemError(const char *operation) {
  const int error_number = errno;
  return MakeError(ErrorCode::kSystemError,
                   std::string{operation} + ": " + std::strerror(error_number),
                   error_number);
}

// 将 verbs 返回码、errno 和操作名称组合成结构化错误。
[[nodiscard]] Error VerbsError(const char *operation, int verbs_status = 0,
                               int system_errno = 0) {
  Error error = MakeError(ErrorCode::kVerbsError, operation, system_errno);
  error.verbs_status = verbs_status;
  return error;
}

// 处理通过 errno 报错的 verbs 创建/注册 API。
[[nodiscard]] Error VerbsErrno(const char *operation) {
  const int error_number = errno;
  return VerbsError(operation, 0, error_number);
}

int PostReceiveVerbs(void * /*context*/, ibv_qp *queue_pair,
                     ibv_recv_wr *first_work_request,
                     ibv_recv_wr **bad_work_request) noexcept {
  return ibv_post_recv(queue_pair, first_work_request, bad_work_request);
}

[[nodiscard]] Outcome<void> CheckMemlockLimit(std::size_t required_bytes) noexcept {
  // MR 注册会锁住整个 ring，提前检查限制可给出明确诊断。
  rlimit limit{};
  if (::getrlimit(RLIMIT_MEMLOCK, &limit) != 0) {
    return Outcome<void>{SystemError("getrlimit RLIMIT_MEMLOCK")};
  }
  if (limit.rlim_cur != RLIM_INFINITY
      && static_cast<std::uint64_t>(required_bytes) > static_cast<std::uint64_t>(limit.rlim_cur)) {
    return Outcome<void>{
      MakeError(ErrorCode::kInvalidConfiguration,
                "RLIMIT_MEMLOCK is below the registered ring size")};
  }
  return {};
}

struct DeviceListDeleter {
  // ibv_get_device_list 对应的自定义释放器。
  void operator()(ibv_device **devices) const noexcept {
    if (devices != nullptr) {
      ibv_free_device_list(devices);
    }
  }
};
using DeviceListPtr = std::unique_ptr<ibv_device *, DeviceListDeleter>;

[[nodiscard]] ifreq InterfaceRequest(const std::string &name) noexcept {
  // 初始化 ioctl 请求并保证接口名以 NUL 结尾。
  ifreq request{};
  std::strncpy(request.ifr_name, name.c_str(), IFNAMSIZ - 1U);
  request.ifr_name[IFNAMSIZ - 1U] = '\0';
  return request;
}

[[nodiscard]] bool QueryInterface(int fd, unsigned long request_code,
                                  ifreq &request) noexcept {
  // 对各类 netdev ioctl 使用同一布尔结果接口。
  return ::ioctl(fd, request_code, &request) == 0;
}

[[nodiscard]] bool GidMatchesIpv4(const ibv_gid &gid,
                                  const in_addr &ipv4) noexcept {
  // RoCEv2 IPv4 GID 必须是 ::ffff:a.b.c.d 映射格式。
  constexpr std::array<unsigned char, 12> kIpv4MappedPrefix{
    0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0xffU, 0xffU};
  return std::memcmp(gid.raw, kIpv4MappedPrefix.data(),
                     kIpv4MappedPrefix.size())
           == 0
         && std::memcmp(gid.raw + 12U, &ipv4.s_addr, sizeof(ipv4.s_addr)) == 0;
}

[[nodiscard]] Outcome<ContextPtr> OpenContext(const std::string &name) noexcept {
  // 按精确设备名打开 verbs context，避免误选其他 RDMA 端口。
  int count{};
  DeviceListPtr devices{ibv_get_device_list(&count)};
  if (!devices) {
    return Failure<ContextPtr>(VerbsErrno("ibv_get_device_list"));
  }
  for (int index = 0; index < count; ++index) {
    ibv_device *device = devices.get()[index];
    if (name == ibv_get_device_name(device)) {
      ContextPtr context{ibv_open_device(device)};
      if (!context) {
        return Failure<ContextPtr>(VerbsErrno("ibv_open_device"));
      }
      return context;
    }
  }
  return Failure<ContextPtr>(
    MakeError(ErrorCode::kVerbsError, "requested RDMA device was not found"));
}

[[nodiscard]] int MtuBytes(ibv_mtu mtu) noexcept {
  // 将 verbs 枚举转换为字节数，用于 PMTU 4096 能力校验。
  switch (mtu) {
  case IBV_MTU_256:
    return 256;
  case IBV_MTU_512:
    return 512;
  case IBV_MTU_1024:
    return 1024;
  case IBV_MTU_2048:
    return 2048;
  case IBV_MTU_4096:
    return 4096;
  default:
    return 0;
  }
}

[[nodiscard]] Outcome<int> ChooseGid(ibv_context *context,
                                     const NetworkConfig &config,
                                     const NetdevInfo &netdev,
                                     std::uint32_t minimum_active_mtu_bytes,
                                     ibv_gid &selected) noexcept {
  // GID 必须同时匹配 RoCEv2 类型、netdev ifindex 和本地 IPv4；显式
  // gid_index 也执行同样检查，避免选中同设备的其他端口/VLAN。
  ibv_port_attr port{};
  const int port_status = ibv_query_port(context, config.rdma_port, &port);
  if (port_status != 0) {
    return Failure<int>(VerbsError("ibv_query_port", port_status));
  }
  const auto required_mtu =
    std::max(minimum_active_mtu_bytes, protocol::kPmtuBytes);
  if (port.state != IBV_PORT_ACTIVE || MtuBytes(port.active_mtu) < static_cast<int>(required_mtu)) {
    return Failure<int>(MakeError(
      ErrorCode::kVerbsError,
      "RDMA port is not active or below the configured minimum active MTU"));
  }
  int last_query_status{};
  int successful_queries{};
  const auto matches = [&](int index) {
    ibv_gid_entry entry{};
    last_query_status =
      ibv_query_gid_ex(context, config.rdma_port, index, &entry, 0);
    if (last_query_status != 0) {
      return false;
    }
    ++successful_queries;
    if (entry.gid_type != IBV_GID_TYPE_ROCE_V2
        || entry.ndev_ifindex != netdev.ifindex
        || !GidMatchesIpv4(entry.gid, netdev.ipv4)) {
      return false;
    }
    selected = entry.gid;
    return true;
  };

  if (config.gid_index.has_value()) {
    const int index = *config.gid_index;
    if (index < 0 || index >= port.gid_tbl_len) {
      return Failure<int>(
        MakeError(ErrorCode::kVerbsError,
                  "configured GID index does not match netdev"));
    }
    if (!matches(index)) {
      if (last_query_status != 0) {
        return Failure<int>(VerbsError("ibv_query_gid_ex", last_query_status));
      }
      return Failure<int>(
        MakeError(ErrorCode::kVerbsError,
                  "configured GID index does not match netdev"));
    }
    return index;
  }

  for (int index = 0; index < port.gid_tbl_len; ++index) {
    if (matches(index)) {
      return index;
    }
  }

  if (successful_queries == 0 && last_query_status != 0) {
    return Failure<int>(VerbsError("ibv_query_gid_ex", last_query_status));
  }

  return Failure<int>(MakeError(ErrorCode::kVerbsError,
                                "no RoCEv2 GID matches the selected netdev"));
}

[[nodiscard]] int ModifyInit(ibv_qp *qp, std::uint8_t port) noexcept {
  // INIT 阶段只开放 FPGA 所需的 REMOTE_WRITE 权限。
  ibv_qp_attr attr{};
  attr.qp_state = IBV_QPS_INIT;
  attr.pkey_index = 0;
  attr.port_num = port;
  attr.qp_access_flags = IBV_ACCESS_REMOTE_WRITE;
  constexpr int kAttributeMask =
    IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS;
  return ibv_modify_qp(qp, &attr, kAttributeMask);
}

[[nodiscard]] int ModifyRtr(ibv_qp *qp, std::uint8_t port, int gid_index,
                            const ibv_gid &remote_gid,
                            std::uint32_t remote_psn) noexcept {
  // RTR 固定连接 FPGA QPN 1，并使用协商的 FPGA 发送 PSN。
  ibv_qp_attr attr{};
  attr.qp_state = IBV_QPS_RTR;
  attr.path_mtu = IBV_MTU_4096;
  attr.dest_qp_num = protocol::kFpgaQpn;
  attr.rq_psn = remote_psn;
  attr.max_dest_rd_atomic = 1;
  attr.min_rnr_timer = 12;
  attr.ah_attr.is_global = 1;
  attr.ah_attr.port_num = port;
  attr.ah_attr.grh.dgid = remote_gid;
  attr.ah_attr.grh.sgid_index = gid_index;
  attr.ah_attr.grh.hop_limit = 1;
  constexpr int kAttributeMask =
    IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN
    | IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER;
  return ibv_modify_qp(qp, &attr, kAttributeMask);
}

[[nodiscard]] int ModifyRts(ibv_qp *qp, std::uint32_t local_psn) noexcept {
  // RTS 配置 host 发送 PSN 与 RC 重试参数；host 仅发送协议必要流量。
  ibv_qp_attr attr{};
  attr.qp_state = IBV_QPS_RTS;
  attr.sq_psn = local_psn;
  attr.timeout = 20;
  attr.retry_cnt = 7;
  attr.rnr_retry = 7;
  attr.max_rd_atomic = 1;
  constexpr int kAttributeMask = IBV_QP_STATE | IBV_QP_TIMEOUT
                                 | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY
                                 | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC;
  return ibv_modify_qp(qp, &attr, kAttributeMask);
}

[[nodiscard]] Outcome<in_addr> ParseIpv4(const std::string &text) noexcept {
  // 将 FPGA/host IPv4 文本解析为网络字节序地址。
  in_addr address{};
  if (::inet_pton(AF_INET, text.c_str(), &address) != 1) {
    return Failure<in_addr>(
      MakeError(ErrorCode::kInvalidConfiguration, "invalid IPv4 address"));
  }
  return address;
}

[[nodiscard]] std::uint64_t FallbackRandomValue() noexcept {
  // getrandom 不可用时用时钟、PID 和原子序列混合，仍保证进程内不易重复。
  constexpr std::uint64_t kIncrement{0x9e3779b97f4a7c15ULL};
  static std::atomic<std::uint64_t> sequence{1U};
  auto value =
    static_cast<std::uint64_t>(
      std::chrono::steady_clock::now().time_since_epoch().count())
    ^ (static_cast<std::uint64_t>(::getpid()) << 32U) ^ sequence.fetch_add(kIncrement, std::memory_order_relaxed);
  value = (value ^ (value >> 30U)) * 0xbf58476d1ce4e5b9ULL;
  value = (value ^ (value >> 27U)) * 0x94d049bb133111ebULL;
  return value ^ (value >> 31U);
}

} // namespace

Outcome<NetdevInfo> QueryNetdev(const NetworkConfig &config) noexcept {
  // 先确认 netdev 的 IPv4、掩码、MTU 和 up 状态，再据此选择 RoCE GID，
  // 防止控制面和 RDMA 数据面走到不同的端口。
  UniqueFd socket_fd{::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)};
  if (socket_fd.Get() < 0) {
    return Failure<NetdevInfo>(SystemError("socket"));
  }
  if (::if_nametoindex(config.netdev_name.c_str()) == 0U) {
    return Failure<NetdevInfo>(MakeError(ErrorCode::kInvalidConfiguration,
                                         "configured netdev does not exist"));
  }

  NetdevInfo info{};
  auto request = InterfaceRequest(config.netdev_name);
  if (!QueryInterface(socket_fd.Get(), SIOCGIFADDR, request) || request.ifr_addr.sa_family != AF_INET) {
    return Failure<NetdevInfo>(SystemError("SIOCGIFADDR"));
  }
  info.ipv4 = reinterpret_cast<sockaddr_in *>(&request.ifr_addr)->sin_addr;
  if (!QueryInterface(socket_fd.Get(), SIOCGIFNETMASK, request)) {
    return Failure<NetdevInfo>(SystemError("SIOCGIFNETMASK"));
  }
  info.netmask =
    reinterpret_cast<sockaddr_in *>(&request.ifr_netmask)->sin_addr;
  if (!QueryInterface(socket_fd.Get(), SIOCGIFHWADDR, request)) {
    return Failure<NetdevInfo>(SystemError("SIOCGIFHWADDR"));
  }
  std::memcpy(info.mac.data(), request.ifr_hwaddr.sa_data, info.mac.size());
  if (!QueryInterface(socket_fd.Get(), SIOCGIFMTU, request)) {
    return Failure<NetdevInfo>(SystemError("SIOCGIFMTU"));
  }
  info.mtu = request.ifr_mtu;
  if (!QueryInterface(socket_fd.Get(), SIOCGIFFLAGS, request)) {
    return Failure<NetdevInfo>(SystemError("SIOCGIFFLAGS"));
  }
  if (config.validate_netdev && ((request.ifr_flags & IFF_UP) == 0 || info.mtu < static_cast<int>(config.minimum_mtu))) {
    return Failure<NetdevInfo>(MakeError(ErrorCode::kInvalidConfiguration,
                                         "netdev is down or MTU is too small"));
  }
  info.ifindex = ::if_nametoindex(config.netdev_name.c_str());
  if (!config.local_ipv4.empty()) {
    const auto requested = ParseIpv4(config.local_ipv4);
    if (!requested) {
      return Failure<NetdevInfo>(requested.GetError());
    }
    if (config.validate_netdev && requested.Value().s_addr != info.ipv4.s_addr) {
      return Failure<NetdevInfo>(MakeError(ErrorCode::kInvalidConfiguration,
                                           "local IPv4 does not match netdev"));
    }
    info.ipv4 = requested.Value();
  }
  if (!config.required_netmask.empty()) {
    const auto requested = ParseIpv4(config.required_netmask);
    if (!requested) {
      return Failure<NetdevInfo>(
        MakeError(ErrorCode::kInvalidConfiguration,
                  "required netmask must be a valid IPv4 netmask"));
    }
    if (config.validate_netdev && requested.Value().s_addr != info.netmask.s_addr) {
      return Failure<NetdevInfo>(
        MakeError(ErrorCode::kInvalidConfiguration,
                  "netdev netmask does not match required_netmask"));
    }
  }
  return info;
}

Outcome<std::unique_ptr<VerbsResources>> VerbsResources::Create(const SessionOptions &config,
                                                                const NetdevInfo &netdev,
                                                                RingStorage &storage) noexcept {
  // 一次性建立 context/PD/MR/CQ/QP，并完成 INIT->RTR->RTS；Immediate 模式
  // 预先投递整个 RQ，普通轮询模式则不引入多余的 receive WR。
  if (config.verbs.max_send_wr <= 0 || config.verbs.completion_queue_slack < 0
      || (config.session.notification == NotificationMode::kWriteWithImm
          && config.session.receive_depth == 0U)) {
    return Failure<std::unique_ptr<VerbsResources>>(MakeError(
      ErrorCode::kInvalidConfiguration, "invalid verbs queue dimensions"));
  }
  auto context_result = OpenContext(config.network.device_name);
  if (!context_result) {
    return Failure<std::unique_ptr<VerbsResources>>(context_result.GetError());
  }
  auto result = std::unique_ptr<VerbsResources>(new (std::nothrow) VerbsResources{});
  if (!result) {
    return Failure<std::unique_ptr<VerbsResources>>(MakeError(
      ErrorCode::kAllocationFailed, "cannot allocate verbs resource handle"));
  }
  result->context_ = std::move(context_result.Value());
  const int async_flags = ::fcntl(result->context_->async_fd, F_GETFL, 0);
  if (async_flags < 0 || ::fcntl(result->context_->async_fd, F_SETFL, async_flags | O_NONBLOCK) < 0) {
    return Failure<std::unique_ptr<VerbsResources>>(
      SystemError("fcntl RDMA async event fd"));
  }
  const auto gid_result =
    ChooseGid(result->context_.get(), config.network, netdev,
              config.verbs.minimum_active_mtu_bytes, result->host_gid_);
  if (!gid_result) {
    return Failure<std::unique_ptr<VerbsResources>>(gid_result.GetError());
  }
  result->gid_index_ = gid_result.Value();

  result->protection_domain_.reset(ibv_alloc_pd(result->context_.get()));
  if (!result->protection_domain_) {
    return Failure<std::unique_ptr<VerbsResources>>(VerbsErrno("ibv_alloc_pd"));
  }
  const auto memlock = CheckMemlockLimit(storage.Storage().size());
  if (!memlock) {
    return Failure<std::unique_ptr<VerbsResources>>(memlock.GetError());
  }
  result->memory_region_.reset(
    ibv_reg_mr(result->protection_domain_.get(), storage.Storage().data(),
               storage.Storage().size(),
               IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE));
  if (!result->memory_region_) {
    return Failure<std::unique_ptr<VerbsResources>>(VerbsErrno("ibv_reg_mr"));
  }

  const auto receive_wr =
    config.session.notification == NotificationMode::kWriteWithImm ? config.session.receive_depth : 1U;
  const auto cq_depth =
    static_cast<std::uint64_t>(receive_wr) + static_cast<std::uint64_t>(config.verbs.completion_queue_slack);
  if (cq_depth > static_cast<std::uint64_t>(std::numeric_limits<int>::max())) {
    return Failure<std::unique_ptr<VerbsResources>>(MakeError(
      ErrorCode::kInvalidConfiguration, "completion queue is too large"));
  }
  result->completion_queue_.reset(ibv_create_cq(
    result->context_.get(), static_cast<int>(cq_depth), nullptr, nullptr, 0));
  if (!result->completion_queue_) {
    return Failure<std::unique_ptr<VerbsResources>>(
      VerbsErrno("ibv_create_cq"));
  }

  ibv_qp_init_attr qp_attributes{};
  qp_attributes.send_cq = result->completion_queue_.get();
  qp_attributes.recv_cq = result->completion_queue_.get();
  qp_attributes.qp_type = IBV_QPT_RC;
  qp_attributes.cap.max_send_wr = config.verbs.max_send_wr;
  qp_attributes.cap.max_recv_wr =
    config.session.notification == NotificationMode::kWriteWithImm ? config.session.receive_depth : 1U;
  qp_attributes.cap.max_send_sge = 1;
  qp_attributes.cap.max_recv_sge = 1;
  result->queue_pair_.reset(
    ibv_create_qp(result->protection_domain_.get(), &qp_attributes));
  if (!result->queue_pair_) {
    return Failure<std::unique_ptr<VerbsResources>>(
      VerbsErrno("ibv_create_qp"));
  }
  if (config.session.notification == NotificationMode::kWriteWithImm
      && qp_attributes.cap.max_recv_wr < config.session.receive_depth) {
    return Failure<std::unique_ptr<VerbsResources>>(MakeError(
      ErrorCode::kVerbsError,
      "provider returned fewer receive WRs than immediate mode requires"));
  }
  result->commit_ = storage.Commit();

  try {
    result->receive_wrs_.resize(config.polling.completion_batch);
    result->receive_sges_.resize(config.polling.completion_batch);
  } catch (const std::exception &) {
    return Failure<std::unique_ptr<VerbsResources>>(
      MakeError(ErrorCode::kAllocationFailed,
                "cannot allocate batched receive descriptors"));
  }

  if (config.session.notification == NotificationMode::kWriteWithImm) {
    for (std::uint32_t id = 0; id < config.session.receive_depth; ++id) {
      const auto posted = result->PostReceive(id);
      if (!posted) {
        return Failure<std::unique_ptr<VerbsResources>>(posted.GetError());
      }
    }
  }

  auto remote_gid_result = ParseIpv4(config.network.fpga_ipv4);
  if (!remote_gid_result) {
    return Failure<std::unique_ptr<VerbsResources>>(
      remote_gid_result.GetError());
  }
  ibv_gid remote_gid{};
  remote_gid.raw[10] = 0xffU;
  remote_gid.raw[11] = 0xffU;
  std::memcpy(remote_gid.raw + 12U, &remote_gid_result.Value().s_addr,
              sizeof(remote_gid_result.Value().s_addr));
  result->fpga_tx_psn_ = config.verbs.fpga_tx_psn.value_or(RandomNonzeroPsn());
  const auto host_tx_psn = config.verbs.host_tx_psn.value_or(RandomNonzeroPsn());
  if (result->fpga_tx_psn_ == 0U || host_tx_psn == 0U) {
    return Failure<std::unique_ptr<VerbsResources>>(
      MakeError(ErrorCode::kInvalidConfiguration,
                "QP packet sequence numbers must be non-zero"));
  }
  const int init_status = ModifyInit(result->queue_pair_.get(), config.network.rdma_port);
  if (init_status != 0) {
    return Failure<std::unique_ptr<VerbsResources>>(
      VerbsError("ibv_modify_qp INIT", init_status));
  }
  const int rtr_status = ModifyRtr(result->queue_pair_.get(), config.network.rdma_port,
                                   result->gid_index_, remote_gid, result->fpga_tx_psn_);
  if (rtr_status != 0) {
    return Failure<std::unique_ptr<VerbsResources>>(
      VerbsError("ibv_modify_qp RTR", rtr_status));
  }
  const int rts_status = ModifyRts(result->queue_pair_.get(), host_tx_psn);
  if (rts_status != 0) {
    return Failure<std::unique_ptr<VerbsResources>>(
      VerbsError("ibv_modify_qp RTS", rts_status));
  }
  return result;
}

Outcome<void> VerbsResources::PostReceive(std::uint64_t work_request_id) noexcept {
  // 初始 RQ 填充复用批量接口，使单个和批量投递具有相同布局。
  ibv_wc completion{};
  completion.wr_id = work_request_id;
  return PostReceives(std::span<const ibv_wc>{&completion, 1U});
}

bool BuildReceiveChain(std::span<ibv_recv_wr> receive_wrs,
                       std::span<ibv_sge> receive_sges,
                       std::span<const ibv_wc> completions,
                       std::uintptr_t receive_address,
                       std::uint32_t receive_bytes,
                       std::uint32_t local_key) noexcept {
  // 将一批 CQE 链成一次 ibv_post_recv，减少 immediate 模式的 verbs 调用
  // 次数；每个 RQE 都指向同一个 64 字节 commit slot。
  if (completions.size() > receive_wrs.size() || completions.size() > receive_sges.size()) {
    return false;
  }
  for (std::size_t index{}; index < completions.size(); ++index) {
    auto &sge = receive_sges[index];
    sge.addr = receive_address;
    sge.length = receive_bytes;
    sge.lkey = local_key;
    auto &wr = receive_wrs[index];
    wr = {};
    wr.wr_id = completions[index].wr_id;
    wr.sg_list = &sge;
    wr.num_sge = 1;
    wr.next = index + 1U < completions.size() ? &receive_wrs[index + 1U] : nullptr;
  }
  return true;
}

Outcome<void> PostReceiveBatch(ibv_qp *queue_pair,
                               std::span<ibv_recv_wr> receive_wrs,
                               void *context,
                               PostReceiveFunction post_receive) noexcept {
  // 空 batch 无需调用 verbs；非空 batch 必须从链首一次提交。
  if (receive_wrs.empty()) {
    return {};
  }
  if (queue_pair == nullptr || post_receive == nullptr) {
    return Outcome<void>{MakeError(ErrorCode::kInternalError,
                                   "receive batch has no QP or post function")};
  }
  ibv_recv_wr *bad_work_request{};
  const int status =
    post_receive(context, queue_pair, receive_wrs.data(), &bad_work_request);
  if (status != 0) {
    return Outcome<void>{VerbsError("ibv_post_recv", status)};
  }
  return {};
}

Outcome<void> VerbsResources::PostReceives(std::span<const ibv_wc> completions) noexcept {
  // 批量补充已消费的 RQE，确保 FPGA 的 WRITE_WITH_IMM 通知不会因 RQ
  // 短暂耗尽而丢失。
  if (completions.empty()) {
    return {};
  }
  if (!BuildReceiveChain(receive_wrs_, receive_sges_, completions,
                         reinterpret_cast<std::uintptr_t>(commit_),
                         commit_bytes_, memory_region_->lkey)) {
    return Outcome<void>{MakeError(
      ErrorCode::kInternalError,
      "receive completion batch exceeds preallocated descriptor capacity")};
  }

  return PostReceiveBatch(
    queue_pair_.get(),
    std::span<ibv_recv_wr>{receive_wrs_.data(), completions.size()}, nullptr,
    PostReceiveVerbs);
}

Outcome<std::size_t> VerbsResources::PollCompletions(
  std::span<ibv_wc> completions) const noexcept {
  // 一次 poll 多个 completion；调用方只在 housekeeping/通知路径处理 CQ，
  // commit polling 本身不进入系统调用。
  if (completions.empty()) {
    return 0U;
  }
  const auto count =
    ibv_poll_cq(completion_queue_.get(), static_cast<int>(completions.size()),
                completions.data());
  if (count < 0) {
    const int error_number = errno;
    return Failure<std::size_t>(VerbsError("ibv_poll_cq", count, error_number));
  }
  return static_cast<std::size_t>(count);
}

Outcome<void> VerbsResources::PollAsyncEvent() const noexcept {
  // async fd 已设为 nonblocking，只在 housekeeping 周期读取一个事件。
  pollfd descriptor{};
  descriptor.fd = context_->async_fd;
  descriptor.events = POLLIN;
  const auto poll_result = ::poll(&descriptor, 1, 0);
  if (poll_result == 0) {
    return {};
  }

  if (poll_result < 0) {
    if (errno == EINTR) {
      return {};
    }
    return Outcome<void>{SystemError("poll RDMA async event fd")};
  }

  if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
    return Outcome<void>{MakeError(ErrorCode::kVerbsError,
                                   "RDMA async event fd reported an error")};
  }

  if ((descriptor.revents & POLLIN) == 0) {
    return {};
  }

  ibv_async_event event{};
  const int status = ibv_get_async_event(context_.get(), &event);
  if (status != 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      return {};
    }
    return Outcome<void>{VerbsError("ibv_get_async_event", status, errno)};
  }

  Error error = MakeError(ErrorCode::kVerbsError,
                          std::string{"RDMA asynchronous event: "} + ibv_event_type_str(event.event_type));
  error.verbs_status = static_cast<int>(event.event_type);
  ibv_ack_async_event(&event);

  return Outcome<void>{std::move(error)};
}

void ContextDeleter::operator()(ibv_context *value) const noexcept {
  // RAII 清理顺序由 VerbsResources 成员逆序析构保证。
  if (value != nullptr) {
    (void)ibv_close_device(value);
  }
}

void ProtectionDomainDeleter::operator()(ibv_pd *value) const noexcept {
  if (value != nullptr) {
    (void)ibv_dealloc_pd(value);
  }
}

void CompletionQueueDeleter::operator()(ibv_cq *value) const noexcept {
  if (value != nullptr) {
    (void)ibv_destroy_cq(value);
  }
}

void QueuePairDeleter::operator()(ibv_qp *value) const noexcept {
  if (value != nullptr) {
    (void)ibv_destroy_qp(value);
  }
}

void MemoryRegionDeleter::operator()(ibv_mr *value) const noexcept {
  if (value != nullptr) {
    (void)ibv_dereg_mr(value);
  }
}

std::uint64_t RandomNonzeroU64() noexcept {
  // 优先使用内核随机源；读取失败或返回零时使用进程内 fallback。
  std::uint64_t value{};
  ssize_t received{};
  do {
    received = ::getrandom(&value, sizeof(value), 0);
  } while (received < 0 && errno == EINTR);

  if (received != static_cast<ssize_t>(sizeof(value)) || value == 0U) {
    do {
      value = FallbackRandomValue();
    } while (value == 0U);
  }
  return value;
}

std::uint32_t RandomNonzeroU32() noexcept {
  // 截断 64 位随机数并排除协议保留的零值。
  std::uint32_t value{};
  do {
    value = static_cast<std::uint32_t>(RandomNonzeroU64());
  } while (value == 0U);

  return value;
}

std::uint32_t RandomNonzeroPsn() noexcept {
  // RC PSN 为 24 位且不能为零。
  std::uint32_t value{};
  do {
    value = RandomNonzeroU32() & 0x00ffffffU;
  } while (value == 0U);

  return value;
}

} // namespace rrdma::detail
