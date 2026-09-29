#include <arpa/inet.h>
#include <getopt.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iomanip>
#include <iostream>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <utility>

#include "rrdma/session.hpp"
#include "rfso.hpp"

namespace {

using Clock = std::chrono::steady_clock;

constexpr double kBytesPerMib{1024.0 * 1024.0};
constexpr double kBitsPerGigabit{1'000'000'000.0};

// CLI 只保存应用层选项，ring/verbs/timing 默认值由公共库统一提供。
struct Options {
  std::string device;
  std::string netdev;
  std::string fpga_ip{"192.168.17.11"};
  rrdma::HostCount receive_depth{rrdma::kDefaultReceiveDepth};
  rrdma::HostCount seconds{};
  bool immediate{};
  bool verify_on_exit{};
  bool verbose_commits{};
};

enum class ParseResult : std::uint8_t {
  // 区分正常参数、已打印帮助和语法错误。
  kSuccess,
  kHelp,
  kFailure,
};

volatile std::sig_atomic_t g_signal_seen{};

// 信号处理器只写 sig_atomic_t，实际 stop_source 由普通线程触发。
extern "C" void HandleSignal(int) noexcept {
  g_signal_seen = 1;
}

// 输出薄 CLI 的参数说明，不泄漏内部 session 实现细节。
void PrintUsage(std::string_view program) {
  std::cerr
    << "Usage: " << program << " --device NAME --netdev NAME [options]\n\n"
    << "  --fpga-ip IPv4       default 192.168.17.11\n"
    << "  --immediate          use RDMA WRITE_WITH_IMM notifications\n"
    << "  --recv-depth COUNT   immediate receive depth, default 1024\n"
    << "  --seconds COUNT      request normal STOP after COUNT seconds\n"
    << "  --verify-on-exit     rescan the newest ring-sized RFSO window\n"
    << "  --verbose-commits    print every commit\n";
}

bool ParseUnsigned64(const char *text, std::uint64_t &value) noexcept {
  // 使用 strtoull 严格拒绝空串、尾随字符和溢出。
  if (text == nullptr || *text == '\0') {
    return false;
  }
  char *end{};
  errno = 0;
  const auto parsed = std::strtoull(text, &end, 0);
  if (errno != 0 || end == text || *end != '\0') {
    return false;
  }
  value = static_cast<std::uint64_t>(parsed);
  return true;
}

ParseResult ParseOptions(int argc, char **argv, Options &options) {
  // 保留原有命令行选项，并在进入库之前完成范围和 IPv4 校验。
  static constexpr option kLongOptions[] = {
    {"device", required_argument, nullptr, 'd'},
    {"netdev", required_argument, nullptr, 'n'},
    {"fpga-ip", required_argument, nullptr, 'i'},
    {"immediate", no_argument, nullptr, 'I'},
    {"recv-depth", required_argument, nullptr, 'R'},
    {"seconds", required_argument, nullptr, 't'},
    {"verify-on-exit", no_argument, nullptr, 'v'},
    {"verbose-commits", no_argument, nullptr, 'C'},
    {"help", no_argument, nullptr, 'h'},
    {nullptr, 0, nullptr, 0}};
  ::optind = 1;
  ::opterr = 0;
  while (true) {
    const int option =
      ::getopt_long(argc, argv, "d:n:i:IR:t:vCh", kLongOptions, nullptr);
    if (option == -1) {
      break;
    }
    std::uint64_t parsed{};
    switch (option) {
    case 'd':
      options.device = optarg;
      break;
    case 'n':
      options.netdev = optarg;
      break;
    case 'i':
      options.fpga_ip = optarg;
      break;
    case 'I':
      options.immediate = true;
      break;
    case 'R':
      if (!ParseUnsigned64(optarg, parsed) || parsed == 0U
          || parsed > std::numeric_limits<rrdma::HostCount>::max()) {
        return ParseResult::kFailure;
      }
      options.receive_depth = static_cast<rrdma::HostCount>(parsed);
      break;
    case 't':
      if (!ParseUnsigned64(optarg, parsed)
          || parsed > static_cast<rrdma::HostCount>(
               std::numeric_limits<std::chrono::seconds::rep>::max())) {
        return ParseResult::kFailure;
      }
      options.seconds = static_cast<rrdma::HostCount>(parsed);
      break;
    case 'v':
      options.verify_on_exit = true;
      break;
    case 'C':
      options.verbose_commits = true;
      break;
    case 'h':
      PrintUsage(argv[0]);
      return ParseResult::kHelp;
    default:
      return ParseResult::kFailure;
    }
  }
  in_addr address{};
  if (options.device.empty() || options.netdev.empty()
      || ::inet_pton(AF_INET, options.fpga_ip.c_str(), &address) != 1
      || ::optind != argc) {
    return ParseResult::kFailure;
  }
  return ParseResult::kSuccess;
}

class ConsoleEvents {
 public:
  // 将库的结构化事件映射到 stdout/stderr；核心库本身不做控制台 I/O。
  void OnEvent(const rrdma::Event &event) noexcept {
    switch (event.level) {
    case rrdma::Event::Level::kDebug:
      std::clog << "debug: ";
      break;
    case rrdma::Event::Level::kInfo:
      std::clog << "info: ";
      break;
    case rrdma::Event::Level::kWarning:
      std::cerr << "warning: ";
      break;
    case rrdma::Event::Level::kError:
      std::cerr << "error: ";
      break;
    }
    if (event.level == rrdma::Event::Level::kWarning || event.level == rrdma::Event::Level::kError) {
      std::cerr << event.message << '\n';
    } else {
      std::clog << event.message << '\n';
    }
  }
};

class RfsoApplicationConsumer {
 public:
  // 组合通用 RFSO 校验器与 CLI 的速率/commit 输出。
  explicit RfsoApplicationConsumer(bool verbose) noexcept : verbose_(verbose) {
  }

  rrdma::BatchAction OnCommit(const rrdma::CommitBatch &batch) noexcept {
    // 此函数运行在库的 consumer 线程；完成校验后返回才会发送 CONSUME。
    const auto action = consumer_.OnCommit(batch);
    if (verbose_ || batch.commit.final) {
      std::cout << "commit sequence=" << batch.commit.sequence
                << " published=" << batch.commit.published_bytes
                << " end=" << batch.commit.ring_end_offset
                << " interval=" << batch.commit.interval_bytes
                << " final=" << (batch.commit.final ? 1 : 0)
                << " bytes=" << batch.data.size() << '\n';
    }
    const auto now = Clock::now();
    if (!traffic_started_.has_value() && !batch.data.empty() && action != rrdma::BatchAction::kAbort) {
      traffic_started_ = now;
      measurement_origin_ = consumer_.Stats();
      consumer_.ResetRateBaseline(now);
      return action;
    }
    if (!traffic_started_.has_value()) {
      return action;
    }
    const auto sample = consumer_.Sample(now);
    if (sample.seconds >= 1.0) {
      const auto mib = static_cast<double>(sample.bytes) / (1024.0 * 1024.0) / sample.seconds;
      const auto gbps = static_cast<double>(sample.bytes) * 8.0 / 1'000'000'000.0 / sample.seconds;
      const auto pps = static_cast<double>(sample.packets) / sample.seconds;
      const auto cps = static_cast<double>(sample.commits) / sample.seconds;
      std::cout << "Rate=" << std::fixed << std::setprecision(2) << mib
                << " MiB/s (" << std::setprecision(3) << gbps
                << " Gbps) packets=" << std::setprecision(2) << pps
                << "/s commits=" << cps
                << "/s discontinuities=" << consumer_.Stats().discontinuities
                << " (+" << sample.discontinuities
                << ") invalid=" << consumer_.Stats().invalid_headers << " (+"
                << sample.invalid_headers << ")\n";
      consumer_.ResetRateBaseline(now);
    }
    return action;
  }

  [[nodiscard]] const rrdma::RfsoStats &Stats() const noexcept {
    // Run 返回后读取稳定的累计统计。
    return consumer_.Stats();
  }

  [[nodiscard]] const std::optional<Clock::time_point> &TrafficStarted()
    const noexcept {
    // 零长度 final commit 不建立吞吐测量起点。
    return traffic_started_;
  }

  [[nodiscard]] const rrdma::RfsoStats &MeasurementOrigin() const noexcept {
    return measurement_origin_;
  }

  [[nodiscard]] bool Verify(const rrdma::SessionReport &report) const noexcept {
    // 仅在 FPGA 已正常安全关闭后执行最终 ring 复扫。
    return consumer_.Verify(report);
  }

 private:
  rrdma::RfsoConsumer consumer_{};
  bool verbose_{};
  std::optional<Clock::time_point> traffic_started_;
  rrdma::RfsoStats measurement_origin_{};
};

int Run(const Options &options) {
  // CLI 将部署默认值组装为公共 SessionOptions，其余生命周期交由库管理。
  rrdma::SessionOptions config{};
  config.network.device_name = options.device;
  config.network.netdev_name = options.netdev;
  config.network.fpga_ipv4 = options.fpga_ip;
  config.network.local_ipv4 = "192.168.17.10";
  config.network.required_netmask = "255.255.255.0";
  config.session.receive_depth = options.receive_depth;
  config.session.notification = options.immediate ? rrdma::NotificationMode::kWriteWithImm : rrdma::NotificationMode::kPollCommit;

  auto receiver_result = rrdma::Session::Create(std::move(config));
  if (!receiver_result) {
    std::cerr << "configuration error: " << receiver_result.GetError().message
              << '\n';
    return EXIT_FAILURE;
  }
  auto receiver = std::move(receiver_result.Value());

  std::stop_source stop_source;
  std::atomic<bool> stop_bridge_finished{};
  const auto deadline = options.seconds == 0U ? Clock::time_point{} : Clock::now() + std::chrono::seconds(options.seconds);
  std::thread stop_bridge([&] {
    // 把异步信号和定时退出转换为 C++20 stop_token，避免 signal handler
    // 直接调用非 async-signal-safe API。
    while (!stop_bridge_finished.load(std::memory_order_acquire)) {
      if (g_signal_seen != 0 || (deadline != Clock::time_point{} && Clock::now() >= deadline)) {
        stop_source.request_stop();
        return;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds{20});
    }
  });

  ConsoleEvents events;
  RfsoApplicationConsumer consumer{options.verbose_commits};
  rrdma::Dependencies dependencies{};
  dependencies.events = rrdma::EventSink::Bind(events);
  auto result = receiver->Run(stop_source.get_token(),
                              rrdma::CommitCallback::Bind(consumer),
                              dependencies);
  stop_bridge_finished.store(true, std::memory_order_release);
  if (stop_bridge.joinable()) {
    stop_bridge.join();
  }
  if (!result) {
    std::cerr << "receiver failed: " << result.GetError().message;
    if (result.GetError().overrun_count != 0U) {
      std::cerr << " overruns=" << result.GetError().overrun_count;
    }
    std::cerr << '\n';
    return EXIT_FAILURE;
  }

  const auto &report = result.Value();
  // 只有正常释放、至少一个有效 RFSO 包且所有校验计数为零才返回成功。
  const auto &stats = consumer.Stats();
  if (!consumer.TrafficStarted().has_value() || stats.packets == 0U) {
    std::cerr << "no RFSO benchmark packets were observed\n";
    return EXIT_FAILURE;
  }
  const auto finished_at = Clock::now();
  const double elapsed_seconds = std::chrono::duration<double>(finished_at - *consumer.TrafficStarted()).count();
  const rrdma::ByteCount measured_bytes = stats.bytes - consumer.MeasurementOrigin().bytes;
  const double average_mib_per_second =
    elapsed_seconds > 0.0 ? static_cast<double>(measured_bytes) / kBytesPerMib / elapsed_seconds : 0.0;
  const double average_gbits_per_second =
    elapsed_seconds > 0.0 ? static_cast<double>(measured_bytes) * 8.0 / kBitsPerGigabit / elapsed_seconds : 0.0;

  std::cout << "Received=" << stats.packets << " bytes=" << stats.bytes
            << " measured_bytes=" << measured_bytes
            << " published=" << report.counters.published_bytes
            << " consumed=" << report.counters.consumed_bytes
            << " commits=" << stats.commits
            << " discontinuities=" << stats.discontinuities
            << " invalid=" << stats.invalid_headers
            << " overruns=" << (stats.overruns + report.counters.overruns)
            << " elapsed=" << std::fixed << std::setprecision(3)
            << elapsed_seconds << " s rate=" << std::setprecision(2)
            << average_mib_per_second << " MiB/s (" << std::setprecision(3)
            << average_gbits_per_second << " Gbps)\n";

  if (options.verify_on_exit && !consumer.Verify(report)) {
    std::cerr << "ring RFSO header verification failed\n";
    return EXIT_FAILURE;
  }

  if (stats.discontinuities != 0U || stats.invalid_headers != 0U
      || stats.overruns != 0U || report.counters.overruns != 0U) {
    std::cerr << "RFSO validation reported errors\n";
    return EXIT_FAILURE;
  }
  return report.normal_release ? EXIT_SUCCESS : EXIT_FAILURE;
}

} // namespace

int main(int argc, char **argv) {
  // 顶层兜底捕获异常，公共库 API 正常情况下只返回 Outcome。
  try {
    std::signal(SIGINT, HandleSignal);
    std::signal(SIGTERM, HandleSignal);
    Options options;
    const auto parse_result = ParseOptions(argc, argv, options);
    if (parse_result == ParseResult::kHelp) {
      return EXIT_SUCCESS;
    }
    if (parse_result == ParseResult::kFailure) {
      PrintUsage(argv[0]);
      return EXIT_FAILURE;
    }
    return Run(options);
  } catch (const std::exception &error) {
    std::cerr << "fatal: " << error.what() << '\n';
    return EXIT_FAILURE;
  } catch (...) {
    std::cerr << "fatal: unknown exception\n";
    return EXIT_FAILURE;
  }
}
