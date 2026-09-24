#ifndef RRDMA_SRC_DETAIL_HPP_
#define RRDMA_SRC_DETAIL_HPP_

#include <infiniband/verbs.h>
#include <netinet/in.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <vector>

#include "rrdma/session.hpp"

namespace rrdma::detail {

// 在建立任何系统资源前执行所有本地配置约束检查。
[[nodiscard]] Outcome<void> ValidateConfig(const SessionOptions &config);

// FPGA 写入的 64 字节 commit record。字段偏移由 static_assert 锁定，
// producer_sequence 位于末尾用于 seqlock 发布。
struct alignas(kCommitBytes) CommitRecord {
  std::uint64_t published_bytes;
  std::uint32_t ring_end_offset;
  std::uint32_t interval_bytes;
  std::uint32_t final;
  std::uint32_t magic;
  std::array<std::byte, 16> reserved_before_sequence;
  std::uint64_t producer_sequence;
  std::array<std::byte, 16> reserved_after_sequence;
};

static_assert(sizeof(CommitRecord) == kCommitBytes);
static_assert(offsetof(CommitRecord, producer_sequence) == 40U);

struct NetdevInfo {
  // 从 ioctl 查询出的 netdev 属性，用于 UDP 绑定和 GID 选择。
  in_addr ipv4{};
  in_addr netmask{};
  std::array<std::uint8_t, 6> mac{};
  int mtu{};
  unsigned int ifindex{};
};

class RingStorage {
 public:
  // 建立 RDMA 主映射，并把同一 ring 物理页连续映射两次供 callback 读取。
  static Outcome<std::unique_ptr<RingStorage>> Create(
    const MemoryConfig &config, std::uint64_t ring_bytes) noexcept;
  ~RingStorage();

  RingStorage(const RingStorage &) = delete;
  RingStorage &operator=(const RingStorage &) = delete;

  [[nodiscard]] std::span<std::byte> Storage() noexcept {
    // 返回包含 commit slot 的可写 MR 区间。
    return {registered_data_, registered_size_};
  }
  [[nodiscard]] std::span<const std::byte> Storage() const noexcept {
    return {registered_data_, registered_size_};
  }
  [[nodiscard]] std::span<std::byte> Ring() noexcept {
    // 只返回数据 ring，不包含末尾 commit slot。
    return {registered_data_, ring_bytes_};
  }
  [[nodiscard]] std::span<const std::byte> Ring() const noexcept {
    return {registered_data_, ring_bytes_};
  }
  [[nodiscard]] std::span<const std::byte> MirroredRing() const noexcept {
    // 同一物理 ring 的双映射窗口，长度固定为 2 * ring_bytes。
    return {mirrored_data_, mirrored_size_};
  }
  [[nodiscard]] volatile CommitRecord *Commit() noexcept {
    // 返回 FPGA 直接写入的 volatile commit 地址。
    return reinterpret_cast<volatile CommitRecord *>(registered_data_ + ring_bytes_);
  }
  [[nodiscard]] std::uintptr_t Address() const noexcept {
    // 获取注册 MR 的 host 虚拟地址，作为 RDCP remote_base。
    return reinterpret_cast<std::uintptr_t>(registered_data_);
  }
  [[nodiscard]] std::uintptr_t CommitAddress() const noexcept {
    // commit 地址自动位于 ring 末尾，不能由应用单独指定。
    return Address() + ring_bytes_;
  }

 private:
  RingStorage(std::byte *registered_data, std::size_t registered_size,
              std::size_t registered_mapping_size,
              std::byte *mirrored_data, std::size_t mirrored_size,
              std::uint64_t ring_bytes) noexcept
   : registered_data_(registered_data),
     registered_size_(registered_size),
     registered_mapping_size_(registered_mapping_size),
     mirrored_data_(mirrored_data),
     mirrored_size_(mirrored_size),
     ring_bytes_(ring_bytes) {
  }

  std::byte *registered_data_{};
  // registered_size_ 是协议/MR 可见的 ring+commit 逻辑长度；实际 mmap
  // 必须按页取整，因此由 registered_mapping_size_ 单独负责 munmap。
  std::size_t registered_size_{};
  std::size_t registered_mapping_size_{};
  std::byte *mirrored_data_{};
  std::size_t mirrored_size_{};
  std::uint64_t ring_bytes_{};
};

enum class CommitDisposition : std::uint8_t {
  // 新 sequence 尚未变化、合法可交付或检测到协议异常。
  kUnchanged,
  kReady,
  kInvalid,
};

[[nodiscard]] bool ReadCommit(const volatile CommitRecord *record,
                              CommitMetadata &metadata) noexcept;
[[nodiscard]] std::uint64_t ReadCommitSequence(
  const volatile CommitRecord *record) noexcept;
[[nodiscard]] Outcome<CommitBatch> MakeBatch(
  std::span<const std::byte> mirrored_ring, std::uint64_t ring_bytes,
  std::uint64_t scanned_bytes, std::uint64_t released_bytes,
  const CommitMetadata &metadata) noexcept;
[[nodiscard]] bool ValidInterval(const CommitMetadata &metadata,
                                 std::uint32_t maximum_interval) noexcept;
[[nodiscard]] CommitDisposition ClassifyCommit(
  const CommitMetadata &previous, const CommitMetadata &current,
  std::uint32_t maximum_interval) noexcept;

struct ContextDeleter {
  // unique_ptr 的 verbs RAII 删除器，保证异常路径按依赖逆序释放。
  void operator()(ibv_context *value) const noexcept;
};
struct ProtectionDomainDeleter {
  void operator()(ibv_pd *value) const noexcept;
};
struct CompletionQueueDeleter {
  void operator()(ibv_cq *value) const noexcept;
};
struct QueuePairDeleter {
  void operator()(ibv_qp *value) const noexcept;
};
struct MemoryRegionDeleter {
  void operator()(ibv_mr *value) const noexcept;
};

using ContextPtr = std::unique_ptr<ibv_context, ContextDeleter>;
using ProtectionDomainPtr = std::unique_ptr<ibv_pd, ProtectionDomainDeleter>;
using CompletionQueuePtr = std::unique_ptr<ibv_cq, CompletionQueueDeleter>;
using QueuePairPtr = std::unique_ptr<ibv_qp, QueuePairDeleter>;
using MemoryRegionPtr = std::unique_ptr<ibv_mr, MemoryRegionDeleter>;

class VerbsResources {
 public:
  VerbsResources() noexcept = default;
  // 建立 context/PD/MR/CQ/QP 并将 QP 迁移到 RTS。
  static Outcome<std::unique_ptr<VerbsResources>> Create(
    const SessionOptions &config, const NetdevInfo &netdev,
    RingStorage &storage) noexcept;
  ~VerbsResources() = default;

  VerbsResources(const VerbsResources &) = delete;
  VerbsResources &operator=(const VerbsResources &) = delete;

  // 以下访问器只暴露底层句柄，不转移资源所有权。
  [[nodiscard]] ibv_context *Context() const noexcept {
    return context_.get();
  }
  [[nodiscard]] ibv_pd *ProtectionDomain() const noexcept {
    return protection_domain_.get();
  }
  [[nodiscard]] ibv_cq *CompletionQueue() const noexcept {
    return completion_queue_.get();
  }
  [[nodiscard]] ibv_qp *QueuePair() const noexcept {
    return queue_pair_.get();
  }
  [[nodiscard]] ibv_mr *MemoryRegion() const noexcept {
    return memory_region_.get();
  }
  [[nodiscard]] int GidIndex() const noexcept {
    return gid_index_;
  }
  [[nodiscard]] const ibv_gid &HostGid() const noexcept {
    return host_gid_;
  }
  [[nodiscard]] std::uint32_t Qpn() const noexcept {
    return queue_pair_ == nullptr ? 0U : queue_pair_->qp_num;
  }
  [[nodiscard]] std::uint32_t FpgaTxPsn() const noexcept {
    return fpga_tx_psn_;
  }

  [[nodiscard]] Outcome<void> PostReceive(
    std::uint64_t work_request_id) noexcept;
  [[nodiscard]] Outcome<void> PostReceives(
    std::span<const ibv_wc> completions) noexcept;
  [[nodiscard]] Outcome<void> PollAsyncEvent() const noexcept;
  [[nodiscard]] Outcome<std::size_t> PollCompletions(
    std::span<ibv_wc> completions) const noexcept;

 private:
  ContextPtr context_;
  ProtectionDomainPtr protection_domain_;
  MemoryRegionPtr memory_region_;
  CompletionQueuePtr completion_queue_;
  QueuePairPtr queue_pair_;
  int gid_index_{-1};
  ibv_gid host_gid_{};
  std::uint32_t fpga_tx_psn_{};
  std::uint32_t commit_bytes_{static_cast<std::uint32_t>(kCommitBytes)};
  volatile CommitRecord *commit_{};
  std::vector<ibv_recv_wr> receive_wrs_;
  std::vector<ibv_sge> receive_sges_;
};

[[nodiscard]] Outcome<NetdevInfo> QueryNetdev(
  const NetworkConfig &config) noexcept;
// 生成非零随机 session/transaction/PSN，避免复用旧 session。
[[nodiscard]] std::uint64_t RandomNonzeroU64() noexcept;
[[nodiscard]] std::uint32_t RandomNonzeroU32() noexcept;
[[nodiscard]] std::uint32_t RandomNonzeroPsn() noexcept;

[[nodiscard]] bool BuildReceiveChain(std::span<ibv_recv_wr> receive_wrs,
                                     std::span<ibv_sge> receive_sges,
                                     std::span<const ibv_wc> completions,
                                     std::uintptr_t receive_address,
                                     std::uint32_t receive_bytes,
                                     std::uint32_t local_key) noexcept;

using PostReceiveFunction = int (*)(void *context, ibv_qp *queue_pair,
                                    ibv_recv_wr *first_work_request,
                                    ibv_recv_wr **bad_work_request) noexcept;

// 提交一条已经链接完成的 receive WR 链；显式函数入口便于无 HCA 单元测试
// 验证 Immediate 批量 repost 的调用次数、链首和错误传播。
[[nodiscard]] Outcome<void> PostReceiveBatch(
  ibv_qp *queue_pair, std::span<ibv_recv_wr> receive_wrs, void *context,
  PostReceiveFunction post_receive) noexcept;

} // namespace rrdma::detail

#endif // RRDMA_SRC_DETAIL_HPP_
