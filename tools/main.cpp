#if !defined(__linux__)
#error "This DPDK receiver supports Linux only."
#endif

#include <array>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <new>
#include <thread>
#include <vector>

extern "C" {
#include <rte_byteorder.h>
#include <rte_cycles.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_flow.h>
#include <rte_launch.h>
#include <rte_lcore.h>
#include <rte_mbuf.h>
#include <rte_mempool.h>
}

/* ============================================================
 * Configuration
 * ============================================================ */

static constexpr uint16_t RX_DESC = 4096;
static constexpr uint16_t BURST_SIZE = 64;
using RxBurstHistogram = std::array<uint64_t, BURST_SIZE + 1>;

/*
 * Jumbo frame:
 *
 * E810 maximum configurable RX packet length ≈ 9728.
 * Current traffic is ~9KB Jumbo Frame.
 */
static constexpr uint32_t MBUF_DATA_SIZE = 9728;

/*
 * Number of mbufs.
 *
 * 65536 * ~10KB ≈ 640MB plus mbuf metadata.
 *
 * Make sure NUMA node has enough hugepage memory.
 */
static constexpr uint32_t NUM_MBUFS = 65536;
static constexpr uint32_t MBUF_CACHE_SIZE = 256;

/*
 * UDP benchmark frame layout:
 *
 * Ethernet | IPv4 | UDP | RFSO header (24 bytes)
 *                         ^ sequence at byte offset 4, big endian
 */
static constexpr uint16_t ETHERNET_HEADER_LENGTH = 14;
static constexpr uint16_t IPV4_MINIMUM_HEADER_LENGTH = 20;
static constexpr uint16_t UDP_HEADER_LENGTH = 8;
static constexpr uint16_t BENCHMARK_HEADER_LENGTH = 24;
static constexpr uint16_t MINIMUM_BENCHMARK_FRAME_LENGTH =
    ETHERNET_HEADER_LENGTH + IPV4_MINIMUM_HEADER_LENGTH + UDP_HEADER_LENGTH +
    BENCHMARK_HEADER_LENGTH;
static constexpr uint16_t MAXIMUM_BENCHMARK_HEADER_READ_LENGTH =
    ETHERNET_HEADER_LENGTH + 60 + UDP_HEADER_LENGTH + BENCHMARK_HEADER_LENGTH;

static constexpr uint16_t ETHER_TYPE_IPV4 = 0x0800;
static constexpr uint8_t IPV4_PROTOCOL_UDP = 17;
static constexpr uint16_t IPV4_FRAGMENT_OFFSET_AND_MF_MASK = 0x3FFF;
static constexpr uint16_t UDP_SOURCE_PORT_OFFSET = 0;
static constexpr uint16_t UDP_DESTINATION_PORT_OFFSET = 2;
static constexpr uint16_t BENCHMARK_FIRST_DESTINATION_PORT = 5001;
static constexpr uint16_t DEFAULT_BENCHMARK_STREAM_COUNT = 2;
static constexpr uint32_t MAXIMUM_BENCHMARK_STREAM_COUNT =
    65536U - BENCHMARK_FIRST_DESTINATION_PORT;
static constexpr uint32_t BENCHMARK_MAGIC = 0x5246534F;
static constexpr double BYTES_PER_MEGABYTE = 1000.0 * 1000.0;
static constexpr double BYTES_PER_GIGABYTE = 1000.0 * 1000.0 * 1000.0;

/* ============================================================
 * Global state
 * ============================================================ */

static std::atomic<bool> force_quit{false};

/* ============================================================
 * Per RX queue statistics
 *
 * RX worker only increments these counters.
 * Statistics thread reads them atomically.
 * ============================================================ */

struct BenchmarkStreamStats {
  std::atomic<uint64_t> packets{0};
  std::atomic<uint64_t> bytes{0};
  std::atomic<uint64_t> discontinuities{0};
};

struct PollGapStats {
  uint64_t samples{0};
  uint64_t total_tsc_cycles{0};
  uint64_t min_tsc_cycles{0};
  uint64_t max_tsc_cycles{0};
};

struct QueueStats {
  std::atomic<uint64_t> packets{0};
  std::atomic<uint64_t> bytes{0};
  std::atomic<uint64_t> rx_bursts{0};
  /* Written by the RX lcore before exit, then read after it is joined. */
  RxBurstHistogram burst_histogram{};
  PollGapStats poll_gap{};
  std::unique_ptr<BenchmarkStreamStats[]> benchmark_streams;
};

struct BenchmarkSequenceState {
  bool has_previous_sequence{false};
  uint32_t previous_sequence{0};
};

/* ============================================================
 * RX queue context
 * ============================================================ */

struct RxQueueContext {
  uint16_t port_id;
  uint16_t queue_id;
  unsigned lcore_id;
  uint16_t benchmark_stream_count{0};
  QueueStats stats;

  /* Accessed only by this queue's RX lcore. */
  std::unique_ptr<BenchmarkSequenceState[]> benchmark_sequences;
};

static RxQueueContext g_queues[RTE_MAX_ETHPORTS * RTE_MAX_QUEUES_PER_PORT];

/* ============================================================
 * Signal handler
 * ============================================================ */

static void signal_handler(int signum) {
  if (signum == SIGINT || signum == SIGTERM) {
    force_quit.store(true, std::memory_order_relaxed);
  }
}

/* ============================================================
 * UDP benchmark header validation
 * ============================================================ */

static uint16_t read_be16(const uint8_t *data) {
  return (static_cast<uint16_t>(data[0]) << 8U) |
         static_cast<uint16_t>(data[1]);
}

static uint32_t read_be32(const uint8_t *data) {
  return (static_cast<uint32_t>(data[0]) << 24U) |
         (static_cast<uint32_t>(data[1]) << 16U) |
         (static_cast<uint32_t>(data[2]) << 8U) |
         static_cast<uint32_t>(data[3]);
}

static bool find_benchmark_stream_index(uint16_t destination_port,
                                        uint16_t benchmark_stream_count,
                                        uint16_t &benchmark_stream_index) {
  if (destination_port < BENCHMARK_FIRST_DESTINATION_PORT)
    return false;

  const uint32_t stream_index = static_cast<uint32_t>(destination_port) -
                                BENCHMARK_FIRST_DESTINATION_PORT;

  if (stream_index >= benchmark_stream_count)
    return false;

  benchmark_stream_index = static_cast<uint16_t>(stream_index);
  return true;
}

static uint16_t benchmark_destination_port(uint16_t benchmark_stream_index) {
  return static_cast<uint16_t>(BENCHMARK_FIRST_DESTINATION_PORT +
                               benchmark_stream_index);
}

static uint16_t benchmark_stream_queue(uint16_t benchmark_stream_index,
                                       uint16_t nb_rx_queues) {
  return static_cast<uint16_t>(benchmark_stream_index % nb_rx_queues);
}

static const char *flow_error_message(const struct rte_flow_error &error) {
  return error.message != nullptr ? error.message : "unspecified error";
}

static void destroy_benchmark_flow_rules(
    uint16_t port_id, std::vector<struct rte_flow *> &flow_handles) {
  for (auto flow_it = flow_handles.rbegin(); flow_it != flow_handles.rend();
       ++flow_it) {
    if (*flow_it == nullptr)
      continue;

    struct rte_flow_error error{};
    const int ret = rte_flow_destroy(port_id, *flow_it, &error);

    if (ret != 0) {
      printf("Warning: failed to destroy rte_flow rule: ret=%d, %s\n", ret,
             flow_error_message(error));
    }
  }

  flow_handles.clear();
}

static bool create_benchmark_flow_rules(
    uint16_t port_id, uint16_t nb_rx_queues, uint16_t benchmark_stream_count,
    std::vector<struct rte_flow *> &flow_handles) {
  if (nb_rx_queues == 0 || benchmark_stream_count == 0)
    return false;

  struct rte_flow_attr flow_attr{};
  flow_attr.ingress = 1;

  printf("Installing %u rte_flow UDP destination-port rules (round-robin "
         "across %u RX queues)\n",
         static_cast<unsigned>(benchmark_stream_count),
         static_cast<unsigned>(nb_rx_queues));

  for (uint16_t benchmark_stream_index = 0;
       benchmark_stream_index < benchmark_stream_count;
       ++benchmark_stream_index) {
    const uint16_t destination_port =
        benchmark_destination_port(benchmark_stream_index);
    const uint16_t queue_id =
        benchmark_stream_queue(benchmark_stream_index, nb_rx_queues);

    struct rte_flow_item_udp udp_spec{};
    struct rte_flow_item_udp udp_mask{};
    udp_spec.hdr.dst_port = rte_cpu_to_be_16(destination_port);
    udp_mask.hdr.dst_port = rte_cpu_to_be_16(UINT16_MAX);

    struct rte_flow_item pattern[4]{};
    pattern[0].type = RTE_FLOW_ITEM_TYPE_ETH;
    pattern[1].type = RTE_FLOW_ITEM_TYPE_IPV4;
    pattern[2].type = RTE_FLOW_ITEM_TYPE_UDP;
    pattern[2].spec = &udp_spec;
    pattern[2].mask = &udp_mask;
    pattern[3].type = RTE_FLOW_ITEM_TYPE_END;

    struct rte_flow_action_queue queue_action{};
    queue_action.index = queue_id;

    struct rte_flow_action actions[2]{};
    actions[0].type = RTE_FLOW_ACTION_TYPE_QUEUE;
    actions[0].conf = &queue_action;
    actions[1].type = RTE_FLOW_ACTION_TYPE_END;

    struct rte_flow_error error{};
    int ret = rte_flow_validate(port_id, &flow_attr, pattern, actions, &error);

    if (ret != 0) {
      printf("rte_flow_validate failed for UDP dst %u -> RXQ %u: ret=%d, %s\n",
             static_cast<unsigned>(destination_port),
             static_cast<unsigned>(queue_id), ret, flow_error_message(error));
      destroy_benchmark_flow_rules(port_id, flow_handles);
      return false;
    }

    struct rte_flow *flow =
        rte_flow_create(port_id, &flow_attr, pattern, actions, &error);

    if (flow == nullptr) {
      printf("rte_flow_create failed for UDP dst %u -> RXQ %u: %s\n",
             static_cast<unsigned>(destination_port),
             static_cast<unsigned>(queue_id), flow_error_message(error));
      destroy_benchmark_flow_rules(port_id, flow_handles);
      return false;
    }

    flow_handles.push_back(flow);

    if (benchmark_stream_count <= 32) {
      printf("  UDP dst %u -> RXQ %u\n",
             static_cast<unsigned>(destination_port),
             static_cast<unsigned>(queue_id));
    }
  }

  return true;
}

/*
 * Returns true only for a complete, unfragmented IPv4/UDP RFSO frame.
 * The scratch buffer lets rte_pktmbuf_read handle multi-segment mbufs.
 */
static bool validate_benchmark_sequence(
    const struct rte_mbuf *packet, RxQueueContext &ctx,
    std::array<uint8_t, MAXIMUM_BENCHMARK_HEADER_READ_LENGTH> &header_buffer,
    uint16_t &benchmark_stream_index, bool &sequence_discontinuity) {
  sequence_discontinuity = false;
  const uint32_t packet_length = rte_pktmbuf_pkt_len(packet);

  if (packet_length < MINIMUM_BENCHMARK_FRAME_LENGTH)
    return false;

  const uint32_t header_read_length =
      packet_length < MAXIMUM_BENCHMARK_HEADER_READ_LENGTH
          ? packet_length
          : MAXIMUM_BENCHMARK_HEADER_READ_LENGTH;

  const auto *header = static_cast<const uint8_t *>(
      rte_pktmbuf_read(packet, 0, header_read_length, header_buffer.data()));

  if (header == nullptr)
    return false;

  if (read_be16(header + 12) != ETHER_TYPE_IPV4)
    return false;

  const auto *ipv4_header = header + ETHERNET_HEADER_LENGTH;
  const uint8_t version_ihl = ipv4_header[0];
  const uint32_t ipv4_header_length =
      static_cast<uint32_t>(version_ihl & 0x0FU) * 4U;

  if ((version_ihl >> 4U) != 4 ||
      ipv4_header_length < IPV4_MINIMUM_HEADER_LENGTH ||
      ipv4_header[9] != IPV4_PROTOCOL_UDP)
    return false;

  if ((read_be16(ipv4_header + 6) & IPV4_FRAGMENT_OFFSET_AND_MF_MASK) != 0)
    return false;

  const uint32_t ipv4_total_length = read_be16(ipv4_header + 2);

  if (ipv4_total_length < ipv4_header_length + UDP_HEADER_LENGTH)
    return false;

  const uint32_t udp_header_offset =
      ETHERNET_HEADER_LENGTH + ipv4_header_length;
  const uint32_t benchmark_header_offset =
      udp_header_offset + UDP_HEADER_LENGTH;
  const uint32_t required_frame_length =
      benchmark_header_offset + BENCHMARK_HEADER_LENGTH;

  if (packet_length < ETHERNET_HEADER_LENGTH + ipv4_total_length ||
      header_read_length < required_frame_length)
    return false;

  const auto *udp_header = header + udp_header_offset;
  const uint32_t udp_length = read_be16(udp_header + 4);

  if (udp_length < UDP_HEADER_LENGTH + BENCHMARK_HEADER_LENGTH ||
      udp_length > ipv4_total_length - ipv4_header_length)
    return false;

#if 0
  printf("RXQ%u hash=0x%08x UDP source port: %u\n", ctx.queue_id,
         packet->hash.rss,
         static_cast<unsigned>(
             read_be16(udp_header + UDP_SOURCE_PORT_OFFSET)));
#endif

  const uint16_t destination_port =
      read_be16(udp_header + UDP_DESTINATION_PORT_OFFSET);

  if (!find_benchmark_stream_index(destination_port, ctx.benchmark_stream_count,
                                   benchmark_stream_index)) {
    return false;
  }

  const auto *benchmark_header = header + benchmark_header_offset;

  if (read_be32(benchmark_header) != BENCHMARK_MAGIC)
    return false;

  const uint32_t sequence = read_be32(benchmark_header + 4);
  auto &sequence_state = ctx.benchmark_sequences[benchmark_stream_index];

  if (sequence_state.has_previous_sequence &&
      sequence != sequence_state.previous_sequence + 1U) {
    sequence_discontinuity = true;
  }

  sequence_state.previous_sequence = sequence;
  sequence_state.has_previous_sequence = true;

  return true;
}

/* ============================================================
 * RX worker
 *
 * One RX queue <-> one lcore
 *
 * Example:
 *
 *   RXQ0 -> lcore 15
 *   RXQ1 -> lcore 16
 *   RXQ2 -> lcore 17
 *   ...
 * ============================================================ */

static int rx_loop(void *arg) {
  auto *ctx = static_cast<RxQueueContext *>(arg);
  const uint16_t port_id = ctx->port_id;
  const uint16_t queue_id = ctx->queue_id;
  struct rte_mbuf *pkts[BURST_SIZE];
  std::array<uint8_t, MAXIMUM_BENCHMARK_HEADER_READ_LENGTH> header_buffer{};
  std::vector<uint64_t> benchmark_packets(ctx->benchmark_stream_count, 0);
  std::vector<uint64_t> benchmark_bytes(ctx->benchmark_stream_count, 0);
  std::vector<uint64_t> discontinuities(ctx->benchmark_stream_count, 0);
  std::vector<uint16_t> active_benchmark_streams;
  RxBurstHistogram burst_histogram{};
  PollGapStats poll_gap{};
  uint64_t last_poll_tsc = 0;
  bool has_previous_poll_tsc = false;
  active_benchmark_streams.reserve(BURST_SIZE);

  printf("lcore %u -> RXQ%u started\n", ctx->lcore_id, queue_id);

  while (!force_quit.load(std::memory_order_relaxed)) {
    const uint64_t now = rte_get_tsc_cycles();

    if (has_previous_poll_tsc) {
      const uint64_t gap = now - last_poll_tsc;

      ++poll_gap.samples;
      poll_gap.total_tsc_cycles += gap;

      if (poll_gap.samples == 1 || gap < poll_gap.min_tsc_cycles) {
        poll_gap.min_tsc_cycles = gap;
      }

      if (gap > poll_gap.max_tsc_cycles) {
        poll_gap.max_tsc_cycles = gap;
      }
    }

    last_poll_tsc = now;
    has_previous_poll_tsc = true;

    uint16_t nb_rx = rte_eth_rx_burst(port_id, queue_id, pkts, BURST_SIZE);
    ++burst_histogram[nb_rx];

    if (nb_rx == 0)
      continue;

    ctx->stats.rx_bursts.fetch_add(1, std::memory_order_relaxed);

    uint64_t bytes = 0;
    active_benchmark_streams.clear();

    for (uint16_t i = 0; i < nb_rx; i++) {
      const uint32_t packet_length = rte_pktmbuf_pkt_len(pkts[i]);
      bytes += packet_length;

      uint16_t benchmark_stream_index = 0;
      bool sequence_discontinuity = false;

      if (validate_benchmark_sequence(pkts[i], *ctx, header_buffer,
                                      benchmark_stream_index,
                                      sequence_discontinuity)) {
        if (benchmark_packets[benchmark_stream_index] == 0) {
          active_benchmark_streams.push_back(benchmark_stream_index);
        }

        ++benchmark_packets[benchmark_stream_index];
        benchmark_bytes[benchmark_stream_index] += packet_length;

        if (sequence_discontinuity) {
          ++discontinuities[benchmark_stream_index];
        }
      }

      rte_pktmbuf_free(pkts[i]);
    }

    ctx->stats.packets.fetch_add(nb_rx, std::memory_order_relaxed);
    ctx->stats.bytes.fetch_add(bytes, std::memory_order_relaxed);

    for (uint16_t benchmark_stream_index : active_benchmark_streams) {
      auto &stream_stats = ctx->stats.benchmark_streams[benchmark_stream_index];

      stream_stats.packets.fetch_add(benchmark_packets[benchmark_stream_index],
                                     std::memory_order_relaxed);
      stream_stats.bytes.fetch_add(benchmark_bytes[benchmark_stream_index],
                                   std::memory_order_relaxed);

      if (discontinuities[benchmark_stream_index] != 0) {
        stream_stats.discontinuities.fetch_add(
            discontinuities[benchmark_stream_index], std::memory_order_relaxed);
      }

      benchmark_packets[benchmark_stream_index] = 0;
      benchmark_bytes[benchmark_stream_index] = 0;
      discontinuities[benchmark_stream_index] = 0;
    }
  }

  ctx->stats.burst_histogram = burst_histogram;
  ctx->stats.poll_gap = poll_gap;

  printf("lcore %u -> RXQ%u stopped\n", ctx->lcore_id, queue_id);

  return 0;
}

/* ============================================================
 * Port information
 * ============================================================ */

static void print_port_info(uint16_t port_id, uint16_t nb_rx_queues,
                            uint16_t benchmark_stream_count, int socket_id) {
  struct rte_eth_dev_info dev_info{};
  int ret = rte_eth_dev_info_get(port_id, &dev_info);

  if (ret != 0) {
    printf("Warning: rte_eth_dev_info_get failed: %d\n", ret);
  }

  struct rte_eth_link link{};

  ret = rte_eth_link_get(port_id, &link);

  printf("\n");
  printf("====================================================\n");
  printf("              DPDK E810 RX TEST\n");
  printf("====================================================\n");
  printf("Port             : %u\n", port_id);
  printf("Driver           : %s\n",
         dev_info.driver_name ? dev_info.driver_name : "unknown");
  printf("NUMA socket      : %d\n", socket_id);
  printf("Link             : %s\n", link.link_status ? "UP" : "DOWN");

  if (link.link_status) {
    printf("Speed            : %u Mbps\n", link.link_speed);
    printf("Duplex           : %s\n",
           link.link_duplex == RTE_ETH_LINK_FULL_DUPLEX ? "Full" : "Half");
  }

  printf("RX queues        : %u\n", nb_rx_queues);
  printf("RX descriptors   : %u\n", RX_DESC);
  printf("Burst size       : %u\n", BURST_SIZE);
  printf("Mbuf count       : %u\n", NUM_MBUFS);
  printf("Mbuf data size   : %u\n", MBUF_DATA_SIZE);
  printf("RFSO UDP streams : %u\n",
         static_cast<unsigned>(benchmark_stream_count));
  printf("RFSO UDP dst     : %u-%u\n",
         static_cast<unsigned>(BENCHMARK_FIRST_DESTINATION_PORT),
         static_cast<unsigned>(
             benchmark_destination_port(benchmark_stream_count - 1U)));
  printf("====================================================\n");
  printf("\n");
}

/* ============================================================
 * Print RX queue mapping
 * ============================================================ */

static void print_queue_mapping(uint16_t nb_rx_queues) {
  printf("\n");
  printf("--------------------------------------------\n");
  printf("RX Queue / lcore mapping\n");
  printf("--------------------------------------------\n");

  for (uint16_t q = 0; q < nb_rx_queues; q++) {
    printf("RXQ[%2u] -> lcore[%2u]\n", q, g_queues[q].lcore_id);
  }

  printf("--------------------------------------------\n");
  printf("\n");
}

static void print_burst_histogram(uint16_t nb_rx_queues) {
  RxBurstHistogram total_burst_histogram{};

  for (uint16_t q = 0; q < nb_rx_queues; ++q) {
    for (uint16_t burst_size = 0; burst_size <= BURST_SIZE; ++burst_size) {
      total_burst_histogram[burst_size] +=
          g_queues[q].stats.burst_histogram[burst_size];
    }
  }

  printf("\nRX burst histogram (all RX queues)\n");

  for (uint16_t burst_size = 0; burst_size <= BURST_SIZE; ++burst_size) {
    printf("burst %u = %lu\n", static_cast<unsigned>(burst_size),
           total_burst_histogram[burst_size]);
  }
}

static void print_poll_gap_statistics(uint16_t nb_rx_queues) {
  PollGapStats total_poll_gap{};

  printf("\nRX poll gap (TSC cycles)\n");

  for (uint16_t q = 0; q < nb_rx_queues; ++q) {
    const PollGapStats &poll_gap = g_queues[q].stats.poll_gap;

    if (poll_gap.samples == 0) {
      printf("RXQ%-2u: samples=0\n", q);
      continue;
    }

    const double average_tsc_cycles =
        static_cast<double>(poll_gap.total_tsc_cycles) /
        static_cast<double>(poll_gap.samples);

    printf("RXQ%-2u: samples=%lu avg=%9.2f min=%lu max=%lu\n", q,
           poll_gap.samples, average_tsc_cycles, poll_gap.min_tsc_cycles,
           poll_gap.max_tsc_cycles);

    if (total_poll_gap.samples == 0 ||
        poll_gap.min_tsc_cycles < total_poll_gap.min_tsc_cycles) {
      total_poll_gap.min_tsc_cycles = poll_gap.min_tsc_cycles;
    }

    if (poll_gap.max_tsc_cycles > total_poll_gap.max_tsc_cycles) {
      total_poll_gap.max_tsc_cycles = poll_gap.max_tsc_cycles;
    }

    total_poll_gap.samples += poll_gap.samples;
    total_poll_gap.total_tsc_cycles += poll_gap.total_tsc_cycles;
  }

  if (total_poll_gap.samples == 0) {
    printf("TOTAL: samples=0\n");
    return;
  }

  const double total_average_tsc_cycles =
      static_cast<double>(total_poll_gap.total_tsc_cycles) /
      static_cast<double>(total_poll_gap.samples);

  printf("TOTAL: samples=%lu avg=%9.2f min=%lu max=%lu\n",
         total_poll_gap.samples, total_average_tsc_cycles,
         total_poll_gap.min_tsc_cycles, total_poll_gap.max_tsc_cycles);
}

/* ============================================================
 * Statistics loop
 *
 * Every second output:
 *
 *   Per queue:
 *      Byte rate (MB/s or GB/s), successful RX bursts, and average burst size
 *      RFSO benchmark packets and discontinuities per destination port
 *
 *   Total:
 *      Byte rate (MB/s or GB/s), successful RX bursts, and average burst size
 *      RFSO benchmark packets and discontinuities per destination port
 *
 *   Hardware:
 *      Bit rate (Gbps)
 *      ipackets
 *      ibytes
 *      imissed
 *      ierrors
 *      rx_nombuf
 * ============================================================ */

struct ByteRate {
  double value{0.0};
  const char *unit{"MB/s"};
};

struct BenchmarkStreamSnapshot {
  uint64_t packets{0};
  uint64_t bytes{0};
  uint64_t discontinuities{0};
};

static ByteRate format_byte_rate(uint64_t bytes, double elapsed) {
  const double bytes_per_second =
      elapsed > 0.0 ? static_cast<double>(bytes) / elapsed : 0.0;

  if (bytes_per_second >= BYTES_PER_GIGABYTE) {
    return {bytes_per_second / BYTES_PER_GIGABYTE, "GB/s"};
  }

  return {bytes_per_second / BYTES_PER_MEGABYTE, "MB/s"};
}

static void statistics_loop(
    uint16_t port_id, uint16_t nb_rx_queues, uint16_t benchmark_stream_count,
    const struct rte_mempool *mbuf_pool,
    std::chrono::steady_clock::time_point program_start_time) {
  using clock = std::chrono::steady_clock;

  auto last_time = clock::now();

  std::vector<uint64_t> last_packets(nb_rx_queues, 0);
  std::vector<uint64_t> last_bytes(nb_rx_queues, 0);
  std::vector<uint64_t> last_rx_bursts(nb_rx_queues, 0);
  std::vector<std::vector<BenchmarkStreamSnapshot>> last_benchmark_streams(
      nb_rx_queues,
      std::vector<BenchmarkStreamSnapshot>(benchmark_stream_count));
  std::vector<BenchmarkStreamSnapshot> last_total_benchmark_streams(
      benchmark_stream_count);
  std::vector<BenchmarkStreamSnapshot> delta_benchmark_streams(
      benchmark_stream_count);

  uint64_t last_total_packets = 0;
  uint64_t last_total_bytes = 0;
  uint64_t last_total_rx_bursts = 0;
  uint64_t last_total_benchmark_packets = 0;
  uint64_t last_total_discontinuities = 0;
  uint64_t last_hw_ipackets = 0;
  uint64_t last_hw_ibytes = 0;
  uint64_t last_hw_imissed = 0;
  uint64_t last_hw_ierrors = 0;
  uint64_t last_hw_rx_nombuf = 0;
  bool has_imissed_mempool_snapshot = false;
  unsigned imissed_mempool_in_use = 0;
  unsigned imissed_mempool_total = 0;
  double imissed_mempool_utilization = 0.0;
  uint64_t imissed_snapshot_total = 0;
  uint64_t imissed_snapshot_increment = 0;

  while (!force_quit.load(std::memory_order_relaxed)) {
    std::this_thread::sleep_for(std::chrono::seconds(1));
    auto now = clock::now();
    double elapsed = std::chrono::duration<double>(now - last_time).count();

    if (elapsed <= 0.0)
      continue;

    /* ----------------------------------------------------
     * Application statistics
     * ---------------------------------------------------- */

    uint64_t total_packets = 0;
    uint64_t total_bytes = 0;
    uint64_t total_rx_bursts = 0;
    uint64_t total_benchmark_packets = 0;
    uint64_t total_discontinuities = 0;
    std::vector<BenchmarkStreamSnapshot> total_benchmark_streams(
        benchmark_stream_count);

    printf("\n");
    printf("================ RX statistics ================\n");

    const double program_uptime_seconds =
        std::chrono::duration<double>(now - program_start_time).count();
    printf("Program uptime    : %9.3f s\n", program_uptime_seconds);

    const unsigned mempool_in_use = rte_mempool_in_use_count(mbuf_pool);
    const unsigned mempool_total = mbuf_pool->size;
    const double mempool_utilization =
        mempool_total != 0
            ? 100.0 * static_cast<double>(mempool_in_use) /
                  static_cast<double>(mempool_total)
            : 0.0;
    printf("RX mempool        : in_use=%u/%u (%.2f%%)\n", mempool_in_use,
           mempool_total, mempool_utilization);

    for (uint16_t q = 0; q < nb_rx_queues; q++) {
      uint64_t packets =
          g_queues[q].stats.packets.load(std::memory_order_relaxed);
      uint64_t bytes = g_queues[q].stats.bytes.load(std::memory_order_relaxed);
      uint64_t rx_bursts =
          g_queues[q].stats.rx_bursts.load(std::memory_order_relaxed);
      uint64_t d_packets = packets - last_packets[q];
      uint64_t d_bytes = bytes - last_bytes[q];
      uint64_t d_rx_bursts = rx_bursts - last_rx_bursts[q];
      uint64_t benchmark_packets = 0;
      uint64_t discontinuities = 0;
      uint64_t d_benchmark_packets = 0;
      uint64_t d_discontinuities = 0;

      last_packets[q] = packets;
      last_bytes[q] = bytes;
      last_rx_bursts[q] = rx_bursts;

      for (uint16_t benchmark_stream_index = 0;
           benchmark_stream_index < benchmark_stream_count;
           ++benchmark_stream_index) {
        const auto &stream_stats =
            g_queues[q].stats.benchmark_streams[benchmark_stream_index];
        const BenchmarkStreamSnapshot stream_snapshot{
            stream_stats.packets.load(std::memory_order_relaxed),
            stream_stats.bytes.load(std::memory_order_relaxed),
            stream_stats.discontinuities.load(std::memory_order_relaxed)};
        const auto &last_stream_snapshot =
            last_benchmark_streams[q][benchmark_stream_index];

        delta_benchmark_streams[benchmark_stream_index] = {
            stream_snapshot.packets - last_stream_snapshot.packets,
            stream_snapshot.bytes - last_stream_snapshot.bytes,
            stream_snapshot.discontinuities -
                last_stream_snapshot.discontinuities};
        last_benchmark_streams[q][benchmark_stream_index] = stream_snapshot;

        benchmark_packets += stream_snapshot.packets;
        discontinuities += stream_snapshot.discontinuities;
        d_benchmark_packets +=
            delta_benchmark_streams[benchmark_stream_index].packets;
        d_discontinuities +=
            delta_benchmark_streams[benchmark_stream_index].discontinuities;
        total_benchmark_streams[benchmark_stream_index].packets +=
            stream_snapshot.packets;
        total_benchmark_streams[benchmark_stream_index].bytes +=
            stream_snapshot.bytes;
        total_benchmark_streams[benchmark_stream_index].discontinuities +=
            stream_snapshot.discontinuities;
      }

      total_packets += packets;
      total_bytes += bytes;
      total_rx_bursts += rx_bursts;
      total_benchmark_packets += benchmark_packets;
      total_discontinuities += discontinuities;

      const ByteRate rate = format_byte_rate(d_bytes, elapsed);
      const double average_burst =
          d_rx_bursts != 0
              ? static_cast<double>(d_packets) / static_cast<double>(d_rx_bursts)
              : 0.0;

      printf("RXQ%-2u  lcore %-2u : "
             "rate=%9.3f %-4s  "
             "packets=%10lu  "
             "rx_bursts=%10lu  avg_burst=%5.2f  "
             "RFSO=%10lu  "
             "discontinuities_total=%10lu (+%lu)\n",
             q, g_queues[q].lcore_id, rate.value, rate.unit, d_packets,
             d_rx_bursts, average_burst, d_benchmark_packets, discontinuities,
             d_discontinuities);

      for (uint16_t benchmark_stream_index = 0;
           benchmark_stream_index < benchmark_stream_count;
           ++benchmark_stream_index) {
        const auto &stream_snapshot =
            last_benchmark_streams[q][benchmark_stream_index];
        const auto &delta_stream_snapshot =
            delta_benchmark_streams[benchmark_stream_index];
        const ByteRate stream_rate =
            format_byte_rate(delta_stream_snapshot.bytes, elapsed);

        printf("  UDP dst %-5u    : rate=%9.3f %-4s  "
               "RFSO=%10lu  "
               "discontinuities_total=%10lu (+%lu)\n",
               static_cast<unsigned>(
                   benchmark_destination_port(benchmark_stream_index)),
               stream_rate.value, stream_rate.unit,
               delta_stream_snapshot.packets, stream_snapshot.discontinuities,
               delta_stream_snapshot.discontinuities);
      }
    }

    /* ----------------------------------------------------
     * Total application statistics
     * ---------------------------------------------------- */

    uint64_t d_total_packets = total_packets - last_total_packets;
    uint64_t d_total_bytes = total_bytes - last_total_bytes;
    uint64_t d_total_rx_bursts = total_rx_bursts - last_total_rx_bursts;
    uint64_t d_total_benchmark_packets =
        total_benchmark_packets - last_total_benchmark_packets;
    uint64_t d_total_discontinuities =
        total_discontinuities - last_total_discontinuities;

    const ByteRate total_rate = format_byte_rate(d_total_bytes, elapsed);
    const double total_average_burst =
        d_total_rx_bursts != 0
            ? static_cast<double>(d_total_packets) /
                  static_cast<double>(d_total_rx_bursts)
            : 0.0;

    printf("\n"
           "TOTAL              : "
           "rate=%9.3f %s\n",
           total_rate.value, total_rate.unit);

    printf("TOTAL packets      : %lu (+%lu)\n", total_packets, d_total_packets);
    printf("TOTAL bytes        : %lu\n", total_bytes);
    printf("TOTAL RX bursts    : %lu (+%lu), avg_burst=%.2f\n",
           total_rx_bursts, d_total_rx_bursts, total_average_burst);
    printf("TOTAL RFSO packets : %lu (+%lu)\n", total_benchmark_packets,
           d_total_benchmark_packets);
    printf("Discontinuities total: %lu (+%lu)\n", total_discontinuities,
           d_total_discontinuities);

    for (uint16_t benchmark_stream_index = 0;
         benchmark_stream_index < benchmark_stream_count;
         ++benchmark_stream_index) {
      const auto &stream_snapshot =
          total_benchmark_streams[benchmark_stream_index];
      const auto &last_stream_snapshot =
          last_total_benchmark_streams[benchmark_stream_index];
      const BenchmarkStreamSnapshot delta_stream_snapshot{
          stream_snapshot.packets - last_stream_snapshot.packets,
          stream_snapshot.bytes - last_stream_snapshot.bytes,
          stream_snapshot.discontinuities -
              last_stream_snapshot.discontinuities};
      const ByteRate stream_rate =
          format_byte_rate(delta_stream_snapshot.bytes, elapsed);

      printf("TOTAL UDP dst %-5u: rate=%9.3f %-4s  "
             "RFSO=%10lu (+%lu)  "
             "discontinuities_total=%10lu (+%lu)\n",
             static_cast<unsigned>(
                 benchmark_destination_port(benchmark_stream_index)),
             stream_rate.value, stream_rate.unit, stream_snapshot.packets,
             delta_stream_snapshot.packets, stream_snapshot.discontinuities,
             delta_stream_snapshot.discontinuities);
      last_total_benchmark_streams[benchmark_stream_index] = stream_snapshot;
    }

    /* ----------------------------------------------------
     * Hardware statistics
     * ---------------------------------------------------- */

    struct rte_eth_stats stats{};
    int ret = rte_eth_stats_get(port_id, &stats);

    if (ret == 0) {
      uint64_t d_hw_ipackets = stats.ipackets - last_hw_ipackets;
      uint64_t d_hw_ibytes = stats.ibytes - last_hw_ibytes;
      uint64_t d_hw_imissed = stats.imissed - last_hw_imissed;
      uint64_t d_hw_ierrors = stats.ierrors - last_hw_ierrors;
      uint64_t d_hw_rx_nombuf = stats.rx_nombuf - last_hw_rx_nombuf;
      const double hw_gbps =
          static_cast<double>(d_hw_ibytes) * 8.0 / elapsed / 1e9;

      if (d_hw_imissed != 0) {
        has_imissed_mempool_snapshot = true;
        imissed_mempool_in_use = mempool_in_use;
        imissed_mempool_total = mempool_total;
        imissed_mempool_utilization = mempool_utilization;
        imissed_snapshot_total = stats.imissed;
        imissed_snapshot_increment = d_hw_imissed;
      }

      printf("\n"
             "Hardware RX        : "
             "rate=%9.3f Gbps\n",
             hw_gbps);
      printf("HW ipackets        : %lu (+%lu)\n", stats.ipackets,
             d_hw_ipackets);
      printf("HW ibytes total    : %lu\n", stats.ibytes);
      printf("HW imissed +%lu    : %lu total\n", d_hw_imissed, stats.imissed);
      printf("HW ierrors +%lu    : %lu total\n", d_hw_ierrors, stats.ierrors);
      printf("HW rx_nombuf +%lu  : %lu total\n", d_hw_rx_nombuf,
             stats.rx_nombuf);

      last_hw_ipackets = stats.ipackets;
      last_hw_ibytes = stats.ibytes;
      last_hw_imissed = stats.imissed;
      last_hw_ierrors = stats.ierrors;
      last_hw_rx_nombuf = stats.rx_nombuf;
    }

    if (has_imissed_mempool_snapshot) {
      printf("RX mempool at imissed: in_use=%u/%u (%.2f%%), "
             "HW imissed=%lu (+%lu)\n",
             imissed_mempool_in_use, imissed_mempool_total,
             imissed_mempool_utilization, imissed_snapshot_total,
             imissed_snapshot_increment);
    } else {
      printf("RX mempool at imissed: not captured\n");
    }

    printf("================================================\n");
    last_total_packets = total_packets;
    last_total_bytes = total_bytes;
    last_total_rx_bursts = total_rx_bursts;
    last_total_benchmark_packets = total_benchmark_packets;
    last_total_discontinuities = total_discontinuities;
    last_time = now;
  }
}

/* ============================================================
 * Main
 * ============================================================ */

int main(int argc, char **argv) {
  signal(SIGINT, signal_handler);
  signal(SIGTERM, signal_handler);
  const auto program_start_time = std::chrono::steady_clock::now();

  /* ========================================================
   * 1. Initialize DPDK EAL
   * ======================================================== */

  int ret = rte_eal_init(argc, argv);

  if (ret < 0) {
    rte_exit(EXIT_FAILURE, "Failed to initialize DPDK EAL\n");
  }

  argc -= ret;
  argv += ret;

  /* ========================================================
   * 2. Port
   *
   * Current E810:
   *
   *   0000:83:00.0
   *
   * DPDK sees it as port 0.
   * ======================================================== */

  uint16_t port_id = 0;

  if (!rte_eth_dev_is_valid_port(port_id)) {
    rte_exit(EXIT_FAILURE, "DPDK port %u is not available\n", port_id);
  }

  /* ========================================================
   * 3. Parse application arguments
   *
   * Usage:
   *
   *   -- -q 8 -s 2
   *
   * Default:
   *
   *   1 RX queue
   *   2 RFSO UDP streams: destination ports 5001-5002
   * ======================================================== */

  uint16_t nb_rx_queues = 1;
  uint16_t benchmark_stream_count = DEFAULT_BENCHMARK_STREAM_COUNT;

  for (int i = 0; i < argc; i++) {
    if (!strcmp(argv[i], "-q")) {
      if (i + 1 >= argc) {
        rte_exit(EXIT_FAILURE, "-q requires an argument\n");
      }

      long value = strtol(argv[++i], nullptr, 10);

      if (value <= 0 || value > 256) {
        rte_exit(EXIT_FAILURE, "Invalid RX queue count: %ld\n", value);
      }

      nb_rx_queues = static_cast<uint16_t>(value);
    } else if (!strcmp(argv[i], "-s") || !strcmp(argv[i], "--streams")) {
      if (i + 1 >= argc) {
        rte_exit(EXIT_FAILURE, "%s requires an argument\n", argv[i]);
      }

      long value = strtol(argv[++i], nullptr, 10);

      if (value <= 0 ||
          static_cast<unsigned long>(value) > MAXIMUM_BENCHMARK_STREAM_COUNT) {
        rte_exit(EXIT_FAILURE,
                 "Invalid RFSO UDP stream count: %ld (allowed 1-%u)\n", value,
                 static_cast<unsigned>(MAXIMUM_BENCHMARK_STREAM_COUNT));
      }

      benchmark_stream_count = static_cast<uint16_t>(value);
    }
  }

  /* ========================================================
   * 4. Enumerate WORKER lcores
   *
   * IMPORTANT:
   *
   * rte_lcore_count()
   * includes MAIN lcore.
   *
   * We need one worker lcore per RX queue.
   *
   * Example:
   *
   *   -l 14-27
   *
   * Main:
   *   lcore 14
   *
   * Workers:
   *   15 ... 27
   *
   * Therefore:
   *
   *   13 worker lcores
   * ======================================================== */

  std::vector<unsigned> worker_lcores;

  unsigned lcore_id;

  RTE_LCORE_FOREACH_WORKER(lcore_id) { worker_lcores.push_back(lcore_id); }

  printf("\n");
  printf("Main lcore       : %u\n", rte_get_main_lcore());

  printf("Worker lcores    : %zu\n", worker_lcores.size());

  printf("Worker lcore list: ");

  for (unsigned id : worker_lcores) {

    printf("%u ", id);
  }

  printf("\n");

  /* ========================================================
   * 5. Check queue / worker relationship
   *
   * One queue MUST use one worker.
   * ======================================================== */

  if (nb_rx_queues > worker_lcores.size()) {
    rte_exit(EXIT_FAILURE,

             "Not enough worker lcores!\n"
             "RX queues   = %u\n"
             "Workers     = %zu\n"
             "Please add more lcores with -l.\n",

             nb_rx_queues, worker_lcores.size());
  }

  printf("Using %u RX queues\n", nb_rx_queues);
  printf("Using %u RFSO UDP streams (destination ports %u-%u)\n",
         static_cast<unsigned>(benchmark_stream_count),
         static_cast<unsigned>(BENCHMARK_FIRST_DESTINATION_PORT),
         static_cast<unsigned>(
             benchmark_destination_port(benchmark_stream_count - 1U)));

  /* ========================================================
   * 6. Get NIC NUMA socket
   * ======================================================== */

  int socket_id = rte_eth_dev_socket_id(port_id);

  if (socket_id < 0)
    socket_id = 0;

  printf("E810 NUMA socket = %d\n", socket_id);

  /* ========================================================
   * 7. Create mbuf pool
   * ======================================================== */

  char pool_name[64];

  snprintf(pool_name, sizeof(pool_name), "E810_RX_MBUF_%u", port_id);

  struct rte_mempool *mbuf_pool = rte_pktmbuf_pool_create(
      pool_name, NUM_MBUFS, MBUF_CACHE_SIZE, 0, MBUF_DATA_SIZE, socket_id);

  if (mbuf_pool == nullptr) {
    rte_exit(EXIT_FAILURE,
             "Cannot create mbuf pool!\n"
             "NUMA socket = %d\n"
             "NUM_MBUFS   = %u\n"
             "DATA_SIZE   = %u\n",
             socket_id, NUM_MBUFS, MBUF_DATA_SIZE);
  }

  printf("Mbuf pool created: "
         "%u mbufs, data size=%u\n",
         NUM_MBUFS, MBUF_DATA_SIZE);

  /* ========================================================
   * 8. Configure Ethernet port
   * ======================================================== */

  struct rte_eth_conf port_conf{};

  port_conf.rxmode.mq_mode = RTE_ETH_MQ_RX_RSS;
  port_conf.rx_adv_conf.rss_conf.rss_hf = RTE_ETH_RSS_NONFRAG_IPV4_UDP;
  printf("RSS hash flags = 0x%016lx\n", port_conf.rx_adv_conf.rss_conf.rss_hf);

  ret = rte_eth_dev_configure(port_id, nb_rx_queues, 0, &port_conf);

  if (ret < 0) {
    rte_exit(EXIT_FAILURE,
             "rte_eth_dev_configure() "
             "failed: %d\n",
             ret);
  }

  uint16_t mtu = 9100;

  ret = rte_eth_dev_set_mtu(port_id, mtu);
  if (ret < 0) {
    rte_exit(EXIT_FAILURE, "Failed to set MTU %u: %s\n", mtu,
             rte_strerror(-ret));
  }
  printf("Port %u MTU set to %u\n", port_id, mtu);

  /* ========================================================
   * 9. Configure RX queues
   * ======================================================== */

  for (uint16_t q = 0; q < nb_rx_queues; q++) {
    ret = rte_eth_rx_queue_setup(port_id, q, RX_DESC, socket_id, nullptr,
                                 mbuf_pool);

    if (ret < 0) {
      rte_exit(EXIT_FAILURE, "RX queue %u setup failed: %d\n", q, ret);
    }
  }

  /* ========================================================
   * 10. Start port
   *
   * Do NOT modify MTU here.
   *
   * The current E810 traffic is already Jumbo Frame,
   * and MBUF_DATA_SIZE=9728 is sufficient.
   * ======================================================== */

  ret = rte_eth_dev_start(port_id);

  if (ret < 0) {
    rte_exit(EXIT_FAILURE, "Failed to start port %u: %d\n", port_id, ret);
  }

  /* ========================================================
   * 11. Install exact UDP destination-port steering rules
   *
   * Matching benchmark streams use QUEUE actions. Other traffic
   * continues through the configured RSS path.
   * ======================================================== */

  std::vector<struct rte_flow *> benchmark_flow_handles;
  benchmark_flow_handles.reserve(benchmark_stream_count);

  if (!create_benchmark_flow_rules(port_id, nb_rx_queues,
                                   benchmark_stream_count,
                                   benchmark_flow_handles)) {
    rte_eth_dev_stop(port_id);
    rte_eth_dev_close(port_id);
    rte_exit(EXIT_FAILURE, "Failed to install RFSO UDP steering rules\n");
  }

  /* ========================================================
   * 12. Enable promiscuous mode
   * ======================================================== */

  ret = rte_eth_promiscuous_enable(port_id);

  if (ret < 0) {
    printf("Warning: "
           "promiscuous mode enable failed: %d\n",
           ret);
  }

  /* ========================================================
   * 13. Print port information
   * ======================================================== */

  print_port_info(port_id, nb_rx_queues, benchmark_stream_count, socket_id);

  /* ========================================================
   * 14. Assign RX queue -> worker lcore
   *
   * STRICT 1:1 mapping.
   *
   * Example:
   *
   *   worker_lcores:
   *
   *      15 16 17 18 19 20 21 22
   *
   *   mapping:
   *
   *      RXQ0 -> 15
   *      RXQ1 -> 16
   *      RXQ2 -> 17
   *      RXQ3 -> 18
   *      RXQ4 -> 19
   *      RXQ5 -> 20
   *      RXQ6 -> 21
   *      RXQ7 -> 22
   * ======================================================== */

  for (uint16_t q = 0; q < nb_rx_queues; q++) {
    unsigned worker = worker_lcores[q];
    g_queues[q].port_id = port_id;
    g_queues[q].queue_id = q;
    g_queues[q].lcore_id = worker;
    g_queues[q].benchmark_stream_count = benchmark_stream_count;
    g_queues[q].stats.benchmark_streams.reset(
        new (std::nothrow) BenchmarkStreamStats[benchmark_stream_count]);
    g_queues[q].benchmark_sequences.reset(
        new (std::nothrow) BenchmarkSequenceState[benchmark_stream_count]);

    if (!g_queues[q].stats.benchmark_streams ||
        !g_queues[q].benchmark_sequences) {
      rte_exit(EXIT_FAILURE,
               "Cannot allocate RFSO UDP state for RX queue %u, streams=%u\n",
               static_cast<unsigned>(q),
               static_cast<unsigned>(benchmark_stream_count));
    }

    ret = rte_eal_remote_launch(rx_loop, &g_queues[q], worker);

    if (ret != 0) {
      rte_exit(EXIT_FAILURE,
               "Failed to launch RXQ%u "
               "on lcore %u: %d\n",
               q, worker, ret);
    }
  }

  /* ========================================================
   * 15. Print mapping
   * ======================================================== */

  print_queue_mapping(nb_rx_queues);

  /* ========================================================
   * 16. Statistics
   *
   * Main lcore is responsible for statistics.
   * ======================================================== */

  statistics_loop(port_id, nb_rx_queues, benchmark_stream_count, mbuf_pool,
                  program_start_time);

  /* ========================================================
   * 17. Wait for worker lcores
   * ======================================================== */

  for (uint16_t q = 0; q < nb_rx_queues; ++q) {
    rte_eal_wait_lcore(g_queues[q].lcore_id);
  }

  print_burst_histogram(nb_rx_queues);
  print_poll_gap_statistics(nb_rx_queues);

  /* ========================================================
   * 18. Destroy steering rules, then stop and close port
   * ======================================================== */

  destroy_benchmark_flow_rules(port_id, benchmark_flow_handles);
  rte_eth_dev_stop(port_id);
  rte_eth_dev_close(port_id);

  printf("\nDPDK RX stopped.\n");

  return 0;
}
