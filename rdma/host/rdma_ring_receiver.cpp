#include "rdma_benchmark_header.hpp"

#include <arpa/inet.h>
#include <endian.h>
#include <getopt.h>
#include <infiniband/verbs.h>
#include <net/if.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <type_traits>
#include <utility>

namespace {

constexpr std::size_t kRdmaPmtuBytes{4096};
constexpr std::size_t kCommitBytes{64};
constexpr std::uint32_t kCommitMagic{0x52444d41U};
constexpr std::size_t kCommitSequenceOffset{40};
constexpr std::uint32_t kDefaultRecvDepth{1024};
constexpr std::uintptr_t kFpgaRemoteAddressLimit{1ULL << 48U};
constexpr std::uint64_t kMaxReportedHeaderErrors{10};
constexpr std::chrono::seconds kRateReportInterval{1};
constexpr double kBytesPerMiB{1024.0 * 1024.0};
constexpr double kBitsPerGigabit{1000.0 * 1000.0 * 1000.0};

struct alignas(kCommitBytes) RdmaRingCommit {
    std::uint64_t published_bytes;
    std::uint32_t ring_end_offset;
    std::uint32_t interval_bytes;
    std::uint32_t final;
    std::uint32_t magic;
    std::array<std::uint8_t, 16> reserved_before_sequence;
    std::uint64_t producer_sequence;
    std::array<std::uint8_t, 16> reserved_after_sequence;
};

static_assert(sizeof(RdmaRingCommit) == kCommitBytes,
              "commit record must be exactly 64 bytes");
static_assert(offsetof(RdmaRingCommit, producer_sequence) == kCommitSequenceOffset,
              "commit release sequence offset must match the FPGA RTL");
static_assert(std::is_trivially_copyable_v<RdmaRingCommit>,
              "commit record must remain trivially copyable");

struct Options {
    std::string device_name;
    std::string netdev_name;
    std::string fpga_ip_text;
    std::string fpga_mac_text;
    std::uint8_t port_num{1};
    std::uint32_t fpga_qpn{1};
    std::uint32_t fpga_tx_psn{};
    std::uint32_t host_tx_psn{};
    std::uint64_t ring_size{1024ULL * 1024ULL * 1024ULL};
    std::uint64_t wr_size{1024ULL * 1024ULL};
    std::uint64_t notify_interval{1024ULL * 1024ULL};
    std::uint64_t local_base{};
    std::uint32_t recv_depth{kDefaultRecvDepth};
    unsigned int run_seconds{};
    bool enable_immediate{};
    bool allow_ring_wrap{};
    bool verify_on_exit{};
    bool verbose_commits{};
};

struct NetdevInfo {
    in_addr ipv4{};
    std::array<std::uint8_t, 6> mac{};
    int mtu{};
    unsigned int ifindex{};
};

struct CommitSnapshot {
    std::uint64_t sequence{};
    std::uint64_t published_bytes{};
    std::uint32_t ring_end_offset{};
    std::uint32_t interval_bytes{};
    bool final{};
};

using BenchmarkStats = rdma_benchmark::ScanStats;

struct RateBaseline {
    std::chrono::steady_clock::time_point time{};
    std::uint64_t packets{};
    std::uint64_t bytes{};
    std::uint64_t discontinuities{};
    std::uint64_t invalid_headers{};
    std::uint64_t commits{};
};

volatile sig_atomic_t stop_requested{};

void on_signal(int) noexcept {
    stop_requested = 1;
}

void usage(std::string_view program) {
    std::cerr
        << "Usage: " << program
        << " --device irdma0 --netdev <ice-netdev> --fpga-ip A.B.C.D \\\n"
        << "       --fpga-mac XX:XX:XX:XX:XX:XX [options]\n"
        << "\n"
        << "Required:\n"
        << "  --device NAME              libibverbs device, normally irdmaN\n"
        << "  --netdev NAME              matching ice netdevice\n"
        << "  --fpga-ip IPv4             FPGA IPv4 address\n"
        << "  --fpga-mac MAC             FPGA Ethernet MAC address\n"
        << "\n"
        << "Ring / notification options:\n"
        << "  --ring-size SIZE           default 1G, must be 4096-byte aligned\n"
        << "  --wr-size SIZE             default 1M, must be <= ring size\n"
        << "  --notify-interval SIZE     default 1M; for example 1M or 10M\n"
        << "  --immediate                use WRITE_WITH_IMM commits and post RQEs\n"
        << "  --recv-depth COUNT         Immediate receive WQEs, default 1024\n"
        << "  --allow-ring-wrap          permit overwrite after one ring; requires consumer credit\n"
        << "  --local-base VALUE         FPGA data-generator base, default 0\n"
        << "\n"
        << "QP / runtime options:\n"
        << "  --fpga-qpn VALUE           default 1, valid range 1..255\n"
        << "  --fpga-tx-psn VALUE        default random 24-bit PSN\n"
        << "  --host-tx-psn VALUE        default random 24-bit PSN\n"
        << "  --port VALUE               RDMA port, default 1\n"
        << "  --seconds VALUE            print a stop reminder after this duration\n"
        << "  --verify-on-exit           rescan RFSO headers after FPGA is drained\n"
        << "  --verbose-commits          print every commit instead of final only\n";
}

bool parse_u64(const std::string& text, std::uint64_t& value) {
    char* end{};

    errno = 0;
    const auto parsed = std::strtoull(text.c_str(), &end, 0);
    if (errno != 0 || end == text.c_str() || *end != '\0') {
        return false;
    }
    value = static_cast<std::uint64_t>(parsed);
    return true;
}

bool parse_size(const std::string& text, std::uint64_t& value) {
    char* end{};
    std::uint64_t multiplier{1};

    errno = 0;
    const auto parsed = std::strtoull(text.c_str(), &end, 0);
    if (errno != 0 || end == text.c_str()) {
        return false;
    }
    if (*end != '\0') {
        if (end[1] != '\0') {
            return false;
        }
        switch (*end) {
        case 'k':
        case 'K':
            multiplier = 1024ULL;
            break;
        case 'm':
        case 'M':
            multiplier = 1024ULL * 1024ULL;
            break;
        case 'g':
        case 'G':
            multiplier = 1024ULL * 1024ULL * 1024ULL;
            break;
        default:
            return false;
        }
    }
    if (parsed > std::numeric_limits<std::uint64_t>::max() / multiplier) {
        return false;
    }
    value = static_cast<std::uint64_t>(parsed) * multiplier;
    return true;
}

bool parse_psn(const std::string& text, std::uint32_t& psn) {
    std::uint64_t value{};

    if (!parse_u64(text, value) || value > 0xffffffULL) {
        return false;
    }
    psn = static_cast<std::uint32_t>(value);
    return true;
}

bool parse_mac(const std::string& text, std::array<std::uint8_t, 6>& mac) {
    std::array<unsigned int, 6> bytes{};

    if (std::sscanf(text.c_str(), "%x:%x:%x:%x:%x:%x", &bytes[0], &bytes[1],
                    &bytes[2], &bytes[3], &bytes[4], &bytes[5]) != 6) {
        return false;
    }
    for (std::size_t index = 0; index < mac.size(); ++index) {
        if (bytes[index] > 0xffU) {
            return false;
        }
        mac[index] = static_cast<std::uint8_t>(bytes[index]);
    }
    return true;
}

std::string format_mac(const std::array<std::uint8_t, 6>& mac) {
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

std::string format_mac_vio(const std::array<std::uint8_t, 6>& mac) {
    std::ostringstream output;

    output << "0x" << std::hex << std::uppercase << std::setfill('0');
    for (const auto byte : mac) {
        output << std::setw(2) << static_cast<unsigned int>(byte);
    }
    return output.str();
}

std::string format_gid(const ibv_gid& gid) {
    std::ostringstream output;

    output << std::hex << std::nouppercase << std::setfill('0');
    for (const auto byte : gid.raw) {
        output << std::setw(2) << static_cast<unsigned int>(byte);
    }
    return output.str();
}

std::string format_hex(std::uint64_t value, std::size_t width) {
    std::ostringstream output;

    output << "0x" << std::hex << std::uppercase << std::setfill('0')
           << std::setw(static_cast<int>(width)) << value;
    return output.str();
}

bool gid_matches_ipv4(const ibv_gid& gid, const in_addr& ipv4) {
    constexpr std::array<std::uint8_t, 12> prefix{
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};

    return std::memcmp(gid.raw, prefix.data(), prefix.size()) == 0 &&
           std::memcmp(&gid.raw[12], &ipv4.s_addr, sizeof(ipv4.s_addr)) == 0;
}

ibv_gid ipv4_mapped_gid(const in_addr& ipv4) {
    ibv_gid result{};

    result.raw[10] = 0xff;
    result.raw[11] = 0xff;
    std::memcpy(&result.raw[12], &ipv4.s_addr, sizeof(ipv4.s_addr));
    return result;
}

class FileDescriptor {
public:
    explicit FileDescriptor(int fd = -1) noexcept : fd_(fd) {}

    ~FileDescriptor() {
        reset();
    }

    FileDescriptor(const FileDescriptor&) = delete;
    FileDescriptor& operator=(const FileDescriptor&) = delete;

    FileDescriptor(FileDescriptor&& other) noexcept
        : fd_(std::exchange(other.fd_, -1)) {}

    FileDescriptor& operator=(FileDescriptor&& other) noexcept {
        if (this != &other) {
            reset();
            fd_ = std::exchange(other.fd_, -1);
        }
        return *this;
    }

    int get() const noexcept {
        return fd_;
    }

private:
    void reset() noexcept {
        if (fd_ >= 0) {
            ::close(fd_);
            fd_ = -1;
        }
    }

    int fd_;
};

bool query_netdev(const std::string& name, NetdevInfo& info) {
    FileDescriptor socket_fd{::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)};
    if (socket_fd.get() < 0) {
        std::perror("socket");
        return false;
    }

    ifreq request{};
    std::strncpy(request.ifr_name, name.c_str(), IFNAMSIZ - 1);
    request.ifr_name[IFNAMSIZ - 1] = '\0';
    if (::ioctl(socket_fd.get(), SIOCGIFADDR, &request) != 0 ||
        request.ifr_addr.sa_family != AF_INET) {
        std::perror("SIOCGIFADDR");
        return false;
    }
    info.ipv4 = reinterpret_cast<sockaddr_in*>(&request.ifr_addr)->sin_addr;

    if (::ioctl(socket_fd.get(), SIOCGIFHWADDR, &request) != 0) {
        std::perror("SIOCGIFHWADDR");
        return false;
    }
    std::memcpy(info.mac.data(), request.ifr_hwaddr.sa_data, info.mac.size());

    if (::ioctl(socket_fd.get(), SIOCGIFMTU, &request) != 0) {
        std::perror("SIOCGIFMTU");
        return false;
    }
    info.mtu = request.ifr_mtu;

    if (::ioctl(socket_fd.get(), SIOCGIFFLAGS, &request) != 0) {
        std::perror("SIOCGIFFLAGS");
        return false;
    }
    if ((request.ifr_flags & IFF_UP) == 0 ||
        (request.ifr_flags & IFF_RUNNING) == 0) {
        std::cerr << "netdev " << name << " is not up and carrier-running\n";
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
    return true;
}

struct DeviceListDeleter {
    void operator()(ibv_device** devices) const noexcept {
        if (devices != nullptr) {
            ibv_free_device_list(devices);
        }
    }
};

struct ContextDeleter {
    void operator()(ibv_context* context) const noexcept {
        if (context != nullptr) {
            ibv_close_device(context);
        }
    }
};

struct ProtectionDomainDeleter {
    void operator()(ibv_pd* protection_domain) const noexcept {
        if (protection_domain != nullptr) {
            ibv_dealloc_pd(protection_domain);
        }
    }
};

struct CompletionQueueDeleter {
    void operator()(ibv_cq* completion_queue) const noexcept {
        if (completion_queue != nullptr) {
            ibv_destroy_cq(completion_queue);
        }
    }
};

struct QueuePairDeleter {
    void operator()(ibv_qp* queue_pair) const noexcept {
        if (queue_pair != nullptr) {
            ibv_destroy_qp(queue_pair);
        }
    }
};

struct MemoryRegionDeleter {
    void operator()(ibv_mr* memory_region) const noexcept {
        if (memory_region != nullptr) {
            ibv_dereg_mr(memory_region);
        }
    }
};

using DeviceListPtr = std::unique_ptr<ibv_device*, DeviceListDeleter>;
using ContextPtr = std::unique_ptr<ibv_context, ContextDeleter>;
using ProtectionDomainPtr = std::unique_ptr<ibv_pd, ProtectionDomainDeleter>;
using CompletionQueuePtr = std::unique_ptr<ibv_cq, CompletionQueueDeleter>;
using QueuePairPtr = std::unique_ptr<ibv_qp, QueuePairDeleter>;
using MemoryRegionPtr = std::unique_ptr<ibv_mr, MemoryRegionDeleter>;

ContextPtr open_device(const std::string& name) {
    int device_count{};
    DeviceListPtr devices{ibv_get_device_list(&device_count)};
    if (!devices) {
        std::perror("ibv_get_device_list");
        return {};
    }

    ContextPtr context;
    for (int index = 0; index < device_count; ++index) {
        ibv_device* device = devices.get()[index];
        const char* device_name = ibv_get_device_name(device);

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

bool select_rocev2_gid(ibv_context* context, std::uint8_t port_num,
                       const NetdevInfo& netdev, int& gid_index, ibv_gid& gid) {
    ibv_port_attr port_attr{};

    if (ibv_query_port(context, port_num, &port_attr) != 0) {
        std::perror("ibv_query_port");
        return false;
    }
    if (port_attr.state != IBV_PORT_ACTIVE) {
        std::cerr << "RDMA port " << static_cast<unsigned int>(port_num)
                  << " is not active\n";
        return false;
    }
    if (port_attr.active_mtu < IBV_MTU_4096) {
        std::cerr << "RDMA port " << static_cast<unsigned int>(port_num)
                  << " active MTU is smaller than 4096\n";
        return false;
    }
    for (int index = 0; index < port_attr.gid_tbl_len; ++index) {
        ibv_gid_entry entry{};

        if (ibv_query_gid_ex(context, port_num, index, &entry, 0) != 0) {
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
    std::cerr << "no RoCEv2 GID on port "
              << static_cast<unsigned int>(port_num)
              << " matches the selected netdev and its IPv4 address\n";
    return false;
}

bool modify_qp_to_rts(ibv_qp* queue_pair, const Options& options, int gid_index,
                      const ibv_gid& fpga_gid) {
    ibv_qp_attr attr{};
    int mask{};

    attr.qp_state = IBV_QPS_INIT;
    attr.pkey_index = 0;
    attr.port_num = options.port_num;
    attr.qp_access_flags = IBV_ACCESS_REMOTE_WRITE;
    mask = IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS;
    if (ibv_modify_qp(queue_pair, &attr, mask) != 0) {
        std::perror("ibv_modify_qp INIT");
        return false;
    }

    attr = {};
    attr.qp_state = IBV_QPS_RTR;
    attr.path_mtu = IBV_MTU_4096;
    attr.dest_qp_num = options.fpga_qpn;
    attr.rq_psn = options.fpga_tx_psn;
    attr.max_dest_rd_atomic = 1;
    attr.min_rnr_timer = 12;
    attr.ah_attr.is_global = 1;
    attr.ah_attr.port_num = options.port_num;
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
    attr.sq_psn = options.host_tx_psn;
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

bool post_receive(ibv_qp* queue_pair, const ibv_mr* memory_region,
                  const void* scratch, std::uint64_t work_request_id) {
    ibv_sge scatter_gather{};
    ibv_recv_wr receive{};
    ibv_recv_wr* bad_work_request{};

    scatter_gather.addr = reinterpret_cast<std::uintptr_t>(scratch);
    scatter_gather.length = static_cast<std::uint32_t>(kCommitBytes);
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

bool read_commit(const volatile RdmaRingCommit* record, CommitSnapshot& snapshot) {
    RdmaRingCommit local{};
    const auto first_sequence =
        __atomic_load_n(&record->producer_sequence, __ATOMIC_ACQUIRE);
    if (first_sequence == 0) {
        return false;
    }
    std::atomic_thread_fence(std::memory_order_acquire);
    std::memcpy(&local,
                const_cast<const void*>(
                    static_cast<const volatile void*>(record)),
                sizeof(local));
    std::atomic_thread_fence(std::memory_order_acquire);
    const auto second_sequence =
        __atomic_load_n(&record->producer_sequence, __ATOMIC_ACQUIRE);
    if (first_sequence != second_sequence ||
        le64toh(local.producer_sequence) != second_sequence ||
        le32toh(local.magic) != kCommitMagic) {
        return false;
    }
    snapshot.sequence = second_sequence;
    snapshot.published_bytes = le64toh(local.published_bytes);
    snapshot.ring_end_offset = le32toh(local.ring_end_offset);
    snapshot.interval_bytes = le32toh(local.interval_bytes);
    snapshot.final = le32toh(local.final) != 0;
    return true;
}

void report_sequence_discontinuity(std::uint64_t count,
                                   std::uint64_t published_offset,
                                   const rdma_benchmark::SequenceObservation& observation) {
    if (count <= kMaxReportedHeaderErrors) {
        std::cerr << "Sequence discontinuity: offset=" << published_offset
                  << " expected=0x" << std::hex << observation.expected
                  << " actual=0x" << observation.actual << std::dec << '\n';
    } else if (count == kMaxReportedHeaderErrors + 1) {
        std::cerr << "Further discontinuity details suppressed; counting continues\n";
    }
}

void report_invalid_header(std::uint64_t count, std::uint64_t published_offset,
                           std::uint32_t magic) {
    if (count <= kMaxReportedHeaderErrors) {
        std::cerr << "Invalid RFSO header: offset=" << published_offset
                  << " magic=0x" << std::hex
                  << magic << std::dec << '\n';
    } else if (count == kMaxReportedHeaderErrors + 1) {
        std::cerr << "Further invalid-header details suppressed; counting continues\n";
    }
}

bool scan_benchmark_headers(const volatile std::uint8_t* ring,
                            std::uint64_t ring_size,
                            const CommitSnapshot& snapshot,
                            std::uint64_t& scanned_bytes,
                            BenchmarkStats& stats) {
    const auto report_issue =
        [&](std::uint64_t offset,
            const rdma_benchmark::SequenceObservation& observation) {
            if (!observation.valid_magic) {
                report_invalid_header(stats.invalid_headers, offset,
                                      observation.magic);
            } else {
                report_sequence_discontinuity(stats.discontinuities, offset,
                                              observation);
            }
        };
    const auto result = rdma_benchmark::scan_committed_headers(
        ring, ring_size, snapshot.published_bytes, snapshot.ring_end_offset,
        scanned_bytes, stats, report_issue);
    stats.commits = snapshot.sequence;
    stats.published_bytes = snapshot.published_bytes;
    switch (result.error) {
    case rdma_benchmark::ScanError::none:
        if (result.overrun) {
            std::cerr << "benchmark ring overrun: unread="
                      << result.unread_bytes << " ring=" << ring_size
                      << "; sequence validation is no longer complete\n";
        }
        return true;
    case rdma_benchmark::ScanError::invalid_ring_size:
        std::cerr << "invalid benchmark ring size " << ring_size << '\n';
        break;
    case rdma_benchmark::ScanError::invalid_ring_offset:
        std::cerr << "invalid published ring offset "
                  << snapshot.ring_end_offset << " for "
                  << snapshot.published_bytes << " bytes\n";
        break;
    case rdma_benchmark::ScanError::counter_moved_backwards:
        std::cerr << "published byte counter moved backwards: previous="
                  << scanned_bytes << " current=" << snapshot.published_bytes
                  << '\n';
        break;
    case rdma_benchmark::ScanError::unaligned_counter:
        std::cerr << "published byte counter is not 4096-byte aligned: current="
                  << snapshot.published_bytes << " scanned=" << scanned_bytes
                  << '\n';
        break;
    }
    return false;
}

void report_rate(const BenchmarkStats& stats,
                 std::chrono::steady_clock::time_point now,
                 RateBaseline& baseline) {
    const double seconds =
        std::chrono::duration<double>(now - baseline.time).count();
    if (seconds <= 0.0) {
        return;
    }

    const std::uint64_t interval_bytes = stats.bytes - baseline.bytes;
    const std::uint64_t interval_packets = stats.packets - baseline.packets;
    const std::uint64_t interval_commits = stats.commits - baseline.commits;
    const std::uint64_t interval_discontinuities =
        stats.discontinuities - baseline.discontinuities;
    const std::uint64_t interval_invalid =
        stats.invalid_headers - baseline.invalid_headers;
    const double mib_per_second =
        static_cast<double>(interval_bytes) / kBytesPerMiB / seconds;
    const double gbits_per_second =
        static_cast<double>(interval_bytes) * 8.0 / kBitsPerGigabit / seconds;
    const double packets_per_second =
        static_cast<double>(interval_packets) / seconds;
    const double commits_per_second =
        static_cast<double>(interval_commits) / seconds;

    std::cout << "Rate=" << std::fixed << std::setprecision(2)
              << mib_per_second << " MiB/s (" << std::setprecision(3)
              << gbits_per_second << " Gbps) packets=" << std::setprecision(2)
              << packets_per_second << "/s commits=" << commits_per_second
              << "/s discontinuities=" << stats.discontinuities << " (+"
              << interval_discontinuities << ") invalid="
              << stats.invalid_headers << " (+" << interval_invalid << ")\n"
              << std::flush;

    baseline.time = now;
    baseline.packets = stats.packets;
    baseline.bytes = stats.bytes;
    baseline.discontinuities = stats.discontinuities;
    baseline.invalid_headers = stats.invalid_headers;
    baseline.commits = stats.commits;
}

bool verify_ring_headers(const volatile std::uint8_t* ring,
                         const CommitSnapshot& snapshot,
                         std::uint64_t ring_size) {
    if (snapshot.published_bytes == 0) {
        std::cerr << "no published bytes to verify\n";
        return false;
    }

    const std::uint64_t bytes_to_check =
        snapshot.published_bytes < ring_size ? snapshot.published_bytes : ring_size;
    std::uint64_t scanned_bytes = snapshot.published_bytes - bytes_to_check;
    BenchmarkStats stats{};
    if (!scan_benchmark_headers(ring, ring_size, snapshot, scanned_bytes,
                                stats) ||
        stats.invalid_headers != 0 || stats.discontinuities != 0 ||
        stats.overruns != 0) {
        std::cerr << "ring RFSO header verification failed\n";
        return false;
    }

    std::cout << "ring header verification passed: packets=" << stats.packets
              << " bytes=" << stats.bytes << " sequence=" << snapshot.sequence
              << '\n';
    return true;
}

struct FreeDeleter {
    void operator()(std::uint8_t* buffer) const noexcept {
        std::free(buffer);
    }
};

class AlignedBuffer {
public:
    explicit AlignedBuffer(std::size_t size) : size_(size) {
        void* allocation{};
        const int result = ::posix_memalign(&allocation, kRdmaPmtuBytes, size_);
        if (result != 0) {
            throw std::runtime_error(
                std::string{"posix_memalign ring: "} + std::strerror(result));
        }
        storage_.reset(static_cast<std::uint8_t*>(allocation));
        std::memset(storage_.get(), 0, size_);
    }

    AlignedBuffer(const AlignedBuffer&) = delete;
    AlignedBuffer& operator=(const AlignedBuffer&) = delete;
    AlignedBuffer(AlignedBuffer&&) = delete;
    AlignedBuffer& operator=(AlignedBuffer&&) = delete;

    std::uint8_t* data() noexcept {
        return storage_.get();
    }

    const std::uint8_t* data() const noexcept {
        return storage_.get();
    }

    std::size_t size() const noexcept {
        return size_;
    }

private:
    std::unique_ptr<std::uint8_t[], FreeDeleter> storage_;
    std::size_t size_;
};

void print_vio_json(const Options& options, const NetdevInfo& netdev,
                    const ibv_qp& queue_pair, const ibv_mr& memory_region,
                    const ibv_gid& host_gid, int gid_index, const void* ring,
                    const void* commit) {
    char host_ip[INET_ADDRSTRLEN]{};
    const auto host_ip_hex = ntohl(netdev.ipv4.s_addr);

    if (::inet_ntop(AF_INET, &netdev.ipv4, host_ip, sizeof(host_ip)) == nullptr) {
        std::strncpy(host_ip, "<unavailable>", sizeof(host_ip) - 1);
    }
    std::cout
        << "{\n"
        << "  \"host\": {\n"
        << "    \"device\": \"" << options.device_name << "\", \"netdev\": \""
        << options.netdev_name << "\", \"ip\": \"" << host_ip << "\",\n"
        << "    \"mac\": \"" << format_mac(netdev.mac) << "\", \"gid\": \""
        << format_gid(host_gid) << "\", \"gid_index\": " << gid_index << ",\n"
        << "    \"qpn\": " << queue_pair.qp_num << ", \"sq_psn\": "
        << options.host_tx_psn << ", \"rq_psn\": " << options.fpga_tx_psn
        << "\n"
        << "  },\n"
        << "  \"fpga\": {\n"
        << "    \"ip\": \"" << options.fpga_ip_text << "\", \"mac\": \""
        << options.fpga_mac_text << "\", \"qpn\": " << options.fpga_qpn
        << ", \"tx_psn\": " << options.fpga_tx_psn << "\n"
        << "  },\n"
        << "  \"vio\": {\n"
        << "    \"cfg_force_remote_mac\": 1,\n"
        << "    \"cfg_remote_mac\": \"" << format_mac_vio(netdev.mac) << "\",\n"
        << "    \"cfg_remote_ip\": \"" << format_hex(host_ip_hex, 8) << "\",\n"
        << "    \"cfg_local_qpn\": " << options.fpga_qpn
        << ", \"cfg_remote_qpn\": " << queue_pair.qp_num << ",\n"
        << "    \"cfg_local_psn\": " << options.fpga_tx_psn
        << ", \"cfg_remote_psn\": " << options.host_tx_psn << ",\n"
        << "    \"cfg_remote_base\": \""
        << format_hex(reinterpret_cast<std::uintptr_t>(ring), 12) << "\",\n"
        << "    \"cfg_rkey\": \"" << format_hex(memory_region.rkey, 8) << "\",\n"
        << "    \"cfg_ring_size\": " << options.ring_size
        << ", \"cfg_wr_size\": " << options.wr_size << ",\n"
        << "    \"cfg_local_base\": \"" << format_hex(options.local_base, 16)
        << "\",\n"
        << "    \"cfg_enable_immediate\": "
        << (options.enable_immediate ? 1U : 0U) << ",\n"
        << "    \"cfg_notify_interval_bytes\": " << options.notify_interval
        << ",\n"
        << "    \"cfg_commit_remote_addr\": \""
        << format_hex(reinterpret_cast<std::uintptr_t>(commit), 12) << "\",\n"
        << "    \"cfg_allow_ring_wrap\": "
        << (options.allow_ring_wrap ? 1U : 0U) << "\n"
        << "  }\n"
        << "}\n";
}

std::uint32_t random_psn() {
    timespec now{};
    ::clock_gettime(CLOCK_MONOTONIC, &now);
    const auto psn = (static_cast<std::uint32_t>(now.tv_nsec) ^
                      static_cast<std::uint32_t>(now.tv_sec) ^
                      static_cast<std::uint32_t>(::getpid())) &
                     0xffffffU;
    return psn == 0 ? 1 : psn;
}

enum class ParseResult {
    success,
    help,
    failure,
};

ParseResult parse_options(int argc, char* argv[], Options& options) {
    static constexpr option long_options[] = {
        {"device", required_argument, nullptr, 'd'},
        {"netdev", required_argument, nullptr, 'n'},
        {"fpga-ip", required_argument, nullptr, 'i'},
        {"fpga-mac", required_argument, nullptr, 'm'},
        {"port", required_argument, nullptr, 'p'},
        {"fpga-qpn", required_argument, nullptr, 'q'},
        {"fpga-tx-psn", required_argument, nullptr, 'f'},
        {"host-tx-psn", required_argument, nullptr, 's'},
        {"ring-size", required_argument, nullptr, 'r'},
        {"wr-size", required_argument, nullptr, 'w'},
        {"notify-interval", required_argument, nullptr, 'N'},
        {"local-base", required_argument, nullptr, 'l'},
        {"recv-depth", required_argument, nullptr, 'R'},
        {"immediate", no_argument, nullptr, 'I'},
        {"allow-ring-wrap", no_argument, nullptr, 'W'},
        {"seconds", required_argument, nullptr, 't'},
        {"verify-on-exit", no_argument, nullptr, 'v'},
        {"verbose-commits", no_argument, nullptr, 'C'},
        {"help", no_argument, nullptr, 'h'},
        {nullptr, 0, nullptr, 0},
    };
    constexpr const char* short_options{"d:n:i:m:p:q:f:s:r:w:N:l:R:IWt:vCh"};

    ::optind = 1;
    ::opterr = 0;
    while (true) {
        const int option = ::getopt_long(argc, argv, short_options, long_options, nullptr);
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
        case 'm':
            options.fpga_mac_text = argument;
            break;
        case 'p':
            if (!parse_u64(argument, value) || value == 0 ||
                value > std::numeric_limits<std::uint8_t>::max()) {
                std::cerr << "invalid value for option -p\n";
                return ParseResult::failure;
            }
            options.port_num = static_cast<std::uint8_t>(value);
            break;
        case 'q':
            if (!parse_u64(argument, value) || value == 0 || value > 255) {
                std::cerr << "invalid value for option -q\n";
                return ParseResult::failure;
            }
            options.fpga_qpn = static_cast<std::uint32_t>(value);
            break;
        case 'f':
            if (!parse_psn(argument, options.fpga_tx_psn)) {
                std::cerr << "invalid value for option -f\n";
                return ParseResult::failure;
            }
            break;
        case 's':
            if (!parse_psn(argument, options.host_tx_psn)) {
                std::cerr << "invalid value for option -s\n";
                return ParseResult::failure;
            }
            break;
        case 'r':
            if (!parse_size(argument, options.ring_size)) {
                std::cerr << "invalid value for option -r\n";
                return ParseResult::failure;
            }
            break;
        case 'w':
            if (!parse_size(argument, options.wr_size)) {
                std::cerr << "invalid value for option -w\n";
                return ParseResult::failure;
            }
            break;
        case 'N':
            if (!parse_size(argument, options.notify_interval)) {
                std::cerr << "invalid value for option -N\n";
                return ParseResult::failure;
            }
            break;
        case 'l':
            if (!parse_u64(argument, options.local_base)) {
                std::cerr << "invalid value for option -l\n";
                return ParseResult::failure;
            }
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
        case 'W':
            options.allow_ring_wrap = true;
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
    std::array<std::uint8_t, 6> fpga_mac{};
    if (options.device_name.empty() || options.netdev_name.empty() ||
        options.fpga_ip_text.empty() || options.fpga_mac_text.empty() ||
        ::inet_pton(AF_INET, options.fpga_ip_text.c_str(), &fpga_ipv4) != 1 ||
        !parse_mac(options.fpga_mac_text, fpga_mac)) {
        usage(argv[0]);
        return ParseResult::failure;
    }
    return ParseResult::success;
}

bool validate_options(const Options& options) {
    if (options.ring_size > std::numeric_limits<std::uint32_t>::max() ||
        options.wr_size > std::numeric_limits<std::uint32_t>::max() ||
        options.notify_interval > std::numeric_limits<std::uint32_t>::max() ||
        options.ring_size % kRdmaPmtuBytes != 0 ||
        options.wr_size % kRdmaPmtuBytes != 0 ||
        options.notify_interval % kRdmaPmtuBytes != 0 ||
        options.wr_size == 0 || options.wr_size > options.ring_size ||
        options.notify_interval == 0 ||
        options.notify_interval > options.ring_size ||
        (options.local_base & 7U) != 0) {
        std::cerr
            << "ring, WR, and notification sizes must fit FPGA 32-bit VIO fields, "
            << "be nonzero 4096-byte multiples, and have WR/interval <= ring\n";
        return false;
    }
    if (options.ring_size >
        std::numeric_limits<std::size_t>::max() - kCommitBytes) {
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

int run_receiver(const Options& options) {
    in_addr fpga_ipv4{};
    NetdevInfo netdev{};

    if (::inet_pton(AF_INET, options.fpga_ip_text.c_str(), &fpga_ipv4) != 1) {
        std::cerr << "invalid FPGA IPv4 address\n";
        return EXIT_FAILURE;
    }
    if (!query_netdev(options.netdev_name, netdev)) {
        return EXIT_FAILURE;
    }

    rlimit limit{};
    if (::getrlimit(RLIMIT_MEMLOCK, &limit) != 0) {
        std::perror("getrlimit RLIMIT_MEMLOCK");
        return EXIT_FAILURE;
    }
    const auto required_bytes = options.ring_size + kCommitBytes;
    if (limit.rlim_cur != RLIM_INFINITY &&
        required_bytes > static_cast<std::uint64_t>(limit.rlim_cur)) {
        std::cerr << "memlock soft limit "
                  << static_cast<std::uint64_t>(limit.rlim_cur)
                  << " is below required registered memory " << required_bytes
                  << "; raise ulimit -l first\n";
        return EXIT_FAILURE;
    }

    AlignedBuffer ring_memory{static_cast<std::size_t>(required_bytes)};
    auto* commit_storage =
        ring_memory.data() + static_cast<std::size_t>(options.ring_size);
    auto* commit = ::new (static_cast<void*>(commit_storage)) RdmaRingCommit{};
    const auto ring_address = reinterpret_cast<std::uintptr_t>(ring_memory.data());
    const auto commit_address = reinterpret_cast<std::uintptr_t>(commit);
    if (ring_address >= kFpgaRemoteAddressLimit ||
        commit_address > kFpgaRemoteAddressLimit - kCommitBytes) {
        std::cerr
            << "the allocated MR is outside the FPGA 48-bit remote-address range\n";
        return EXIT_FAILURE;
    }

    ContextPtr context = open_device(options.device_name);
    if (!context) {
        return EXIT_FAILURE;
    }

    int gid_index{-1};
    ibv_gid host_gid{};
    if (!select_rocev2_gid(context.get(), options.port_num, netdev, gid_index,
                           host_gid)) {
        return EXIT_FAILURE;
    }
    const ibv_gid fpga_gid = ipv4_mapped_gid(fpga_ipv4);

    ProtectionDomainPtr protection_domain{ibv_alloc_pd(context.get())};
    if (!protection_domain) {
        std::perror("ibv_alloc_pd");
        return EXIT_FAILURE;
    }
    MemoryRegionPtr memory_region{
        ibv_reg_mr(protection_domain.get(), ring_memory.data(), ring_memory.size(),
                   IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE)};
    if (!memory_region) {
        std::perror("ibv_reg_mr");
        return EXIT_FAILURE;
    }
    CompletionQueuePtr completion_queue{
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
    init_attr.cap.max_recv_wr =
        options.enable_immediate ? options.recv_depth : 1;
    init_attr.cap.max_send_sge = 1;
    init_attr.cap.max_recv_sge = 1;
    QueuePairPtr queue_pair{ibv_create_qp(protection_domain.get(), &init_attr)};
    if (!queue_pair) {
        std::perror("ibv_create_qp");
        return EXIT_FAILURE;
    }
    if (options.enable_immediate) {
        for (std::uint32_t index = 0; index < options.recv_depth; ++index) {
            if (!post_receive(queue_pair.get(), memory_region.get(), commit, index)) {
                return EXIT_FAILURE;
            }
        }
    }
    if (!modify_qp_to_rts(queue_pair.get(), options, gid_index, fpga_gid)) {
        return EXIT_FAILURE;
    }

    print_vio_json(options, netdev, *queue_pair, *memory_region, host_gid,
                   gid_index, ring_memory.data(), commit);
    std::cout.flush();
    std::cerr
        << "QP is RTS. Apply the emitted VIO fields while FPGA is drained, then "
        << "assert start. Stop FPGA and wait for drained before terminating this "
        << "tool.\n";
    if (options.allow_ring_wrap) {
        std::cerr
            << "WARNING: ring wrap is enabled without a consumer-credit protocol; "
            << "use only for controlled diagnostics.\n";
    }

    stop_requested = 0;
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    bool duration_elapsed{};
    bool shutdown_requested{};
    bool benchmark_valid{true};
    CommitSnapshot last_commit{};
    BenchmarkStats benchmark_stats{};
    BenchmarkStats measurement_origin{};
    RateBaseline rate_baseline{};
    std::optional<std::chrono::steady_clock::time_point> traffic_started;
    std::uint64_t scanned_bytes{};
    const volatile std::uint8_t* ring = ring_memory.data();

    while (true) {
        const auto now = std::chrono::steady_clock::now();
        if (stop_requested != 0 && !shutdown_requested) {
            shutdown_requested = true;
            std::cerr
                << "termination requested; waiting for FPGA final commit before "
                << "releasing the QP/MR\n";
        }
        if (options.run_seconds != 0 && traffic_started.has_value() &&
            !duration_elapsed && now - *traffic_started >=
                std::chrono::seconds{options.run_seconds}) {
            duration_elapsed = true;
            std::cerr
                << "requested duration elapsed; pulse FPGA cfg_stop and wait "
                << "for the final commit before releasing the QP/MR\n";
        }

        std::array<ibv_wc, 16> completions{};
        int completion_count{};
        while ((completion_count = ibv_poll_cq(
                    completion_queue.get(),
                    static_cast<int>(completions.size()),
                    completions.data())) > 0) {
            for (int index = 0; index < completion_count; ++index) {
                const ibv_wc& completion =
                    completions[static_cast<std::size_t>(index)];

                if (completion.status != IBV_WC_SUCCESS) {
                    std::cerr << "CQ error: status="
                              << ibv_wc_status_str(completion.status)
                              << " opcode=" << completion.opcode
                              << " wr_id=" << completion.wr_id << '\n';
                    return EXIT_FAILURE;
                }
                if (completion.opcode != IBV_WC_RECV_RDMA_WITH_IMM) {
                    std::cerr << "unexpected receive completion opcode "
                              << completion.opcode << '\n';
                    return EXIT_FAILURE;
                }
                if (options.verbose_commits) {
                    std::cout << "immediate sequence low32="
                              << ntohl(completion.imm_data) << '\n';
                }
                if (!post_receive(queue_pair.get(), memory_region.get(), commit,
                                  completion.wr_id)) {
                    return EXIT_FAILURE;
                }
            }
        }
        if (completion_count < 0) {
            std::cerr << "ibv_poll_cq failed\n";
            return EXIT_FAILURE;
        }

        pollfd async_fd{};
        async_fd.fd = context->async_fd;
        async_fd.events = POLLIN;
        if (::poll(&async_fd, 1, 0) > 0 &&
            (async_fd.revents & POLLIN) != 0) {
            ibv_async_event event{};
            if (ibv_get_async_event(context.get(), &event) == 0) {
                std::cerr << "RDMA async event: "
                          << ibv_event_type_str(event.event_type) << '\n';
                ibv_ack_async_event(&event);
            }
        }

        CommitSnapshot snapshot{};
        if (read_commit(commit, snapshot) &&
            snapshot.sequence != last_commit.sequence) {
            if (last_commit.sequence != 0 &&
                snapshot.sequence < last_commit.sequence) {
                std::cerr << "commit sequence moved backwards: previous="
                          << last_commit.sequence << " current="
                          << snapshot.sequence << '\n';
                return EXIT_FAILURE;
            }
            if ((!snapshot.final &&
                 snapshot.interval_bytes != options.notify_interval) ||
                (snapshot.final &&
                 snapshot.interval_bytes > options.notify_interval)) {
                std::cerr << "commit interval is invalid: FPGA="
                          << snapshot.interval_bytes << " host-configured="
                          << options.notify_interval << " final="
                          << (snapshot.final ? 1U : 0U) << '\n';
                return EXIT_FAILURE;
            }
            const bool establish_measurement_origin =
                !traffic_started.has_value() && snapshot.published_bytes != 0;
            const auto measurement_started = establish_measurement_origin
                ? std::chrono::steady_clock::now()
                : std::chrono::steady_clock::time_point{};
            if (!scan_benchmark_headers(ring, options.ring_size, snapshot,
                                        scanned_bytes, benchmark_stats)) {
                benchmark_valid = false;
            }
            if (establish_measurement_origin) {
                traffic_started = measurement_started;
                measurement_origin = benchmark_stats;
                rate_baseline.time = measurement_started;
                rate_baseline.packets = benchmark_stats.packets;
                rate_baseline.bytes = benchmark_stats.bytes;
                rate_baseline.discontinuities =
                    benchmark_stats.discontinuities;
                rate_baseline.invalid_headers =
                    benchmark_stats.invalid_headers;
                rate_baseline.commits = benchmark_stats.commits;
            }
            last_commit = snapshot;
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
            report_rate(benchmark_stats, report_now, rate_baseline);
        }
        if (last_commit.final) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }

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
    const double average_mib_per_second = elapsed_seconds > 0.0
        ? static_cast<double>(measured_bytes) / kBytesPerMiB /
              elapsed_seconds
        : 0.0;
    const double average_gbits_per_second = elapsed_seconds > 0.0
        ? static_cast<double>(measured_bytes) * 8.0 /
              kBitsPerGigabit / elapsed_seconds
        : 0.0;
    std::cout << "Received=" << benchmark_stats.packets
              << " bytes=" << benchmark_stats.bytes
              << " measured_bytes=" << measured_bytes
              << " published=" << benchmark_stats.published_bytes
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
         !verify_ring_headers(ring, last_commit, options.ring_size))) {
        return EXIT_FAILURE;
    }
    if (!benchmark_valid || benchmark_stats.discontinuities != 0 ||
        benchmark_stats.invalid_headers != 0 || benchmark_stats.overruns != 0) {
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}

}

int main(int argc, char* argv[]) {
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
        if (options.fpga_tx_psn == 0) {
            options.fpga_tx_psn = random_psn();
        }
        if (options.host_tx_psn == 0) {
            options.host_tx_psn = random_psn();
        }
        return run_receiver(options);
    } catch (const std::exception& error) {
        std::cerr << "fatal: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
