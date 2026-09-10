`timescale 1ps / 1ps

// Single-QP RoCEv2 RC RDMA WRITE bring-up endpoint.
//
// The endpoint deliberately owns the wire-format boundary rather than relying
// on the admitted HLS core. It uses a deterministic local-data generator so a
// retransmission is byte-for-byte identical to the original packet. The
// packet scheduler permits one unacknowledged packet at a time; this keeps the
// first-board-debug state machine observable and makes error recovery
// deterministic. It is not the final multi-outstanding line-rate scheduler.
module cmac_usplus_0_rdma_endpoint #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
  parameter integer ACK_TIMEOUT_CYCLES = 250_000,
  parameter integer MAX_RETRIES = 12,
  parameter integer RNR_TIMER_10US_CYCLES = 2_500
) (
  input  logic          clk,
  input  logic          reset,
  input  logic [31:0]   local_ip,

  input  logic          learned_remote_valid,
  input  logic [47:0]   learned_remote_mac,
  input  logic [31:0]   learned_remote_ip,
  input  logic [31:0]   rx_overflow_source_count,

  input  logic          cfg_apply,
  input  logic          cfg_start,
  input  logic          cfg_stop,
  input  logic          cfg_clear_stats,
  input  logic          cfg_force_remote_mac,
  input  logic [47:0]   cfg_remote_mac,
  input  logic [31:0]   cfg_remote_ip,
  input  logic [23:0]   cfg_local_qpn,
  input  logic [23:0]   cfg_remote_qpn,
  input  logic [23:0]   cfg_local_psn,
  input  logic [23:0]   cfg_remote_psn,
  input  logic [47:0]   cfg_remote_base,
  input  logic [31:0]   cfg_rkey,
  input  logic [31:0]   cfg_ring_size,
  input  logic [31:0]   cfg_wr_size,
  input  logic [63:0]   cfg_local_base,
  input  logic          cfg_enable_immediate,
  input  logic [31:0]   cfg_notify_interval_bytes,
  input  logic [47:0]   cfg_commit_remote_addr,
  input  logic          cfg_allow_ring_wrap,

  input  logic          rx_axis_tvalid,
  output logic          rx_axis_tready,
  input  logic [511:0] rx_axis_tdata,
  input  logic [63:0]  rx_axis_tkeep,
  input  logic          rx_axis_tlast,
  input  logic          rx_axis_tuser,

  input  logic          tx_axis_tready,
  output logic          tx_axis_tvalid,
  output logic [511:0] tx_axis_tdata,
  output logic [63:0]  tx_axis_tkeep,
  output logic          tx_axis_tlast,
  output logic          tx_axis_tuser,

  output logic          configured,
  output logic          active,
  output logic          drained,
  output logic          fault,
  output logic [31:0]   config_reject_count,
  output logic [31:0]   icrc_drop_count,
  output logic [31:0]   invalid_psn_count,
  output logic [31:0]   nak_count,
  output logic [31:0]   retrans_count,
  output logic [31:0]   retry_exhausted_count,
  output logic [31:0]   rx_overflow_count,
  output logic [31:0]   tx_underflow_count,
  output logic [63:0]   issued_bytes,
  output logic [63:0]   acked_bytes,
  output logic [31:0]   ring_offset,
  output logic [23:0]   current_psn,
  output logic [3:0]    debug_state,
  output logic [31:0]   commit_count,
  output logic [31:0]   immediate_count,
  output logic [63:0]   published_bytes,
  output logic [63:0]   producer_sequence
);

  localparam logic [7:0] RC_RDMA_WRITE_FIRST  = 8'h06;
  localparam logic [7:0] RC_RDMA_WRITE_MIDDLE = 8'h07;
  localparam logic [7:0] RC_RDMA_WRITE_LAST   = 8'h08;
  localparam logic [7:0] RC_RDMA_WRITE_LAST_WITH_IMM = 8'h09;
  localparam logic [7:0] RC_RDMA_WRITE_ONLY   = 8'h0A;
  localparam logic [7:0] RC_RDMA_WRITE_ONLY_WITH_IMM = 8'h0B;
  localparam logic [7:0] RC_ACK               = 8'h11;
  localparam logic [15:0] ROCE_UDP_PORT       = 16'd4791;
  localparam logic [31:0] ICRC_INIT           = 32'hDEBB_20E3;
  localparam logic [31:0] COMMIT_MAGIC        = 32'h5244_4D41;
  localparam logic [31:0] COMMIT_BYTES        = 32'd64;
  localparam integer COMMIT_PUBLISH_SEQUENCE_OFFSET = 40;
  localparam integer MAX_PACKET_BEATS        = 66;
  localparam integer TX_PACKET_BUFFER_DEPTH  = 128;
  localparam integer TX_PACKET_BUFFER_WIDTH  = 577;

  typedef enum logic [3:0] {
    TX_IDLE,
    TX_SELECT,
    TX_SELECT_LENGTH,
    TX_PREPARE,
    TX_CRC,
    TX_SEND,
    TX_WAIT_ACK,
    TX_RNR_WAIT,
    TX_BUILD,
    TX_LOAD,
    TX_LOAD_WAIT,
    TX_BUILD_COMMIT,
    TX_CHECKSUM,
    TX_CRC_UPDATE,
    TX_BUILD_DECODE,
    TX_BUILD_STORE
  } tx_state_t;

  typedef enum logic [2:0] {
    RX_IDLE,
    RX_CRC,
    RX_VERIFY,
    RX_DROP,
    RX_REPORT
  } rx_state_t;

  tx_state_t tx_state;
  rx_state_t rx_state;

  logic apply_q;
  logic start_q;
  logic stop_q;
  logic clear_stats_q;
  logic apply_pulse;
  logic start_pulse;
  logic stop_pulse;
  logic clear_stats_pulse;

  logic        cfg_validate_pending;
  logic        cfg_apply_pending;
  logic        cfg_validation_accept;
  logic        cfg_identity_valid;
  logic        cfg_sizes_valid;
  logic        cfg_commit_valid;
  logic [48:0] cfg_snapshot_remote_end;
  logic [48:0] cfg_snapshot_commit_end;
  logic [47:0] cfg_snapshot_remote_mac;
  logic [31:0] cfg_snapshot_local_ip;
  logic [31:0] cfg_snapshot_remote_ip;
  logic [23:0] cfg_snapshot_local_qpn;
  logic [23:0] cfg_snapshot_remote_qpn;
  logic [23:0] cfg_snapshot_local_psn;
  logic [47:0] cfg_snapshot_remote_base;
  logic [31:0] cfg_snapshot_rkey;
  logic [31:0] cfg_snapshot_ring_size;
  logic [31:0] cfg_snapshot_wr_size;
  logic [63:0] cfg_snapshot_local_base;
  logic        cfg_snapshot_enable_immediate;
  logic [31:0] cfg_snapshot_notify_interval_bytes;
  logic [47:0] cfg_snapshot_commit_remote_addr;
  logic        cfg_snapshot_allow_ring_wrap;

  logic run_enable;
  logic stop_requested;
  logic inflight_valid;
  logic inflight_issued_accounted;
  logic [3:0] retry_count;
  logic [31:0] timeout_count;
  logic [31:0] rnr_wait_cycles;
  logic response_pending;
  logic [23:0] response_pending_psn;
  logic [7:0] response_pending_syndrome;

  logic [47:0] session_remote_mac;
  logic [31:0] session_local_ip;
  logic [31:0] session_remote_ip;
  logic [23:0] session_local_qpn;
  logic [23:0] session_remote_qpn;
  logic [23:0] session_remote_psn;
  logic [47:0] session_remote_base;
  logic [31:0] session_rkey;
  logic [31:0] session_ring_size;
  logic [31:0] session_wr_size;
  logic [63:0] session_local_base;
  logic        session_enable_immediate;
  logic [31:0] session_notify_interval_bytes;
  logic [47:0] session_commit_remote_addr;
  logic        session_allow_ring_wrap;

  logic [63:0] local_byte_address;
  logic        logical_wr_active;
  logic [31:0] logical_wr_remaining;
  logic [31:0] physical_message_remaining;
  logic [31:0] bytes_since_commit;
  logic        pending_commit;
  logic [63:0] pending_commit_total_bytes;
  logic [31:0] pending_commit_end_offset;
  logic [31:0] pending_commit_interval_bytes;
  logic [63:0] pending_commit_sequence;
  logic        pending_commit_final;
  logic [15:0] next_ip_identification;

  logic        inflight_is_commit;
  logic [7:0]  inflight_opcode;
  logic        inflight_has_reth;
  logic        inflight_has_immediate;
  logic [31:0] inflight_payload_length;
  logic [31:0] inflight_work_length;
  logic [31:0] inflight_remaining_after;
  logic [63:0] inflight_laddr;
  logic [47:0] inflight_remote_address;
  logic [23:0] inflight_psn;
  logic [63:0] inflight_commit_total_bytes;
  logic [31:0] inflight_commit_end_offset;
  logic [31:0] inflight_commit_interval_bytes;
  logic [63:0] inflight_commit_sequence;
  logic        inflight_commit_final;
  logic [15:0] inflight_ip_identification;
  logic [15:0] inflight_ip_checksum;
  logic [31:0] packet_icrc;
  logic [31:0] crc_state;
  logic [15:0] crc_offset;

  (* KEEP = "TRUE" *) logic        select_has_reth;
  (* KEEP = "TRUE" *) logic [31:0] select_logical_remaining;
  (* KEEP = "TRUE" *) logic [31:0] select_physical_remaining;
  (* KEEP = "TRUE" *) logic [31:0] select_ring_remaining;
  (* KEEP = "TRUE" *) logic [31:0] select_notification_remaining;
  (* KEEP = "TRUE" *) logic [63:0] select_laddr;
  (* KEEP = "TRUE" *) logic [47:0] select_remote_address;
  (* KEEP = "TRUE" *) logic [31:0] select_work_length;

  // The packet is built once, then replayed during ACK/NAK retries. Keep the
  // storage as one ordinary single-write/synchronous-read RAM so Vivado can
  // map it to block RAM instead of expanding 66 variable-indexed registers.
  (* ram_style = "block" *) logic [TX_PACKET_BUFFER_WIDTH-1:0]
    tx_packet_buffer [0:TX_PACKET_BUFFER_DEPTH-1];
  logic [6:0] tx_packet_read_address;
  logic [TX_PACKET_BUFFER_WIDTH-1:0] tx_packet_read_data;
  logic tx_packet_read_enable;
  logic [6:0] tx_build_beat;
  logic [6:0] tx_build_byte_index;
  logic [6:0] tx_build_valid_bytes;
  logic [15:0] tx_build_byte_offset;
  logic [7:0] tx_build_byte;
  logic [3:0] tx_build_region;
  logic [15:0] tx_build_region_offset;
  logic [511:0] tx_build_word;
  logic [63:0] tx_build_keep;
  logic [6:0] tx_packet_last_beat;
  logic [6:0] tx_packet_last_valid_bytes;
  logic [63:0] tx_packet_last_keep;
  logic [6:0] tx_send_beat;
  logic [511:0] tx_send_word;
  logic [63:0] tx_send_keep;
  logic tx_send_last;

  logic [511:0] rx_frame_data;
  logic [15:0]  rx_crc_index;
  logic [31:0]  rx_crc_state;
  logic [31:0]  rx_crc_final;
  logic [31:0]  rx_received_icrc;
  logic         rx_ack_header_valid;
  logic         rx_ack_pulse;
  logic [23:0]  rx_ack_psn;
  logic         rx_ack_psn_matches;
  logic         rx_ack_is_nak;
  logic [7:0]   rx_ack_syndrome;
  logic         rx_icrc_drop_pulse;
  logic         rx_invalid_packet_pulse;

  logic [15:0] inflight_udp_length;
  logic [15:0] inflight_ip_total_length;
  logic [15:0] inflight_icrc_data_bytes;
  logic [31:0] rx_overflow_source_seen;
  logic [31:0] rx_overflow_delta;
  logic [15:0] inflight_packet_bytes;
  logic [17:0] ip_checksum_sum_a;
  logic [17:0] ip_checksum_sum_b;
  logic [17:0] ip_checksum_sum_c;
  logic [7:0] tx_crc_byte;

  localparam logic [63:0] RX_ACK_KEEP = 64'h3FFF_FFFF_FFFF_FFFF;
  localparam logic [15:0] RX_ACK_ICRC_DATA_BYTES = 16'd44;

  localparam logic [3:0] TX_BYTE_DEST_MAC  = 4'd0;
  localparam logic [3:0] TX_BYTE_SOURCE_MAC = 4'd1;
  localparam logic [3:0] TX_BYTE_ETHERTYPE = 4'd2;
  localparam logic [3:0] TX_BYTE_IPV4      = 4'd3;
  localparam logic [3:0] TX_BYTE_UDP       = 4'd4;
  localparam logic [3:0] TX_BYTE_BTH       = 4'd5;
  localparam logic [3:0] TX_BYTE_RETH      = 4'd6;
  localparam logic [3:0] TX_BYTE_IMMEDIATE = 4'd7;
  localparam logic [3:0] TX_BYTE_PAYLOAD   = 4'd8;
  localparam logic [3:0] TX_BYTE_ICRC      = 4'd9;
  assign active = run_enable;
  assign drained = !run_enable && !stop_requested && !logical_wr_active && !pending_commit &&
                   !inflight_valid && (tx_state == TX_IDLE);
  assign debug_state = tx_state;
  assign current_psn = inflight_valid ? inflight_psn : session_remote_psn;
  assign rx_overflow_delta = rx_overflow_source_count - rx_overflow_source_seen;

  function automatic logic [31:0] sat_inc32(input logic [31:0] value);
    begin
      sat_inc32 = (&value) ? value : value + 32'd1;
    end
  endfunction

  function automatic logic [31:0] sat_add32(
    input logic [31:0] value,
    input logic [31:0] addend
  );
    logic [32:0] sum;
    begin
      sum = {1'b0, value} + {1'b0, addend};
      sat_add32 = sum[32] ? 32'hFFFF_FFFF : sum[31:0];
    end
  endfunction

  function automatic logic [63:0] sat_add64(
    input logic [63:0] value,
    input logic [31:0] addend
  );
    logic [64:0] sum;
    begin
      sum = {1'b0, value} + {33'd0, addend};
      sat_add64 = sum[64] ? 64'hFFFF_FFFF_FFFF_FFFF : sum[63:0];
    end
  endfunction

  function automatic logic [63:0] sat_inc64(input logic [63:0] value);
    begin
      sat_inc64 = (&value) ? value : value + 64'd1;
    end
  endfunction

  function automatic logic [7:0] get_byte(
    input logic [511:0] data,
    input integer index
  );
    begin
      get_byte = data[index * 8 +: 8];
    end
  endfunction

  function automatic logic [15:0] get_be16(
    input logic [511:0] data,
    input integer index
  );
    begin
      get_be16 = {get_byte(data, index), get_byte(data, index + 1)};
    end
  endfunction

  function automatic logic [23:0] get_be24(
    input logic [511:0] data,
    input integer index
  );
    begin
      get_be24 = {get_byte(data, index), get_byte(data, index + 1),
                  get_byte(data, index + 2)};
    end
  endfunction

  function automatic logic [31:0] get_be32(
    input logic [511:0] data,
    input integer index
  );
    begin
      get_be32 = {get_byte(data, index), get_byte(data, index + 1),
                  get_byte(data, index + 2), get_byte(data, index + 3)};
    end
  endfunction

  function automatic logic [31:0] get_le32(
    input logic [511:0] data,
    input integer index
  );
    begin
      get_le32 = {get_byte(data, index + 3), get_byte(data, index + 2),
                  get_byte(data, index + 1), get_byte(data, index)};
    end
  endfunction

  // InfiniBand AETH RNR timers are encoded in 10 us units, except code zero
  // which represents 655.36 ms. The scale parameter is 2500 at 250 MHz and
  // can be reduced in simulation without changing the protocol mapping.
  function automatic logic [31:0] rnr_retry_delay_cycles(input logic [4:0] timer_code);
    logic [31:0] timer_10us_units;
    logic [63:0] scaled_cycles;
    begin
      case (timer_code)
        5'd0:  timer_10us_units = 32'd65536;
        5'd1:  timer_10us_units = 32'd1;
        5'd2:  timer_10us_units = 32'd2;
        5'd3:  timer_10us_units = 32'd3;
        5'd4:  timer_10us_units = 32'd4;
        5'd5:  timer_10us_units = 32'd6;
        5'd6:  timer_10us_units = 32'd8;
        5'd7:  timer_10us_units = 32'd12;
        5'd8:  timer_10us_units = 32'd16;
        5'd9:  timer_10us_units = 32'd24;
        5'd10: timer_10us_units = 32'd32;
        5'd11: timer_10us_units = 32'd48;
        5'd12: timer_10us_units = 32'd64;
        5'd13: timer_10us_units = 32'd96;
        5'd14: timer_10us_units = 32'd128;
        5'd15: timer_10us_units = 32'd192;
        5'd16: timer_10us_units = 32'd256;
        5'd17: timer_10us_units = 32'd384;
        5'd18: timer_10us_units = 32'd512;
        5'd19: timer_10us_units = 32'd768;
        5'd20: timer_10us_units = 32'd1024;
        5'd21: timer_10us_units = 32'd1536;
        5'd22: timer_10us_units = 32'd2048;
        5'd23: timer_10us_units = 32'd3072;
        5'd24: timer_10us_units = 32'd4096;
        5'd25: timer_10us_units = 32'd6144;
        5'd26: timer_10us_units = 32'd8192;
        5'd27: timer_10us_units = 32'd12288;
        5'd28: timer_10us_units = 32'd16384;
        5'd29: timer_10us_units = 32'd24576;
        5'd30: timer_10us_units = 32'd32768;
        default: timer_10us_units = 32'd49152;
      endcase
      scaled_cycles = timer_10us_units * RNR_TIMER_10US_CYCLES;
      if (scaled_cycles == 64'd0) begin
        rnr_retry_delay_cycles = 32'd1;
      end else if (|scaled_cycles[63:32]) begin
        rnr_retry_delay_cycles = 32'hFFFF_FFFF;
      end else begin
        rnr_retry_delay_cycles = scaled_cycles[31:0];
      end
    end
  endfunction

  function automatic logic [47:0] get_mac(
    input logic [511:0] data,
    input integer index
  );
    begin
      get_mac = {get_byte(data, index), get_byte(data, index + 1),
                 get_byte(data, index + 2), get_byte(data, index + 3),
                 get_byte(data, index + 4), get_byte(data, index + 5)};
    end
  endfunction

  function automatic logic [31:0] crc32_byte(
    input logic [31:0] seed,
    input logic [7:0] data_byte
  );
    integer bit_index;
    logic [31:0] crc;
    begin
      crc = seed ^ {24'd0, data_byte};
      for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
        crc = crc[0] ? ((crc >> 1) ^ 32'hEDB8_8320) : (crc >> 1);
      end
      crc32_byte = crc;
    end
  endfunction

  function automatic logic [7:0] mac_byte(
    input logic [47:0] mac,
    input integer index
  );
    begin
      case (index)
        0: mac_byte = mac[47:40];
        1: mac_byte = mac[39:32];
        2: mac_byte = mac[31:24];
        3: mac_byte = mac[23:16];
        4: mac_byte = mac[15:8];
        default: mac_byte = mac[7:0];
      endcase
    end
  endfunction

  function automatic logic [7:0] be16_byte(
    input logic [15:0] value,
    input integer index
  );
    begin
      be16_byte = index == 0 ? value[15:8] : value[7:0];
    end
  endfunction

  function automatic logic [7:0] be24_byte(
    input logic [23:0] value,
    input integer index
  );
    begin
      case (index)
        0: be24_byte = value[23:16];
        1: be24_byte = value[15:8];
        default: be24_byte = value[7:0];
      endcase
    end
  endfunction

  function automatic logic [7:0] be32_byte(
    input logic [31:0] value,
    input integer index
  );
    begin
      case (index)
        0: be32_byte = value[31:24];
        1: be32_byte = value[23:16];
        2: be32_byte = value[15:8];
        default: be32_byte = value[7:0];
      endcase
    end
  endfunction

  function automatic logic [7:0] be64_byte(
    input logic [63:0] value,
    input integer index
  );
    begin
      case (index)
        0: be64_byte = value[63:56];
        1: be64_byte = value[55:48];
        2: be64_byte = value[47:40];
        3: be64_byte = value[39:32];
        4: be64_byte = value[31:24];
        5: be64_byte = value[23:16];
        6: be64_byte = value[15:8];
        default: be64_byte = value[7:0];
      endcase
    end
  endfunction

  function automatic logic [7:0] le32_byte(
    input logic [31:0] value,
    input integer index
  );
    begin
      case (index)
        0: le32_byte = value[7:0];
        1: le32_byte = value[15:8];
        2: le32_byte = value[23:16];
        default: le32_byte = value[31:24];
      endcase
    end
  endfunction

  function automatic logic [7:0] le64_byte(
    input logic [63:0] value,
    input integer index
  );
    begin
      case (index)
        0: le64_byte = value[7:0];
        1: le64_byte = value[15:8];
        2: le64_byte = value[23:16];
        3: le64_byte = value[31:24];
        4: le64_byte = value[39:32];
        5: le64_byte = value[47:40];
        6: le64_byte = value[55:48];
        default: le64_byte = value[63:56];
      endcase
    end
  endfunction

  // Each little-endian 64-bit word is the corresponding local word address.
  function automatic logic [7:0] data_payload_byte(input integer payload_offset);
    logic [63:0] byte_address;
    logic [63:0] word_value;
    begin
      byte_address = inflight_laddr + payload_offset;
      word_value = byte_address >> 3;
      case (byte_address[2:0])
        3'd0: data_payload_byte = word_value[7:0];
        3'd1: data_payload_byte = word_value[15:8];
        3'd2: data_payload_byte = word_value[23:16];
        3'd3: data_payload_byte = word_value[31:24];
        3'd4: data_payload_byte = word_value[39:32];
        3'd5: data_payload_byte = word_value[47:40];
        3'd6: data_payload_byte = word_value[55:48];
        default: data_payload_byte = word_value[63:56];
      endcase
    end
  endfunction

  // The producer sequence is deliberately placed after all metadata.  In
  // polling mode Linux reads that trailing release marker, performs an
  // acquire barrier, then reads the preceding fields.  All multi-byte fields
  // are little-endian because the destination is host memory.
  function automatic logic [7:0] commit_payload_byte(input integer payload_offset);
    begin
      if (payload_offset < 8) begin
        commit_payload_byte = le64_byte(inflight_commit_total_bytes, payload_offset);
      end else if (payload_offset < 12) begin
        commit_payload_byte = le32_byte(inflight_commit_end_offset, payload_offset - 8);
      end else if (payload_offset < 16) begin
        commit_payload_byte = le32_byte(inflight_commit_interval_bytes, payload_offset - 12);
      end else if (payload_offset < 20) begin
        commit_payload_byte = le32_byte({31'd0, inflight_commit_final}, payload_offset - 16);
      end else if (payload_offset < 24) begin
        commit_payload_byte = le32_byte(COMMIT_MAGIC, payload_offset - 20);
      end else if ((payload_offset >= COMMIT_PUBLISH_SEQUENCE_OFFSET) &&
                   (payload_offset < (COMMIT_PUBLISH_SEQUENCE_OFFSET + 8))) begin
        commit_payload_byte = le64_byte(inflight_commit_sequence,
                                        payload_offset - COMMIT_PUBLISH_SEQUENCE_OFFSET);
      end else begin
        commit_payload_byte = 8'd0;
      end
    end
  endfunction

  function automatic logic [7:0] payload_byte(input integer payload_offset);
    begin
      payload_byte = inflight_is_commit ? commit_payload_byte(payload_offset) :
                     data_payload_byte(payload_offset);
    end
  endfunction

  function automatic logic [7:0] ipv4_byte(input integer index);
    begin
      case (index)
        0: ipv4_byte = 8'h45;
        1: ipv4_byte = 8'h00;
        2: ipv4_byte = inflight_ip_total_length[15:8];
        3: ipv4_byte = inflight_ip_total_length[7:0];
        4: ipv4_byte = inflight_ip_identification[15:8];
        5: ipv4_byte = inflight_ip_identification[7:0];
        6: ipv4_byte = 8'h40;
        7: ipv4_byte = 8'h00;
        8: ipv4_byte = 8'd64;
        9: ipv4_byte = 8'd17;
        10: ipv4_byte = inflight_ip_checksum[15:8];
        11: ipv4_byte = inflight_ip_checksum[7:0];
        12: ipv4_byte = session_local_ip[31:24];
        13: ipv4_byte = session_local_ip[23:16];
        14: ipv4_byte = session_local_ip[15:8];
        15: ipv4_byte = session_local_ip[7:0];
        16: ipv4_byte = session_remote_ip[31:24];
        17: ipv4_byte = session_remote_ip[23:16];
        18: ipv4_byte = session_remote_ip[15:8];
        default: ipv4_byte = session_remote_ip[7:0];
      endcase
    end
  endfunction

  function automatic logic [7:0] udp_byte(input integer index);
    logic [15:0] source_port;
    begin
      source_port = 16'hC000 | {2'b00, session_local_qpn[13:0]};
      case (index)
        0: udp_byte = source_port[15:8];
        1: udp_byte = source_port[7:0];
        2: udp_byte = ROCE_UDP_PORT[15:8];
        3: udp_byte = ROCE_UDP_PORT[7:0];
        4: udp_byte = inflight_udp_length[15:8];
        5: udp_byte = inflight_udp_length[7:0];
        6: udp_byte = 8'h00;
        default: udp_byte = 8'h00;
      endcase
    end
  endfunction

  function automatic logic [7:0] bth_byte(input integer index);
    begin
      case (index)
        0: bth_byte = inflight_opcode;
        1: bth_byte = 8'h00;
        2: bth_byte = 8'hFF;
        3: bth_byte = 8'hFF;
        4: bth_byte = 8'h00;
        5: bth_byte = session_remote_qpn[23:16];
        6: bth_byte = session_remote_qpn[15:8];
        7: bth_byte = session_remote_qpn[7:0];
        8: bth_byte = 8'h80;
        9: bth_byte = inflight_psn[23:16];
        10: bth_byte = inflight_psn[15:8];
        default: bth_byte = inflight_psn[7:0];
      endcase
    end
  endfunction

  function automatic logic [7:0] reth_byte(input integer index);
    logic [63:0] address64;
    begin
      address64 = {16'd0, inflight_remote_address};
      if (index < 8) begin
        reth_byte = be64_byte(address64, index);
      end else if (index < 12) begin
        reth_byte = be32_byte(session_rkey, index - 8);
      end else begin
        reth_byte = be32_byte(inflight_work_length, index - 12);
      end
    end
  endfunction

  function automatic logic [7:0] immediate_byte(input integer index);
    begin
      immediate_byte = be32_byte(inflight_commit_sequence[31:0], index);
    end
  endfunction

  // Byte offset is from the IPv4 header and excludes the ICRC itself.
  function automatic logic [7:0] icrc_actual_byte(input integer index);
    integer payload_start;
    integer immediate_start;
    begin
      immediate_start = 20 + 8 + 12 + (inflight_has_reth ? 16 : 0);
      payload_start = immediate_start + (inflight_has_immediate ? 4 : 0);
      if (index < 20) begin
        icrc_actual_byte = ipv4_byte(index);
      end else if (index < 28) begin
        icrc_actual_byte = udp_byte(index - 20);
      end else if (index < 40) begin
        icrc_actual_byte = bth_byte(index - 28);
      end else if (inflight_has_reth && (index < 56)) begin
        icrc_actual_byte = reth_byte(index - 40);
      end else if (inflight_has_immediate && (index < (immediate_start + 4))) begin
        icrc_actual_byte = immediate_byte(index - immediate_start);
      end else begin
        icrc_actual_byte = payload_byte(index - payload_start);
      end
    end
  endfunction

  // ICRC uses the IPv4/UDP pseudo-header substitutions defined for RoCEv2.
  function automatic logic [7:0] icrc_masked_byte(input integer index);
    begin
      case (index)
        1, 8, 10, 11, 26, 27, 32: icrc_masked_byte = 8'hFF;
        default: icrc_masked_byte = icrc_actual_byte(index);
      endcase
    end
  endfunction

  function automatic logic [63:0] packet_keep_mask(input logic [6:0] byte_count);
    begin
      if (byte_count >= 7'd64) begin
        packet_keep_mask = 64'hFFFF_FFFF_FFFF_FFFF;
      end else if (byte_count == 7'd0) begin
        packet_keep_mask = 64'd0;
      end else begin
        packet_keep_mask = (64'h1 << byte_count) - 64'd1;
      end
    end
  endfunction

  function automatic logic [7:0] rx_icrc_byte(input integer index);
    logic [7:0] value;
    begin
      value = get_byte(rx_frame_data, 14 + index);
      case (index)
        1, 8, 10, 11, 26, 27, 32: rx_icrc_byte = 8'hFF;
        default: rx_icrc_byte = value;
      endcase
    end
  endfunction

  function automatic logic valid_rx_ack_header;
    logic [15:0] source_port;
    logic [15:0] udp_length;
    begin
      source_port = get_be16(rx_frame_data, 34);
      udp_length = get_be16(rx_frame_data, 38);
      valid_rx_ack_header = (get_mac(rx_frame_data, 0) == LOCAL_MAC) &&
                            (get_mac(rx_frame_data, 6) == session_remote_mac) &&
                            (get_be16(rx_frame_data, 12) == 16'h0800) &&
                            (get_byte(rx_frame_data, 14) == 8'h45) &&
                            ((get_be16(rx_frame_data, 20) & 16'h3FFF) == 16'd0) &&
                            (get_byte(rx_frame_data, 23) == 8'd17) &&
                            (get_be32(rx_frame_data, 26) == session_remote_ip) &&
                            (get_be32(rx_frame_data, 30) == session_local_ip) &&
                            (source_port == ROCE_UDP_PORT) &&
                            (udp_length == 16'd28) &&
                            (get_byte(rx_frame_data, 42) == RC_ACK) &&
                            (get_be24(rx_frame_data, 47) == session_local_qpn);
    end
  endfunction

  assign tx_axis_tvalid = (tx_state == TX_SEND);
  assign tx_axis_tdata = tx_send_word;
  assign tx_axis_tkeep = tx_send_keep;
  assign tx_axis_tlast = tx_send_last;
  assign tx_axis_tuser = 1'b0;

  assign rx_axis_tready = (rx_state == RX_IDLE) || (rx_state == RX_DROP);
  assign tx_packet_read_enable = (tx_state == TX_LOAD);

  // Synchronous read port for the replay buffer. TX_LOAD is deliberately a
  // one-cycle request state; TX_LOAD_WAIT consumes the registered result.
  always_ff @(posedge clk) begin
    if (reset) begin
      tx_packet_read_data <= '0;
    end else if (tx_packet_read_enable) begin
      tx_packet_read_data <= tx_packet_buffer[tx_packet_read_address];
    end
  end

  // RX accepts only complete, untagged IPv4 RoCE ACK packets. A packet is
  // buffered before ICRC validation so no malformed packet affects QP state.
  always_ff @(posedge clk) begin
    if (reset) begin
      rx_state <= RX_IDLE;
      rx_frame_data <= 512'd0;
      rx_crc_index <= 16'd0;
      rx_crc_state <= ICRC_INIT;
      rx_crc_final <= 32'd0;
      rx_received_icrc <= 32'd0;
      rx_ack_header_valid <= 1'b0;
      rx_ack_pulse <= 1'b0;
      rx_ack_psn <= 24'd0;
      rx_ack_psn_matches <= 1'b0;
      rx_ack_is_nak <= 1'b0;
      rx_ack_syndrome <= 8'd0;
      rx_icrc_drop_pulse <= 1'b0;
      rx_invalid_packet_pulse <= 1'b0;
    end else begin
      rx_ack_pulse <= 1'b0;
      rx_icrc_drop_pulse <= 1'b0;
      rx_invalid_packet_pulse <= 1'b0;
      case (rx_state)
        RX_IDLE: begin
          if (rx_axis_tvalid && rx_axis_tready) begin
            rx_frame_data <= rx_axis_tdata;
            if (!rx_axis_tlast) begin
              rx_state <= RX_DROP;
            end else if (rx_axis_tuser || (rx_axis_tkeep != RX_ACK_KEEP)) begin
              rx_invalid_packet_pulse <= 1'b1;
            end else begin
              rx_received_icrc <= get_le32(rx_axis_tdata, 58);
              rx_crc_state <= ICRC_INIT;
              rx_crc_index <= 16'd0;
              rx_state <= RX_CRC;
            end
          end
        end

        RX_CRC: begin
          if (rx_crc_index + 16'd1 >= RX_ACK_ICRC_DATA_BYTES) begin
            rx_crc_final <= ~crc32_byte(rx_crc_state, rx_icrc_byte(rx_crc_index));
            rx_state <= RX_VERIFY;
          end else begin
            rx_crc_state <= crc32_byte(rx_crc_state, rx_icrc_byte(rx_crc_index));
            rx_crc_index <= rx_crc_index + 16'd1;
          end
        end

        RX_VERIFY: begin
          rx_ack_header_valid <= valid_rx_ack_header();
          rx_ack_psn <= get_be24(rx_frame_data, 51);
          rx_ack_psn_matches <= (get_be24(rx_frame_data, 51) == inflight_psn);
          rx_ack_is_nak <= ((get_byte(rx_frame_data, 54) & 8'hE0) != 8'h00);
          rx_ack_syndrome <= get_byte(rx_frame_data, 54);
          rx_state <= RX_REPORT;
        end

        RX_REPORT: begin
          if (rx_received_icrc != rx_crc_final) begin
            rx_icrc_drop_pulse <= 1'b1;
          end else if (rx_ack_header_valid) begin
            rx_ack_pulse <= 1'b1;
          end else begin
            rx_invalid_packet_pulse <= 1'b1;
          end
          rx_state <= RX_IDLE;
        end

        RX_DROP: begin
          if (rx_axis_tvalid && rx_axis_tready && rx_axis_tlast) begin
            rx_state <= RX_IDLE;
          end
        end

        default: rx_state <= RX_IDLE;
      endcase
    end
  end

  always_comb begin
    apply_pulse = cfg_apply && !apply_q;
    start_pulse = cfg_start && !start_q;
    stop_pulse = cfg_stop && !stop_q;
    clear_stats_pulse = cfg_clear_stats && !clear_stats_q;
  end

  // The scheduler keeps a logical WR separate from each contiguous physical
  // RDMA message. A physical message ends at a ring or notification boundary
  // so its next segment always starts with a fresh RETH.
  always_ff @(posedge clk) begin
    logic [31:0] selected_work_length;
    logic [31:0] selected_payload_length;
    logic [31:0] selected_logical_remaining;
    logic [31:0] ring_remaining;
    logic [31:0] notification_remaining;
    logic [31:0] completed_interval_bytes;
    logic [31:0] post_ack_ring_offset;
    logic [31:0] post_ack_logical_remaining;
    logic selected_has_reth;
    logic [7:0] selected_opcode;
    logic data_message_done;
    logic final_logical_packet;
    logic notification_due;
    logic stopping;
    logic ring_wrap_stop;

    if (reset) begin
      tx_state <= TX_IDLE;
      apply_q <= 1'b0;
      start_q <= 1'b0;
      stop_q <= 1'b0;
      clear_stats_q <= 1'b0;
      cfg_validate_pending <= 1'b0;
      cfg_apply_pending <= 1'b0;
      cfg_validation_accept <= 1'b0;
      cfg_identity_valid <= 1'b0;
      cfg_sizes_valid <= 1'b0;
      cfg_commit_valid <= 1'b0;
      cfg_snapshot_remote_end <= 49'd0;
      cfg_snapshot_commit_end <= 49'd0;
      cfg_snapshot_remote_mac <= 48'd0;
      cfg_snapshot_local_ip <= 32'd0;
      cfg_snapshot_remote_ip <= 32'd0;
      cfg_snapshot_local_qpn <= 24'd0;
      cfg_snapshot_remote_qpn <= 24'd0;
      cfg_snapshot_local_psn <= 24'd0;
      cfg_snapshot_remote_base <= 48'd0;
      cfg_snapshot_rkey <= 32'd0;
      cfg_snapshot_ring_size <= 32'd0;
      cfg_snapshot_wr_size <= 32'd0;
      cfg_snapshot_local_base <= 64'd0;
      cfg_snapshot_enable_immediate <= 1'b0;
      cfg_snapshot_notify_interval_bytes <= 32'd0;
      cfg_snapshot_commit_remote_addr <= 48'd0;
      cfg_snapshot_allow_ring_wrap <= 1'b0;
      run_enable <= 1'b0;
      stop_requested <= 1'b0;
      inflight_valid <= 1'b0;
      inflight_issued_accounted <= 1'b0;
      retry_count <= 4'd0;
      timeout_count <= 32'd0;
      rnr_wait_cycles <= 32'd1;
      response_pending <= 1'b0;
      response_pending_psn <= 24'd0;
      response_pending_syndrome <= 8'd0;
      configured <= 1'b0;
      fault <= 1'b0;
      session_remote_mac <= 48'd0;
      session_local_ip <= 32'd0;
      session_remote_ip <= 32'd0;
      session_local_qpn <= 24'd0;
      session_remote_qpn <= 24'd0;
      session_remote_psn <= 24'd0;
      session_remote_base <= 48'd0;
      session_rkey <= 32'd0;
      session_ring_size <= 32'd0;
      session_wr_size <= 32'd0;
      session_local_base <= 64'd0;
      session_enable_immediate <= 1'b0;
      session_notify_interval_bytes <= 32'd0;
      session_commit_remote_addr <= 48'd0;
      session_allow_ring_wrap <= 1'b0;
      local_byte_address <= 64'd0;
      ring_offset <= 32'd0;
      logical_wr_active <= 1'b0;
      logical_wr_remaining <= 32'd0;
      physical_message_remaining <= 32'd0;
      bytes_since_commit <= 32'd0;
      pending_commit <= 1'b0;
      pending_commit_total_bytes <= 64'd0;
      pending_commit_end_offset <= 32'd0;
      pending_commit_interval_bytes <= 32'd0;
      pending_commit_sequence <= 64'd0;
      pending_commit_final <= 1'b0;
      next_ip_identification <= 16'd0;
      inflight_is_commit <= 1'b0;
      inflight_opcode <= RC_RDMA_WRITE_ONLY;
      inflight_has_reth <= 1'b1;
      inflight_has_immediate <= 1'b0;
      inflight_payload_length <= 32'd0;
      inflight_work_length <= 32'd0;
      inflight_remaining_after <= 32'd0;
      inflight_laddr <= 64'd0;
      inflight_remote_address <= 48'd0;
      inflight_psn <= 24'd0;
      inflight_commit_total_bytes <= 64'd0;
      inflight_commit_end_offset <= 32'd0;
      inflight_commit_interval_bytes <= 32'd0;
      inflight_commit_sequence <= 64'd0;
      inflight_commit_final <= 1'b0;
      inflight_ip_identification <= 16'd0;
      inflight_ip_checksum <= 16'd0;
      packet_icrc <= 32'd0;
      crc_state <= ICRC_INIT;
      crc_offset <= 16'd0;
      tx_packet_read_address <= 7'd0;
      tx_build_beat <= 7'd0;
      tx_build_byte_index <= 7'd0;
      tx_build_valid_bytes <= 7'd0;
      tx_build_byte_offset <= 16'd0;
      tx_build_byte <= 8'd0;
      tx_build_region <= TX_BYTE_DEST_MAC;
      tx_build_region_offset <= 16'd0;
      tx_build_word <= 512'd0;
      tx_build_keep <= 64'd0;
      tx_packet_last_beat <= 7'd0;
      tx_packet_last_valid_bytes <= 7'd0;
      tx_packet_last_keep <= 64'd0;
      tx_send_beat <= 7'd0;
      tx_send_word <= 512'd0;
      tx_send_keep <= 64'd0;
      tx_send_last <= 1'b0;
      select_has_reth <= 1'b0;
      select_logical_remaining <= 32'd0;
      select_physical_remaining <= 32'd0;
      select_ring_remaining <= 32'd0;
      select_notification_remaining <= 32'd0;
      select_laddr <= 64'd0;
      select_remote_address <= 48'd0;
      select_work_length <= 32'd0;
      config_reject_count <= 32'd0;
      icrc_drop_count <= 32'd0;
      invalid_psn_count <= 32'd0;
      nak_count <= 32'd0;
      retrans_count <= 32'd0;
      retry_exhausted_count <= 32'd0;
      rx_overflow_count <= 32'd0;
      rx_overflow_source_seen <= 32'd0;
      tx_underflow_count <= 32'd0;
      issued_bytes <= 64'd0;
      acked_bytes <= 64'd0;
      commit_count <= 32'd0;
      immediate_count <= 32'd0;
      published_bytes <= 64'd0;
      producer_sequence <= 64'd0;
      inflight_udp_length <= 16'd0;
      inflight_ip_total_length <= 16'd0;
      inflight_icrc_data_bytes <= 16'd0;
      inflight_packet_bytes <= 16'd0;
      ip_checksum_sum_a <= 18'd0;
      ip_checksum_sum_b <= 18'd0;
      ip_checksum_sum_c <= 18'd0;
      tx_crc_byte <= 8'd0;
    end else begin
      apply_q <= cfg_apply;
      start_q <= cfg_start;
      stop_q <= cfg_stop;
      clear_stats_q <= cfg_clear_stats;
      rx_overflow_source_seen <= rx_overflow_source_count;
      cfg_validate_pending <= 1'b0;
      cfg_apply_pending <= cfg_validate_pending;

      if (clear_stats_pulse) begin
        config_reject_count <= 32'd0;
        icrc_drop_count <= 32'd0;
        invalid_psn_count <= 32'd0;
        nak_count <= 32'd0;
        retrans_count <= 32'd0;
        retry_exhausted_count <= 32'd0;
        rx_overflow_count <= 32'd0;
        rx_overflow_source_seen <= rx_overflow_source_count;
        tx_underflow_count <= 32'd0;
        issued_bytes <= 64'd0;
        acked_bytes <= 64'd0;
        commit_count <= 32'd0;
        immediate_count <= 32'd0;
      end else begin
        if (rx_overflow_delta != 32'd0) begin
          rx_overflow_count <= sat_add32(rx_overflow_count, rx_overflow_delta);
        end
        if (rx_icrc_drop_pulse) icrc_drop_count <= sat_inc32(icrc_drop_count);
        if (rx_invalid_packet_pulse) invalid_psn_count <= sat_inc32(invalid_psn_count);
      end

      // Capture all VIO/configuration inputs at the apply edge. Validation is
      // split over the next two cycles so its wide comparisons do not drive
      // every session-state enable directly.
      if (apply_pulse && !cfg_validate_pending && !cfg_apply_pending) begin
        cfg_snapshot_remote_end <= {1'b0, cfg_remote_base} + {17'd0, cfg_ring_size};
        cfg_snapshot_commit_end <= {1'b0, cfg_commit_remote_addr} + 49'd64;
        cfg_snapshot_remote_mac <= cfg_force_remote_mac ? cfg_remote_mac : learned_remote_mac;
        cfg_snapshot_local_ip <= local_ip;
        cfg_snapshot_remote_ip <= (cfg_remote_ip != 32'd0) ? cfg_remote_ip : learned_remote_ip;
        cfg_snapshot_local_qpn <= cfg_local_qpn;
        cfg_snapshot_remote_qpn <= cfg_remote_qpn;
        cfg_snapshot_local_psn <= cfg_local_psn;
        cfg_snapshot_remote_base <= cfg_remote_base;
        cfg_snapshot_rkey <= cfg_rkey;
        cfg_snapshot_ring_size <= cfg_ring_size;
        cfg_snapshot_wr_size <= cfg_wr_size;
        cfg_snapshot_local_base <= cfg_local_base;
        cfg_snapshot_enable_immediate <= cfg_enable_immediate;
        cfg_snapshot_notify_interval_bytes <= cfg_notify_interval_bytes;
        cfg_snapshot_commit_remote_addr <= cfg_commit_remote_addr;
        cfg_snapshot_allow_ring_wrap <= cfg_allow_ring_wrap;
        cfg_identity_valid <= drained &&
                              (cfg_force_remote_mac ? (cfg_remote_mac != 48'd0) :
                                                      learned_remote_valid) &&
                              (cfg_local_qpn != 24'd0) && (cfg_local_qpn <= 24'd255) &&
                              (cfg_remote_qpn != 24'd0) &&
                              ((cfg_remote_ip != 32'd0) || (learned_remote_ip != 32'd0));
        cfg_sizes_valid <= (cfg_ring_size != 32'd0) && (cfg_wr_size != 32'd0) &&
                           (cfg_ring_size[11:0] == 12'd0) &&
                           (cfg_wr_size[11:0] == 12'd0) &&
                           (cfg_wr_size <= cfg_ring_size) &&
                           (cfg_local_base[2:0] == 3'd0) &&
                           (cfg_notify_interval_bytes != 32'd0) &&
                           (cfg_notify_interval_bytes[11:0] == 12'd0) &&
                           (cfg_notify_interval_bytes <= cfg_ring_size);
        cfg_commit_valid <= (cfg_commit_remote_addr != 48'd0) &&
                            (cfg_commit_remote_addr[5:0] == 6'd0);
        cfg_validate_pending <= 1'b1;
      end

      if (cfg_validate_pending) begin
        cfg_validation_accept <= cfg_identity_valid && cfg_sizes_valid && cfg_commit_valid &&
                                 !cfg_snapshot_remote_end[48] &&
                                 !cfg_snapshot_commit_end[48] &&
                                 ((cfg_snapshot_commit_end <=
                                   {1'b0, cfg_snapshot_remote_base}) ||
                                  ({1'b0, cfg_snapshot_commit_remote_addr} >=
                                   cfg_snapshot_remote_end));
      end

      if (cfg_apply_pending) begin
        if (!cfg_validation_accept) begin
          config_reject_count <= sat_inc32(config_reject_count);
        end else begin
          configured <= 1'b1;
          fault <= 1'b0;
          run_enable <= 1'b0;
          stop_requested <= 1'b0;
          inflight_valid <= 1'b0;
          response_pending <= 1'b0;
          tx_state <= TX_IDLE;
          session_remote_mac <= cfg_snapshot_remote_mac;
          session_local_ip <= cfg_snapshot_local_ip;
          session_remote_ip <= cfg_snapshot_remote_ip;
          session_local_qpn <= cfg_snapshot_local_qpn;
          session_remote_qpn <= cfg_snapshot_remote_qpn;
          session_remote_psn <= cfg_snapshot_local_psn;
          session_remote_base <= cfg_snapshot_remote_base;
          session_rkey <= cfg_snapshot_rkey;
          session_ring_size <= cfg_snapshot_ring_size;
          session_wr_size <= cfg_snapshot_wr_size;
          session_local_base <= cfg_snapshot_local_base;
          session_enable_immediate <= cfg_snapshot_enable_immediate;
          session_notify_interval_bytes <= cfg_snapshot_notify_interval_bytes;
          session_commit_remote_addr <= cfg_snapshot_commit_remote_addr;
          session_allow_ring_wrap <= cfg_snapshot_allow_ring_wrap;
          local_byte_address <= cfg_snapshot_local_base;
          ring_offset <= 32'd0;
          logical_wr_active <= 1'b0;
          logical_wr_remaining <= 32'd0;
          physical_message_remaining <= 32'd0;
          bytes_since_commit <= 32'd0;
          pending_commit <= 1'b0;
          pending_commit_total_bytes <= 64'd0;
          pending_commit_end_offset <= 32'd0;
          pending_commit_interval_bytes <= 32'd0;
          pending_commit_sequence <= 64'd0;
          pending_commit_final <= 1'b0;
          published_bytes <= 64'd0;
          producer_sequence <= 64'd0;
          next_ip_identification <= 16'd0;
          retry_count <= 4'd0;
          timeout_count <= 32'd0;
        end
      end

      if (start_pulse && configured && drained && !fault) begin
        run_enable <= 1'b1;
        stop_requested <= 1'b0;
      end
      if (stop_pulse && run_enable) begin
        run_enable <= 1'b0;
        stop_requested <= 1'b1;
      end

      // Responses can complete their CRC check while a replay is on the wire.
      // Queue one response and consume it only after TLAST has transferred, so
      // neither a matching delayed ACK nor a wrong-PSN response can truncate
      // or duplicate an AXIS frame.
      if (rx_ack_pulse && inflight_valid && !response_pending &&
          ((tx_state == TX_SEND) || (tx_state == TX_WAIT_ACK))) begin
        response_pending <= 1'b1;
        response_pending_psn <= rx_ack_psn;
        response_pending_syndrome <= rx_ack_syndrome;
      end

      case (tx_state)
        TX_IDLE: begin
          timeout_count <= 32'd0;
          if (!inflight_valid && !fault) begin
            if (stop_requested && !pending_commit && !logical_wr_active &&
                (physical_message_remaining == 32'd0)) begin
              // A stop is complete only after a final release record is ACKed.
              // Publish even when the last periodic record covered every byte;
              // the zero-byte final marker lets the host tear down its MR/QP.
              pending_commit <= 1'b1;
              pending_commit_total_bytes <= acked_bytes;
              pending_commit_end_offset <= ring_offset;
              pending_commit_interval_bytes <= bytes_since_commit;
              pending_commit_sequence <= sat_inc64(producer_sequence);
              pending_commit_final <= 1'b1;
            end else if (pending_commit) begin
              inflight_valid <= 1'b1;
              inflight_issued_accounted <= 1'b0;
              inflight_is_commit <= 1'b1;
              inflight_opcode <= session_enable_immediate ?
                                  RC_RDMA_WRITE_ONLY_WITH_IMM : RC_RDMA_WRITE_ONLY;
              inflight_has_reth <= 1'b1;
              inflight_has_immediate <= session_enable_immediate;
              inflight_payload_length <= COMMIT_BYTES;
              inflight_work_length <= COMMIT_BYTES;
              inflight_remaining_after <= 32'd0;
              inflight_laddr <= 64'd0;
              inflight_remote_address <= session_commit_remote_addr;
              inflight_psn <= session_remote_psn;
              inflight_commit_total_bytes <= pending_commit_total_bytes;
              inflight_commit_end_offset <= pending_commit_end_offset;
              inflight_commit_interval_bytes <= pending_commit_interval_bytes;
              inflight_commit_sequence <= pending_commit_sequence;
              inflight_commit_final <= pending_commit_final;
              inflight_ip_identification <= next_ip_identification;
              next_ip_identification <= next_ip_identification + 16'd1;
              tx_state <= TX_PREPARE;
            end else if (configured &&
                         (logical_wr_active || (run_enable && !stop_pulse))) begin
              select_has_reth <= (physical_message_remaining == 32'd0);
              select_physical_remaining <= physical_message_remaining;
              select_laddr <= local_byte_address;
              select_remote_address <= session_remote_base + ring_offset;
              if (physical_message_remaining == 32'd0) begin
                select_logical_remaining <= logical_wr_active ?
                                            logical_wr_remaining : session_wr_size;
                select_ring_remaining <= session_ring_size - ring_offset;
                select_notification_remaining <=
                  (session_notify_interval_bytes == 32'd0) ?
                  32'hFFFF_FFFF :
                  session_notify_interval_bytes - bytes_since_commit;
              end else begin
                select_logical_remaining <= 32'd0;
                select_ring_remaining <= 32'd0;
                select_notification_remaining <= 32'd0;
              end
              tx_state <= TX_SELECT;
            end
          end
        end

        TX_SELECT: begin
          if (select_has_reth) begin
            selected_work_length = select_logical_remaining;
            if (select_ring_remaining < selected_work_length) begin
              selected_work_length = select_ring_remaining;
            end
            if (select_notification_remaining < selected_work_length) begin
              selected_work_length = select_notification_remaining;
            end
          end else begin
            selected_work_length = select_physical_remaining;
          end
          select_work_length <= selected_work_length;
          tx_state <= TX_SELECT_LENGTH;
        end

        TX_SELECT_LENGTH: begin
          selected_payload_length = (select_work_length > 32'd4096) ?
                                    32'd4096 : select_work_length;
          if (select_work_length != 32'd0) begin
            if (select_has_reth) begin
              selected_opcode = (select_work_length <= 32'd4096) ?
                                RC_RDMA_WRITE_ONLY : RC_RDMA_WRITE_FIRST;
            end else begin
              selected_opcode = (select_work_length <= 32'd4096) ?
                                RC_RDMA_WRITE_LAST : RC_RDMA_WRITE_MIDDLE;
            end
            inflight_valid <= 1'b1;
            inflight_issued_accounted <= 1'b0;
            inflight_is_commit <= 1'b0;
            inflight_opcode <= selected_opcode;
            inflight_has_reth <= select_has_reth;
            inflight_has_immediate <= 1'b0;
            inflight_payload_length <= selected_payload_length;
            inflight_work_length <= select_work_length;
            inflight_remaining_after <= select_work_length - selected_payload_length;
            inflight_laddr <= select_laddr;
            inflight_remote_address <= select_remote_address;
            inflight_psn <= session_remote_psn;
            inflight_commit_total_bytes <= 64'd0;
            inflight_commit_end_offset <= 32'd0;
            inflight_commit_interval_bytes <= 32'd0;
            inflight_commit_sequence <= 64'd0;
            inflight_commit_final <= 1'b0;
            inflight_ip_identification <= next_ip_identification;
            next_ip_identification <= next_ip_identification + 16'd1;
            if (select_has_reth && !logical_wr_active) begin
              logical_wr_active <= 1'b1;
              logical_wr_remaining <= session_wr_size;
            end
            tx_state <= TX_PREPARE;
          end else begin
            tx_state <= TX_IDLE;
          end
        end

        TX_PREPARE: begin
          logic [15:0] prepared_transport_header_bytes;
          logic [15:0] prepared_udp_length;
          logic [15:0] prepared_ip_total_length;

          prepared_transport_header_bytes = 16'd12 +
            (inflight_has_reth ? 16'd16 : 16'd0) +
            (inflight_has_immediate ? 16'd4 : 16'd0);
          prepared_udp_length = 16'd8 + prepared_transport_header_bytes +
                                inflight_payload_length[15:0] + 16'd4;
          prepared_ip_total_length = 16'd20 + prepared_udp_length;

          inflight_udp_length <= prepared_udp_length;
          inflight_ip_total_length <= prepared_ip_total_length;
          inflight_icrc_data_bytes <= prepared_ip_total_length - 16'd4;
          inflight_packet_bytes <= 16'd14 + prepared_ip_total_length;
          ip_checksum_sum_a <= {2'd0, 16'h4500} +
                               {2'd0, prepared_ip_total_length} +
                               {2'd0, inflight_ip_identification};
          ip_checksum_sum_b <= {2'd0, 16'h4000} + {2'd0, 16'h4011} +
                               {2'd0, session_local_ip[31:16]};
          ip_checksum_sum_c <= {2'd0, session_local_ip[15:0]} +
                               {2'd0, session_remote_ip[31:16]} +
                               {2'd0, session_remote_ip[15:0]};
          tx_state <= TX_CHECKSUM;
        end

        TX_CHECKSUM: begin
          logic [19:0] checksum_sum;
          logic [16:0] checksum_fold;
          logic [16:0] checksum_refold;
          logic [15:0] packet_last_offset;
          logic [6:0] last_valid_bytes;

          checksum_sum = {2'd0, ip_checksum_sum_a} +
                         {2'd0, ip_checksum_sum_b} +
                         {2'd0, ip_checksum_sum_c};
          checksum_fold = {1'b0, checksum_sum[15:0]} + checksum_sum[19:16];
          checksum_refold = {1'b0, checksum_fold[15:0]} + checksum_fold[16];
          inflight_ip_checksum <= ~checksum_refold[15:0];

          packet_last_offset = inflight_packet_bytes - 16'd1;
          last_valid_bytes = {1'b0, packet_last_offset[5:0]} + 7'd1;
          tx_packet_last_beat <= packet_last_offset[12:6];
          tx_packet_last_valid_bytes <= last_valid_bytes;
          tx_packet_last_keep <= packet_keep_mask(last_valid_bytes);
          crc_state <= ICRC_INIT;
          crc_offset <= 16'd0;
          tx_state <= TX_CRC;
        end

        TX_CRC: begin
          // Address decode and the CRC recurrence are separate cycles. This is
          // outside the AXIS data path, so the extra preparation latency does
          // not reduce the one-beat-per-cycle transmit rate.
          tx_crc_byte <= icrc_masked_byte(crc_offset);
          tx_state <= TX_CRC_UPDATE;
        end

        TX_CRC_UPDATE: begin
          logic [31:0] next_crc_state;

          next_crc_state = crc32_byte(crc_state, tx_crc_byte);
          if ((crc_offset + 16'd1) >= inflight_icrc_data_bytes) begin
            packet_icrc <= ~next_crc_state;
            tx_build_beat <= 7'd0;
            tx_build_byte_index <= 7'd0;
            tx_build_byte_offset <= 16'd0;
            tx_build_valid_bytes <= (tx_packet_last_beat == 7'd0) ?
                                    tx_packet_last_valid_bytes : 7'd64;
            tx_build_word <= 512'd0;
            tx_build_keep <= (tx_packet_last_beat == 7'd0) ?
                             tx_packet_last_keep : 64'hFFFF_FFFF_FFFF_FFFF;
            tx_packet_read_address <= 7'd0;
            tx_state <= TX_BUILD;
          end else begin
            crc_state <= next_crc_state;
            crc_offset <= crc_offset + 16'd1;
            tx_state <= TX_CRC;
          end
        end

        TX_BUILD: begin
          logic [15:0] immediate_start;
          logic [15:0] payload_start;
          logic [15:0] icrc_start;

          immediate_start = 16'd54 + (inflight_has_reth ? 16'd16 : 16'd0);
          payload_start = immediate_start + (inflight_has_immediate ? 16'd4 : 16'd0);
          icrc_start = 16'd14 + inflight_icrc_data_bytes;

          if (tx_build_byte_offset < 16'd6) begin
            tx_build_region <= TX_BYTE_DEST_MAC;
            tx_build_region_offset <= tx_build_byte_offset;
          end else if (tx_build_byte_offset < 16'd12) begin
            tx_build_region <= TX_BYTE_SOURCE_MAC;
            tx_build_region_offset <= tx_build_byte_offset - 16'd6;
          end else if (tx_build_byte_offset < 16'd14) begin
            tx_build_region <= TX_BYTE_ETHERTYPE;
            tx_build_region_offset <= tx_build_byte_offset - 16'd12;
          end else if (tx_build_byte_offset < 16'd34) begin
            tx_build_region <= TX_BYTE_IPV4;
            tx_build_region_offset <= tx_build_byte_offset - 16'd14;
          end else if (tx_build_byte_offset < 16'd42) begin
            tx_build_region <= TX_BYTE_UDP;
            tx_build_region_offset <= tx_build_byte_offset - 16'd34;
          end else if (tx_build_byte_offset < 16'd54) begin
            tx_build_region <= TX_BYTE_BTH;
            tx_build_region_offset <= tx_build_byte_offset - 16'd42;
          end else if (inflight_has_reth && (tx_build_byte_offset < 16'd70)) begin
            tx_build_region <= TX_BYTE_RETH;
            tx_build_region_offset <= tx_build_byte_offset - 16'd54;
          end else if (inflight_has_immediate && (tx_build_byte_offset < payload_start)) begin
            tx_build_region <= TX_BYTE_IMMEDIATE;
            tx_build_region_offset <= tx_build_byte_offset - immediate_start;
          end else if (tx_build_byte_offset < icrc_start) begin
            tx_build_region <= TX_BYTE_PAYLOAD;
            tx_build_region_offset <= tx_build_byte_offset - payload_start;
          end else begin
            tx_build_region <= TX_BYTE_ICRC;
            tx_build_region_offset <= tx_build_byte_offset - icrc_start;
          end
          tx_state <= TX_BUILD_DECODE;
        end

        TX_BUILD_DECODE: begin
          case (tx_build_region)
            TX_BYTE_DEST_MAC:
              tx_build_byte <= mac_byte(session_remote_mac, tx_build_region_offset);
            TX_BYTE_SOURCE_MAC:
              tx_build_byte <= mac_byte(LOCAL_MAC, tx_build_region_offset);
            TX_BYTE_ETHERTYPE:
              tx_build_byte <= (tx_build_region_offset == 16'd0) ? 8'h08 : 8'h00;
            TX_BYTE_IPV4:
              tx_build_byte <= ipv4_byte(tx_build_region_offset);
            TX_BYTE_UDP:
              tx_build_byte <= udp_byte(tx_build_region_offset);
            TX_BYTE_BTH:
              tx_build_byte <= bth_byte(tx_build_region_offset);
            TX_BYTE_RETH:
              tx_build_byte <= reth_byte(tx_build_region_offset);
            TX_BYTE_IMMEDIATE:
              tx_build_byte <= immediate_byte(tx_build_region_offset);
            TX_BYTE_PAYLOAD:
              tx_build_byte <= payload_byte(tx_build_region_offset);
            default: begin
              case (tx_build_region_offset)
                16'd0: tx_build_byte <= packet_icrc[7:0];
                16'd1: tx_build_byte <= packet_icrc[15:8];
                16'd2: tx_build_byte <= packet_icrc[23:16];
                default: tx_build_byte <= packet_icrc[31:24];
              endcase
            end
          endcase
          tx_state <= TX_BUILD_COMMIT;
        end

        TX_BUILD_COMMIT: begin
          logic [511:0] completed_word;

          completed_word = tx_build_word;
          completed_word[tx_build_byte_index * 8 +: 8] = tx_build_byte;
          tx_build_word <= completed_word;
          tx_build_byte_offset <= tx_build_byte_offset + 16'd1;
          if ((tx_build_byte_index + 7'd1) >= tx_build_valid_bytes) begin
            tx_state <= TX_BUILD_STORE;
          end else begin
            tx_build_byte_index <= tx_build_byte_index + 7'd1;
            tx_state <= TX_BUILD;
          end
        end

        TX_BUILD_STORE: begin
          logic [6:0] next_build_beat;

          tx_packet_buffer[tx_build_beat] <= {
            (tx_build_beat == tx_packet_last_beat),
            tx_build_keep,
            tx_build_word
          };
          if (tx_build_beat == tx_packet_last_beat) begin
            tx_state <= TX_LOAD;
          end else begin
            next_build_beat = tx_build_beat + 7'd1;
            tx_build_beat <= next_build_beat;
            tx_build_byte_index <= 7'd0;
            tx_build_valid_bytes <= (next_build_beat == tx_packet_last_beat) ?
                                    tx_packet_last_valid_bytes : 7'd64;
            tx_build_word <= 512'd0;
            tx_build_keep <= (next_build_beat == tx_packet_last_beat) ?
                             tx_packet_last_keep : 64'hFFFF_FFFF_FFFF_FFFF;
            tx_state <= TX_BUILD;
          end
        end

        TX_LOAD: begin
          // The synchronous RAM result is consumed in the following state.
          if (tx_packet_read_address == 7'd0) begin
            tx_send_beat <= 7'd0;
          end
          tx_state <= TX_LOAD_WAIT;
        end

        TX_LOAD_WAIT: begin
          tx_send_word <= tx_packet_read_data[511:0];
          tx_send_keep <= tx_packet_read_data[575:512];
          tx_send_last <= tx_packet_read_data[576];
          tx_state <= TX_SEND;
        end

        TX_SEND: begin
          if (tx_axis_tready) begin
            if (tx_send_last) begin
              if (!inflight_issued_accounted) begin
                if (!inflight_is_commit) begin
                  issued_bytes <= sat_add64(issued_bytes, inflight_payload_length);
                end
                inflight_issued_accounted <= 1'b1;
              end
              timeout_count <= 32'd0;
              tx_state <= TX_WAIT_ACK;
            end else begin
              tx_send_beat <= tx_send_beat + 7'd1;
              tx_packet_read_address <= tx_send_beat + 7'd1;
              tx_state <= TX_LOAD;
            end
          end
        end

        TX_WAIT_ACK: begin
          if (response_pending) begin
            response_pending <= 1'b0;
            if (response_pending_syndrome[7:5] == 3'b000) begin
              if (response_pending_psn != inflight_psn) begin
                // A stale ACK is observable but does not restart the retry
                // timer for the packet that is actually outstanding.
                invalid_psn_count <= sat_inc32(invalid_psn_count);
              end else begin
                timeout_count <= 32'd0;
                session_remote_psn <= inflight_psn + 24'd1;
                inflight_valid <= 1'b0;
                retry_count <= 4'd0;
                tx_state <= TX_IDLE;
                if (inflight_is_commit) begin
                  bytes_since_commit <= 32'd0;
                  published_bytes <= inflight_commit_total_bytes;
                  producer_sequence <= inflight_commit_sequence;
                  commit_count <= sat_inc32(commit_count);
                  if (inflight_has_immediate) immediate_count <= sat_inc32(immediate_count);
                  if (inflight_commit_final) begin
                    pending_commit <= 1'b0;
                    stop_requested <= 1'b0;
                  end else if (stop_requested && !logical_wr_active &&
                               (physical_message_remaining == 32'd0)) begin
                    pending_commit <= 1'b1;
                    pending_commit_total_bytes <= inflight_commit_total_bytes;
                    pending_commit_end_offset <= inflight_commit_end_offset;
                    pending_commit_interval_bytes <= 32'd0;
                    pending_commit_sequence <= sat_inc64(inflight_commit_sequence);
                    pending_commit_final <= 1'b1;
                  end else begin
                    pending_commit <= 1'b0;
                  end
                end else begin
                  post_ack_ring_offset = ring_offset + inflight_payload_length;
                  if (post_ack_ring_offset >= session_ring_size) begin
                    post_ack_ring_offset = post_ack_ring_offset - session_ring_size;
                  end
                  post_ack_logical_remaining = logical_wr_remaining - inflight_payload_length;
                  completed_interval_bytes = bytes_since_commit + inflight_payload_length;
                  data_message_done = (inflight_remaining_after == 32'd0);
                  final_logical_packet = (post_ack_logical_remaining == 32'd0);
                  notification_due = (session_notify_interval_bytes != 32'd0) &&
                                     (completed_interval_bytes == session_notify_interval_bytes);
                  ring_wrap_stop = !session_allow_ring_wrap &&
                    (inflight_payload_length >= (session_ring_size - ring_offset));
                  stopping = stop_requested || stop_pulse || !run_enable || ring_wrap_stop;

                  acked_bytes <= sat_add64(acked_bytes, inflight_payload_length);
                  local_byte_address <= local_byte_address + inflight_payload_length;
                  ring_offset <= post_ack_ring_offset;
                  if (ring_wrap_stop) begin
                    // Do not begin the wrapped range without consumer credit.
                    run_enable <= 1'b0;
                    logical_wr_remaining <= 32'd0;
                    logical_wr_active <= 1'b0;
                    physical_message_remaining <= 32'd0;
                  end else begin
                    logical_wr_remaining <= post_ack_logical_remaining;
                    logical_wr_active <= !final_logical_packet;
                    physical_message_remaining <= inflight_remaining_after;
                  end
                  bytes_since_commit <= completed_interval_bytes;

                  if (data_message_done &&
                      (notification_due ||
                       (stopping && (final_logical_packet || ring_wrap_stop) &&
                        (session_notify_interval_bytes != 32'd0) &&
                        (completed_interval_bytes != 32'd0)))) begin
                    pending_commit <= 1'b1;
                    pending_commit_total_bytes <= sat_add64(acked_bytes, inflight_payload_length);
                    pending_commit_end_offset <= post_ack_ring_offset;
                    pending_commit_interval_bytes <= completed_interval_bytes;
                    pending_commit_sequence <= sat_inc64(producer_sequence);
                    pending_commit_final <= stopping &&
                                            (final_logical_packet || ring_wrap_stop);
                  end
                end
              end
            end else if (response_pending_syndrome[7:5] == 3'b001) begin
              // Receiver-not-ready is retryable only for this PSN and only
              // after the AETH-encoded minimum delay.
              if (response_pending_psn != inflight_psn) begin
                invalid_psn_count <= sat_inc32(invalid_psn_count);
              end else begin
                timeout_count <= 32'd0;
                nak_count <= sat_inc32(nak_count);
                if (retry_count >= MAX_RETRIES) begin
                  retry_exhausted_count <= sat_inc32(retry_exhausted_count);
                  fault <= 1'b1;
                  run_enable <= 1'b0;
                  tx_state <= TX_IDLE;
                end else begin
                  retry_count <= retry_count + 4'd1;
                  rnr_wait_cycles <= rnr_retry_delay_cycles(
                    response_pending_syndrome[4:0]);
                  tx_state <= TX_RNR_WAIT;
                end
              end
            end else begin
              // PSN sequence-error recovery needs responder state that this
              // single-outstanding bring-up endpoint does not implement. It
              // and all fatal/unknown AETH syndromes stop the QP immediately.
              if (response_pending_syndrome[7:5] == 3'b011) begin
                nak_count <= sat_inc32(nak_count);
              end
              fault <= 1'b1;
              run_enable <= 1'b0;
              tx_state <= TX_IDLE;
            end
          end else if (rx_ack_pulse && inflight_valid) begin
            // The response is captured above and processed on the next cycle.
          end else if (timeout_count >= (ACK_TIMEOUT_CYCLES - 1)) begin
            timeout_count <= 32'd0;
            if (retry_count >= MAX_RETRIES) begin
              retry_exhausted_count <= sat_inc32(retry_exhausted_count);
              fault <= 1'b1;
              run_enable <= 1'b0;
              tx_state <= TX_IDLE;
            end else begin
              retry_count <= retry_count + 4'd1;
              retrans_count <= sat_inc32(retrans_count);
              tx_send_beat <= 7'd0;
              tx_packet_read_address <= 7'd0;
              tx_state <= TX_LOAD;
            end
          end else begin
            timeout_count <= timeout_count + 32'd1;
          end
        end

        TX_RNR_WAIT: begin
          if (timeout_count >= (rnr_wait_cycles - 32'd1)) begin
            timeout_count <= 32'd0;
            retrans_count <= sat_inc32(retrans_count);
            tx_send_beat <= 7'd0;
            tx_packet_read_address <= 7'd0;
            tx_state <= TX_LOAD;
          end else begin
            timeout_count <= timeout_count + 32'd1;
          end
        end

        default: tx_state <= TX_IDLE;
      endcase
    end
  end

endmodule
