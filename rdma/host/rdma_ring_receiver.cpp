#include "rdcp_client.hpp"
#include "rdcp_stop_signal.hpp"
#include "rdma_host_runtime.hpp"
#include "rdma_ring_consumer.hpp"

#include <arpa/inet.h>
#include <getopt.h>
#include <infiniband/verbs.h>
#include <poll.h>

#include <array>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <limits>
#include <new>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>

namespace {

constexpr std::uint32_t kDefaultRecvDepth{1024};
constexpr std::uint64_t kRingSize{1024ULL * 1024ULL * 1024ULL};
constexpr std::uint64_t kWrSize{10ULL * 1024ULL * 1024ULL};
constexpr std::uint64_t kNotifyInterval{10ULL * 1024ULL * 1024ULL};
constexpr std::uint64_t kLocalBase{0};
constexpr std::string_view kDefaultFpgaIp{"192.168.17.11"};
constexpr std::chrono::seconds kDiscoveryWindow{10};
constexpr std::chrono::seconds kCommandWindow{3};
constexpr std::chrono::seconds kShutdownWindow{15};
constexpr std::uintptr_t kFpgaRemoteAddressLimit{1ULL << 48U};
constexpr std::chrono::seconds kRateReportInterval{1};
constexpr double kBytesPerMiB{1024.0 * 1024.0};
constexpr double kBitsPerGigabit{1000.0 * 1000.0 * 1000.0};

struct Options {
  std::string device_name;
  std::string netdev_name;
  std::string fpga_ip_text{kDefaultFpgaIp};
  std::uint32_t recv_depth{kDefaultRecvDepth};
  unsigned int run_seconds{};
  bool enable_immediate{};
  bool verify_on_exit{};
  bool verbose_commits{};
};

using rdma_ring::BenchmarkStats;
using rdma_ring::CommitSnapshot;
using rdma_ring::RateBaseline;

void usage(std::string_view program) {
  std::cerr
      << "Usage: " << program
      << " --device irdma0 --netdev <ice-netdev> [options]\n"
      << "\n"
      << "Required:\n"
      << "  --device NAME              libibverbs device, normally irdmaN\n"
      << "  --netdev NAME              matching ice netdevice\n"
      << "\n"
      << "Session options (ring/WR/notify are fixed at 1G/10M/10M):\n"
      << "  --fpga-ip IPv4             default 192.168.17.11\n"
      << "  --immediate                use WRITE_WITH_IMM commits and post "
         "RQEs\n"
      << "  --recv-depth COUNT         Immediate receive WQEs, default 1024\n"
      << "  --seconds VALUE            stop automatically after this duration\n"
      << "  --verify-on-exit           rescan RFSO headers after FPGA is "
         "closed\n"
      << "  --verbose-commits          print every commit instead of final "
         "only\n";
}

bool parse_u64(const std::string &text, std::uint64_t &value) {
  char *end{};

  errno = 0;
  const auto parsed = std::strtoull(text.c_str(), &end, 0);
  if (errno != 0 || end == text.c_str() || *end != '\0') {
    return false;
  }
  value = static_cast<std::uint64_t>(parsed);
  return true;
}

enum class ParseResult {
  success,
  help,
  failure,
};

ParseResult parse_options(int argc, char *argv[], Options &options) {
  static constexpr option long_options[] = {
      {"device", required_argument, nullptr, 'd'},
      {"netdev", required_argument, nullptr, 'n'},
      {"fpga-ip", required_argument, nullptr, 'i'},
      {"recv-depth", required_argument, nullptr, 'R'},
      {"immediate", no_argument, nullptr, 'I'},
      {"seconds", required_argument, nullptr, 't'},
      {"verify-on-exit", no_argument, nullptr, 'v'},
      {"verbose-commits", no_argument, nullptr, 'C'},
      {"help", no_argument, nullptr, 'h'},
      {nullptr, 0, nullptr, 0},
  };
  constexpr const char *short_options{"d:n:i:R:It:vCh"};

  ::optind = 1;
  ::opterr = 0;
  while (true) {
    const int option =
        ::getopt_long(argc, argv, short_options, long_options, nullptr);
    if (option == -1) {
      break;
    }
    const std::string argument = optarg == nullptr ? std::string{} : optarg;
    std::uint64_t value{};

    switch (option) {
    case 'd':
      options.device_name = argument;
      break;
    case 'n':
      options.netdev_name = argument;
      break;
    case 'i':
      options.fpga_ip_text = argument;
      break;
    case 'R':
      if (!parse_u64(argument, value) || value == 0 ||
          value > std::numeric_limits<std::uint32_t>::max()) {
        std::cerr << "invalid value for option -R\n";
        return ParseResult::failure;
      }
      options.recv_depth = static_cast<std::uint32_t>(value);
      break;
    case 'I':
      options.enable_immediate = true;
      break;
    case 't':
      if (!parse_u64(argument, value) ||
          value > std::numeric_limits<unsigned int>::max()) {
        std::cerr << "invalid value for option -t\n";
        return ParseResult::failure;
      }
      options.run_seconds = static_cast<unsigned int>(value);
      break;
    case 'v':
      options.verify_on_exit = true;
      break;
    case 'C':
      options.verbose_commits = true;
      break;
    case 'h':
      usage(argv[0]);
      return ParseResult::help;
    default:
      std::cerr << "invalid value for option -" << static_cast<char>(option)
                << '\n';
      return ParseResult::failure;
    }
  }

  in_addr fpga_ipv4{};
  if (options.device_name.empty() || options.netdev_name.empty() ||
      options.fpga_ip_text.empty() ||
      ::inet_pton(AF_INET, options.fpga_ip_text.c_str(), &fpga_ipv4) != 1 ||
      ::optind != argc) {
    usage(argv[0]);
    return ParseResult::failure;
  }
  return ParseResult::success;
}

bool validate_options(const Options &options) {
  if (kRingSize >
      std::numeric_limits<std::size_t>::max() - rdma_ring::kCommitBytes) {
    std::cerr << "ring allocation is too large for this process\n";
    return false;
  }
  if (options.recv_depth >
      static_cast<std::uint32_t>(std::numeric_limits<int>::max() - 16)) {
    std::cerr << "receive depth is too large for the completion queue\n";
    return false;
  }
  return true;
}

void abort_until_safe(rdcp::Client &control) noexcept {
  auto next_warning = std::chrono::steady_clock::now() + kShutdownWindow;
  bool exception_reported{};

  while (true) {
    try {
      if (control.abort_and_check_safe(kCommandWindow,
                                       std::chrono::milliseconds{200})) {
        return;
      }
    } catch (const std::exception &error) {
      if (!exception_reported) {
        std::cerr << "ABORT recovery raised an exception; retaining QP/MR "
                     "and retrying: "
                  << error.what() << '\n';
        exception_reported = true;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds{100});
    } catch (...) {
      if (!exception_reported) {
        std::cerr << "ABORT recovery raised an unknown exception; retaining "
                     "QP/MR and retrying\n";
        exception_reported = true;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds{100});
    }

    const auto now = std::chrono::steady_clock::now();
    if (now >= next_warning) {
      std::cerr << "FPGA has not reached FAULTED + safe_to_release; "
                   "holding QP/MR and continuing ABORT recovery\n";
      next_warning = now + kShutdownWindow;
    }
  }
}

class SessionReleaseGuard {
public:
  explicit SessionReleaseGuard(rdcp::Client &control) noexcept
      : control_(control) {}

  ~SessionReleaseGuard() {
    if (armed_) {
      abort_until_safe(control_);
    }
  }

  SessionReleaseGuard(const SessionReleaseGuard &) = delete;
  SessionReleaseGuard &operator=(const SessionReleaseGuard &) = delete;

  void arm() noexcept { armed_ = true; }

  void abort() noexcept {
    if (armed_) {
      abort_until_safe(control_);
      armed_ = false;
    }
  }

  void disarm() noexcept { armed_ = false; }

private:
  rdcp::Client &control_;
  bool armed_{};
};

int run_receiver(const Options &options) {
  in_addr fpga_ipv4{};
  rdma_host::NetdevInfo netdev{};

  if (::inet_pton(AF_INET, options.fpga_ip_text.c_str(), &fpga_ipv4) != 1) {
    std::cerr << "invalid FPGA IPv4 address\n";
    return EXIT_FAILURE;
  }
  if (!rdcp::install_stop_signal_handlers()) {
    std::cerr << "cannot install SIGINT/SIGTERM handlers\n";
    return EXIT_FAILURE;
  }
  if (!rdma_host::query_netdev(options.netdev_name, netdev)) {
    return EXIT_FAILURE;
  }

  rdma_host::UdpControlTransport control_transport{options.netdev_name,
                                                   netdev.ipv4, fpga_ipv4};
  rdcp::Client control{control_transport, rdma_host::random_nonzero_u32()};
  rdcp::Status control_status{};
  if (!control.transact(rdcp::Opcode::hello, kDiscoveryWindow,
                        control_status)) {
    std::cerr << "FPGA RDCP discovery timed out after 10 seconds\n";
    return EXIT_FAILURE;
  }
  const bool state_allows_config =
      control_status.state == rdcp::State::idle ||
      control_status.state == rdcp::State::closed ||
      control_status.state == rdcp::State::faulted;
  if (control_status.result != rdcp::Result::ok ||
      control_status.local_qpn != rdcp::kLocalQpn ||
      control_status.pmtu_bytes != rdcp::kPmtuBytes ||
      (control_status.capabilities & rdcp::kCapabilitiesV2) !=
          rdcp::kCapabilitiesV2 ||
      !state_allows_config) {
    std::cerr << "FPGA RDCP HELLO is incompatible: result="
              << static_cast<unsigned int>(control_status.result)
              << " state=" << static_cast<unsigned int>(control_status.state)
              << " qpn=" << control_status.local_qpn
              << " pmtu=" << control_status.pmtu_bytes << " capabilities=0x"
              << std::hex << control_status.capabilities << std::dec << '\n';
    return EXIT_FAILURE;
  }
  std::cout << "RDCP discovered " << options.fpga_ip_text
            << ": qpn=1 pmtu=4096 state="
            << static_cast<unsigned int>(control_status.state) << '\n';
  if (rdcp::stop_signal_requested()) {
    std::cerr << "termination requested before FPGA configuration\n";
    return EXIT_FAILURE;
  }

  const auto required_bytes = kRingSize + rdma_ring::kCommitBytes;
  if (!rdma_host::check_memlock_limit(required_bytes)) {
    return EXIT_FAILURE;
  }

  rdma_host::AlignedBuffer ring_memory{
      static_cast<std::size_t>(required_bytes)};
  auto *commit_storage =
      ring_memory.data() + static_cast<std::size_t>(kRingSize);
  auto *commit =
      ::new (static_cast<void *>(commit_storage)) rdma_ring::CommitRecord{};
  const auto ring_address =
      reinterpret_cast<std::uintptr_t>(ring_memory.data());
  const auto commit_address = reinterpret_cast<std::uintptr_t>(commit);
  if (ring_address >= kFpgaRemoteAddressLimit ||
      commit_address > kFpgaRemoteAddressLimit - rdma_ring::kCommitBytes) {
    std::cerr
        << "the allocated MR is outside the FPGA 48-bit remote-address range\n";
    return EXIT_FAILURE;
  }

  rdma_host::ContextPtr context = rdma_host::open_device(options.device_name);
  if (!context) {
    return EXIT_FAILURE;
  }

  int gid_index{-1};
  ibv_gid host_gid{};
  if (!rdma_host::select_rocev2_gid(context.get(), netdev, gid_index,
                                    host_gid)) {
    return EXIT_FAILURE;
  }
  const ibv_gid fpga_gid = rdma_host::ipv4_mapped_gid(fpga_ipv4);

  rdma_host::ProtectionDomainPtr protection_domain{ibv_alloc_pd(context.get())};
  if (!protection_domain) {
    std::perror("ibv_alloc_pd");
    return EXIT_FAILURE;
  }
  rdma_host::MemoryRegionPtr memory_region{ibv_reg_mr(
      protection_domain.get(), ring_memory.data(), ring_memory.size(),
      IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE)};
  if (!memory_region) {
    std::perror("ibv_reg_mr");
    return EXIT_FAILURE;
  }
  rdma_host::CompletionQueuePtr completion_queue{
      ibv_create_cq(context.get(), static_cast<int>(options.recv_depth) + 16,
                    nullptr, nullptr, 0)};
  if (!completion_queue) {
    std::perror("ibv_create_cq");
    return EXIT_FAILURE;
  }

  ibv_qp_init_attr init_attr{};
  init_attr.send_cq = completion_queue.get();
  init_attr.recv_cq = completion_queue.get();
  init_attr.qp_type = IBV_QPT_RC;
  init_attr.cap.max_send_wr = 1;
  init_attr.cap.max_recv_wr = options.enable_immediate ? options.recv_depth : 1;
  init_attr.cap.max_send_sge = 1;
  init_attr.cap.max_recv_sge = 1;
  rdma_host::QueuePairPtr queue_pair{
      ibv_create_qp(protection_domain.get(), &init_attr)};
  if (!queue_pair) {
    std::perror("ibv_create_qp");
    return EXIT_FAILURE;
  }
  if (options.enable_immediate) {
    for (std::uint32_t index = 0; index < options.recv_depth; ++index) {
      if (!rdma_host::post_receive(
              queue_pair.get(), memory_region.get(), commit,
              static_cast<std::uint32_t>(rdma_ring::kCommitBytes), index)) {
        return EXIT_FAILURE;
      }
    }
  }
  const std::uint32_t fpga_tx_psn = rdma_host::random_nonzero_psn();
  const std::uint32_t host_tx_psn = rdma_host::random_nonzero_psn();
  if (!rdma_host::modify_qp_to_rts(queue_pair.get(), gid_index, fpga_gid,
                                   fpga_tx_psn, host_tx_psn)) {
    return EXIT_FAILURE;
  }
  if (rdcp::stop_signal_requested()) {
    std::cerr << "termination requested before FPGA configuration\n";
    return EXIT_FAILURE;
  }

  const std::uint64_t session_id = rdma_host::random_nonzero_u64();
  control.set_session(session_id);
  rdcp::Config config{};
  config.remote_qpn = queue_pair->qp_num;
  config.local_psn = fpga_tx_psn;
  config.remote_base = ring_address;
  config.rkey = memory_region->rkey;
  config.ring_size = static_cast<std::uint32_t>(kRingSize);
  config.wr_size = static_cast<std::uint32_t>(kWrSize);
  config.notify_interval = static_cast<std::uint32_t>(kNotifyInterval);
  config.local_base = kLocalBase;
  config.commit_address = commit_address;
  config.flags = options.enable_immediate ? 1U : 0U;

  SessionReleaseGuard session_guard{control};
  session_guard.arm();
  const bool config_response_received =
      control.configure(config, kCommandWindow, control_status);
  if (!config_response_received) {
    std::cerr << "RDCP CONFIG response timed out; aborting the possibly "
                 "configured session\n";
    session_guard.abort();
    return EXIT_FAILURE;
  }
  if (control_status.result != rdcp::Result::ok ||
      control_status.state != rdcp::State::ready) {
    std::cerr << "RDCP CONFIG failed: result="
              << static_cast<unsigned int>(control_status.result)
              << " state=" << static_cast<unsigned int>(control_status.state)
              << " reason=0x" << std::hex << control_status.reason << std::dec
              << '\n';
    session_guard.disarm();
    return EXIT_FAILURE;
  }

  if (rdcp::stop_signal_requested()) {
    std::cerr << "termination requested during CONFIG; aborting the "
                 "configured session\n";
    session_guard.abort();
    return EXIT_FAILURE;
  }
  if (!control.transact(rdcp::Opcode::start, kCommandWindow, control_status) ||
      control_status.result != rdcp::Result::ok ||
      control_status.state != rdcp::State::running) {
    std::cerr << "RDCP START failed; aborting the configured session\n";
    session_guard.abort();
    return EXIT_FAILURE;
  }
  const auto session_started_at = std::chrono::steady_clock::now();

  char host_ip_text[INET_ADDRSTRLEN]{};
  ::inet_ntop(AF_INET, &netdev.ipv4, host_ip_text, sizeof(host_ip_text));
  std::cout << "session running: host=" << host_ip_text
            << " mac=" << rdma_host::format_mac(netdev.mac)
            << " gid=" << rdma_host::format_gid(host_gid)
            << " gid_index=" << gid_index << " qpn=" << queue_pair->qp_num
            << " fpga_tx_psn=" << fpga_tx_psn
            << " ring=1G wr=10M notify=10M flow_control=1 immediate="
            << (options.enable_immediate ? 1U : 0U) << '\n';

  bool duration_elapsed{};
  bool shutdown_requested{};
  bool stop_command_sent{};
  bool session_failed{};
  std::optional<std::chrono::steady_clock::time_point> shutdown_deadline;
  auto next_status_poll = std::chrono::steady_clock::now();
  rdcp::ReleaseGate release_gate;
  CommitSnapshot last_commit{};
  BenchmarkStats benchmark_stats{};
  BenchmarkStats measurement_origin{};
  RateBaseline rate_baseline{};
  std::optional<std::chrono::steady_clock::time_point> traffic_started;
  std::uint64_t scanned_bytes{};
  std::uint64_t confirmed_consumed_bytes{};
  const volatile std::uint8_t *ring = ring_memory.data();

  while (true) {
    const auto now = std::chrono::steady_clock::now();
    if (rdcp::stop_signal_requested() && !shutdown_requested) {
      shutdown_requested = true;
      shutdown_deadline = now + kShutdownWindow;
      std::cerr << "termination requested; stopping the FPGA session\n";
    }
    if (options.run_seconds != 0 && !duration_elapsed &&
        now - session_started_at >= std::chrono::seconds{options.run_seconds}) {
      duration_elapsed = true;
      shutdown_requested = true;
      shutdown_deadline = now + kShutdownWindow;
      std::cerr << "requested duration elapsed; stopping the FPGA session\n";
    }
    if (shutdown_requested && !stop_command_sent) {
      stop_command_sent = true;
      if (!control.transact(rdcp::Opcode::stop, kShutdownWindow,
                            control_status) ||
          control_status.result != rdcp::Result::ok) {
        std::cerr << "RDCP STOP failed; aborting the session\n";
        session_failed = true;
        session_guard.abort();
        break;
      }
      release_gate.observe_status(control_status);
    }

    std::array<ibv_wc, 16> completions{};
    int completion_count{};
    while ((completion_count = ibv_poll_cq(completion_queue.get(),
                                           static_cast<int>(completions.size()),
                                           completions.data())) > 0) {
      for (int index = 0; index < completion_count; ++index) {
        const ibv_wc &completion = completions[static_cast<std::size_t>(index)];

        if (completion.status != IBV_WC_SUCCESS) {
          std::cerr << "CQ error: status="
                    << ibv_wc_status_str(completion.status)
                    << " opcode=" << completion.opcode
                    << " wr_id=" << completion.wr_id << '\n';
          session_failed = true;
          break;
        }
        if (completion.opcode != IBV_WC_RECV_RDMA_WITH_IMM) {
          std::cerr << "unexpected receive completion opcode "
                    << completion.opcode << '\n';
          session_failed = true;
          break;
        }
        if (options.verbose_commits) {
          std::cout << "immediate sequence low32=" << ntohl(completion.imm_data)
                    << '\n';
        }
        if (!rdma_host::post_receive(
                queue_pair.get(), memory_region.get(), commit,
                static_cast<std::uint32_t>(rdma_ring::kCommitBytes),
                completion.wr_id)) {
          session_failed = true;
          break;
        }
      }
      if (session_failed) {
        break;
      }
    }
    if (completion_count < 0) {
      std::cerr << "ibv_poll_cq failed\n";
      session_failed = true;
    }
    if (session_failed) {
      session_guard.abort();
      break;
    }

    pollfd async_fd{};
    async_fd.fd = context->async_fd;
    async_fd.events = POLLIN;
    if (::poll(&async_fd, 1, 0) > 0 && (async_fd.revents & POLLIN) != 0) {
      ibv_async_event event{};
      if (ibv_get_async_event(context.get(), &event) == 0) {
        std::cerr << "RDMA async event: "
                  << ibv_event_type_str(event.event_type) << '\n';
        ibv_ack_async_event(&event);
        session_failed = true;
      }
    }
    if (session_failed) {
      session_guard.abort();
      break;
    }

    CommitSnapshot snapshot{};
    if (rdma_ring::read_commit(commit, snapshot) &&
        snapshot.sequence != last_commit.sequence) {
      bool commit_valid{true};
      if (last_commit.sequence != 0 &&
          snapshot.sequence < last_commit.sequence) {
        std::cerr << "commit sequence moved backwards: previous="
                  << last_commit.sequence << " current=" << snapshot.sequence
                  << '\n';
        commit_valid = false;
      }
      if (!rdma_ring::is_valid_commit_interval(snapshot, kNotifyInterval)) {
        std::cerr << "commit interval is invalid: FPGA="
                  << snapshot.interval_bytes
                  << " host-configured=" << kNotifyInterval
                  << " final=" << (snapshot.final ? 1U : 0U) << '\n';
        commit_valid = false;
      }
      if (!commit_valid) {
        session_failed = true;
        session_guard.abort();
        break;
      }
      const bool establish_measurement_origin =
          !traffic_started.has_value() && snapshot.published_bytes != 0;
      const auto measurement_started =
          establish_measurement_origin
              ? std::chrono::steady_clock::now()
              : std::chrono::steady_clock::time_point{};
      const bool scan_ok = rdma_ring::scan_benchmark_headers(
          ring, kRingSize, snapshot, scanned_bytes, benchmark_stats);
      if (!scan_ok) {
        std::cerr << "committed ring data failed validation; aborting the "
                     "session without returning credit\n";
        session_failed = true;
        session_guard.abort();
        break;
      } else if (scanned_bytes > confirmed_consumed_bytes) {
        rdcp::Status consume_status{};
        bool response_observed = false;
        const bool consume_completed =
            control.consume(scanned_bytes, kCommandWindow, consume_status,
                            &response_observed);
        if (!consume_completed ||
            consume_status.result != rdcp::Result::ok ||
            consume_status.consumed_bytes != scanned_bytes) {
          std::cerr << "RDCP CONSUME failed at " << scanned_bytes
                    << " bytes: consume_completed=" << consume_completed
                    << " verified_reply=" << response_observed;
          if (response_observed) {
            std::cerr << " result=" << static_cast<unsigned>(consume_status.result)
                      << " reason=" << consume_status.reason
                      << " state=" << static_cast<unsigned>(consume_status.state)
                      << " consumed=" << consume_status.consumed_bytes
                      << " published=" << consume_status.published_bytes
                      << " acked=" << consume_status.acked_bytes;
          }
          std::cerr << "; aborting the session\n";
          session_failed = true;
          session_guard.abort();
          break;
        }
        confirmed_consumed_bytes = scanned_bytes;
        control_status = consume_status;
        release_gate.observe_status(control_status);
      }
      if (establish_measurement_origin) {
        traffic_started = measurement_started;
        measurement_origin = benchmark_stats;
        rate_baseline.time = measurement_started;
        rate_baseline.packets = benchmark_stats.packets;
        rate_baseline.bytes = benchmark_stats.bytes;
        rate_baseline.discontinuities = benchmark_stats.discontinuities;
        rate_baseline.invalid_headers = benchmark_stats.invalid_headers;
        rate_baseline.commits = benchmark_stats.commits;
      }
      last_commit = snapshot;
      if (snapshot.final) {
        release_gate.observe_final_commit();
        if (!shutdown_deadline.has_value()) {
          shutdown_deadline = now + kShutdownWindow;
        }
      }
      if (options.verbose_commits || snapshot.final) {
        std::cout << "commit sequence=" << snapshot.sequence
                  << " published=" << snapshot.published_bytes
                  << " end=" << snapshot.ring_end_offset
                  << " interval=" << snapshot.interval_bytes
                  << " final=" << (snapshot.final ? 1U : 0U) << '\n';
      }
    }
    const auto report_now = std::chrono::steady_clock::now();
    if (traffic_started.has_value() &&
        report_now - rate_baseline.time >= kRateReportInterval) {
      rdma_ring::report_rate(benchmark_stats, report_now, rate_baseline);
    }

    if (report_now >= next_status_poll) {
      rdcp::Status next_status{};
      if (control.transact(rdcp::Opcode::status, std::chrono::milliseconds{200},
                           next_status)) {
        control_status = next_status;
        release_gate.observe_status(control_status);
        if ((control_status.state == rdcp::State::stopping ||
             control_status.state == rdcp::State::closed) &&
            !shutdown_deadline.has_value()) {
          shutdown_deadline =
              std::chrono::steady_clock::now() + kShutdownWindow;
        }
        if (rdcp::active_session_requires_abort(control_status)) {
          std::cerr << "FPGA session fault: state="
                    << static_cast<unsigned int>(control_status.state)
                    << " reason=0x" << std::hex << control_status.reason
                    << std::dec << '\n';
          session_failed = true;
          session_guard.abort();
          break;
        }
      }
      next_status_poll =
          std::chrono::steady_clock::now() + std::chrono::milliseconds{100};
    }
    if (release_gate.normal_release_ready()) {
      break;
    }
    if (shutdown_deadline.has_value() &&
        std::chrono::steady_clock::now() >= *shutdown_deadline) {
      std::cerr << "normal shutdown did not reach final + CLOSED/safe; "
                   "aborting the session\n";
      session_failed = true;
      session_guard.abort();
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }

  if (session_failed) {
    return EXIT_FAILURE;
  }
  session_guard.disarm();
  if (!last_commit.final) {
    std::cerr
        << "no FPGA final commit was observed; refusing a successful teardown "
        << "while the ring may still be active\n";
    return EXIT_FAILURE;
  }
  if (!traffic_started.has_value() || benchmark_stats.packets == 0) {
    std::cerr << "no RFSO benchmark packets were observed\n";
    return EXIT_FAILURE;
  }

  const auto finished = std::chrono::steady_clock::now();
  const double elapsed_seconds =
      std::chrono::duration<double>(finished - *traffic_started).count();
  const std::uint64_t measured_bytes =
      benchmark_stats.bytes - measurement_origin.bytes;
  const double average_mib_per_second =
      elapsed_seconds > 0.0
          ? static_cast<double>(measured_bytes) / kBytesPerMiB / elapsed_seconds
          : 0.0;
  const double average_gbits_per_second =
      elapsed_seconds > 0.0 ? static_cast<double>(measured_bytes) * 8.0 /
                                  kBitsPerGigabit / elapsed_seconds
                            : 0.0;
  std::cout << "Received=" << benchmark_stats.packets
            << " bytes=" << benchmark_stats.bytes
            << " measured_bytes=" << measured_bytes
            << " published=" << benchmark_stats.published_bytes
            << " consumed=" << confirmed_consumed_bytes
            << " commits=" << benchmark_stats.commits
            << " discontinuities=" << benchmark_stats.discontinuities
            << " invalid=" << benchmark_stats.invalid_headers
            << " overruns=" << benchmark_stats.overruns
            << " elapsed=" << std::fixed << std::setprecision(3)
            << elapsed_seconds << " s rate=" << std::setprecision(2)
            << average_mib_per_second << " MiB/s (" << std::setprecision(3)
            << average_gbits_per_second << " Gbps)\n";

  if (options.verify_on_exit &&
      (last_commit.sequence == 0 ||
       !rdma_ring::verify_ring_headers(ring, last_commit, kRingSize))) {
    return EXIT_FAILURE;
  }
  if (benchmark_stats.discontinuities != 0 ||
      benchmark_stats.invalid_headers != 0 || benchmark_stats.overruns != 0) {
    return EXIT_FAILURE;
  }
  return EXIT_SUCCESS;
}

} // namespace

int main(int argc, char *argv[]) {
  try {
    Options options;
    const auto parse_result = parse_options(argc, argv, options);
    if (parse_result == ParseResult::help) {
      return EXIT_SUCCESS;
    }
    if (parse_result == ParseResult::failure) {
      return EXIT_FAILURE;
    }
    if (!validate_options(options)) {
      return EXIT_FAILURE;
    }
    return run_receiver(options);
  } catch (const std::exception &error) {
    std::cerr << "fatal: " << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
