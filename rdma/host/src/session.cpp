#include "rrdma/session.hpp"

#include <arpa/inet.h>
#include <infiniband/verbs.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <exception>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "batch_queue.hpp"
#include "consumer_path.hpp"
#include "control_client.hpp"
#include "detail.hpp"

namespace rrdma {
namespace {

using Clock = std::chrono::steady_clock;

// FPGA 只接受 48 位远端地址，检查起点和长度相加均不越界。
[[nodiscard]] bool FitsFpgaAddress(std::uintptr_t address,
                                   std::uint64_t length) noexcept {
  const auto start = static_cast<std::uint64_t>(address);
  return start < protocol::kRemoteAddressLimit &&
         length <= protocol::kRemoteAddressLimit - start;
}

// 构造本地参数错误，便于 Create/Run 统一返回。
[[nodiscard]] Error ConfigurationError(std::string message) {
  return MakeError(ErrorCode::kInvalidConfiguration, std::move(message));
}

[[nodiscard]] Error RemoteError(const protocol::Status &status, ErrorCode code,
                                std::string message) {
  // 保留 FPGA result/state/reason，应用可据此区分配置拒绝和运行故障。
  Error error = MakeError(code, std::move(message));
  error.remote_result = static_cast<std::uint16_t>(status.result);
  error.remote_state = static_cast<std::uint8_t>(status.state);
  error.remote_reason = status.reason;
  return error;
}

[[nodiscard]] bool IsConfigurationState(protocol::State state) noexcept {
  // 仅空闲或已经安全结束的 FPGA 状态允许建立新 session。
  return state == protocol::State::kIdle || state == protocol::State::kClosed ||
         state == protocol::State::kFaulted;
}

[[nodiscard]] std::string Ipv4Text(const in_addr &address) {
  // 把 ioctl 查询结果转换为 UDP channel 使用的文本地址。
  std::array<char, INET_ADDRSTRLEN> text{};
  if (::inet_ntop(AF_INET, &address, text.data(), text.size()) == nullptr) {
    return {};
  }
  return text.data();
}

}  // namespace

struct Session::State {
  // State 的生命周期覆盖 Run；所有 worker 只引用这一块稳定存储。
  explicit State(const SessionOptions &value) : config(value) {}

  // 资源和控制面对象由协调器创建并按声明逆序销毁。
  // Session 先析构 state_ 再析构 config_，因此该只读引用始终有效。
  const SessionOptions &config;
  std::unique_ptr<detail::RingStorage> storage;
  std::unique_ptr<detail::VerbsResources> verbs;
  std::unique_ptr<DatagramChannel> owned_channel;
  std::unique_ptr<detail::ControlClient> control;
  std::mutex control_mutex;

  // data_mutex 保护非原子的状态快照、统计和首个 fatal error。
  mutable std::mutex data_mutex;
  protocol::Status status{};
  protocol::ReleaseGate release_gate;
  CommitMetadata last_commit{};
  SessionCounters counters{};
  std::optional<Error> fatal_error;

  std::unique_ptr<detail::BatchQueue> queue;
  std::vector<ibv_wc> completions;
  std::atomic<bool> abort_requested{};
  // worker 间只共享轻量进度标志，payload 和统计不需要原子逐包更新。
  std::atomic<bool> producer_exit{};
  std::atomic<bool> producer_done{};
  std::atomic<bool> consumer_done{};
  std::atomic<bool> control_priority_waiting{};
  std::atomic<std::uint64_t> released_frontier{};
  std::atomic<bool> final_seen{};
  std::atomic<std::uint64_t> final_batch_index{
      std::numeric_limits<std::uint64_t>::max()};
  std::atomic<bool> consumer_stop_requested{};
  std::thread producer;
  std::thread consumer;
  ThreadStartHook thread_start;

  bool session_armed{};
};

namespace {

void RequestAbort(Session::State &state) noexcept {
  // 先置位无锁中断标志，使正在等待响应或准备 reason=2 重试的控制事务尽快
  // 返回；随后获取同一 control_mutex，排空已经进入发送区的事务。函数返回
  // 后，不会再有早于本次 ABORT 请求线性化的 CONSUME 留在执行中。
  state.abort_requested.store(true, std::memory_order_release);
  state.control_priority_waiting.store(true, std::memory_order_release);
  std::scoped_lock control_gate(state.control_mutex);
}

void SetFatal(Session::State &state, Error error) noexcept {
  // 只保留首个根因，并同时唤醒/终止两个 worker。
  {
    std::lock_guard lock(state.data_mutex);
    if (!state.fatal_error.has_value()) {
      state.fatal_error = std::move(error);
    }
  }
  RequestAbort(state);
  state.producer_exit.store(true, std::memory_order_release);
  if (state.queue != nullptr) {
    state.queue->Close();
  }
}

[[nodiscard]] bool HasFatal(const Session::State &state) noexcept {
  // 协调器周期性检查 worker 是否报告了不可恢复错误。
  std::lock_guard lock(state.data_mutex);
  return state.fatal_error.has_value();
}

[[nodiscard]] std::optional<Error> GetFatal(const Session::State &state) {
  // 返回错误副本，避免锁释放后引用失效。
  std::lock_guard lock(state.data_mutex);
  return state.fatal_error;
}

void ObserveStatus(Session::State &state, const protocol::Status &status) {
  // 同时更新报告快照和安全释放门。
  std::lock_guard lock(state.data_mutex);
  state.status = status;
  state.release_gate.ObserveStatus(status);
}

[[nodiscard]] bool NormalReleaseReady(const Session::State &state) noexcept {
  // 在锁内读取 final/status 组合条件，防止协调器观察到不一致快照。
  std::lock_guard lock(state.data_mutex);
  return state.release_gate.NormalReleaseReady();
}

[[nodiscard]] bool FinalCommitConsumed(const Session::State &state) noexcept {
  // final descriptor 必须已经 callback 成功、CONSUME 确认并回收。
  if (!state.final_seen.load(std::memory_order_acquire) ||
      state.queue == nullptr) {
    return false;
  }
  const auto final_batch =
      state.final_batch_index.load(std::memory_order_acquire);
  return final_batch != std::numeric_limits<std::uint64_t>::max() &&
         state.queue->Reclaimed() > final_batch;
}

[[nodiscard]] bool ConsumerHasPendingBatch(
    const Session::State &state) noexcept {
  // 有 credit 等待返回时跳过低优先级 STATUS，缩短 FPGA 停顿时间。
  return state.queue != nullptr &&
         state.queue->Reclaimed() < state.queue->Published();
}

[[nodiscard]] bool PollImmediateReceives(Session::State &state) noexcept {
  // polling 模式无需 CQ；Immediate 模式将 CQE 视为唤醒信号，数据正确性
  // 仍由 commit seqlock 验证。
  if (state.config.session.notification != NotificationMode::kWriteWithImm) {
    return true;
  }
  const auto completion_result =
      state.verbs->PollCompletions(state.completions);
  if (!completion_result) {
    SetFatal(state, completion_result.GetError());
    return false;
  }
  const auto count = completion_result.Value();
  for (std::size_t index{}; index < count; ++index) {
    const auto &completion = state.completions[index];
    if (completion.status != IBV_WC_SUCCESS ||
        completion.opcode != IBV_WC_RECV_RDMA_WITH_IMM) {
      Error error =
          MakeError(ErrorCode::kVerbsError,
                    completion.status == IBV_WC_SUCCESS
                        ? "unexpected immediate receive completion opcode"
                        : ibv_wc_status_str(completion.status));
      error.verbs_status = static_cast<int>(completion.status);
      SetFatal(state, std::move(error));
      return false;
    }
  }
  if (count != 0U) {
    const auto posted = state.verbs->PostReceives(
        std::span<const ibv_wc>{state.completions.data(), count});
    if (!posted) {
      SetFatal(state, posted.GetError());
      return false;
    }
  }
  return true;
}

[[nodiscard]] bool PollHousekeeping(
    Session::State &state, Clock::time_point now,
    Clock::time_point &next_housekeeping) noexcept {
  // async event 检查与 commit 轮询解耦，避免每次热循环调用 poll()。
  if (next_housekeeping != Clock::time_point{} && now < next_housekeeping) {
    return true;
  }
  const auto async_result = state.verbs->PollAsyncEvent();
  if (!async_result) {
    SetFatal(state, async_result.GetError());
    return false;
  }
  next_housekeeping = now + state.config.polling.housekeeping_interval;
  return true;
}

void RunProducer(Session::State &state) noexcept {
  // 生产者独占 commit/CQ 轮询，只生成非 owning 的 batch descriptor；应用
  // 处理在消费者线程执行，因此慢 callback 不会阻塞 RDMA 可见性检查。
  state.thread_start.Invoke(ThreadRole::kProducer);
  try {
    std::uint32_t spin_count{};
    auto next_housekeeping = Clock::time_point{};
    CommitMetadata last_commit{};
    std::uint64_t scanned_bytes{};
    while (!state.abort_requested.load(std::memory_order_acquire) &&
           !state.producer_exit.load(std::memory_order_acquire)) {
      const auto now = Clock::now();
      if (!PollImmediateReceives(state) ||
          !PollHousekeeping(state, now, next_housekeeping)) {
        break;
      }

      const auto observed_sequence =
          detail::ReadCommitSequence(state.storage->Commit());
      if (observed_sequence != 0U &&
          observed_sequence != last_commit.sequence) {
        CommitMetadata commit{};
        if (detail::ReadCommit(state.storage->Commit(), commit) &&
            commit.sequence != last_commit.sequence) {
          if (detail::ClassifyCommit(
                  last_commit, commit,
                  state.config.session.notify_interval_bytes) !=
              detail::CommitDisposition::kReady) {
            SetFatal(
                state,
                MakeError(ErrorCode::kProtocolError,
                          "commit sequence, interval or progress is invalid"));
            break;
          }

          const auto batch_result = detail::MakeBatch(
              state.storage->MirroredRing(), state.config.session.ring_bytes,
              scanned_bytes,
              state.released_frontier.load(std::memory_order_acquire), commit);
          if (!batch_result) {
            auto error = batch_result.GetError();
            if (error.code == ErrorCode::kSessionFault) {
              {
                std::lock_guard lock(state.data_mutex);
                ++state.counters.overruns;
              }
            }
            SetFatal(state, std::move(error));
            break;
          }
          const auto batch = batch_result.Value();

          bool queued{};
          while (!queued &&
                 !state.abort_requested.load(std::memory_order_acquire) &&
                 !state.producer_exit.load(std::memory_order_acquire)) {
            queued = state.queue->TryPush(batch);
            if (queued) {
              break;
            }
            if (state.queue->Closed()) {
              break;
            }
            const auto service_now = Clock::now();
            if (!PollImmediateReceives(state) ||
                !PollHousekeeping(state, service_now, next_housekeeping)) {
              break;
            }
            if (state.config.polling.mode == PollingMode::kSleep) {
              std::this_thread::sleep_for(state.config.polling.idle_sleep);
            } else {
              std::this_thread::yield();
            }
          }
          if (!queued) {
            if (!state.abort_requested.load(std::memory_order_acquire) &&
                !HasFatal(state)) {
              SetFatal(
                  state,
                  MakeError(ErrorCode::kStopped,
                            "consumer queue closed before commit delivery"));
            }
            break;
          }

          const auto published_batch_index = state.queue->Published() - 1U;
          {
            std::lock_guard lock(state.data_mutex);
            state.last_commit = commit;
            ++state.counters.commits;
            state.counters.published_bytes = commit.published_bytes;
            if (commit.final) {
              state.release_gate.ObserveFinalCommit();
            }
          }
          last_commit = commit;
          scanned_bytes = commit.published_bytes;
          if (commit.final) {
            state.final_batch_index.store(published_batch_index,
                                          std::memory_order_release);
            state.final_seen.store(true, std::memory_order_release);
            break;
          }
        }
      }

      if (state.config.polling.mode == PollingMode::kSleep ||
          (state.config.polling.mode == PollingMode::kAdaptive &&
           ++spin_count >= state.config.polling.spin_iterations)) {
        spin_count = 0U;
        std::this_thread::sleep_for(state.config.polling.idle_sleep);
      }
    }
  } catch (const std::exception &error) {
    SetFatal(state, MakeError(ErrorCode::kInternalError, error.what()));
  } catch (...) {
    SetFatal(state,
             MakeError(ErrorCode::kInternalError, "unknown producer failure"));
  }
  state.producer_done.store(true, std::memory_order_release);
}

void RunConsumer(Session::State &state, CommitCallback callback) noexcept {
  // 消费者按发布顺序调用应用 callback，成功后发送累计 CONSUME，再释放
  // 队列槽位；callback 失败不会把未确认的数据 credit 给 FPGA。
  state.thread_start.Invoke(ThreadRole::kConsumer);
  try {
    while (!state.abort_requested.load(std::memory_order_acquire)) {
      CommitBatch *batch{};
      if (!state.queue->WaitForFront(batch)) {
        break;
      }

      const auto consumed_bytes = batch->commit.published_bytes;
      auto consume_result = detail::ProcessCommittedBatch(
          *batch, callback, *state.control, state.control_mutex,
          state.released_frontier, state.control_priority_waiting,
          state.abort_requested, state.config.timing.command_window);
      if (state.abort_requested.load(std::memory_order_acquire)) {
        break;
      }
      if (!consume_result) {
        SetFatal(state, consume_result.GetError());
        break;
      }

      ObserveStatus(state, consume_result.Value().status);
      {
        std::lock_guard lock(state.data_mutex);
        state.counters.consumed_bytes = consumed_bytes;
        ++state.counters.batches;
      }
      state.queue->ReleaseFront();
      if (consume_result.Value().action == BatchAction::kStopAfterConsume) {
        state.consumer_stop_requested.store(true, std::memory_order_release);
      }
    }
  } catch (const std::exception &error) {
    SetFatal(state, MakeError(ErrorCode::kInternalError, error.what()));
  } catch (...) {
    SetFatal(state,
             MakeError(ErrorCode::kInternalError, "unknown consumer failure"));
  }
  state.consumer_done.store(true, std::memory_order_release);
}

void JoinWorkers(Session::State &state) noexcept {
  // 仅广播本地退出并 join；正常 STOP 路径不能因此额外发送 ABORT。
  state.producer_exit.store(true, std::memory_order_release);
  if (state.queue != nullptr) {
    state.queue->Close();
  }
  if (state.producer.joinable()) {
    state.producer.join();
  }
  if (state.consumer.joinable()) {
    state.consumer.join();
  }
}

void StopWorkers(Session::State &state) noexcept {
  // 失败路径先阻止新的控制事务，再关闭队列并等待 worker，保证 ring/MR
  // 销毁前没有线程仍在访问 commit record 或 callback span。
  RequestAbort(state);
  JoinWorkers(state);
}

void CleanupFailedSession(Session::State &state, EventSink events) noexcept {
  // 只有 ABORT 已确认 FAULTED + safe_to_release 后，才能按 QP/MR -> mapping
  // 顺序释放资源；配置尚未激活时 session_armed 为 false，不会误伤旧会话。
  StopWorkers(state);
  if (state.session_armed && state.control != nullptr) {
    std::scoped_lock lock(state.control_mutex);
    (void)state.control->AbortUntilSafe(state.config.timing, events);
    state.session_armed = false;
  }
  state.verbs.reset();
  state.storage.reset();
}

[[nodiscard]] Outcome<void> CheckHello(const protocol::Status &status) {
  // HELLO 同时校验 RDCP 能力、固定 QPN/PMTU 和允许配置的生命周期状态。
  if (status.result != protocol::Result::kOk ||
      status.local_qpn != protocol::kFpgaQpn ||
      status.pmtu_bytes != protocol::kPmtuBytes ||
      (status.capabilities & protocol::kCapabilitiesV2) !=
          protocol::kCapabilitiesV2 ||
      !IsConfigurationState(status.state)) {
    return Outcome<void>{RemoteError(
        status, ErrorCode::kRemoteRejected,
        "FPGA RDCP HELLO is incompatible with the requested session")};
  }
  return {};
}

[[nodiscard]] protocol::Config MakeProtocolConfig(
    const SessionOptions &config, const detail::RingStorage &storage,
    const detail::VerbsResources &verbs) noexcept {
  // 从已创建的 MR/QP 提取真实 remote_base、rkey、QPN 和 PSN，确保发送给
  // FPGA 的 CONFIG 与本地资源完全一致。
  protocol::Config result{};
  result.remote_qpn = verbs.Qpn();
  result.local_psn = verbs.FpgaTxPsn();
  result.remote_base = storage.Address();
  result.rkey = verbs.MemoryRegion()->rkey;
  result.ring_size = static_cast<std::uint32_t>(config.session.ring_bytes);
  result.wr_size = config.session.wr_bytes;
  result.notify_interval = config.session.notify_interval_bytes;
  result.local_base = config.session.local_base;
  result.commit_address = storage.CommitAddress();
  result.flags =
      config.session.notification == NotificationMode::kWriteWithImm ? 1U : 0U;
  return result;
}

// 完成控制面准备：查询 netdev、创建/接管 datagram channel、HELLO 握手。
// 该阶段不分配 RDMA 资源，因此失败不会留下可写入 FPGA 的 session。
[[nodiscard]] Outcome<detail::NetdevInfo> PrepareControlSession(
    Session::State &state, const Dependencies &dependencies,
    std::stop_token stop_token) {
  const auto &config = state.config;
  auto netdev_result = detail::QueryNetdev(config.network);
  if (!netdev_result) {
    return Failure<detail::NetdevInfo>(netdev_result.GetError());
  }

  DatagramChannel *channel = dependencies.control_channel;
  if (channel == nullptr) {
    UdpChannelConfig channel_config{};
    channel_config.netdev = config.network.netdev_name;
    channel_config.local_ipv4 = Ipv4Text(netdev_result.Value().ipv4);
    channel_config.remote_ipv4 = config.network.fpga_ipv4;
    channel_config.remote_port = config.network.control_port;
    auto channel_result = UdpChannel::Create(channel_config);
    if (!channel_result) {
      return Failure<detail::NetdevInfo>(channel_result.GetError());
    }
    state.owned_channel = std::move(channel_result.Value());
    channel = state.owned_channel.get();
  }

  const auto transaction_seed =
      config.verbs.transaction_seed.value_or(detail::RandomNonzeroU32());
  const auto session_id =
      config.verbs.session_id.value_or(detail::RandomNonzeroU64());
  state.control = std::make_unique<detail::ControlClient>(
      *channel, config.timing, 0U, transaction_seed);

  auto hello = state.control->Request(protocol::Opcode::kHello, {},
                                      config.timing.discovery_window);
  if (!hello) {
    return Failure<detail::NetdevInfo>(hello.GetError());
  }
  state.status = hello.Value().status;
  const auto hello_valid = CheckHello(state.status);
  if (!hello_valid) {
    return Failure<detail::NetdevInfo>(hello_valid.GetError());
  }

  // HELLO 使用零 session；握手通过后切换到本次 session，后续 CONFIG/START
  // 将复用同一个随机 ID，而不需要把它放进长期共享 State。
  state.control->SetSession(session_id);
  dependencies.events.Emit({Event::Level::kInfo, "RDCP HELLO accepted"});
  if (stop_token.stop_requested()) {
    return Failure<detail::NetdevInfo>(MakeError(
        ErrorCode::kStopped, "stop requested before configuration"));
  }
  return std::move(netdev_result.Value());
}

// 分配 ring/MR/QP，并完成 CONFIG -> START。所有资源仍由 State 统一拥有。
[[nodiscard]] Outcome<void> CreateAndStartSession(
    Session::State &state, const detail::NetdevInfo &netdev,
    EventSink events) {
  const auto &config = state.config;
  auto storage_result =
      detail::RingStorage::Create(config.memory, config.session.ring_bytes);
  if (!storage_result) {
    return Failure<void>(storage_result.GetError());
  }
  state.storage = std::move(storage_result.Value());
  if (!FitsFpgaAddress(state.storage->Address(),
                       config.session.ring_bytes + kCommitBytes)) {
    return Failure<void>(ConfigurationError(
        "ring and commit addresses do not fit the FPGA 48-bit range"));
  }

  auto verbs_result =
      detail::VerbsResources::Create(config, netdev, *state.storage);
  if (!verbs_result) {
    return Failure<void>(verbs_result.GetError());
  }
  state.verbs = std::move(verbs_result.Value());

  const auto protocol_config =
      MakeProtocolConfig(config, *state.storage, *state.verbs);
  auto start_result = detail::ConfigureAndStartSession(
      *state.control, protocol_config, config.timing, events,
      state.session_armed);
  if (!start_result) {
    return Failure<void>(start_result.GetError());
  }
  state.status = start_result.Value();
  return {};
}

// 预分配 descriptor/CQE 缓冲后再启动 producer/consumer，确保 worker 看到
// 完整的 queue、MR、QP 和控制客户端状态。
void StartWorkers(Session::State &state, CommitCallback callback,
                  const Dependencies &dependencies) {
  state.queue = std::make_unique<detail::BatchQueue>(
      state.config.polling.consumer_queue_depth);
  state.completions.resize(state.config.polling.completion_batch);
  state.thread_start = dependencies.thread_start;
  state.producer = std::thread(RunProducer, std::ref(state));
  state.consumer = std::thread(RunConsumer, std::ref(state), callback);
}

// 发送一次正常 STOP，并验证 FPGA 已进入 STOPPING/CLOSED。
[[nodiscard]] Outcome<void> SendNormalStop(Session::State &state,
                                            EventSink events,
                                            const char *reason) {
  events.Emit({Event::Level::kInfo, reason});
  auto stop_reply = [&] {
    std::scoped_lock lock(state.control_mutex);
    return state.control->Request(protocol::Opcode::kStop, {},
                                  state.config.timing.command_window);
  }();
  if (!stop_reply) {
    return Failure<void>(stop_reply.GetError());
  }

  ObserveStatus(state, stop_reply.Value().status);
  const auto &status = stop_reply.Value().status;
  if (status.result != protocol::Result::kOk ||
      (status.state != protocol::State::kStopping &&
       status.state != protocol::State::kClosed)) {
    return Failure<void>(RemoteError(status, ErrorCode::kRemoteRejected,
                                     "FPGA STOP failed"));
  }
  return {};
}

// 周期性获取低优先级 STATUS；有待发送 CONSUME 时让出控制锁，避免反压。
[[nodiscard]] Outcome<void> PollSessionStatus(
    Session::State &state, Clock::time_point now,
    Clock::time_point &next_status) {
  if (now < next_status || ConsumerHasPendingBatch(state)) {
    return {};
  }

  auto status_reply = [&] {
    std::scoped_lock lock(state.control_mutex);
    return state.control->RequestInterruptible(
        protocol::Opcode::kStatus, {}, state.config.timing.status_timeout,
        state.control_priority_waiting);
  }();
  next_status = Clock::now() + state.config.timing.status_interval;
  if (!status_reply) {
    const auto code = status_reply.GetError().code;
    if (code == ErrorCode::kTimeout || code == ErrorCode::kStopped) {
      return {};
    }
    return Failure<void>(status_reply.GetError());
  }

  ObserveStatus(state, status_reply.Value().status);
  if (protocol::ActiveSessionRequiresAbort(status_reply.Value().status)) {
    return Failure<void>(RemoteError(
        status_reply.Value().status, ErrorCode::kSessionFault,
        "FPGA reported an active-session fault"));
  }
  return {};
}

// 协调器只处理 stop/status/release 条件；数据搬运和 callback 在两个 worker
// 中并行完成。失败时把错误交给上层统一清理，避免这里再维护第二套清理逻辑。
[[nodiscard]] Outcome<void> CoordinateSession(
    Session::State &state, std::stop_token stop_token, EventSink events) {
  bool stop_sent{};
  auto next_status = Clock::now();
  Clock::time_point shutdown_deadline{};

  while (true) {
    const auto now = Clock::now();
    if (HasFatal(state)) {
      const auto fatal = GetFatal(state);
      return Failure<void>(fatal.value_or(
          MakeError(ErrorCode::kInternalError, "worker reported a fatal error")));
    }

    const bool final_consumed = FinalCommitConsumed(state);
    const bool stop_requested =
        stop_token.stop_requested() ||
        state.consumer_stop_requested.load(std::memory_order_acquire) ||
        final_consumed;
    if (stop_requested && !stop_sent) {
      stop_sent = true;
      shutdown_deadline = now + state.config.timing.shutdown_window;
      const char *reason =
          final_consumed ? "final commit consumed; sending FPGA STOP"
                         : "stop requested; sending FPGA STOP";
      const auto stop_result = SendNormalStop(state, events, reason);
      if (!stop_result) {
        return Failure<void>(stop_result.GetError());
      }
    }

    if (state.producer_done.load(std::memory_order_acquire) &&
        state.final_seen.load(std::memory_order_acquire)) {
      state.queue->Close();
    }

    const auto status_result = PollSessionStatus(state, now, next_status);
    if (!status_result) {
      return Failure<void>(status_result.GetError());
    }

    if (state.producer_done.load(std::memory_order_acquire) &&
        state.consumer_done.load(std::memory_order_acquire) &&
        state.queue->Reclaimed() == state.queue->Published() &&
        NormalReleaseReady(state)) {
      JoinWorkers(state);
      return {};
    }
    if (shutdown_deadline != Clock::time_point{} && now >= shutdown_deadline) {
      return Failure<void>(MakeError(
          ErrorCode::kTimeout,
          "normal shutdown did not reach CLOSED/safe_to_release"));
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
}

// 将已经满足正常释放门的 State 转换为稳定报告；ring span 继续由 Session
// 持有，直到应用销毁 Session。
[[nodiscard]] SessionReport BuildSessionReport(const Session::State &state) {
  SessionReport report{};
  {
    std::lock_guard lock(state.data_mutex);
    report.counters = state.counters;
    report.final_commit = state.last_commit;
    report.final_status = state.status;
  }
  report.ring = state.storage->MirroredRing();
  report.ring_bytes = state.config.session.ring_bytes;
  report.normal_release = true;
  return report;
}

// 单次会话的完整步骤编排。它只返回结果，不负责失败清理；调用方统一执行
// CleanupFailedSession，因而所有早退点都共享同一套资源生命周期规则。
[[nodiscard]] Outcome<SessionReport> RunSession(
    Session::State &state, std::stop_token stop_token, CommitCallback callback,
    const Dependencies &dependencies) {
  const auto netdev_result =
      PrepareControlSession(state, dependencies, stop_token);
  if (!netdev_result) {
    return Failure<SessionReport>(netdev_result.GetError());
  }

  const auto resources_result = CreateAndStartSession(
      state, netdev_result.Value(), dependencies.events);
  if (!resources_result) {
    return Failure<SessionReport>(resources_result.GetError());
  }

  StartWorkers(state, callback, dependencies);

  const auto coordination_result =
      CoordinateSession(state, stop_token, dependencies.events);
  if (!coordination_result) {
    return Failure<SessionReport>(coordination_result.GetError());
  }

  if (const auto fatal = GetFatal(state); fatal.has_value()) {
    return Failure<SessionReport>(*fatal);
  }
  return BuildSessionReport(state);
}

// 三类失败共享同一清理和诊断优先级：先停止并回收 worker，再完成 FPGA
// 安全恢复；若 worker 已记录更具体的首个 fatal，则优先返回该根因。
[[nodiscard]] Outcome<SessionReport> CleanupAndFail(
    Session::State *state, EventSink events, Error error) noexcept {
  if (state != nullptr) {
    CleanupFailedSession(*state, events);
    if (const auto fatal = GetFatal(*state); fatal.has_value()) {
      error = *fatal;
    }
  }
  return Failure<SessionReport>(std::move(error));
}

}  // namespace

Session::Session(SessionOptions config) : config_(std::move(config)) {}

Outcome<std::unique_ptr<Session>> Session::Create(
    SessionOptions config) noexcept {
  // Create 只做无副作用的配置校验和对象分配；设备、QP 与 FPGA session
  // 均延迟到 Run，便于应用注入测试 channel 和线程钩子。
  try {
    const auto valid = detail::ValidateConfig(config);
    if (!valid) {
      return Failure<std::unique_ptr<Session>>(valid.GetError());
    }
    auto receiver = std::unique_ptr<Session>(new (std::nothrow)
                                                  Session(std::move(config)));
    if (!receiver) {
      return Failure<std::unique_ptr<Session>>(
          MakeError(ErrorCode::kAllocationFailed, "cannot allocate Session"));
    }
    return receiver;
  } catch (const std::exception &error) {
    return Failure<std::unique_ptr<Session>>(
        MakeError(ErrorCode::kInternalError, error.what()));
  } catch (...) {
    return Failure<std::unique_ptr<Session>>(MakeError(
        ErrorCode::kInternalError, "unknown Session creation error"));
  }
}

Session::~Session() noexcept {
  // 防御应用在异常路径提前析构；先停止 worker 再释放 verbs 资源。
  if (state_ != nullptr) {
    StopWorkers(*state_);
  }
}

Outcome<SessionReport> Session::Run(std::stop_token stop_token,
                                     CommitCallback callback,
                                     Dependencies dependencies) noexcept {
  // Run 只负责单次运行门禁、异常边界和失败清理；具体阶段由内部函数编排。
  if (ran_) {
    return Failure<SessionReport>(MakeError(
        ErrorCode::kAlreadyRunning, "Session instances are single-use"));
  }
  ran_ = true;

  const EventSink events = dependencies.events;
  try {
    state_ = std::make_unique<State>(config_);
    auto result = RunSession(*state_, stop_token, callback, dependencies);
    if (result) {
      return result;
    }
    return CleanupAndFail(state_.get(), events, result.GetError());
  } catch (const std::exception &error) {
    return CleanupAndFail(
        state_.get(), events,
        MakeError(ErrorCode::kInternalError, error.what()));
  } catch (...) {
    return CleanupAndFail(
        state_.get(), events,
        MakeError(ErrorCode::kInternalError, "unknown receiver failure"));
  }
}

}  // namespace rrdma
