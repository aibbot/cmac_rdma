`timescale 1ps / 1ps

package cmac_usplus_0_rdma_endpoint_pkg;
  localparam logic [7:0] RDMA_RC_ACK = 8'h11;
  localparam logic [15:0] RDMA_ROCE_UDP_PORT = 16'd4791;
  localparam logic [31:0] RDMA_ICRC_INIT = 32'hDEBB_20E3;

  typedef struct packed {
    logic [47:0] remote_mac;
    logic [31:0] local_ip;
    logic [31:0] remote_ip;
    logic [23:0] remote_qpn;
    logic [23:0] initial_psn;
    logic [47:0] remote_base;
    logic [31:0] rkey;
    logic [31:0] ring_size;
    logic [31:0] wr_size;
    logic [63:0] local_base;
    logic enable_immediate;
    logic [31:0] notify_interval_bytes;
    logic [47:0] commit_remote_addr;
    logic use_external_payload;
  } rdma_endpoint_config_t;

  typedef enum logic [3:0] {
    RDMA_PACKET_DEST_MAC,
    RDMA_PACKET_SOURCE_MAC,
    RDMA_PACKET_ETHERTYPE,
    RDMA_PACKET_IPV4,
    RDMA_PACKET_UDP,
    RDMA_PACKET_BTH,
    RDMA_PACKET_RETH,
    RDMA_PACKET_IMMEDIATE,
    RDMA_PACKET_PAYLOAD,
    RDMA_PACKET_ICRC
  } rdma_packet_region_t;

  typedef struct packed {
    logic [47:0] remote_mac;
    logic [31:0] local_ip;
    logic [31:0] remote_ip;
    logic [13:0] local_qpn;
    logic [23:0] remote_qpn;
    logic [31:0] rkey;
    logic        is_commit;
    logic [7:0]  opcode;
    logic        has_reth;
    logic        has_immediate;
    logic [31:0] payload_length;
    logic [31:0] work_length;
    logic [63:0] local_address;
    logic [47:0] remote_address;
    logic [23:0] psn;
    logic [31:0] benchmark_sequence;
    logic [63:0] commit_total_bytes;
    logic [31:0] commit_end_offset;
    logic [31:0] commit_interval_bytes;
    logic [63:0] commit_sequence;
    logic        commit_final;
    logic [15:0] ip_identification;
    logic [15:0] ip_checksum;
    logic [15:0] udp_length;
    logic [15:0] ip_total_length;
  } rdma_packet_context_t;

  typedef struct packed {
    logic        valid;
    logic [23:0] psn;
    logic [31:0] ring_offset;
    logic [63:0] local_address;
    logic [31:0] data_sequence;
    logic [31:0] interval_bytes;
    logic [31:0] logical_remaining;
    logic [31:0] work_length;
  } rdma_recovery_checkpoint_t;

  typedef struct packed {
    logic [23:0] psn;
    logic [23:0] packet_index;
    logic [31:0] byte_offset;
    logic [31:0] replay_bytes;
  } rdma_recovery_action_t;
endpackage
