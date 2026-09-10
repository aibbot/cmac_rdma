#define _GNU_SOURCE

#include <arpa/inet.h>
#include <endian.h>
#include <errno.h>
#include <getopt.h>
#include <infiniband/verbs.h>
#include <inttypes.h>
#include <net/if.h>
#include <netpacket/packet.h>
#include <poll.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum {
    RDMA_PMTU_BYTES = 4096,
    COMMIT_BYTES = 64,
    COMMIT_MAGIC = 0x52444d41,
    COMMIT_SEQUENCE_OFFSET = 40,
    DEFAULT_RECV_DEPTH = 1024,
};

struct rdma_ring_commit {
    uint64_t published_bytes;
    uint32_t ring_end_offset;
    uint32_t interval_bytes;
    uint32_t final;
    uint32_t magic;
    uint8_t reserved_before_sequence[16];
    uint64_t producer_sequence;
    uint8_t reserved_after_sequence[16];
} __attribute__((aligned(COMMIT_BYTES)));

_Static_assert(sizeof(struct rdma_ring_commit) == COMMIT_BYTES,
               "commit record must be exactly 64 bytes");
_Static_assert(offsetof(struct rdma_ring_commit, producer_sequence) ==
                   COMMIT_SEQUENCE_OFFSET,
               "commit release sequence offset must match the FPGA RTL");

struct options {
    const char *device_name;
    const char *netdev_name;
    const char *fpga_ip_text;
    const char *fpga_mac_text;
    uint8_t port_num;
    uint32_t fpga_qpn;
    uint32_t fpga_tx_psn;
    uint32_t host_tx_psn;
    uint64_t ring_size;
    uint64_t wr_size;
    uint64_t notify_interval;
    uint64_t local_base;
    uint32_t recv_depth;
    unsigned int run_seconds;
    bool enable_immediate;
    bool allow_ring_wrap;
    bool verify_on_exit;
};

struct netdev_info {
    struct in_addr ipv4;
    uint8_t mac[6];
    int mtu;
    unsigned int ifindex;
};

struct commit_snapshot {
    uint64_t sequence;
    uint64_t published_bytes;
    uint32_t ring_end_offset;
    uint32_t interval_bytes;
    bool final;
};

static volatile sig_atomic_t stop_requested;

static void on_signal(int signal_number) {
    (void)signal_number;
    stop_requested = 1;
}

static void usage(const char *program) {
    fprintf(stderr,
            "Usage: %s --device irdma0 --netdev <ice-netdev> --fpga-ip A.B.C.D \\\n+--fpga-mac XX:XX:XX:XX:XX:XX [options]\n"
            "\n"
            "Required:\n"
            "  --device NAME              libibverbs device, normally irdmaN\n"
            "  --netdev NAME              matching ice netdevice\n"
            "  --fpga-ip IPv4             FPGA IPv4 address\n"
            "  --fpga-mac MAC             FPGA Ethernet MAC address\n"
            "\n"
            "Ring / notification options:\n"
            "  --ring-size SIZE           default 1G, must be 4096-byte aligned\n"
            "  --wr-size SIZE             default 1M, must be <= ring size\n"
            "  --notify-interval SIZE     default 1M; for example 1M or 10M\n"
            "  --immediate                use WRITE_WITH_IMM commits and post RQEs\n"
            "  --recv-depth COUNT         Immediate receive WQEs, default 1024\n"
            "  --allow-ring-wrap          permit overwrite after one ring; requires consumer credit\n"
            "  --local-base VALUE         FPGA data-generator base, default 0\n"
            "\n"
            "QP / runtime options:\n"
            "  --fpga-qpn VALUE           default 1, valid range 1..255\n"
            "  --fpga-tx-psn VALUE        default random 24-bit PSN\n"
            "  --host-tx-psn VALUE        default random 24-bit PSN\n"
            "  --port VALUE               RDMA port, default 1\n"
            "  --seconds VALUE            print a stop reminder after this duration\n"
            "  --verify-on-exit           scan the published ring after FPGA is drained\n",
            program);
}

static int parse_u64(const char *text, uint64_t *value) {
    char *end = NULL;
    unsigned long long parsed;

    errno = 0;
    parsed = strtoull(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0') {
        return -1;
    }
    *value = (uint64_t)parsed;
    return 0;
}

static int parse_size(const char *text, uint64_t *value) {
    char *end = NULL;
    unsigned long long parsed;
    uint64_t multiplier = 1;

    errno = 0;
    parsed = strtoull(text, &end, 0);
    if (errno != 0 || end == text) {
        return -1;
    }
    if (*end != '\0') {
        if (end[1] != '\0') {
            return -1;
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
            return -1;
        }
    }
    if (parsed > UINT64_MAX / multiplier) {
        return -1;
    }
    *value = (uint64_t)parsed * multiplier;
    return 0;
}

static int parse_psn(const char *text, uint32_t *psn) {
    uint64_t value;

    if (parse_u64(text, &value) != 0 || value > 0xffffffULL) {
        return -1;
    }
    *psn = (uint32_t)value;
    return 0;
}

static int parse_mac(const char *text, uint8_t mac[6]) {
    unsigned int bytes[6];

    if (sscanf(text, "%x:%x:%x:%x:%x:%x", &bytes[0], &bytes[1], &bytes[2],
               &bytes[3], &bytes[4], &bytes[5]) != 6) {
        return -1;
    }
    for (size_t index = 0; index < 6; ++index) {
        if (bytes[index] > 0xffU) {
            return -1;
        }
        mac[index] = (uint8_t)bytes[index];
    }
    return 0;
}

static void format_mac(const uint8_t mac[6], char output[18]) {
    snprintf(output, 18, "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1],
             mac[2], mac[3], mac[4], mac[5]);
}

static void format_mac_vio(const uint8_t mac[6], char output[15]) {
    snprintf(output, 15, "0x%02X%02X%02X%02X%02X%02X", mac[0], mac[1],
             mac[2], mac[3], mac[4], mac[5]);
}

static void format_gid(const union ibv_gid *gid, char output[33]) {
    for (size_t index = 0; index < 16; ++index) {
        snprintf(&output[index * 2], 3, "%02x", gid->raw[index]);
    }
    output[32] = '\0';
}

static bool gid_matches_ipv4(const union ibv_gid *gid, const struct in_addr *ipv4) {
    static const uint8_t prefix[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};

    return memcmp(gid->raw, prefix, sizeof(prefix)) == 0 &&
           memcmp(&gid->raw[12], &ipv4->s_addr, sizeof(ipv4->s_addr)) == 0;
}

static union ibv_gid ipv4_mapped_gid(const struct in_addr *ipv4) {
    union ibv_gid result = {{0}};

    result.raw[10] = 0xff;
    result.raw[11] = 0xff;
    memcpy(&result.raw[12], &ipv4->s_addr, sizeof(ipv4->s_addr));
    return result;
}

static int query_netdev(const char *name, struct netdev_info *info) {
    int socket_fd = -1;
    struct ifreq request;

    memset(info, 0, sizeof(*info));
    socket_fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (socket_fd < 0) {
        perror("socket");
        return -1;
    }
    memset(&request, 0, sizeof(request));
    strncpy(request.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(socket_fd, SIOCGIFADDR, &request) != 0 ||
        request.ifr_addr.sa_family != AF_INET) {
        perror("SIOCGIFADDR");
        close(socket_fd);
        return -1;
    }
    info->ipv4 = ((struct sockaddr_in *)&request.ifr_addr)->sin_addr;

    if (ioctl(socket_fd, SIOCGIFHWADDR, &request) != 0) {
        perror("SIOCGIFHWADDR");
        close(socket_fd);
        return -1;
    }
    memcpy(info->mac, request.ifr_hwaddr.sa_data, sizeof(info->mac));

    if (ioctl(socket_fd, SIOCGIFMTU, &request) != 0) {
        perror("SIOCGIFMTU");
        close(socket_fd);
        return -1;
    }
    info->mtu = request.ifr_mtu;

    if (ioctl(socket_fd, SIOCGIFFLAGS, &request) != 0) {
        perror("SIOCGIFFLAGS");
        close(socket_fd);
        return -1;
    }
    if ((request.ifr_flags & IFF_UP) == 0 || (request.ifr_flags & IFF_RUNNING) == 0) {
        fprintf(stderr, "netdev %s is not up and carrier-running\n", name);
        close(socket_fd);
        return -1;
    }
    close(socket_fd);

    info->ifindex = if_nametoindex(name);
    if (info->ifindex == 0) {
        fprintf(stderr, "cannot resolve netdev index for %s\n", name);
        return -1;
    }
    if (info->mtu < 9000) {
        fprintf(stderr, "netdev %s MTU is %d; 9000 or greater is required\n", name,
                info->mtu);
        return -1;
    }
    return 0;
}

static struct ibv_context *open_device(const char *name) {
    struct ibv_device **devices = NULL;
    struct ibv_context *context = NULL;
    int device_count = 0;

    devices = ibv_get_device_list(&device_count);
    if (devices == NULL) {
        perror("ibv_get_device_list");
        return NULL;
    }
    for (int index = 0; index < device_count; ++index) {
        if (strcmp(ibv_get_device_name(devices[index]), name) == 0) {
            context = ibv_open_device(devices[index]);
            break;
        }
    }
    ibv_free_device_list(devices);
    if (context == NULL) {
        fprintf(stderr, "cannot open RDMA device %s\n", name);
    }
    return context;
}

static int select_rocev2_gid(struct ibv_context *context, uint8_t port_num,
                             const struct netdev_info *netdev, int *gid_index,
                             union ibv_gid *gid) {
    struct ibv_port_attr port_attr;

    if (ibv_query_port(context, port_num, &port_attr) != 0) {
        perror("ibv_query_port");
        return -1;
    }
    if (port_attr.state != IBV_PORT_ACTIVE) {
        fprintf(stderr, "RDMA port %u is not active\n", port_num);
        return -1;
    }
    if (port_attr.active_mtu < IBV_MTU_4096) {
        fprintf(stderr, "RDMA port %u active MTU is smaller than 4096\n", port_num);
        return -1;
    }
    for (int index = 0; index < port_attr.gid_tbl_len; ++index) {
        struct ibv_gid_entry entry;

        memset(&entry, 0, sizeof(entry));
        if (ibv_query_gid_ex(context, port_num, index, &entry, 0) != 0) {
            continue;
        }
        if (entry.gid_type != IBV_GID_TYPE_ROCE_V2 ||
            entry.ndev_ifindex != netdev->ifindex ||
            !gid_matches_ipv4(&entry.gid, &netdev->ipv4)) {
            continue;
        }
        *gid_index = index;
        *gid = entry.gid;
        return 0;
    }
    fprintf(stderr,
            "no RoCEv2 GID on port %u matches netdev %s and its IPv4 address\n",
            port_num, "selected netdev");
    return -1;
}

static int modify_qp_to_rts(struct ibv_qp *qp, const struct options *options,
                            int gid_index, const union ibv_gid *fpga_gid) {
    struct ibv_qp_attr attr;
    int mask;

    memset(&attr, 0, sizeof(attr));
    attr.qp_state = IBV_QPS_INIT;
    attr.pkey_index = 0;
    attr.port_num = options->port_num;
    attr.qp_access_flags = IBV_ACCESS_REMOTE_WRITE;
    mask = IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS;
    if (ibv_modify_qp(qp, &attr, mask) != 0) {
        perror("ibv_modify_qp INIT");
        return -1;
    }

    memset(&attr, 0, sizeof(attr));
    attr.qp_state = IBV_QPS_RTR;
    attr.path_mtu = IBV_MTU_4096;
    attr.dest_qp_num = options->fpga_qpn;
    attr.rq_psn = options->fpga_tx_psn;
    attr.max_dest_rd_atomic = 1;
    attr.min_rnr_timer = 12;
    attr.ah_attr.is_global = 1;
    attr.ah_attr.port_num = options->port_num;
    attr.ah_attr.grh.dgid = *fpga_gid;
    attr.ah_attr.grh.sgid_index = gid_index;
    attr.ah_attr.grh.hop_limit = 1;
    mask = IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN |
           IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER;
    if (ibv_modify_qp(qp, &attr, mask) != 0) {
        perror("ibv_modify_qp RTR");
        return -1;
    }

    memset(&attr, 0, sizeof(attr));
    attr.qp_state = IBV_QPS_RTS;
    attr.sq_psn = options->host_tx_psn;
    attr.timeout = 20;
    attr.retry_cnt = 7;
    attr.rnr_retry = 7;
    attr.max_rd_atomic = 1;
    mask = IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY |
           IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC;
    if (ibv_modify_qp(qp, &attr, mask) != 0) {
        perror("ibv_modify_qp RTS");
        return -1;
    }
    return 0;
}

static int post_receive(struct ibv_qp *qp, const struct ibv_mr *mr,
                        const void *scratch, uint64_t wr_id) {
    struct ibv_sge sge;
    struct ibv_recv_wr receive;
    struct ibv_recv_wr *bad = NULL;

    memset(&sge, 0, sizeof(sge));
    sge.addr = (uintptr_t)scratch;
    sge.length = COMMIT_BYTES;
    sge.lkey = mr->lkey;
    memset(&receive, 0, sizeof(receive));
    receive.wr_id = wr_id;
    receive.sg_list = &sge;
    receive.num_sge = 1;
    if (ibv_post_recv(qp, &receive, &bad) != 0) {
        perror("ibv_post_recv");
        return -1;
    }
    return 0;
}

static bool read_commit(const volatile struct rdma_ring_commit *record,
                        struct commit_snapshot *snapshot) {
    struct rdma_ring_commit local;
    uint64_t first_sequence;
    uint64_t second_sequence;

    first_sequence = __atomic_load_n(&record->producer_sequence, __ATOMIC_ACQUIRE);
    if (first_sequence == 0) {
        return false;
    }
    atomic_thread_fence(memory_order_acquire);
    memcpy(&local, (const void *)record, sizeof(local));
    atomic_thread_fence(memory_order_acquire);
    second_sequence = __atomic_load_n(&record->producer_sequence, __ATOMIC_ACQUIRE);
    if (first_sequence != second_sequence ||
        le64toh(local.producer_sequence) != second_sequence ||
        le32toh(local.magic) != COMMIT_MAGIC) {
        return false;
    }
    snapshot->sequence = second_sequence;
    snapshot->published_bytes = le64toh(local.published_bytes);
    snapshot->ring_end_offset = le32toh(local.ring_end_offset);
    snapshot->interval_bytes = le32toh(local.interval_bytes);
    snapshot->final = le32toh(local.final) != 0;
    return true;
}

static int verify_ring(const uint8_t *ring, const struct commit_snapshot *snapshot,
                       uint64_t ring_size, uint64_t local_base) {
    uint64_t bytes_to_check;
    uint64_t chronological_offset;
    uint64_t ring_offset;

    if (snapshot->published_bytes == 0) {
        fprintf(stderr, "no published bytes to verify\n");
        return -1;
    }
    if (snapshot->ring_end_offset >= ring_size ||
        snapshot->ring_end_offset != snapshot->published_bytes % ring_size) {
        fprintf(stderr, "invalid published ring offset %" PRIu32 " for %" PRIu64 " bytes\n",
                snapshot->ring_end_offset, snapshot->published_bytes);
        return -1;
    }
    bytes_to_check = snapshot->published_bytes < ring_size ?
                         snapshot->published_bytes : ring_size;
    chronological_offset = snapshot->published_bytes - bytes_to_check;
    ring_offset = snapshot->published_bytes < ring_size ? 0 : snapshot->ring_end_offset;

    for (uint64_t checked = 0; checked < bytes_to_check; checked += sizeof(uint64_t)) {
        uint64_t actual;
        uint64_t expected;

        memcpy(&actual, ring + ring_offset, sizeof(actual));
        actual = le64toh(actual);
        expected = (local_base + chronological_offset + checked) >> 3;
        if (actual != expected) {
            fprintf(stderr,
                    "ring verification failed: remote offset=%" PRIu64
                    " actual=%" PRIx64 " expected=%" PRIx64 "\n",
                    ring_offset, actual, expected);
            return -1;
        }
        ring_offset += sizeof(uint64_t);
        if (ring_offset == ring_size) {
            ring_offset = 0;
        }
    }
    printf("ring verification passed: %" PRIu64 " bytes, sequence=%" PRIu64 "\n",
           bytes_to_check, snapshot->sequence);
    return 0;
}

static void print_vio_json(const struct options *options, const struct netdev_info *netdev,
                           const struct ibv_qp *qp, const struct ibv_mr *mr,
                           const union ibv_gid *host_gid, int gid_index,
                           const void *ring, const void *commit) {
    char host_ip[INET_ADDRSTRLEN];
    char host_mac[18];
    char host_mac_vio[15];
    char gid_text[33];
    uint32_t host_ip_hex = ntohl(netdev->ipv4.s_addr);
    uint8_t fpga_mac[6];

    (void)parse_mac(options->fpga_mac_text, fpga_mac);
    inet_ntop(AF_INET, &netdev->ipv4, host_ip, sizeof(host_ip));
    format_mac(netdev->mac, host_mac);
    format_mac_vio(netdev->mac, host_mac_vio);
    format_gid(host_gid, gid_text);
    printf("{\n"
           "  \"host\": {\n"
           "    \"device\": \"%s\", \"netdev\": \"%s\", \"ip\": \"%s\",\n"
           "    \"mac\": \"%s\", \"gid\": \"%s\", \"gid_index\": %d,\n"
           "    \"qpn\": %u, \"sq_psn\": %u, \"rq_psn\": %u\n"
           "  },\n"
           "  \"fpga\": {\n"
           "    \"ip\": \"%s\", \"mac\": \"%s\", \"qpn\": %u, \"tx_psn\": %u\n"
           "  },\n"
           "  \"vio\": {\n"
           "    \"cfg_force_remote_mac\": 1,\n"
           "    \"cfg_remote_mac\": \"%s\",\n"
           "    \"cfg_remote_ip\": \"0x%08" PRIX32 "\",\n"
           "    \"cfg_local_qpn\": %u, \"cfg_remote_qpn\": %u,\n"
           "    \"cfg_local_psn\": %u, \"cfg_remote_psn\": %u,\n"
           "    \"cfg_remote_base\": \"0x%012" PRIXPTR "\",\n"
           "    \"cfg_rkey\": \"0x%08" PRIX32 "\",\n"
           "    \"cfg_ring_size\": %" PRIu64 ", \"cfg_wr_size\": %" PRIu64 ",\n"
           "    \"cfg_local_base\": \"0x%016" PRIX64 "\",\n"
            "    \"cfg_enable_immediate\": %u,\n"
            "    \"cfg_notify_interval_bytes\": %" PRIu64 ",\n"
            "    \"cfg_commit_remote_addr\": \"0x%012" PRIXPTR "\",\n"
            "    \"cfg_allow_ring_wrap\": %u\n"
           "  }\n"
           "}\n",
           options->device_name, options->netdev_name, host_ip, host_mac, gid_text,
           gid_index, qp->qp_num, options->host_tx_psn, options->fpga_tx_psn,
           options->fpga_ip_text, options->fpga_mac_text, options->fpga_qpn,
           options->fpga_tx_psn, host_mac_vio, host_ip_hex, options->fpga_qpn,
           qp->qp_num, options->fpga_tx_psn, options->host_tx_psn,
           (uintptr_t)ring, mr->rkey, options->ring_size, options->wr_size,
           options->local_base, options->enable_immediate ? 1U : 0U,
           options->notify_interval, (uintptr_t)commit,
           options->allow_ring_wrap ? 1U : 0U);
}

static uint32_t random_psn(void) {
    struct timespec now;
    uint32_t psn;

    clock_gettime(CLOCK_MONOTONIC, &now);
    psn = ((uint32_t)now.tv_nsec ^ (uint32_t)now.tv_sec ^ (uint32_t)getpid()) & 0xffffffU;
    return psn == 0 ? 1 : psn;
}

int main(int argc, char **argv) {
    static const struct option long_options[] = {
        {"device", required_argument, NULL, 'd'},
        {"netdev", required_argument, NULL, 'n'},
        {"fpga-ip", required_argument, NULL, 'i'},
        {"fpga-mac", required_argument, NULL, 'm'},
        {"port", required_argument, NULL, 'p'},
        {"fpga-qpn", required_argument, NULL, 'q'},
        {"fpga-tx-psn", required_argument, NULL, 'f'},
        {"host-tx-psn", required_argument, NULL, 's'},
        {"ring-size", required_argument, NULL, 'r'},
        {"wr-size", required_argument, NULL, 'w'},
        {"notify-interval", required_argument, NULL, 'N'},
        {"local-base", required_argument, NULL, 'l'},
        {"recv-depth", required_argument, NULL, 'R'},
        {"immediate", no_argument, NULL, 'I'},
        {"allow-ring-wrap", no_argument, NULL, 'W'},
        {"seconds", required_argument, NULL, 't'},
        {"verify-on-exit", no_argument, NULL, 'v'},
        {"help", no_argument, NULL, 'h'},
        {NULL, 0, NULL, 0},
    };
    struct options options = {
        .port_num = 1,
        .fpga_qpn = 1,
        .ring_size = 1024ULL * 1024ULL * 1024ULL,
        .wr_size = 1024ULL * 1024ULL,
        .notify_interval = 1024ULL * 1024ULL,
        .recv_depth = DEFAULT_RECV_DEPTH,
    };
    struct netdev_info netdev;
    struct in_addr fpga_ipv4;
    union ibv_gid host_gid;
    union ibv_gid fpga_gid;
    struct ibv_context *context = NULL;
    struct ibv_pd *pd = NULL;
    struct ibv_cq *cq = NULL;
    struct ibv_qp *qp = NULL;
    struct ibv_mr *mr = NULL;
    uint8_t fpga_mac[6];
    uint8_t *ring_memory = NULL;
    struct rdma_ring_commit *commit = NULL;
    struct commit_snapshot last_commit = {0};
    int gid_index = -1;
    int exit_status = EXIT_FAILURE;
    int option;
    time_t started;

    while ((option = getopt_long(argc, argv, "d:n:i:m:p:q:f:s:r:w:N:l:R:IWt:vh",
                                 long_options, NULL)) != -1) {
        uint64_t value;

        switch (option) {
        case 'd': options.device_name = optarg; break;
        case 'n': options.netdev_name = optarg; break;
        case 'i': options.fpga_ip_text = optarg; break;
        case 'm': options.fpga_mac_text = optarg; break;
        case 'p':
            if (parse_u64(optarg, &value) != 0 || value == 0 || value > UINT8_MAX) goto bad_option;
            options.port_num = (uint8_t)value;
            break;
        case 'q':
            if (parse_u64(optarg, &value) != 0 || value == 0 || value > 255) goto bad_option;
            options.fpga_qpn = (uint32_t)value;
            break;
        case 'f': if (parse_psn(optarg, &options.fpga_tx_psn) != 0) goto bad_option; break;
        case 's': if (parse_psn(optarg, &options.host_tx_psn) != 0) goto bad_option; break;
        case 'r': if (parse_size(optarg, &options.ring_size) != 0) goto bad_option; break;
        case 'w': if (parse_size(optarg, &options.wr_size) != 0) goto bad_option; break;
        case 'N': if (parse_size(optarg, &options.notify_interval) != 0) goto bad_option; break;
        case 'l': if (parse_u64(optarg, &options.local_base) != 0) goto bad_option; break;
        case 'R':
            if (parse_u64(optarg, &value) != 0 || value == 0 || value > UINT32_MAX) goto bad_option;
            options.recv_depth = (uint32_t)value;
            break;
        case 'I': options.enable_immediate = true; break;
        case 'W': options.allow_ring_wrap = true; break;
        case 't':
            if (parse_u64(optarg, &value) != 0 || value > UINT32_MAX) goto bad_option;
            options.run_seconds = (unsigned int)value;
            break;
        case 'v': options.verify_on_exit = true; break;
        case 'h': usage(argv[0]); return EXIT_SUCCESS;
        default: goto bad_option;
        }
        continue;
bad_option:
        fprintf(stderr, "invalid value for option -%c\n", option);
        return EXIT_FAILURE;
    }

    if (options.device_name == NULL || options.netdev_name == NULL ||
        options.fpga_ip_text == NULL || options.fpga_mac_text == NULL ||
        inet_pton(AF_INET, options.fpga_ip_text, &fpga_ipv4) != 1 ||
        parse_mac(options.fpga_mac_text, fpga_mac) != 0) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }
    if (options.fpga_tx_psn == 0) options.fpga_tx_psn = random_psn();
    if (options.host_tx_psn == 0) options.host_tx_psn = random_psn();
    if (options.ring_size > UINT32_MAX || options.wr_size > UINT32_MAX ||
        options.notify_interval > UINT32_MAX ||
        (options.ring_size % RDMA_PMTU_BYTES) != 0 ||
        (options.wr_size % RDMA_PMTU_BYTES) != 0 ||
        (options.notify_interval % RDMA_PMTU_BYTES) != 0 ||
        options.wr_size == 0 || options.wr_size > options.ring_size ||
        options.notify_interval == 0 || options.notify_interval > options.ring_size ||
        (options.local_base & 7U) != 0) {
        fprintf(stderr, "ring, WR, and notification sizes must fit FPGA 32-bit VIO fields, be nonzero 4096-byte multiples, and have WR/interval <= ring\n");
        return EXIT_FAILURE;
    }
    if (options.ring_size > SIZE_MAX - COMMIT_BYTES) {
        fprintf(stderr, "ring allocation is too large for this process\n");
        return EXIT_FAILURE;
    }
    if (query_netdev(options.netdev_name, &netdev) != 0) goto cleanup;

    {
        struct rlimit limit;
        if (getrlimit(RLIMIT_MEMLOCK, &limit) != 0) {
            perror("getrlimit RLIMIT_MEMLOCK");
            goto cleanup;
        }
        if (limit.rlim_cur != RLIM_INFINITY &&
            options.ring_size + COMMIT_BYTES > limit.rlim_cur) {
            fprintf(stderr,
                    "memlock soft limit (%" PRIu64 ") is below required registered memory (%" PRIu64 "); raise ulimit -l first\n",
                    (uint64_t)limit.rlim_cur, options.ring_size + COMMIT_BYTES);
            goto cleanup;
        }
    }
    if (posix_memalign((void **)&ring_memory, RDMA_PMTU_BYTES,
                       (size_t)(options.ring_size + COMMIT_BYTES)) != 0) {
        perror("posix_memalign ring");
        goto cleanup;
    }
    memset(ring_memory, 0, (size_t)(options.ring_size + COMMIT_BYTES));
    commit = (struct rdma_ring_commit *)(ring_memory + options.ring_size);
    if ((uintptr_t)ring_memory >= (1ULL << 48) ||
        (uintptr_t)commit + COMMIT_BYTES > (1ULL << 48)) {
        fprintf(stderr, "the allocated MR is outside the FPGA 48-bit remote-address range\n");
        goto cleanup;
    }

    context = open_device(options.device_name);
    if (context == NULL) goto cleanup;
    if (select_rocev2_gid(context, options.port_num, &netdev, &gid_index, &host_gid) != 0) {
        goto cleanup;
    }
    fpga_gid = ipv4_mapped_gid(&fpga_ipv4);
    pd = ibv_alloc_pd(context);
    if (pd == NULL) {
        perror("ibv_alloc_pd");
        goto cleanup;
    }
    mr = ibv_reg_mr(pd, ring_memory, (size_t)(options.ring_size + COMMIT_BYTES),
                    IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE);
    if (mr == NULL) {
        perror("ibv_reg_mr");
        goto cleanup;
    }
    cq = ibv_create_cq(context, (int)options.recv_depth + 16, NULL, NULL, 0);
    if (cq == NULL) {
        perror("ibv_create_cq");
        goto cleanup;
    }
    {
        struct ibv_qp_init_attr init_attr;
        memset(&init_attr, 0, sizeof(init_attr));
        init_attr.send_cq = cq;
        init_attr.recv_cq = cq;
        init_attr.qp_type = IBV_QPT_RC;
        init_attr.cap.max_send_wr = 1;
        init_attr.cap.max_recv_wr = options.enable_immediate ? options.recv_depth : 1;
        init_attr.cap.max_send_sge = 1;
        init_attr.cap.max_recv_sge = 1;
        qp = ibv_create_qp(pd, &init_attr);
    }
    if (qp == NULL) {
        perror("ibv_create_qp");
        goto cleanup;
    }
    if (options.enable_immediate) {
        for (uint32_t index = 0; index < options.recv_depth; ++index) {
            if (post_receive(qp, mr, commit, index) != 0) goto cleanup;
        }
    }
    if (modify_qp_to_rts(qp, &options, gid_index, &fpga_gid) != 0) goto cleanup;

    print_vio_json(&options, &netdev, qp, mr, &host_gid, gid_index, ring_memory, commit);
    fflush(stdout);
    fprintf(stderr,
            "QP is RTS. Apply the emitted VIO fields while FPGA is drained, then assert start. "
             "Stop FPGA and wait for drained before terminating this tool.\n");
    if (options.allow_ring_wrap) {
        fprintf(stderr,
                "WARNING: ring wrap is enabled without a consumer-credit protocol; use only for controlled diagnostics.\n");
    }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    started = time(NULL);

    {
        bool duration_elapsed = false;
        bool shutdown_requested = false;

    while (true) {
        struct ibv_wc completions[16];
        int count;

        if (stop_requested && !shutdown_requested) {
            shutdown_requested = true;
            fprintf(stderr,
                    "termination requested; waiting for FPGA final commit before releasing the QP/MR\n");
        }
        if (options.run_seconds != 0 && !duration_elapsed &&
            (unsigned int)(time(NULL) - started) >= options.run_seconds) {
            duration_elapsed = true;
            fprintf(stderr,
                    "requested duration elapsed; waiting for FPGA final commit before releasing the QP/MR\n");
        }
        while ((count = ibv_poll_cq(cq, 16, completions)) > 0) {
            for (int index = 0; index < count; ++index) {
                struct ibv_wc *completion = &completions[index];

                if (completion->status != IBV_WC_SUCCESS) {
                    fprintf(stderr, "CQ error: status=%s opcode=%d wr_id=%" PRIu64 "\n",
                            ibv_wc_status_str(completion->status), completion->opcode,
                            completion->wr_id);
                    goto cleanup;
                }
                if (completion->opcode != IBV_WC_RECV_RDMA_WITH_IMM) {
                    fprintf(stderr, "unexpected receive completion opcode %d\n", completion->opcode);
                    goto cleanup;
                }
                printf("immediate sequence low32=%" PRIu32 "\n", ntohl(completion->imm_data));
                if (post_receive(qp, mr, commit, completion->wr_id) != 0) goto cleanup;
            }
        }
        if (count < 0) {
            fprintf(stderr, "ibv_poll_cq failed\n");
            goto cleanup;
        }
        {
            struct pollfd async_fd = {.fd = context->async_fd, .events = POLLIN};
            if (poll(&async_fd, 1, 0) > 0 && (async_fd.revents & POLLIN) != 0) {
                struct ibv_async_event event;
                if (ibv_get_async_event(context, &event) == 0) {
                    fprintf(stderr, "RDMA async event: %s\n", ibv_event_type_str(event.event_type));
                    ibv_ack_async_event(&event);
                }
            }
        }
        {
            struct commit_snapshot snapshot;
            if (read_commit(commit, &snapshot) && snapshot.sequence != last_commit.sequence) {
                if ((!snapshot.final && snapshot.interval_bytes != options.notify_interval) ||
                    (snapshot.final && (snapshot.interval_bytes == 0 ||
                                        snapshot.interval_bytes > options.notify_interval))) {
                    fprintf(stderr,
                            "commit interval is invalid: FPGA=%" PRIu32 " host-configured=%" PRIu64
                            " final=%u\n",
                            snapshot.interval_bytes, options.notify_interval,
                            snapshot.final ? 1U : 0U);
                    goto cleanup;
                }
                last_commit = snapshot;
                printf("commit sequence=%" PRIu64 " published=%" PRIu64
                       " end=%" PRIu32 " interval=%" PRIu32 " final=%u\n",
                       snapshot.sequence, snapshot.published_bytes, snapshot.ring_end_offset,
                       snapshot.interval_bytes, snapshot.final ? 1U : 0U);
            }
        }
        if (last_commit.final) {
            break;
        }
        usleep(1000);
    }
    }
    if (!last_commit.final) {
        fprintf(stderr,
                "no FPGA final commit was observed; refusing a successful teardown while the ring may still be active\n");
        goto cleanup;
    }
    if (options.verify_on_exit) {
        if (last_commit.sequence == 0 ||
            verify_ring(ring_memory, &last_commit, options.ring_size, options.local_base) != 0) {
            goto cleanup;
        }
    }
    exit_status = EXIT_SUCCESS;

cleanup:
    if (qp != NULL) ibv_destroy_qp(qp);
    if (cq != NULL) ibv_destroy_cq(cq);
    if (mr != NULL) ibv_dereg_mr(mr);
    if (pd != NULL) ibv_dealloc_pd(pd);
    if (context != NULL) ibv_close_device(context);
    free(ring_memory);
    return exit_status;
}
