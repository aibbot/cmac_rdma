#include <fcntl.h>
#include <linux/magic.h>
#include <linux/memfd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <bit>
#include <cerrno>
#include <cstring>
#include <limits>
#include <new>
#include <utility>

#include "detail.hpp"
#include "unique_fd.hpp"

namespace rrdma::detail {
namespace {

constexpr std::uint32_t kCommitMagic{0x52444d41U};

// Create() 失败时自动撤销部分映射，成功后由 RingStorage 接管。
class ScopedMapping {
 public:
  ScopedMapping() noexcept = default;
  ScopedMapping(void *address, std::size_t size) noexcept
   : address_(address), size_(size) {
  }
  ~ScopedMapping() {
    if (address_ != MAP_FAILED) {
      (void)::munmap(address_, size_);
    }
  }

  ScopedMapping(const ScopedMapping &) = delete;
  ScopedMapping &operator=(const ScopedMapping &) = delete;
  ScopedMapping(ScopedMapping &&other) noexcept
   : address_(std::exchange(other.address_, MAP_FAILED)),
     size_(std::exchange(other.size_, 0U)) {
  }
  ScopedMapping &operator=(ScopedMapping &&other) noexcept {
    if (this != &other) {
      if (address_ != MAP_FAILED) {
        (void)::munmap(address_, size_);
      }
      address_ = std::exchange(other.address_, MAP_FAILED);
      size_ = std::exchange(other.size_, 0U);
    }
    return *this;
  }

  [[nodiscard]] void *Get() const noexcept {
    return address_;
  }
  [[nodiscard]] void *Release() noexcept {
    void *address = address_;
    address_ = MAP_FAILED;
    size_ = 0U;
    return address;
  }

 private:
  void *address_{MAP_FAILED};
  std::size_t size_{};
};

// 区分协议/MR 可见长度与实际文件和 mmap 长度。commit 固定紧随 ring，
// 但它只占 64 字节，因此 hugetlb 后备需要额外取整到下一张大页。
struct RingMappingGeometry {
  std::size_t ring_bytes{};
  std::size_t registered_bytes{};
  std::size_t registered_mapping_bytes{};
  std::size_t mirrored_bytes{};
  std::size_t mirrored_reservation_bytes{};
  std::size_t mapping_page_bytes{};
  off_t backing_offset{};
};

// 给 ring 分配/边界错误附加统一的错误类别和 errno。
[[nodiscard]] Error StorageError(ErrorCode code, std::string message,
                                 int error_number = 0) {
  return MakeError(code, std::move(message), error_number);
}

// 按任意正页大小向上取整，同时显式检查 size_t 加法溢出。
[[nodiscard]] bool AlignSizeUp(std::size_t value, std::size_t alignment,
                               std::size_t &aligned_value) noexcept {
  if (alignment == 0U) {
    return false;
  }
  const auto remainder = value % alignment;
  const auto padding = remainder == 0U ? 0U : alignment - remainder;
  if (value > std::numeric_limits<std::size_t>::max() - padding) {
    return false;
  }
  aligned_value = value + padding;
  return true;
}

// 在执行任何文件或 mmap 系统调用前完成所有尺寸、偏移和对齐计算。
[[nodiscard]] Outcome<RingMappingGeometry> BuildRingMappingGeometry(
  const MemoryConfig &config, std::uint64_t ring_bytes) noexcept {
  const long system_page_size = ::sysconf(_SC_PAGESIZE);
  if (system_page_size <= 0) {
    return Failure<RingMappingGeometry>(StorageError(
      ErrorCode::kSystemError, "cannot query the system page size", errno));
  }
  const auto system_page_bytes = static_cast<std::uint64_t>(system_page_size);

  std::uint64_t mapping_page_bytes{};
  switch (config.page_mode) {
  case MemoryPageMode::kHugeTlb:
    if (config.huge_page_bytes < system_page_bytes
        || !std::has_single_bit(config.huge_page_bytes)
        || config.huge_page_bytes % system_page_bytes != 0U) {
      return Failure<RingMappingGeometry>(StorageError(
        ErrorCode::kInvalidConfiguration,
        "hugetlb page size is not compatible with the system page size"));
    }
    mapping_page_bytes = config.huge_page_bytes;
    break;
  case MemoryPageMode::kRegular:
    mapping_page_bytes = system_page_bytes;
    break;
  default:
    return Failure<RingMappingGeometry>(StorageError(
      ErrorCode::kInvalidConfiguration, "memory page mode is invalid"));
  }

  if (ring_bytes == 0U || ring_bytes % kPacketBytes != 0U
      || ring_bytes % mapping_page_bytes != 0U
      || config.backing_offset_bytes % mapping_page_bytes != 0U
      || ring_bytes > std::numeric_limits<std::size_t>::max() - kCommitBytes
      || ring_bytes > std::numeric_limits<std::size_t>::max() / 2U
      || mapping_page_bytes > std::numeric_limits<std::size_t>::max()) {
    return Failure<RingMappingGeometry>(StorageError(
      ErrorCode::kInvalidConfiguration,
      "ring size, page size or backing offset is not mmap compatible"));
  }

  RingMappingGeometry geometry{};
  geometry.ring_bytes = static_cast<std::size_t>(ring_bytes);
  geometry.registered_bytes = geometry.ring_bytes + kCommitBytes;
  geometry.mirrored_bytes = geometry.ring_bytes * 2U;
  geometry.mapping_page_bytes = static_cast<std::size_t>(mapping_page_bytes);
  if (config.page_mode == MemoryPageMode::kHugeTlb) {
    if (!AlignSizeUp(geometry.registered_bytes, geometry.mapping_page_bytes,
                     geometry.registered_mapping_bytes)) {
      return Failure<RingMappingGeometry>(StorageError(
        ErrorCode::kInvalidConfiguration,
        "aligned hugetlb ring mapping size overflows"));
    }
  } else {
    geometry.registered_mapping_bytes = geometry.registered_bytes;
  }
  if (geometry.mirrored_bytes > std::numeric_limits<std::size_t>::max()
                                  - geometry.mapping_page_bytes) {
    return Failure<RingMappingGeometry>(StorageError(
      ErrorCode::kInvalidConfiguration, "aligned ring mapping size overflows"));
  }
  geometry.mirrored_reservation_bytes =
    geometry.mirrored_bytes + geometry.mapping_page_bytes;

  const auto maximum_file_offset =
    static_cast<std::uint64_t>(std::numeric_limits<off_t>::max());
  if (config.backing_offset_bytes > maximum_file_offset
      || geometry.registered_mapping_bytes
           > maximum_file_offset - config.backing_offset_bytes) {
    return Failure<RingMappingGeometry>(StorageError(
      ErrorCode::kInvalidConfiguration,
      "aligned ring backing exceeds the off_t address range"));
  }
  geometry.backing_offset = static_cast<off_t>(config.backing_offset_bytes);
  return geometry;
}

// 把配置的大页尺寸编码到 memfd_create flags。页尺寸已经由 geometry
// 校验为非零 2 的幂，因此 countr_zero 就是 Linux 要求的 log2 编码。
[[nodiscard]] unsigned int BuildMemfdFlags(
  const MemoryConfig &config) noexcept {
  unsigned int flags{MFD_CLOEXEC};
  if (config.page_mode == MemoryPageMode::kHugeTlb) {
    const auto page_shift = std::countr_zero(config.huge_page_bytes);
    flags |= MFD_HUGETLB;
    flags |= static_cast<unsigned int>(page_shift) << MFD_HUGE_SHIFT;
  }
  return flags;
}

// 外部 FD 不能只依赖调用者声明为大页：同时校验 hugetlbfs magic 和实际
// f_bsize，防止普通 tmpfs/ext4 文件被误当成显式大页后备。
[[nodiscard]] Outcome<void> ValidateHugeTlbBacking(
  int backing_file, std::uint64_t expected_page_bytes) noexcept {
  struct statfs file_system_status{};
  if (::fstatfs(backing_file, &file_system_status) != 0) {
    return Outcome<void>{StorageError(
      ErrorCode::kSystemError, "cannot inspect ring backing filesystem", errno)};
  }
  if (static_cast<std::uint32_t>(file_system_status.f_type)
      != static_cast<std::uint32_t>(HUGETLBFS_MAGIC)) {
    return Outcome<void>{StorageError(
      ErrorCode::kInvalidConfiguration,
      "hugetlb mode requires a hugetlbfs or MFD_HUGETLB backing file")};
  }
  if (file_system_status.f_bsize <= 0
      || static_cast<std::uint64_t>(file_system_status.f_bsize)
           != expected_page_bytes) {
    return Outcome<void>{StorageError(
      ErrorCode::kInvalidConfiguration,
      "hugetlb backing page size does not match huge_page_bytes")};
  }
  return {};
}

// 先多预留一张映射页，再裁掉首尾空洞，得到满足 hugetlb MAP_FIXED 要求的
// 对齐虚拟地址。普通匿名 mmap 只保证基础页对齐，不能直接用于大页别名。
[[nodiscard]] Outcome<ScopedMapping> ReserveAlignedMapping(
  std::size_t mapping_bytes, std::size_t reservation_bytes,
  std::size_t alignment_bytes) noexcept {
  ScopedMapping reservation{
    ::mmap(nullptr, reservation_bytes, PROT_NONE,
           MAP_PRIVATE | MAP_ANONYMOUS, -1, 0),
    reservation_bytes};
  if (reservation.Get() == MAP_FAILED) {
    return Failure<ScopedMapping>(StorageError(
      ErrorCode::kAllocationFailed,
      "cannot reserve aligned mirrored ring address range", errno));
  }

  const auto raw_address =
    reinterpret_cast<std::uintptr_t>(reservation.Get());
  const auto remainder = raw_address % alignment_bytes;
  const auto prefix_bytes =
    remainder == 0U ? 0U : alignment_bytes - remainder;
  if (raw_address > std::numeric_limits<std::uintptr_t>::max() - prefix_bytes) {
    return Failure<ScopedMapping>(StorageError(
      ErrorCode::kAllocationFailed,
      "aligned mirrored ring address overflows uintptr_t"));
  }
  auto *const raw_base = static_cast<std::byte *>(reservation.Get());
  auto *const aligned_base = reinterpret_cast<std::byte *>(
    raw_address + prefix_bytes);
  const auto suffix_bytes = reservation_bytes - prefix_bytes - mapping_bytes;
  if ((prefix_bytes != 0U && ::munmap(raw_base, prefix_bytes) != 0)
      || (suffix_bytes != 0U
          && ::munmap(aligned_base + mapping_bytes, suffix_bytes) != 0)) {
    return Failure<ScopedMapping>(StorageError(
      ErrorCode::kSystemError,
      "cannot trim mirrored ring address reservation", errno));
  }
  (void)reservation.Release();
  return ScopedMapping{aligned_base, mapping_bytes};
}

// 用同一后备文件替换预留窗口的一半；调用两次后形成 [ring][ring]。
// 大页属性由已验证的 hugetlbfs/MFD_HUGETLB 文件决定，不依赖
// MAP_HUGETLB 或 MADV_HUGEPAGE 这类匿名/透明大页选择。
[[nodiscard]] Outcome<void> MapRingAlias(void *address,
                                         std::size_t ring_bytes,
                                         int backing_file,
                                         off_t backing_offset) noexcept {
  constexpr int kAliasMapFlags{MAP_SHARED | MAP_FIXED | MAP_POPULATE};
  if (::mmap(address, ring_bytes, PROT_READ | PROT_WRITE, kAliasMapFlags,
             backing_file, backing_offset)
      == MAP_FAILED) {
    return Outcome<void>{StorageError(
      ErrorCode::kAllocationFailed, "mmap mirrored ring alias failed", errno)};
  }
  return {};
}

// 从 FPGA little-endian commit slot 读取 32 位字段。
[[nodiscard]] std::uint32_t LoadLe32(const volatile std::byte *bytes) noexcept {
  return static_cast<std::uint32_t>(std::to_integer<unsigned char>(bytes[0]))
         | (static_cast<std::uint32_t>(std::to_integer<unsigned char>(bytes[1])) << 8U)
         | (static_cast<std::uint32_t>(std::to_integer<unsigned char>(bytes[2])) << 16U)
         | (static_cast<std::uint32_t>(std::to_integer<unsigned char>(bytes[3])) << 24U);
}

// 组合两个 little-endian 32 位字段读取绝对字节游标。
[[nodiscard]] std::uint64_t LoadLe64(const volatile std::byte *bytes) noexcept {
  return static_cast<std::uint64_t>(LoadLe32(bytes))
         | (static_cast<std::uint64_t>(LoadLe32(bytes + 4U)) << 32U);
}

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
// 仅在主机为大端时把原子加载值转换为 host order。
[[nodiscard]] std::uint64_t ByteSwap64(std::uint64_t value) noexcept {
  return ((value & 0x00000000000000ffULL) << 56U)
         | ((value & 0x000000000000ff00ULL) << 40U)
         | ((value & 0x0000000000ff0000ULL) << 24U)
         | ((value & 0x00000000ff000000ULL) << 8U)
         | ((value & 0x000000ff00000000ULL) >> 8U)
         | ((value & 0x0000ff0000000000ULL) >> 24U)
         | ((value & 0x00ff000000000000ULL) >> 40U)
         | ((value & 0xff00000000000000ULL) >> 56U);
}
#endif

[[nodiscard]] std::uint64_t LoadSequence(const volatile std::byte *bytes) noexcept {
  // sequence 必须以 acquire 原子读取，配合 FPGA 的 release 发布顺序。
  std::uint64_t value{};
  const auto *sequence =
    reinterpret_cast<const volatile std::uint64_t *>(bytes);
  __atomic_load(sequence, &value, __ATOMIC_ACQUIRE);
#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
  value = ByteSwap64(value);
#endif
  return value;
}

} // namespace

Outcome<std::unique_ptr<RingStorage>> RingStorage::Create(const MemoryConfig &config,
                                                          std::uint64_t ring_bytes) noexcept {
  // 主映射保持 wire protocol 要求的 [ring][commit] 连续地址；另建一个
  // [ring][ring] 双映射读取窗口，让任何不超过一圈的数据都能形成单 span。
  auto geometry_result = BuildRingMappingGeometry(config, ring_bytes);
  if (!geometry_result) {
    return Failure<std::unique_ptr<RingStorage>>(
      std::move(geometry_result.GetError()));
  }
  const auto geometry = geometry_result.Value();

  UniqueFd owned_file;
  int backing_file = config.backing_file_descriptor;
  if (backing_file < 0) {
    if (config.backing_offset_bytes != 0U) {
      return Failure<std::unique_ptr<RingStorage>>(
        StorageError(ErrorCode::kInvalidConfiguration,
                     "library-owned memfd requires a zero backing offset"));
    }
    const int created = static_cast<int>(::syscall(
      SYS_memfd_create, "rrdma-ring", BuildMemfdFlags(config)));
    if (created < 0) {
      return Failure<std::unique_ptr<RingStorage>>(StorageError(
        ErrorCode::kAllocationFailed,
        config.page_mode == MemoryPageMode::kHugeTlb ? "memfd_create(MFD_HUGETLB) failed" : "memfd_create failed",
        errno));
    }
    owned_file = UniqueFd(created);
    backing_file = owned_file.Get();
    if (::ftruncate(
          backing_file,
          static_cast<off_t>(geometry.registered_mapping_bytes))
        != 0) {
      return Failure<std::unique_ptr<RingStorage>>(
        StorageError(ErrorCode::kAllocationFailed,
                     "ftruncate ring backing failed", errno));
    }
  } else {
    struct stat file_status{};
    if (::fstat(backing_file, &file_status) != 0) {
      return Failure<std::unique_ptr<RingStorage>>(StorageError(
        ErrorCode::kSystemError, "cannot inspect ring backing file", errno));
    }
    const auto required_end = config.backing_offset_bytes
                              + geometry.registered_mapping_bytes;
    if (file_status.st_size < 0 || static_cast<std::uint64_t>(file_status.st_size) < required_end) {
      return Failure<std::unique_ptr<RingStorage>>(
        StorageError(ErrorCode::kInvalidConfiguration,
                     "ring backing file is smaller than the aligned mapping"));
    }
  }

  if (config.page_mode == MemoryPageMode::kHugeTlb) {
    auto backing_result =
      ValidateHugeTlbBacking(backing_file, config.huge_page_bytes);
    if (!backing_result) {
      return Failure<std::unique_ptr<RingStorage>>(
        std::move(backing_result.GetError()));
    }
    // hugetlbfs 的 ftruncate 只设置文件长度；posix_fallocate 在 mmap 和
    // commit 清零之前预留全部物理大页，使池不足以 errno 返回而非 SIGBUS。
    int allocation_error{};
    do {
      allocation_error = ::posix_fallocate(
        backing_file, geometry.backing_offset,
        static_cast<off_t>(geometry.registered_mapping_bytes));
    } while (allocation_error == EINTR);
    if (allocation_error != 0) {
      return Failure<std::unique_ptr<RingStorage>>(StorageError(
        ErrorCode::kAllocationFailed,
        "cannot reserve hugetlb pages for ring backing", allocation_error));
    }
  }

  // hugetlbfs/MFD_HUGETLB 文件本身决定映射页类型；MAP_POPULATE 只负责
  // 在 START 前建立页表，不承担透明大页升级或降级。
  ScopedMapping registered{
    ::mmap(nullptr, geometry.registered_mapping_bytes,
           PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, backing_file,
           geometry.backing_offset),
    geometry.registered_mapping_bytes};
  if (registered.Get() == MAP_FAILED) {
    const int error_number = errno;
    return Failure<std::unique_ptr<RingStorage>>(
      StorageError(ErrorCode::kAllocationFailed,
                   "mmap registered ring storage failed", error_number));
  }

  auto mirrored_result = ReserveAlignedMapping(
    geometry.mirrored_bytes, geometry.mirrored_reservation_bytes,
    geometry.mapping_page_bytes);
  if (!mirrored_result) {
    return Failure<std::unique_ptr<RingStorage>>(
      std::move(mirrored_result.GetError()));
  }
  auto mirrored = std::move(mirrored_result).Value();
  auto *mirrored_base = static_cast<std::byte *>(mirrored.Get());
  // callback 实际读取 mirrored window，而 ibv_reg_mr 只会锁定主映射。
  // MAP_POPULATE 在 START 前预建两段 alias 的页表，避免首次扫描 1 GiB
  // ring 时把逐页 minor fault 带入数据热路径。
  auto first_alias = MapRingAlias(mirrored_base, geometry.ring_bytes,
                                  backing_file, geometry.backing_offset);
  if (!first_alias) {
    return Failure<std::unique_ptr<RingStorage>>(
      std::move(first_alias.GetError()));
  }
  auto second_alias = MapRingAlias(mirrored_base + geometry.ring_bytes,
                                   geometry.ring_bytes, backing_file,
                                   geometry.backing_offset);
  if (!second_alias) {
    return Failure<std::unique_ptr<RingStorage>>(
      std::move(second_alias.GetError()));
  }

  auto *registered_base = static_cast<std::byte *>(registered.Get());
  auto result = std::unique_ptr<RingStorage>(new (std::nothrow) RingStorage(
    registered_base, geometry.registered_bytes,
    geometry.registered_mapping_bytes, mirrored_base, geometry.mirrored_bytes,
    ring_bytes));
  if (!result) {
    return Failure<std::unique_ptr<RingStorage>>(StorageError(
      ErrorCode::kAllocationFailed, "cannot allocate storage handle"));
  }
  (void)registered.Release();
  (void)mirrored.Release();
  // 只清零 64 字节 commit slot，不触碰可能由应用预置的数据 ring。
  std::memset(registered_base + ring_bytes, 0, kCommitBytes);
  return result;
}

RingStorage::~RingStorage() {
  // 双映射窗口和 RDMA 主映射均由库建立，因此统一在最后解除映射。
  if (mirrored_data_ != nullptr) {
    (void)::munmap(mirrored_data_, mirrored_size_);
  }
  if (registered_data_ != nullptr) {
    (void)::munmap(registered_data_, registered_mapping_size_);
  }
}

bool ReadCommit(const volatile CommitRecord *record,
                CommitMetadata &metadata) noexcept {
  // producer_sequence 是 seqlock：两次 acquire 读取一致时，前面的 RDMA
  // payload 与 commit 元数据才可作为一个原子发布批次交付给消费者。
  if (record == nullptr) {
    return false;
  }
  const auto *bytes = reinterpret_cast<const volatile std::byte *>(record);
  const auto first_sequence = LoadSequence(bytes + 40U);
  if (first_sequence == 0U) {
    return false;
  }
  std::atomic_thread_fence(std::memory_order_acquire);
  const auto published = LoadLe64(bytes);
  const auto ring_end = LoadLe32(bytes + 8U);
  const auto interval = LoadLe32(bytes + 12U);
  const auto final_flag = LoadLe32(bytes + 16U);
  const auto magic = LoadLe32(bytes + 20U);
  std::atomic_thread_fence(std::memory_order_acquire);
  const auto second_sequence = LoadSequence(bytes + 40U);
  if (first_sequence != second_sequence || magic != kCommitMagic) {
    return false;
  }
  metadata.sequence = second_sequence;
  metadata.published_bytes = published;
  metadata.ring_end_offset = ring_end;
  metadata.interval_bytes = interval;
  metadata.final = final_flag != 0U;
  return true;
}

std::uint64_t ReadCommitSequence(const volatile CommitRecord *record) noexcept {
  // 快速路径只读取 sequence，避免每次忙轮询解析其余字段。
  if (record == nullptr) {
    return 0U;
  }
  const auto *bytes = reinterpret_cast<const volatile std::byte *>(record);
  return LoadSequence(bytes + offsetof(CommitRecord, producer_sequence));
}

bool ValidInterval(const CommitMetadata &metadata,
                   std::uint32_t maximum_interval) noexcept {
  // 普通 commit 必须有非零、对齐且不超过协商上限的发布间隔；final 可为零。
  return maximum_interval != 0U && metadata.interval_bytes % kPacketBytes == 0U && metadata.interval_bytes <= maximum_interval && (metadata.final || metadata.interval_bytes != 0U);
}

CommitDisposition ClassifyCommit(const CommitMetadata &previous,
                                 const CommitMetadata &current,
                                 std::uint32_t maximum_interval) noexcept {
  // 比较相邻稳定快照，拒绝回退/跳变；允许一次轮询跨过多个物理 commit。
  if (current.sequence == previous.sequence) {
    return CommitDisposition::kUnchanged;
  }
  if (current.sequence == 0U || current.sequence < previous.sequence || current.published_bytes < previous.published_bytes || !ValidInterval(current, maximum_interval)) {
    return CommitDisposition::kInvalid;
  }
  const auto increment = current.published_bytes - previous.published_bytes;
  if (increment == 0U) {
    return current.final && current.interval_bytes == 0U ? CommitDisposition::kReady : CommitDisposition::kInvalid;
  }
  // STOP 可以紧跟在一次带数据 commit 之后发布 interval=0 的 final。
  // 若轮询线程只看到 final，published_bytes 的增量仍是尚未交付的合法数据，
  // 不能因为 final 自身没有新增 interval 而丢弃这段累计进度。
  const bool interval_matches_progress =
    current.interval_bytes == 0U ? current.final : current.interval_bytes <= increment;
  return increment % kPacketBytes == 0U && interval_matches_progress ? CommitDisposition::kReady : CommitDisposition::kInvalid;
}

Outcome<CommitBatch> MakeBatch(std::span<const std::byte> mirrored_ring,
                               std::uint64_t ring_bytes,
                               std::uint64_t scanned_bytes,
                               std::uint64_t released_bytes,
                               const CommitMetadata &metadata) noexcept {
  // mirrored_ring 是 [ring][ring] 的连续别名，因此跨尾部区间也能直接
  // subspan 成一个逻辑连续视图；released_bytes 仍负责零拷贝覆盖检测。
  if (ring_bytes == 0U || ring_bytes % kPacketBytes != 0U || ring_bytes > std::numeric_limits<std::size_t>::max() / 2U || mirrored_ring.size() != static_cast<std::size_t>(ring_bytes * 2U)) {
    return Failure<CommitBatch>(StorageError(
      ErrorCode::kProtocolError,
      "mirrored ring must contain exactly two aligned ring mappings"));
  }
  if (released_bytes > scanned_bytes || released_bytes % kPacketBytes != 0U || metadata.published_bytes < scanned_bytes || metadata.published_bytes % kPacketBytes != 0U || scanned_bytes % kPacketBytes != 0U || metadata.ring_end_offset >= ring_bytes || metadata.ring_end_offset != metadata.published_bytes % ring_bytes) {
    return Failure<CommitBatch>(
      StorageError(ErrorCode::kProtocolError,
                   "commit counters or ring offset are invalid"));
  }
  const auto protected_bytes = metadata.published_bytes - released_bytes;
  if (protected_bytes > ring_bytes) {
    auto error =
      StorageError(ErrorCode::kSessionFault,
                   "ring overrun: unreleased zero-copy data was overwritten");
    error.overrun_count = 1U;
    return Failure<CommitBatch>(std::move(error));
  }
  const auto unread = metadata.published_bytes - scanned_bytes;
  const auto begin_offset = scanned_bytes % ring_bytes;
  CommitBatch batch{};
  batch.commit = metadata;
  batch.data = mirrored_ring.subspan(static_cast<std::size_t>(begin_offset),
                                     static_cast<std::size_t>(unread));
  return batch;
}

} // namespace rrdma::detail
