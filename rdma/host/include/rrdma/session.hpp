#ifndef RRDMA_INCLUDE_RRDMA_SESSION_HPP_
#define RRDMA_INCLUDE_RRDMA_SESSION_HPP_

#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <stop_token>
#include <string>
#include <string_view>

#include "rrdma/protocol.hpp"
#include "rrdma/result.hpp"
#include "rrdma/transport.hpp"
#include "rrdma/types.hpp"

// 高层会话 API：一个 Session 对应一个 FPGA session、QP、MR 和 ring。
// 线程由库内部拆分为协调器、生产者和消费者，应用 callback 不阻塞 commit 轮询。
namespace rrdma {

// ring/commit 的物理布局常量，必须与 FPGA endpoint 的写入格式一致。
inline constexpr ByteCount kCommitBytes{64U};
inline constexpr ByteCount kPacketBytes{4096U};
inline constexpr ByteCount kDefaultRingBytes{1024ULL * 1024ULL * 1024ULL};
inline constexpr ByteCount kDefaultWrBytes{10U * 1024U * 1024U};
inline constexpr ByteCount kDefaultNotifyBytes{10U * 1024U * 1024U};
inline constexpr RemoteAddress kDefaultLocalBase{};
inline constexpr HostCount kDefaultReceiveDepth{1024U};
inline constexpr ByteCount kDefaultHugePageBytes{2ULL * 1024ULL * 1024ULL};

enum class NotificationMode : std::uint8_t {
  // 生产者线程直接轮询 commit sequence。
  kPollCommit,
  // FPGA 在 commit 写入时附带 immediate，生产者批量消费 CQE。
  kWriteWithImm,
};
enum class PollingMode : std::uint8_t {
  // 持续忙轮询，适合绑定专核的低延迟场景。
  kBusy,
  // 达到 spin_iterations 后短暂休眠，折中功耗和延迟。
  kAdaptive,
  // 每轮无数据都休眠，适合非实时应用。
  kSleep,
};
enum class MemoryPageMode : std::uint8_t {
  // 使用 MFD_HUGETLB 或应用提供的 hugetlbfs 文件；分配失败时明确报错，
  // 绝不回退到普通页或透明大页。
  kHugeTlb,
  // 显式使用系统普通页。该模式用于无 hugetlb 池的开发/测试环境，生产
  // 数据面应保持默认 kHugeTlb。
  kRegular,
};
enum class BatchAction : std::uint8_t {
  // callback 成功，继续接收后续 commit。
  kContinueReceiving,
  // 当前 batch 成功消费后请求正常 STOP。
  kStopAfterConsume,
  // 当前 batch 无法处理，立即进入 ABORT 恢复路径。
  kAbort,
};
enum class ThreadRole : std::uint8_t {
  // 负责 commit seqlock/CQ 轮询和队列发布。
  kProducer,
  // 负责应用 callback、CONSUME 和队列回收。
  kConsumer,
};

struct NetworkConfig {
  // libibverbs 设备名，例如 rocep131s0。
  std::string device_name;
  // 控制 UDP 和 RoCE GID 绑定的 Linux netdev。
  std::string netdev_name;
  // FPGA RDCP IPv4 地址。
  std::string fpga_ipv4{"192.168.17.11"};
  // 可选 host IPv4；为空时从 netdev 查询。
  std::string local_ipv4;
  // 可选强制 netmask；为空时不比较。
  std::string required_netmask;
  // RDCP 控制端口和 RoCE port。
  std::uint16_t control_port{protocol::kControlPort};
  std::uint8_t rdma_port{1U};
  // 可选固定 RoCEv2 GID 索引；为空时按 netdev 和 IPv4 自动选择。
  std::optional<int> gid_index;
  // 是否校验 netdev 已 up、MTU 和地址/掩码匹配。
  bool validate_netdev{true};
  // netdev 必须达到的最小 Ethernet MTU。
  ByteCount minimum_mtu{9000U};
};

struct SessionConfig {
  // 数据 ring 的总容量，commit record 位于其后 64 字节。
  ByteCount ring_bytes{kDefaultRingBytes};
  // FPGA 单次 RDMA WRITE 的逻辑上限。
  ByteCount wr_bytes{kDefaultWrBytes};
  // commit record 的发布间隔。
  ByteCount notify_interval_bytes{kDefaultNotifyBytes};
  // FPGA 远端地址基址，按产品要求对齐。
  RemoteAddress local_base{kDefaultLocalBase};
  // commit 唤醒模式。
  NotificationMode notification{NotificationMode::kPollCommit};
  // WRITE_WITH_IMM 模式预投递的 RQE 数量。
  HostCount receive_depth{kDefaultReceiveDepth};
};

struct VerbsConfig {
  // CQ 相对 receive WR 的额外容量。
  HostCount completion_queue_slack{16U};
  // QP 的发送和接收 WR 上限。
  HostCount max_send_wr{1U};
  HostCount max_receive_wr{4096U};
  // 所选 verbs port 必须满足的最小 active MTU。
  ByteCount minimum_active_mtu_bytes{protocol::kPmtuBytes};
  // 可选的可重复 session/事务/PSN；未指定时生成非零随机值。
  std::optional<SessionId> session_id;
  std::optional<TransactionId> transaction_seed;
  std::optional<std::uint32_t> fpga_tx_psn;
  std::optional<std::uint32_t> host_tx_psn;
};

struct TimingConfig {
  // HELLO、普通命令、STATUS、关闭和故障恢复的独立时间窗口。
  // HELLO 发现/链路等待总窗口。
  std::chrono::milliseconds discovery_window{std::chrono::seconds{10}};
  // CONFIG/START/STOP/CONSUME 单命令总窗口。
  std::chrono::milliseconds command_window{std::chrono::seconds{3}};
  // 单次 STATUS 等待和两次 STATUS 之间的周期。
  std::chrono::milliseconds status_timeout{200};
  std::chrono::milliseconds status_interval{100};
  // STOP 后等待 final commit 与安全释放的总窗口。
  std::chrono::milliseconds shutdown_window{std::chrono::seconds{15}};
  // 普通事务重发间隔。
  std::chrono::milliseconds retry_interval{100};
  // CONSUME reason=2 的快速重试间隔。
  std::chrono::microseconds progress_retry_interval{50};
  // ABORT 恢复长期未收敛时的告警周期。
  std::chrono::milliseconds recovery_warning_interval{std::chrono::seconds{15}};
};

struct PollingConfig {
  // 数据面轮询策略及各类批量/周期参数。
  PollingMode mode{PollingMode::kBusy};
  // Adaptive 模式在休眠前允许的空轮询次数。
  HostCount spin_iterations{2000U};
  // Adaptive/Sleep 模式的休眠时长。
  std::chrono::microseconds idle_sleep{50};
  // 检查 verbs async event 的低频周期。
  std::chrono::milliseconds housekeeping_interval{100};
  // 一次 ibv_poll_cq 和批量 repost 的最大 completion 数。
  HostCount completion_batch{32U};
  // commit descriptor 在 session 启动时一次性预分配；队列满时生产者施加
  // 背压，payload 始终留在注册 ring 中，不复制到队列。
  HostCount consumer_queue_depth{8U};
};

struct MemoryConfig {
  // 默认使用显式 hugetlb 大页；只有应用主动选择 kRegular 才使用普通页。
  // 两种模式都使用同一个文件后备建立 RDMA 主映射和 [ring][ring] 镜像。
  MemoryPageMode page_mode{MemoryPageMode::kHugeTlb};
  // kHugeTlb 模式使用的大页尺寸。默认 2 MiB；系统必须存在同尺寸的
  // hugetlb 池，ring_bytes 和 backing_offset_bytes 也必须按此值对齐。
  // kRegular 模式忽略该字段。
  ByteCount huge_page_bytes{kDefaultHugePageBytes};
  // -1 表示由库创建 memfd；kHugeTlb 模式会附加 MFD_HUGETLB 和页尺寸
  // 编码。非负值表示应用提供可 MAP_SHARED 的后备文件；hugetlb 模式会
  // 使用 fstatfs 验证文件系统类型和实际大页尺寸。文件必须在 Run 返回前
  // 保持打开，并从 backing_offset_bytes 起覆盖按页向上取整后的
  // ring_bytes + 64 字节；库不接管也不关闭应用提供的文件描述符。
  int backing_file_descriptor{-1};
  // 后备文件起始偏移。hugetlb 模式按 huge_page_bytes 对齐，普通页模式按
  // 系统页对齐；库内创建的 memfd 只允许偏移为 0。
  ByteCount backing_offset_bytes{};
};

struct SessionOptions {
  // 将网络、session、verbs、定时、轮询和内存策略组合成一次运行配置。
  NetworkConfig network;
  SessionConfig session;
  VerbsConfig verbs;
  TimingConfig timing;
  PollingConfig polling;
  MemoryConfig memory;
};

struct CommitMetadata {
  // FPGA commit record 的稳定快照。
  // producer 每次发布递增的 seqlock sequence。
  CommitSequence sequence{};
  // 从 session 起点开始累计发布的绝对字节数。
  ByteCount published_bytes{};
  // published_bytes 在 ring 内的结束偏移。
  ByteCount ring_end_offset{};
  // 本次 commit 声明的发布间隔。
  ByteCount interval_bytes{};
  // 标记 FPGA 已停止产生数据的最终 commit。
  bool final{};
};

struct CommitBatch {
  // 与 data 同一次发布对应的稳定 commit 快照。published_bytes 是累计
  // CONSUME 前沿，sequence/interval/final 供应用记录和决策；无需再暴露
  // 重复的 begin_bytes/end_bytes 字段。
  CommitMetadata commit;
  // 本批逻辑连续的只读数据。库把同一 ring 物理页连续 mmap 两次，因此
  // 即使批次跨越 ring 末尾，应用仍只处理一个 span，无需分支、拼接或复制。
  // 该视图不拥有内存，只在当前 callback 执行期间有效；零长度 final
  // commit 对应空 span。
  std::span<const std::byte> data{};
};

struct SessionCounters {
  // 会话级数据面计数器，由协调器在报告生成时拷贝。
  // producer 接受的稳定 commit 数量。
  HostCount commits{};
  // 最新发布和已确认消费的绝对字节游标。
  ByteCount published_bytes{};
  ByteCount consumed_bytes{};
  // consumer 完成 callback+CONSUME 的 batch 数量。
  HostCount batches{};
  // 检测到 ring 覆盖风险的次数。
  HostCount overruns{};
};

struct SessionReport {
  // Run 成功返回的最终状态、统计和 ring 只读视图。
  SessionCounters counters;
  // 最终 commit 和最终 RDCP 状态快照。
  CommitMetadata final_commit;
  protocol::Status final_status;
  // 同一物理 ring 连续映射两次形成的只读视图，长度为 2 * ring_bytes；
  // 仅在 Session 存活期间有效。
  std::span<const std::byte> ring{};
  // FPGA 可写物理 ring 的单圈容量，因此 ring.size() == 2 * ring_bytes。
  ByteCount ring_bytes{};
  // final commit 与 CLOSED+safe_to_release 均满足时为 true。
  bool normal_release{};
};

struct Event {
  // 低频生命周期事件；库不直接写 stdout/stderr。
  enum class Level : std::uint8_t {
    kDebug,
    kInfo,
    kWarning,
    kError,
  };
  // 事件严重度和仅在 Emit 调用期间有效的消息视图。
  Level level{Level::kInfo};
  std::string_view message;
};

template <typename T>
concept EventMethod = requires(T &value, const Event &event) {
  // 优先适配带 OnEvent 成员函数的对象。
  { value.OnEvent(event) } noexcept;
};

template <typename T>
concept EventCallable = requires(T &value, const Event &event) {
  // 其次适配可调用对象，要求 noexcept 以保护工作线程。
  { value(event) } noexcept;
};

template <typename T>
concept CommitMethod = requires(T &value, const CommitBatch &batch) {
  // callback 通过 OnCommit 返回消费动作。
  { value.OnCommit(batch) } noexcept -> std::same_as<BatchAction>;
};

template <typename T>
concept CommitCallable = requires(T &value, const CommitBatch &batch) {
  // callback 也可直接以 operator() 提供。
  { value(batch) } noexcept -> std::same_as<BatchAction>;
};

template <typename T>
concept ThreadStartMethod = requires(T &value, ThreadRole role) {
  // 线程启动钩子可按角色设置 affinity/调度策略。
  { value.OnThreadStart(role) } noexcept -> std::same_as<void>;
};

template <typename T>
concept ThreadStartCallable = requires(T &value, ThreadRole role) {
  { value(role) } noexcept -> std::same_as<void>;
};

class EventSink {
 public:
  // 非 owning 的 C 风格擦除，避免在事件路径分配 std::function。
  using Function = void (*)(void *, const Event &) noexcept;

  constexpr EventSink() noexcept = default;
  constexpr EventSink(void *object, Function function) noexcept
   : object_(object), function_(function) {
  }

  void Emit(Event event) const noexcept {
    // 空 sink 是合法的 no-op。
    if (function_ != nullptr) {
      function_(object_, event);
    }
  }

  template <typename T>
    requires EventMethod<T>
  static EventSink Bind(T &object) noexcept {
    return {&object, [](void *raw, const Event &event) noexcept {
              static_cast<T *>(raw)->OnEvent(event);
            }};
  }

  template <typename T>
    requires EventCallable<T> && (!EventMethod<T>)
  static EventSink Bind(T &object) noexcept {
    return {&object, [](void *raw, const Event &event) noexcept {
              (*static_cast<T *>(raw))(event);
            }};
  }

 private:
  void *object_{};
  Function function_{};
};

class CommitCallback {
 public:
  // 非 owning callback，调用期间必须保证 object 生命周期覆盖 Run。
  using Function = BatchAction (*)(void *, const CommitBatch &) noexcept;

  constexpr CommitCallback() noexcept = default;
  constexpr CommitCallback(void *object, Function function) noexcept
   : object_(object), function_(function) {
  }

  [[nodiscard]] BatchAction Invoke(const CommitBatch &batch) const noexcept {
    // 未提供 callback 时默认继续接收，仍会正常发送 CONSUME。
    return function_ == nullptr ? BatchAction::kContinueReceiving : function_(object_, batch);
  }

  template <typename T>
    requires CommitMethod<T>
  static CommitCallback Bind(T &object) noexcept {
    return {&object, [](void *raw, const CommitBatch &batch) noexcept {
              return static_cast<T *>(raw)->OnCommit(batch);
            }};
  }

  template <typename T>
    requires CommitCallable<T> && (!CommitMethod<T>)
  static CommitCallback Bind(T &object) noexcept {
    return {&object, [](void *raw, const CommitBatch &batch) noexcept {
              return (*static_cast<T *>(raw))(batch);
            }};
  }

 private:
  void *object_{};
  Function function_{};
};

class ThreadStartHook {
 public:
  // 每个 worker 只调用一次的非 owning 启动钩子。
  using Function = void (*)(void *, ThreadRole) noexcept;

  constexpr ThreadStartHook() noexcept = default;
  constexpr ThreadStartHook(void *object, Function function) noexcept
   : object_(object), function_(function) {
  }

  void Invoke(ThreadRole role) const noexcept {
    if (function_ != nullptr) {
      function_(object_, role);
    }
  }

  template <typename T>
    requires ThreadStartMethod<T>
  static ThreadStartHook Bind(T &object) noexcept {
    return {&object, [](void *raw, ThreadRole role) noexcept {
              static_cast<T *>(raw)->OnThreadStart(role);
            }};
  }

  template <typename T>
    requires ThreadStartCallable<T> && (!ThreadStartMethod<T>)
  static ThreadStartHook Bind(T &object) noexcept {
    return {&object, [](void *raw, ThreadRole role) noexcept {
              (*static_cast<T *>(raw))(role);
            }};
  }

 private:
  void *object_{};
  Function function_{};
};

struct Dependencies {
  // 可注入控制通道；为空时库创建绑定 netdev 的 UDP 通道。
  DatagramChannel *control_channel{};
  // 事件接收器和 worker 启动钩子均由应用持有。
  EventSink events{};
  // 每个 worker 进入循环前调用一次，可设置线程名、调度策略或 affinity；
  // 两个钩子可能并发执行，其引用对象必须存活到 Run() 返回。
  ThreadStartHook thread_start{};
};

class Session {
 public:
  struct State;

  // 校验配置并创建一次性 Session；此阶段不访问 RDMA 设备。
  static Outcome<std::unique_ptr<Session>> Create(
    SessionOptions config) noexcept;
  ~Session() noexcept;

  Session(const Session &) = delete;
  Session &operator=(const Session &) = delete;

  // 启动协调器、生产者和消费者三条执行路径，并在安全释放条件满足后返回。
  Outcome<SessionReport> Run(std::stop_token stop_token,
                             CommitCallback callback = {},
                             Dependencies dependencies = {}) noexcept;

 private:
  explicit Session(SessionOptions config);

  SessionOptions config_;
  bool ran_{};
  std::unique_ptr<State> state_;
};

} // namespace rrdma

#endif // RRDMA_INCLUDE_RRDMA_SESSION_HPP_
