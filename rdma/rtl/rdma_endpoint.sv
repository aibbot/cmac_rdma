`timescale 1ps / 1ps

// Single-QP RoCEv2 RC RDMA WRITE endpoint.
//
// The default bring-up mode permits one unacknowledged packet at a time and
// retains a byte-identical replay image. FAST_BENCHMARK_MODE streams 512-bit
// beats, sends the data portion of each publication interval without per-packet
// waits, and uses the ordered commit ACK as the interval completion barrier.
module cmac_usplus_0_rdma_endpoint #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
  parameter logic [23:0] LOCAL_QPN = 24'd1,
  parameter integer ACK_TIMEOUT_CYCLES = 250_000,
  parameter integer MAX_RETRIES = 12,
  parameter integer MAX_SEQUENCE_RECOVERIES = 12,
  parameter integer SEQUENCE_RECOVERY_QUIET_CYCLES = 4096,
  parameter integer RNR_TIMER_10US_CYCLES = 2_500,
  parameter bit FAST_BENCHMARK_MODE = 1'b0
) (
  input  logic          clk,
  input  logic          reset,
  input  logic [31:0]   local_ip,

  input  logic [31:0]   rx_overflow_source_count,

  input  logic          cfg_valid,
  output logic          cfg_ready,
  output logic          cfg_done,
  output logic          cfg_accepted,
  input  logic [47:0]   cfg_remote_mac,
  input  logic [31:0]   cfg_remote_ip,
  input  logic [23:0]   cfg_remote_qpn,
  input  logic [23:0]   cfg_local_psn,
  input  logic [47:0]   cfg_remote_base,
  input  logic [31:0]   cfg_rkey,
  input  logic [31:0]   cfg_ring_size,
  input  logic [31:0]   cfg_wr_size,
  input  logic [63:0]   cfg_local_base,
  input  logic          cfg_enable_immediate,
  input  logic [31:0]   cfg_notify_interval_bytes,
  input  logic [47:0]   cfg_commit_remote_addr,
  input  logic          cfg_use_external_payload,
  input  logic          start_request,
  input  logic          stop_request,
  input  logic          abort_request,
  input  logic [63:0]   consumed_bytes,
  input  logic          tx_path_idle,
  // Runtime debug control. A low value preserves the current frame, then
  // faults instead of starting a timeout/RNR/NAK replay.
  input  logic          retransmission_enable,

  input  logic          payload_packet_valid,
  input  logic [15:0]   payload_packet_length,
  output logic          payload_packet_release,
  input  logic          payload_buffer_empty,
  output logic          payload_ingress_enable,
  output logic          payload_flush,
  output logic          payload_read_enable,
  output logic [5:0]    payload_read_address,
  input  logic [511:0]  payload_read_data,

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
  output logic          credit_stalled,
  output logic          stopping,
  output logic          drained,
  output logic          fault,
  output logic [31:0]   fault_reason,
  output logic          final_commit_acked,
  output logic [31:0]   config_reject_count,
  output logic [31:0]   config_reject_reason,
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
  output logic [63:0]   producer_sequence,
  output logic [7:0]    last_nak_syndrome,
  output logic [23:0]   last_nak_psn,
  output logic [31:0]   sequence_recovery_count,
  output logic          replay_active,
  output logic          external_payload_active
);
  import cmac_usplus_0_rdma_endpoint_pkg::*;

  localparam logic [7:0] RC_RDMA_WRITE_FIRST  = 8'h06;
  localparam logic [7:0] RC_RDMA_WRITE_MIDDLE = 8'h07;
  localparam logic [7:0] RC_RDMA_WRITE_LAST   = 8'h08;
  localparam logic [7:0] RC_RDMA_WRITE_ONLY   = 8'h0A;
  localparam logic [7:0] RC_RDMA_WRITE_ONLY_WITH_IMM = 8'h0B;
  localparam logic [31:0] ICRC_INIT           = RDMA_ICRC_INIT;
  localparam logic [31:0] COMMIT_BYTES        = 32'd64;
  localparam logic [31:0] FAULT_RETRANSMISSION_DISABLED = 32'h0000_0005;
  localparam integer TX_PACKET_BUFFER_DEPTH  = 128;
  localparam integer TX_PACKET_BUFFER_WIDTH  = 577;
  localparam integer SEQUENCE_RECOVERY_COUNT_WIDTH =
    (MAX_SEQUENCE_RECOVERIES < 1) ? 1 : $clog2(MAX_SEQUENCE_RECOVERIES + 1);
  localparam integer SEQUENCE_RECOVERY_QUIET_LIMIT =
    (SEQUENCE_RECOVERY_QUIET_CYCLES < 1) ? 1 : SEQUENCE_RECOVERY_QUIET_CYCLES;

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

  tx_state_t tx_state;
  rdma_endpoint_config_t cfg_request;
  rdma_endpoint_config_t active_config;
  rdma_packet_context_t packet_context;
  logic cfg_apply_valid;
  logic cfg_busy;

  logic run_enable;
  logic stop_requested;
  logic abort_pending;
  logic inflight_valid;
  logic inflight_issued_accounted;
  logic [3:0] retry_count;
  logic [31:0] timeout_count;
  logic [31:0] rnr_wait_cycles;
  logic response_pending;
  logic [23:0] response_pending_psn;
  logic [7:0] response_pending_syndrome;
  logic fast_nak_pending;
  logic fast_nak_observed;
  logic fast_nak_event;
  logic fast_nak_blocks_credit;
  logic [7:0] fast_nak_pending_syndrome;
  logic [23:0] fast_nak_pending_psn;
  logic [31:0] sequence_recovery_quiet_count;
  logic fast_retryable_commit_rnr;
  logic fast_retryable_commit_sequence;

  wire [47:0] session_remote_mac = active_config.remote_mac;
  wire [31:0] session_local_ip = active_config.local_ip;
  wire [31:0] session_remote_ip = active_config.remote_ip;
  // Keep the low-QPN debug alias visible to existing endpoint probes/tests;
  // the source-port encoding only consumes these fourteen bits.
  wire [13:0] session_local_qpn = LOCAL_QPN[13:0];
  wire [23:0] session_remote_qpn = active_config.remote_qpn;
  logic [23:0] session_tx_psn;
  wire [47:0] session_remote_base = active_config.remote_base;
  wire [31:0] session_rkey = active_config.rkey;
  wire [31:0] session_ring_size = active_config.ring_size;
  wire [31:0] session_wr_size = active_config.wr_size;
  wire session_enable_immediate = active_config.enable_immediate;
  wire session_use_external_payload = active_config.use_external_payload;
  wire [31:0] session_notify_interval_bytes =
    active_config.notify_interval_bytes;
  wire [47:0] session_commit_remote_addr = active_config.commit_remote_addr;

  logic [63:0] local_byte_address;
  logic        logical_wr_active;
  logic [31:0] logical_wr_remaining;
  logic [31:0] physical_message_remaining;
  logic [31:0] bytes_since_commit;
  logic [31:0] available_credit_bytes;
  logic [63:0] applied_consumed_bytes;
  logic [31:0] pending_credit_release_bytes;
  logic        credit_release_valid;
  logic [31:0] credit_release_delta;
  logic [31:0] credit_reserve_bytes;
  logic [32:0] credit_sum;
  logic [32:0] credit_after_reserve;
  // CONSUME is produced by the control-plane register bank.  Keep one local
  // sample and one registered release value before the credit arithmetic so
  // the 64-bit delta does not feed the scheduler's carry chain in one cycle.
  (* DONT_TOUCH = "TRUE" *) logic [63:0] consumed_bytes_sampled;
  logic        pending_commit;
  logic [63:0] pending_commit_total_bytes;
  logic [31:0] pending_commit_end_offset;
  logic [31:0] pending_commit_interval_bytes;
  logic [63:0] pending_commit_sequence;
  logic        pending_commit_final;
  logic [15:0] next_ip_identification;
  logic [31:0] data_packet_sequence;

  logic        message_checkpoint_valid;
  logic [23:0] message_checkpoint_psn;
  logic [31:0] message_checkpoint_ring_offset;
  logic [63:0] message_checkpoint_local_address;
  logic [31:0] message_checkpoint_data_sequence;
  logic [31:0] message_checkpoint_interval_bytes;
  logic [31:0] message_checkpoint_logical_remaining;
  logic [31:0] message_checkpoint_work_length;
  logic [SEQUENCE_RECOVERY_COUNT_WIDTH-1:0] message_recovery_attempts;
  logic [31:0] replay_remaining_bytes;
  logic        replay_message_start;
  logic        recovery_counts_valid;
  logic        recovery_snapshot_valid;
  logic [23:0] recovery_packet_index;
  logic [23:0] recovery_sent_packets;
  logic [31:0] recovery_byte_offset;
  logic [31:0] recovery_replay_bytes;

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
  logic [31:0] inflight_benchmark_sequence;
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
  (* KEEP = "TRUE" *) logic [31:0] select_credit_remaining;
  (* KEEP = "TRUE" *) logic [63:0] select_laddr;
  (* KEEP = "TRUE" *) logic [47:0] select_remote_address;
  (* KEEP = "TRUE" *) logic [31:0] select_work_length;
  logic [31:0] selected_work_length;
  logic [31:0] selected_payload_length;
  logic [7:0] selected_opcode;

  logic [15:0] prepared_transport_header_bytes;
  logic [15:0] prepared_udp_length;
  logic [15:0] prepared_ip_total_length;
  logic [19:0] checksum_sum;
  logic [16:0] checksum_fold;
  logic [15:0] checksum_refold;
  logic [12:0] packet_last_offset;
  logic [6:0] last_valid_bytes;
  logic [31:0] next_crc_state;

  logic [15:0] immediate_start;
  logic [15:0] payload_start;
  logic [15:0] icrc_start;
  logic [511:0] completed_tx_build_word;
  logic [6:0] next_tx_build_beat;
  logic [511:0] prepared_fast_last_word;
  logic [63:0] prepared_fast_last_keep;

  logic [31:0] post_ack_ring_offset;
  logic [31:0] post_ack_logical_remaining;
  logic [31:0] completed_interval_bytes;
  logic data_message_done;
  logic final_logical_packet;
  logic notification_due;
  logic stop_after_ack;

  logic tx_packet_write_enable;
  logic [6:0] tx_packet_write_address;
  logic [TX_PACKET_BUFFER_WIDTH-1:0] tx_packet_write_data;
  logic [6:0] tx_packet_read_address;
  logic [TX_PACKET_BUFFER_WIDTH-1:0] tx_packet_read_data;
  logic tx_packet_read_enable;
  logic [6:0] tx_build_beat;
  logic [6:0] tx_build_byte_index;
  logic [6:0] tx_build_valid_bytes;
  logic [15:0] tx_build_byte_offset;
  logic [7:0] tx_build_byte;
  rdma_packet_region_t tx_build_region;
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
  logic fast_mode_active;
  logic transport_idle;

  logic external_builder_start;
  logic external_builder_busy;
  logic external_builder_done;
  logic external_builder_write_enable;
  logic [6:0] external_builder_write_address;
  logic [511:0] external_builder_write_data;
  logic [63:0] external_builder_write_keep;
  logic external_builder_write_last;
  logic [31:0] external_builder_icrc;
  logic [399:0] external_crc_header_data;
  logic [31:0] external_crc_body_seed;
  logic [511:0] external_crc_body_data;
  logic [31:0] external_crc_tail6_seed;
  logic [47:0] external_crc_tail6_data;
  logic [31:0] external_crc_tail54_seed;
  logic [431:0] external_crc_tail54_data;
  logic [399:0] shared_crc50_data;
  logic [31:0] shared_crc50_result;
  logic [31:0] shared_crc64_seed;
  logic [511:0] shared_crc64_data;
  logic [31:0] shared_crc64_result;
  logic [31:0] shared_crc6_seed;
  logic [47:0] shared_crc6_data;
  logic [31:0] shared_crc6_result;
  logic [31:0] shared_crc54_seed;
  logic [431:0] shared_crc54_data;
  logic [31:0] shared_crc54_result;

  logic fast_data_path;
  logic [511:0] fast_header_word0_next;
  logic [511:0] fast_header_word1_next;
  logic [511:0] fast_header_word0;
  logic [511:0] fast_header_word1;
  logic [399:0] fast_header_word0_masked;
  logic [31:0] fast_crc_after_header0;
  logic [31:0] fast_crc_after_header0_next;
  logic [31:0] fast_crc_after_header1_next;
  logic [31:0] fast_crc_ahead_state;
  logic [31:0] fast_crc_zero6_next;
  logic [31:0] fast_crc_zero54_next;
  logic [31:0] fast_crc_zero64_next;
  logic [5:0] fast_zero_full_count;
  logic [5:0] fast_zero_full_target;
  logic [6:0] fast_tx_beat;
  logic [6:0] fast_penultimate_beat;
  logic [511:0] fast_axis_word;
  logic [63:0] fast_axis_keep;
  logic fast_axis_last;
  logic [511:0] fast_last_word;
  logic [63:0] fast_last_keep;
  logic fast_icrc_valid;

  // Only data packets use the streaming path. Commits remain in the buffered
  // path so timeout and RNR recovery can replay a byte-identical packet.
  assign fast_mode_active = FAST_BENCHMARK_MODE &&
                            !session_use_external_payload;
  assign fast_data_path = fast_mode_active && !inflight_is_commit;

  // Header CRCs are prepared before TVALID is asserted. Once streaming starts,
  // all remaining payload bytes are zero, so the ahead engine only advances a
  // 32-bit CRC state and has two output beats of lead time to build the ICRC.
  assign shared_crc50_data = external_builder_busy ?
                             external_crc_header_data :
                             fast_header_word0_masked;
  assign shared_crc64_seed = external_builder_busy ?
                             external_crc_body_seed : fast_crc_ahead_state;
  assign shared_crc64_data = external_builder_busy ?
                             external_crc_body_data : 512'd0;
  assign shared_crc6_seed = external_builder_busy ?
                            external_crc_tail6_seed : fast_crc_ahead_state;
  assign shared_crc6_data = external_builder_busy ?
                            external_crc_tail6_data : 48'd0;
  assign shared_crc54_seed = external_builder_busy ?
                             external_crc_tail54_seed : fast_crc_ahead_state;
  assign shared_crc54_data = external_builder_busy ?
                             external_crc_tail54_data : 432'd0;

  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(50)) i_crc32_shared_header0 (
    .crc_in(ICRC_INIT),
    .data_in(shared_crc50_data),
    .crc_out(shared_crc50_result)
  );
  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(64)) i_crc32_fast_header1 (
    .crc_in(fast_crc_after_header0),
    .data_in(fast_header_word1),
    .crc_out(fast_crc_after_header1_next)
  );
  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(6)) i_crc32_shared_tail6 (
    .crc_in(shared_crc6_seed),
    .data_in(shared_crc6_data),
    .crc_out(shared_crc6_result)
  );
  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(54)) i_crc32_shared_tail54 (
    .crc_in(shared_crc54_seed),
    .data_in(shared_crc54_data),
    .crc_out(shared_crc54_result)
  );
  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(64)) i_crc32_shared_body64 (
    .crc_in(shared_crc64_seed),
    .data_in(shared_crc64_data),
    .crc_out(shared_crc64_result)
  );

  assign fast_crc_after_header0_next = shared_crc50_result;
  assign fast_crc_zero6_next = shared_crc6_result;
  assign fast_crc_zero54_next = shared_crc54_result;
  assign fast_crc_zero64_next = shared_crc64_result;

  assign external_builder_start = (tx_state == TX_CRC) &&
    session_use_external_payload && !inflight_is_commit &&
    !external_builder_busy && !external_builder_done &&
    !abort_pending && !abort_request && !fault;

  cmac_usplus_0_rdma_external_packet_builder i_external_packet_builder (
    .clk(clk),
    .reset(reset || abort_pending || abort_request || fault),
    .start(external_builder_start),
    .busy(external_builder_busy),
    .done(external_builder_done),
    .header_has_reth(inflight_has_reth),
    .header_word0(fast_header_word0_next),
    .header_word1_prefix(fast_header_word1_next[47:0]),
    .payload_read_enable(payload_read_enable),
    .payload_read_address(payload_read_address),
    .payload_read_data(payload_read_data),
    .packet_write_enable(external_builder_write_enable),
    .packet_write_address(external_builder_write_address),
    .packet_write_data(external_builder_write_data),
    .packet_write_keep(external_builder_write_keep),
    .packet_write_last(external_builder_write_last),
    .packet_icrc(external_builder_icrc),
    .crc_header_data(external_crc_header_data),
    .crc_header_result(shared_crc50_result),
    .crc_body_seed(external_crc_body_seed),
    .crc_body_data(external_crc_body_data),
    .crc_body_result(shared_crc64_result),
    .crc_tail_seed(external_crc_tail6_seed),
    .crc_tail_data(external_crc_tail6_data),
    .crc_tail_result(shared_crc6_result),
    .crc_tail54_seed(external_crc_tail54_seed),
    .crc_tail54_data(external_crc_tail54_data),
    .crc_tail54_result(shared_crc54_result)
  );

  logic         rx_ack_pulse;
  logic [23:0]  rx_ack_psn;
  logic         rx_ack_is_nak;
  logic [7:0]   rx_ack_syndrome;
  logic         rx_invalid_packet_pulse;

  logic [15:0] inflight_udp_length;
  logic [15:0] inflight_ip_total_length;
  logic [15:0] inflight_icrc_data_bytes;
  logic [31:0] rx_overflow_source_seen;
  logic [31:0] rx_overflow_delta;
  logic [12:0] inflight_packet_bytes;
  logic [17:0] ip_checksum_sum_a;
  logic [17:0] ip_checksum_sum_b;
  logic [17:0] ip_checksum_sum_c;
  logic [7:0] tx_crc_byte;
  logic [7:0] packet_layout_build_byte;
  logic [7:0] packet_layout_crc_byte;

  always_comb begin
    cfg_request.remote_mac = cfg_remote_mac;
    cfg_request.local_ip = local_ip;
    cfg_request.remote_ip = cfg_remote_ip;
    cfg_request.remote_qpn = cfg_remote_qpn;
    cfg_request.initial_psn = cfg_local_psn;
    cfg_request.remote_base = cfg_remote_base;
    cfg_request.rkey = cfg_rkey;
    cfg_request.ring_size = cfg_ring_size;
    cfg_request.wr_size = cfg_wr_size;
    cfg_request.local_base = cfg_local_base;
    cfg_request.enable_immediate = cfg_enable_immediate;
    cfg_request.notify_interval_bytes = cfg_notify_interval_bytes;
    cfg_request.commit_remote_addr = cfg_commit_remote_addr;
    cfg_request.use_external_payload = cfg_use_external_payload;
  end

  always_comb begin
    packet_context.remote_mac = session_remote_mac;
    packet_context.local_ip = session_local_ip;
    packet_context.remote_ip = session_remote_ip;
    packet_context.local_qpn = session_local_qpn;
    packet_context.remote_qpn = session_remote_qpn;
    packet_context.rkey = session_rkey;
    packet_context.is_commit = inflight_is_commit;
    packet_context.opcode = inflight_opcode;
    packet_context.has_reth = inflight_has_reth;
    packet_context.has_immediate = inflight_has_immediate;
    packet_context.payload_length = inflight_payload_length;
    packet_context.work_length = inflight_work_length;
    packet_context.local_address = inflight_laddr;
    packet_context.remote_address = inflight_remote_address;
    packet_context.psn = inflight_psn;
    packet_context.benchmark_sequence = inflight_benchmark_sequence;
    packet_context.commit_total_bytes = inflight_commit_total_bytes;
    packet_context.commit_end_offset = inflight_commit_end_offset;
    packet_context.commit_interval_bytes = inflight_commit_interval_bytes;
    packet_context.commit_sequence = inflight_commit_sequence;
    packet_context.commit_final = inflight_commit_final;
    packet_context.ip_identification = inflight_ip_identification;
    packet_context.ip_checksum = inflight_ip_checksum;
    packet_context.udp_length = inflight_udp_length;
    packet_context.ip_total_length = inflight_ip_total_length;
  end

  cmac_usplus_0_rdma_packet_layout #(
    .LOCAL_MAC(LOCAL_MAC)
  ) i_packet_layout (
    .context(packet_context),
    .fast_mode(fast_mode_active),
    .build_region(tx_build_region),
    .build_region_offset(tx_build_region_offset),
    .crc_offset(crc_offset),
    .packet_icrc(packet_icrc),
    .build_byte(packet_layout_build_byte),
    .crc_byte(packet_layout_crc_byte),
    .fast_header_word0(fast_header_word0_next),
    .fast_header_word1(fast_header_word1_next),
    .fast_header_word0_masked(fast_header_word0_masked)
  );

  cmac_usplus_0_rdma_config_manager i_config_manager (
    .clk(clk),
    .reset(reset),
    .drained(drained),
    .request_valid(cfg_valid),
    .request_ready(cfg_ready),
    .request_done(cfg_done),
    .request_accepted(cfg_accepted),
    .request(cfg_request),
    .apply_valid(cfg_apply_valid),
    .active_config(active_config),
    .busy(cfg_busy),
    .reject_count(config_reject_count),
    .reject_reason(config_reject_reason)
  );

  cmac_usplus_0_rdma_ack_receiver #(
    .LOCAL_MAC(LOCAL_MAC),
    .LOCAL_QPN(LOCAL_QPN)
  ) i_ack_receiver (
    .clk(clk),
    .reset(reset),
    .clear_counters(cfg_apply_valid),
    .remote_mac(session_remote_mac),
    .local_ip(session_local_ip),
    .remote_ip(session_remote_ip),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tready(rx_axis_tready),
    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tkeep(rx_axis_tkeep),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tuser(rx_axis_tuser),
    .event_valid(rx_ack_pulse),
    .event_psn(rx_ack_psn),
    .event_syndrome(rx_ack_syndrome),
    .event_is_nak(rx_ack_is_nak),
    .invalid_packet_pulse(rx_invalid_packet_pulse),
    .icrc_drop_count(icrc_drop_count)
  );

  assign active = run_enable;
  assign external_payload_active = configured &&
                                   session_use_external_payload;
  assign payload_ingress_enable = external_payload_active && !fault &&
    !abort_pending && !abort_request && !stop_request &&
    !cfg_busy &&
    !(cfg_valid && cfg_ready) && (!stop_requested || logical_wr_active);
  assign credit_stalled = configured && run_enable && !pending_commit &&
                          !inflight_valid && (tx_state == TX_IDLE) &&
                          (available_credit_bytes < 32'd4096);
  assign stopping = stop_requested ||
                    (configured && !run_enable &&
                     (pending_commit ||
                      (inflight_valid && inflight_is_commit && inflight_commit_final)));
  assign transport_idle = !run_enable && !stop_requested && !abort_pending &&
                          !logical_wr_active && !pending_commit &&
                          !inflight_valid && (tx_state == TX_IDLE);
  assign drained = transport_idle && payload_buffer_empty;
  assign debug_state = tx_state;
  assign current_psn = inflight_valid ? inflight_psn : session_tx_psn;
  assign rx_overflow_delta = rx_overflow_source_count - rx_overflow_source_seen;
  assign fast_retryable_commit_rnr = fast_mode_active && inflight_valid &&
    inflight_is_commit && ((tx_state == TX_SEND) || (tx_state == TX_WAIT_ACK)) &&
    rx_ack_is_nak && (rx_ack_syndrome[7:5] == 3'b001) &&
    (rx_ack_psn == inflight_psn);
  assign fast_retryable_commit_sequence = fast_mode_active && inflight_valid &&
    inflight_is_commit && ((tx_state == TX_SEND) || (tx_state == TX_WAIT_ACK)) &&
    rx_ack_is_nak && (rx_ack_syndrome == 8'h60) &&
    (rx_ack_psn == inflight_psn);
  assign fast_nak_observed = fast_mode_active && rx_ack_pulse &&
    rx_ack_is_nak && !fast_retryable_commit_rnr &&
    !fast_retryable_commit_sequence && !fault &&
    (run_enable || inflight_valid || stop_requested || pending_commit);
  assign fast_nak_event = fast_nak_observed && !fast_nak_pending;
  assign fast_nak_blocks_credit = fast_mode_active &&
                                  rx_ack_pulse && rx_ack_is_nak;

  assign credit_release_valid =
    (consumed_bytes_sampled > applied_consumed_bytes) &&
    (consumed_bytes_sampled <= published_bytes) &&
    (consumed_bytes_sampled[11:0] == 12'd0);
  assign credit_release_delta = consumed_bytes_sampled[31:0] -
                                applied_consumed_bytes[31:0];
  assign credit_reserve_bytes =
    !abort_pending && !fast_nak_pending && !fast_nak_blocks_credit && !fault &&
    !replay_active && (tx_state == TX_SELECT_LENGTH) &&
    (select_work_length != 32'd0) ?
      ((select_work_length > 32'd4096) ? 32'd4096 : select_work_length) : 32'd0;
  assign credit_sum = {1'b0, available_credit_bytes} +
                      {1'b0, pending_credit_release_bytes};
  assign credit_after_reserve = (credit_sum < {1'b0, credit_reserve_bytes}) ?
                                33'd0 :
                                credit_sum - {1'b0, credit_reserve_bytes};

  // Sequence recovery is deliberately staged.  The live PSN arithmetic used
  // to feed the scheduler's large recovery mux in one cycle; registering the
  // packet counts and then the byte offsets keeps that path bounded.  A newer
  // NAK invalidates both stages, so the final observed PSN remains authoritative.
  always_ff @(posedge clk) begin
    if (reset || cfg_apply_valid || abort_pending || abort_request || fault ||
        !fast_nak_pending || fast_nak_observed) begin
      recovery_counts_valid <= 1'b0;
      recovery_snapshot_valid <= 1'b0;
    end else if (tx_state != TX_SEND) begin
      if (!recovery_counts_valid) begin
        recovery_packet_index <=
          fast_nak_pending_psn - message_checkpoint_psn;
        recovery_sent_packets <= session_tx_psn - message_checkpoint_psn +
          (replay_active ? {4'd0, replay_remaining_bytes[31:12]} : 24'd0);
        recovery_counts_valid <= 1'b1;
        recovery_snapshot_valid <= 1'b0;
      end else if (!recovery_snapshot_valid) begin
        recovery_byte_offset <= {recovery_packet_index[19:0], 12'd0};
        recovery_replay_bytes <= {
          recovery_sent_packets[19:0] - recovery_packet_index[19:0], 12'd0
        };
        recovery_snapshot_valid <= 1'b1;
      end
    end
  end

  // Credit is reserved before a data packet enters the transmit pipeline.
  // CONSUME carries an absolute counter, while the scheduler only sees this
  // bounded 32-bit balance, keeping 64-bit arithmetic off the packet path.
  always_ff @(posedge clk) begin
    if (reset) begin
      available_credit_bytes <= 32'd0;
      applied_consumed_bytes <= 64'd0;
      pending_credit_release_bytes <= 32'd0;
      consumed_bytes_sampled <= 64'd0;
    end else if (cfg_apply_valid) begin
      consumed_bytes_sampled <= 64'd0;
      available_credit_bytes <= active_config.ring_size;
      applied_consumed_bytes <= 64'd0;
      pending_credit_release_bytes <= 32'd0;
    end else begin
      consumed_bytes_sampled <= consumed_bytes;
      pending_credit_release_bytes <= 32'd0;
      if (credit_release_valid) begin
        applied_consumed_bytes <= consumed_bytes_sampled;
        pending_credit_release_bytes <= credit_release_delta[31:0];
      end

      if (credit_after_reserve > {1'b0, session_ring_size})
        available_credit_bytes <= session_ring_size;
      else
        available_credit_bytes <= credit_after_reserve[31:0];
    end
  end

  function automatic logic [31:0] sat_inc32(input logic [31:0] value);
    begin
      sat_inc32 = (&value) ? value : value + 32'd1;
    end
  endfunction

  function automatic logic [31:0] min32(
    input logic [31:0] lhs,
    input logic [31:0] rhs
  );
    begin
      min32 = (lhs < rhs) ? lhs : rhs;
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

  function automatic logic [31:0] crc32_masked_word(
    input logic [31:0] seed,
    input logic [511:0] data,
    input logic [63:0] valid_bytes
  );
    integer byte_index;
    logic [31:0] crc;
    begin
      crc = seed;
      for (byte_index = 0; byte_index < 64; byte_index = byte_index + 1) begin
        if (valid_bytes[byte_index]) begin
          crc = crc32_byte(crc, data[byte_index * 8 +: 8]);
        end
      end
      crc32_masked_word = crc;
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

  // Match the UDP benchmark's 24-byte RFSO header at the beginning of every
  // maximum-PMTU data packet. The remaining bytes retain the deterministic
  // local-address pattern used for retransmission and debug.
  function automatic logic [7:0] data_payload_byte(input integer payload_offset);
    logic [63:0] byte_address;
    logic [63:0] word_value;
    begin
      if (payload_offset < 4) begin
        data_payload_byte = be32_byte(BENCHMARK_MAGIC, payload_offset);
      end else if (payload_offset < 8) begin
        data_payload_byte = be32_byte(inflight_benchmark_sequence,
                                      payload_offset - 4);
      end else if (payload_offset < 10) begin
        data_payload_byte = be16_byte(BENCHMARK_VERSION, payload_offset - 8);
      end else if (payload_offset < 12) begin
        data_payload_byte = be16_byte(BENCHMARK_HEADER_LENGTH,
                                      payload_offset - 10);
      end else if (payload_offset < 16) begin
        data_payload_byte = be32_byte(inflight_payload_length,
                                      payload_offset - 12);
      end else if (payload_offset < BENCHMARK_HEADER_LENGTH) begin
        data_payload_byte = 8'd0;
      end else if (fast_mode_active) begin
        // FAST mode only uses the RFSO header for host-side continuity
        // checking.  A constant fill removes a 64-bit add from every beat;
        // the reliable control path still retains its address pattern.
        data_payload_byte = 8'd0;
      end else begin
        byte_address = inflight_laddr + {32'd0, payload_offset};
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
      source_port = 16'hC000 | {2'b00, session_local_qpn};
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
        8: bth_byte = (!fast_mode_active || inflight_is_commit) ? 8'h80 : 8'h00;
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
    integer icrc_payload_start;
    integer icrc_immediate_start;
    begin
      icrc_immediate_start = 20 + 8 + 12 + (inflight_has_reth ? 16 : 0);
      icrc_payload_start = icrc_immediate_start +
                           (inflight_has_immediate ? 4 : 0);
      if (index < 20) begin
        icrc_actual_byte = ipv4_byte(index);
      end else if (index < 28) begin
        icrc_actual_byte = udp_byte(index - 20);
      end else if (index < 40) begin
        icrc_actual_byte = bth_byte(index - 28);
      end else if (inflight_has_reth && (index < 56)) begin
        icrc_actual_byte = reth_byte(index - 40);
      end else if (inflight_has_immediate &&
                   (index < (icrc_immediate_start + 4))) begin
        icrc_actual_byte = immediate_byte(index - icrc_immediate_start);
      end else begin
        icrc_actual_byte = payload_byte(index - icrc_payload_start);
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

  function automatic logic [7:0] tx_frame_byte(input integer frame_offset);
    begin
      if (frame_offset < 6) begin
        tx_frame_byte = mac_byte(session_remote_mac, frame_offset);
      end else if (frame_offset < 12) begin
        tx_frame_byte = mac_byte(LOCAL_MAC, frame_offset - 6);
      end else if (frame_offset < 14) begin
        tx_frame_byte = (frame_offset == 12) ? 8'h08 : 8'h00;
      end else begin
        tx_frame_byte = icrc_actual_byte(frame_offset - 14);
      end
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

  function automatic logic [5:0] fast_zero_target(input logic [6:0] last_beat);
    begin
      // The counter is intentionally six bits: a 4096-byte payload has at
      // most 64 full zero beats before the final ICRC beat.
      fast_zero_target = 6'(last_beat - 7'd2);
    end
  endfunction

  assign selected_work_length = select_has_reth ?
    min32(min32(select_logical_remaining, select_ring_remaining),
          min32(select_notification_remaining, select_credit_remaining)) :
    min32(select_physical_remaining, select_credit_remaining);
  assign selected_payload_length = min32(select_work_length, 32'd4096);
  assign selected_opcode = select_has_reth ?
    ((select_work_length <= 32'd4096) ?
      RC_RDMA_WRITE_ONLY : RC_RDMA_WRITE_FIRST) :
    ((select_work_length <= 32'd4096) ?
      RC_RDMA_WRITE_LAST : RC_RDMA_WRITE_MIDDLE);

  assign prepared_transport_header_bytes = 16'd12 +
    (inflight_has_reth ? 16'd16 : 16'd0) +
    (inflight_has_immediate ? 16'd4 : 16'd0);
  assign prepared_udp_length = 16'd8 + prepared_transport_header_bytes +
                               inflight_payload_length[15:0] + 16'd4;
  assign prepared_ip_total_length = 16'd20 + prepared_udp_length;
  assign checksum_sum = {2'd0, ip_checksum_sum_a} +
                        {2'd0, ip_checksum_sum_b} +
                        {2'd0, ip_checksum_sum_c};
  assign checksum_fold = {1'b0, checksum_sum[15:0]} +
                         {13'd0, checksum_sum[19:16]};
  assign checksum_refold = checksum_fold[15:0] +
                           {15'd0, checksum_fold[16]};
  assign packet_last_offset = inflight_packet_bytes - 13'd1;
  assign last_valid_bytes = {1'b0, packet_last_offset[5:0]} + 7'd1;
  assign next_crc_state = crc32_byte(crc_state, tx_crc_byte);

  assign immediate_start = 16'd54 + (inflight_has_reth ? 16'd16 : 16'd0);
  assign payload_start = immediate_start +
                         (inflight_has_immediate ? 16'd4 : 16'd0);
  assign icrc_start = 16'd14 + inflight_icrc_data_bytes;
  assign next_tx_build_beat = tx_build_beat + 7'd1;

  always_comb begin
    completed_tx_build_word = tx_build_word;
    completed_tx_build_word[tx_build_byte_index * 8 +: 8] = tx_build_byte;
  end

  always_comb begin
    prepared_fast_last_word = 512'd0;
    if (inflight_has_reth) begin
      prepared_fast_last_word[55:48] = ~fast_crc_zero6_next[7:0];
      prepared_fast_last_word[63:56] = ~fast_crc_zero6_next[15:8];
      prepared_fast_last_word[71:64] = ~fast_crc_zero6_next[23:16];
      prepared_fast_last_word[79:72] = ~fast_crc_zero6_next[31:24];
      prepared_fast_last_keep = 64'h0000_0000_0000_03FF;
    end else begin
      prepared_fast_last_word[439:432] = ~fast_crc_zero54_next[7:0];
      prepared_fast_last_word[447:440] = ~fast_crc_zero54_next[15:8];
      prepared_fast_last_word[455:448] = ~fast_crc_zero54_next[23:16];
      prepared_fast_last_word[463:456] = ~fast_crc_zero54_next[31:24];
      prepared_fast_last_keep = 64'h03FF_FFFF_FFFF_FFFF;
    end
  end

  always_comb begin
    post_ack_ring_offset = ring_offset + inflight_payload_length;
    if (post_ack_ring_offset >= session_ring_size)
      post_ack_ring_offset = post_ack_ring_offset - session_ring_size;
  end
  assign post_ack_logical_remaining =
    logical_wr_remaining - inflight_payload_length;
  assign completed_interval_bytes =
    bytes_since_commit + inflight_payload_length;
  assign data_message_done = (inflight_remaining_after == 32'd0);
  assign final_logical_packet = (post_ack_logical_remaining == 32'd0);
  assign notification_due = (session_notify_interval_bytes != 32'd0) &&
                            (completed_interval_bytes ==
                             session_notify_interval_bytes);
  assign stop_after_ack = stop_requested || stop_request || !run_enable;

  // The streaming benchmark has exactly two header layouts: the first packet
  // in a message carries a RETH, and every following 4 KiB packet does not.
  // Explicit fixed byte positions prevent a variable offset decoder from
  // being replicated across all 512 output bits.
  always_comb begin : build_fast_headers
    logic [15:0] source_port;

    source_port = 16'hC000 | {2'b00, session_local_qpn};
    fast_header_word0_next = 512'd0;
    fast_header_word1_next = 512'd0;

    fast_header_word0_next[47:0] = {
      session_remote_mac[7:0], session_remote_mac[15:8],
      session_remote_mac[23:16], session_remote_mac[31:24],
      session_remote_mac[39:32], session_remote_mac[47:40]
    };
    fast_header_word0_next[95:48] = {
      LOCAL_MAC[7:0], LOCAL_MAC[15:8], LOCAL_MAC[23:16],
      LOCAL_MAC[31:24], LOCAL_MAC[39:32], LOCAL_MAC[47:40]
    };
    fast_header_word0_next[103:96] = 8'h08;
    fast_header_word0_next[111:104] = 8'h00;
    fast_header_word0_next[119:112] = 8'h45;
    fast_header_word0_next[127:120] = 8'h00;
    fast_header_word0_next[135:128] = inflight_ip_total_length[15:8];
    fast_header_word0_next[143:136] = inflight_ip_total_length[7:0];
    fast_header_word0_next[151:144] = inflight_ip_identification[15:8];
    fast_header_word0_next[159:152] = inflight_ip_identification[7:0];
    fast_header_word0_next[167:160] = 8'h40;
    fast_header_word0_next[175:168] = 8'h00;
    fast_header_word0_next[183:176] = 8'd64;
    fast_header_word0_next[191:184] = 8'd17;
    fast_header_word0_next[199:192] = inflight_ip_checksum[15:8];
    fast_header_word0_next[207:200] = inflight_ip_checksum[7:0];
    fast_header_word0_next[239:208] = {
      session_local_ip[7:0], session_local_ip[15:8],
      session_local_ip[23:16], session_local_ip[31:24]
    };
    fast_header_word0_next[271:240] = {
      session_remote_ip[7:0], session_remote_ip[15:8],
      session_remote_ip[23:16], session_remote_ip[31:24]
    };
    fast_header_word0_next[279:272] = source_port[15:8];
    fast_header_word0_next[287:280] = source_port[7:0];
    fast_header_word0_next[295:288] = ROCE_UDP_PORT[15:8];
    fast_header_word0_next[303:296] = ROCE_UDP_PORT[7:0];
    fast_header_word0_next[311:304] = inflight_udp_length[15:8];
    fast_header_word0_next[319:312] = inflight_udp_length[7:0];
    fast_header_word0_next[335:320] = 16'd0;
    fast_header_word0_next[343:336] = inflight_opcode;
    fast_header_word0_next[351:344] = 8'h00;
    fast_header_word0_next[367:352] = 16'hFFFF;
    fast_header_word0_next[375:368] = 8'h00;
    fast_header_word0_next[399:376] = {
      session_remote_qpn[7:0], session_remote_qpn[15:8],
      session_remote_qpn[23:16]
    };
    fast_header_word0_next[407:400] =
      (fast_mode_active && !inflight_is_commit) ? 8'h00 : 8'h80;
    fast_header_word0_next[431:408] = {
      inflight_psn[7:0], inflight_psn[15:8], inflight_psn[23:16]
    };

    if (inflight_has_reth) begin
      fast_header_word0_next[447:432] = 16'd0;
      fast_header_word0_next[495:448] = {
        inflight_remote_address[7:0], inflight_remote_address[15:8],
        inflight_remote_address[23:16], inflight_remote_address[31:24],
        inflight_remote_address[39:32], inflight_remote_address[47:40]
      };
      fast_header_word0_next[511:496] = {
        session_rkey[23:16], session_rkey[31:24]
      };
      fast_header_word1_next[15:0] = {
        session_rkey[7:0], session_rkey[15:8]
      };
      fast_header_word1_next[47:16] = {
        inflight_work_length[7:0], inflight_work_length[15:8],
        inflight_work_length[23:16], inflight_work_length[31:24]
      };
      fast_header_word1_next[79:48] = 32'h4F534652;
      fast_header_word1_next[111:80] = {
        inflight_benchmark_sequence[7:0], inflight_benchmark_sequence[15:8],
        inflight_benchmark_sequence[23:16], inflight_benchmark_sequence[31:24]
      };
      fast_header_word1_next[127:112] = 16'h0100;
      fast_header_word1_next[143:128] = 16'h1800;
      fast_header_word1_next[175:144] = {
        inflight_payload_length[7:0], inflight_payload_length[15:8],
        inflight_payload_length[23:16], inflight_payload_length[31:24]
      };
    end else begin
      fast_header_word0_next[463:432] = 32'h4F534652;
      fast_header_word0_next[495:464] = {
        inflight_benchmark_sequence[7:0], inflight_benchmark_sequence[15:8],
        inflight_benchmark_sequence[23:16], inflight_benchmark_sequence[31:24]
      };
      fast_header_word0_next[511:496] = 16'h0100;
      fast_header_word1_next[15:0] = 16'h1800;
      fast_header_word1_next[47:16] = {
        inflight_payload_length[7:0], inflight_payload_length[15:8],
        inflight_payload_length[23:16], inflight_payload_length[31:24]
      };
    end
  end

  always_comb begin
    fast_header_word0_masked = fast_header_word0[511:112];
    fast_header_word0_masked[15:8] = 8'hFF;
    fast_header_word0_masked[71:64] = 8'hFF;
    fast_header_word0_masked[87:80] = 8'hFF;
    fast_header_word0_masked[95:88] = 8'hFF;
    fast_header_word0_masked[215:208] = 8'hFF;
    fast_header_word0_masked[223:216] = 8'hFF;
    fast_header_word0_masked[263:256] = 8'hFF;
  end

  always_comb begin : select_fast_axis_beat
    fast_axis_word = 512'd0;
    fast_axis_keep = 64'hFFFF_FFFF_FFFF_FFFF;
    fast_axis_last = 1'b0;
    case (fast_tx_beat)
      7'd0: fast_axis_word = fast_header_word0;
      7'd1: fast_axis_word = fast_header_word1;
      default: begin
        if (fast_icrc_valid && (fast_tx_beat > fast_penultimate_beat)) begin
          fast_axis_word = fast_last_word;
          fast_axis_keep = fast_last_keep;
          fast_axis_last = 1'b1;
        end
      end
    endcase
  end

  assign tx_axis_tvalid = (tx_state == TX_SEND) &&
                          (!fast_data_path ||
                           (fast_tx_beat <= fast_penultimate_beat) ||
                           fast_icrc_valid);
  assign tx_axis_tdata = fast_data_path ? fast_axis_word : tx_send_word;
  assign tx_axis_tkeep = fast_data_path ? fast_axis_keep : tx_send_keep;
  assign tx_axis_tlast = fast_data_path ? fast_axis_last : tx_send_last;
  assign tx_axis_tuser = 1'b0;

  assign tx_packet_write_enable = external_builder_write_enable ||
                                  (tx_state == TX_BUILD_STORE);
  assign tx_packet_write_address = external_builder_write_enable ?
                                   external_builder_write_address :
                                   tx_build_beat;
  assign tx_packet_write_data = external_builder_write_enable ?
    {external_builder_write_last, external_builder_write_keep,
     external_builder_write_data} :
    {(tx_build_beat == tx_packet_last_beat), tx_build_keep, tx_build_word};
  assign tx_packet_read_enable = (tx_state == TX_LOAD);

  cmac_usplus_0_rdma_replay_buffer #(
    .DATA_WIDTH(TX_PACKET_BUFFER_WIDTH),
    .DEPTH(TX_PACKET_BUFFER_DEPTH),
    .ADDRESS_WIDTH(7)
  ) i_replay_buffer (
    .clk(clk),
    .reset(reset),
    .write_enable(tx_packet_write_enable),
    .write_address(tx_packet_write_address),
    .write_data(tx_packet_write_data),
    .read_enable(tx_packet_read_enable),
    .read_address(tx_packet_read_address),
    .read_data(tx_packet_read_data)
  );

  // The scheduler keeps a logical WR separate from each contiguous physical
  // RDMA message. A physical message ends at a ring or notification boundary
  // so its next segment always starts with a fresh RETH.
  always_ff @(posedge clk) begin
    if (reset) begin
      tx_state <= TX_IDLE;
      run_enable <= 1'b0;
      stop_requested <= 1'b0;
      abort_pending <= 1'b0;
      inflight_valid <= 1'b0;
      inflight_issued_accounted <= 1'b0;
      retry_count <= 4'd0;
      timeout_count <= 32'd0;
      rnr_wait_cycles <= 32'd1;
      response_pending <= 1'b0;
      response_pending_psn <= 24'd0;
      response_pending_syndrome <= 8'd0;
      fast_nak_pending <= 1'b0;
      fast_nak_pending_syndrome <= 8'd0;
      fast_nak_pending_psn <= 24'd0;
      sequence_recovery_quiet_count <= 32'd0;
      configured <= 1'b0;
      fault <= 1'b0;
      fault_reason <= 32'd0;
      final_commit_acked <= 1'b0;
      session_tx_psn <= 24'd0;
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
      data_packet_sequence <= 32'd0;
      message_checkpoint_valid <= 1'b0;
      message_checkpoint_psn <= 24'd0;
      message_checkpoint_ring_offset <= 32'd0;
      message_checkpoint_local_address <= 64'd0;
      message_checkpoint_data_sequence <= 32'd0;
      message_checkpoint_interval_bytes <= 32'd0;
      message_checkpoint_logical_remaining <= 32'd0;
      message_checkpoint_work_length <= 32'd0;
      message_recovery_attempts <= '0;
      replay_remaining_bytes <= 32'd0;
      replay_active <= 1'b0;
      replay_message_start <= 1'b0;
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
      inflight_benchmark_sequence <= 32'd0;
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
      tx_build_region <= RDMA_PACKET_DEST_MAC;
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
      payload_packet_release <= 1'b0;
      payload_flush <= 1'b0;
      fast_header_word0 <= 512'd0;
      fast_header_word1 <= 512'd0;
      fast_crc_after_header0 <= ICRC_INIT;
      fast_crc_ahead_state <= ICRC_INIT;
      fast_zero_full_count <= 6'd0;
      fast_zero_full_target <= 6'd0;
      fast_tx_beat <= 7'd0;
      fast_penultimate_beat <= 7'd0;
      fast_last_keep <= 64'd0;
      fast_icrc_valid <= 1'b0;
      select_has_reth <= 1'b0;
      select_logical_remaining <= 32'd0;
      select_physical_remaining <= 32'd0;
      select_ring_remaining <= 32'd0;
      select_notification_remaining <= 32'd0;
      select_credit_remaining <= 32'd0;
      select_laddr <= 64'd0;
      select_remote_address <= 48'd0;
      select_work_length <= 32'd0;
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
      last_nak_syndrome <= 8'd0;
      last_nak_psn <= 24'd0;
      sequence_recovery_count <= 32'd0;
      inflight_udp_length <= 16'd0;
      inflight_ip_total_length <= 16'd0;
      inflight_icrc_data_bytes <= 16'd0;
      inflight_packet_bytes <= 13'd0;
      ip_checksum_sum_a <= 18'd0;
      ip_checksum_sum_b <= 18'd0;
      ip_checksum_sum_c <= 18'd0;
      tx_crc_byte <= 8'd0;
    end else begin
      payload_packet_release <= 1'b0;
      payload_flush <= 1'b0;
      rx_overflow_source_seen <= rx_overflow_source_count;

      if (rx_overflow_delta != 32'd0) begin
        rx_overflow_count <= sat_add32(rx_overflow_count, rx_overflow_delta);
      end
      if (rx_invalid_packet_pulse) invalid_psn_count <= sat_inc32(invalid_psn_count);

      if (cfg_apply_valid) begin
          configured <= 1'b1;
          final_commit_acked <= 1'b0;
          fault <= 1'b0;
          fault_reason <= 32'd0;
          run_enable <= 1'b0;
          stop_requested <= 1'b0;
          abort_pending <= 1'b0;
          inflight_valid <= 1'b0;
          response_pending <= 1'b0;
          fast_nak_pending <= 1'b0;
          fast_nak_pending_syndrome <= 8'd0;
          fast_nak_pending_psn <= 24'd0;
          sequence_recovery_quiet_count <= 32'd0;
          tx_state <= TX_IDLE;
          fast_tx_beat <= 7'd0;
          fast_crc_after_header0 <= ICRC_INIT;
          fast_crc_ahead_state <= ICRC_INIT;
          fast_zero_full_count <= 6'd0;
          fast_icrc_valid <= 1'b0;
          session_tx_psn <= active_config.initial_psn;
          local_byte_address <= active_config.local_base;
          ring_offset <= 32'd0;
          logical_wr_active <= 1'b0;
          logical_wr_remaining <= 32'd0;
          physical_message_remaining <= 32'd0;
          bytes_since_commit <= 32'd0;
          select_credit_remaining <= 32'd0;
          pending_commit <= 1'b0;
          pending_commit_total_bytes <= 64'd0;
          pending_commit_end_offset <= 32'd0;
          pending_commit_interval_bytes <= 32'd0;
          pending_commit_sequence <= 64'd0;
          pending_commit_final <= 1'b0;
          published_bytes <= 64'd0;
          producer_sequence <= 64'd0;
          next_ip_identification <= 16'd0;
          data_packet_sequence <= 32'd0;
          message_checkpoint_valid <= 1'b0;
          message_checkpoint_psn <= 24'd0;
          message_checkpoint_ring_offset <= 32'd0;
          message_checkpoint_local_address <= 64'd0;
          message_checkpoint_data_sequence <= 32'd0;
          message_checkpoint_interval_bytes <= 32'd0;
          message_checkpoint_logical_remaining <= 32'd0;
          message_checkpoint_work_length <= 32'd0;
          message_recovery_attempts <= '0;
          replay_remaining_bytes <= 32'd0;
          replay_active <= 1'b0;
          replay_message_start <= 1'b0;
          retry_count <= 4'd0;
          timeout_count <= 32'd0;
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
          last_nak_syndrome <= 8'd0;
          last_nak_psn <= 24'd0;
          sequence_recovery_count <= 32'd0;
          if (payload_buffer_empty) payload_flush <= 1'b1;
      end

      if (start_request && configured && transport_idle && !fault) begin
        run_enable <= 1'b1;
        stop_requested <= 1'b0;
      end
      if (stop_request && run_enable) begin
        run_enable <= 1'b0;
        stop_requested <= 1'b1;
      end
      if (abort_request) begin
        run_enable <= 1'b0;
        stop_requested <= 1'b0;
        abort_pending <= 1'b1;
        payload_flush <= 1'b1;
      end

      // Responses can complete their CRC check while a replay is on the wire.
      // Queue one response and consume it only after TLAST has transferred, so
      // neither a matching delayed ACK nor a wrong-PSN response can truncate
      // or duplicate an AXIS frame.
      if (rx_ack_pulse && inflight_valid && !response_pending &&
          (!fast_mode_active ||
           (inflight_is_commit &&
             ((!rx_ack_is_nak && (rx_ack_psn == inflight_psn)) ||
             fast_retryable_commit_rnr ||
             fast_retryable_commit_sequence))) &&
          ((tx_state == TX_SEND) || (tx_state == TX_WAIT_ACK))) begin
        response_pending <= 1'b1;
        response_pending_psn <= rx_ack_psn;
        response_pending_syndrome <= rx_ack_syndrome;
      end

      // Hold every fast-path NAK until the current AXIS frame is complete.
      // The scheduler then either rewinds a bounded message checkpoint or
      // quiesces the session without truncating the frame on the wire.
      if (fast_nak_event) begin
        fast_nak_pending <= 1'b1;
        fast_nak_pending_syndrome <= rx_ack_syndrome;
        fast_nak_pending_psn <= rx_ack_psn;
        sequence_recovery_quiet_count <= 32'd0;
        last_nak_syndrome <= rx_ack_syndrome;
        last_nak_psn <= rx_ack_psn;
        nak_count <= sat_inc32(nak_count);
      end else if (fast_nak_observed && fast_nak_pending) begin
        // Coalesce NAKs caused by packets that were already buffered past the
        // gap. The final observed PSN is authoritative when recovery starts.
        fast_nak_pending_syndrome <= rx_ack_syndrome;
        fast_nak_pending_psn <= rx_ack_psn;
        sequence_recovery_quiet_count <= 32'd0;
        last_nak_syndrome <= rx_ack_syndrome;
        last_nak_psn <= rx_ack_psn;
      end

      if (abort_pending && (tx_state != TX_SEND)) begin
        abort_pending <= 1'b0;
        configured <= 1'b0;
        fault <= 1'b1;
        if (!fault) fault_reason <= 32'h8000_0001;
        run_enable <= 1'b0;
        stop_requested <= 1'b0;
        logical_wr_active <= 1'b0;
        logical_wr_remaining <= 32'd0;
        physical_message_remaining <= 32'd0;
        pending_commit <= 1'b0;
        pending_commit_final <= 1'b0;
        inflight_valid <= 1'b0;
        response_pending <= 1'b0;
        fast_nak_pending <= 1'b0;
        replay_active <= 1'b0;
        replay_remaining_bytes <= 32'd0;
        replay_message_start <= 1'b0;
        sequence_recovery_quiet_count <= 32'd0;
        message_checkpoint_valid <= 1'b0;
        payload_flush <= 1'b1;
        tx_state <= TX_IDLE;
      end else if (fast_nak_pending && (tx_state != TX_SEND)) begin
        // A NAK can arrive while an earlier replay is still below the original
        // transmit high-water mark.  Preserve that unsent replay tail so a
        // nested rewind cannot turn it into newly issued data.
        if (!recovery_snapshot_valid || fast_nak_observed) begin
          sequence_recovery_quiet_count <= 32'd0;
        end else if ((fast_nak_pending_syndrome == 8'h60) &&
            message_checkpoint_valid &&
            (recovery_packet_index <
             {4'd0, message_checkpoint_work_length[31:12]}) &&
            (recovery_packet_index < recovery_sent_packets) &&
            (recovery_sent_packets <=
             {4'd0, message_checkpoint_work_length[31:12]}) &&
                (message_recovery_attempts < MAX_SEQUENCE_RECOVERIES)) begin
          if (!tx_path_idle || fast_nak_observed) begin
            sequence_recovery_quiet_count <= 32'd0;
          end else if (sequence_recovery_quiet_count <
                       (SEQUENCE_RECOVERY_QUIET_LIMIT - 1)) begin
            sequence_recovery_quiet_count <=
              sequence_recovery_quiet_count + 32'd1;
          end else begin
            // Only a recovery that passed the same qualification checks used
            // by the replay path is controlled by the VIO switch.  Invalid,
            // out-of-window, and exhausted-recovery NAKs fall through to the
            // original diagnostic reasons below.
            if (!retransmission_enable) begin
              fast_nak_pending <= 1'b0;
              sequence_recovery_quiet_count <= 32'd0;
              fault <= 1'b1;
              fault_reason <= FAULT_RETRANSMISSION_DISABLED;
              abort_pending <= 1'b1;
              run_enable <= 1'b0;
              tx_state <= TX_IDLE;
            end else begin
              fast_nak_pending <= 1'b0;
              sequence_recovery_quiet_count <= 32'd0;
              session_tx_psn <= fast_nak_pending_psn;
              ring_offset <= message_checkpoint_ring_offset + recovery_byte_offset;
              local_byte_address <=
                message_checkpoint_local_address +
                {32'd0, recovery_byte_offset};
              data_packet_sequence <=
                message_checkpoint_data_sequence +
                {8'd0, recovery_packet_index};
              bytes_since_commit <=
                message_checkpoint_interval_bytes + recovery_byte_offset;
              logical_wr_active <= 1'b1;
              logical_wr_remaining <=
                message_checkpoint_logical_remaining - recovery_byte_offset;
              physical_message_remaining <= (recovery_byte_offset == 32'd0) ?
                32'd0 : message_checkpoint_work_length - recovery_byte_offset;
              pending_commit <= 1'b0;
              pending_commit_final <= 1'b0;
              inflight_valid <= 1'b0;
              inflight_issued_accounted <= 1'b0;
              response_pending <= 1'b0;
              retry_count <= 4'd0;
              timeout_count <= 32'd0;
              replay_active <= 1'b1;
              replay_remaining_bytes <= recovery_replay_bytes;
              replay_message_start <= recovery_byte_offset == 32'd0;
              message_recovery_attempts <= message_recovery_attempts + 1'b1;
              sequence_recovery_count <= sat_inc32(sequence_recovery_count);
              retrans_count <= sat_inc32(retrans_count);
              fast_tx_beat <= 7'd0;
              fast_icrc_valid <= 1'b0;
              tx_state <= TX_IDLE;
            end
          end
        end else begin
          fast_nak_pending <= 1'b0;
          sequence_recovery_quiet_count <= 32'd0;
          configured <= 1'b0;
          fault <= 1'b1;
          if (fast_nak_pending_syndrome != 8'h60)
            fault_reason <= 32'h0000_0103;
          else if (message_recovery_attempts >= MAX_SEQUENCE_RECOVERIES)
            fault_reason <= 32'h0000_0102;
          else
            fault_reason <= 32'h0000_0101;
          run_enable <= 1'b0;
          stop_requested <= 1'b0;
          logical_wr_active <= 1'b0;
          logical_wr_remaining <= 32'd0;
          physical_message_remaining <= 32'd0;
          pending_commit <= 1'b0;
          pending_commit_final <= 1'b0;
          inflight_valid <= 1'b0;
          response_pending <= 1'b0;
          replay_active <= 1'b0;
          replay_remaining_bytes <= 32'd0;
          replay_message_start <= 1'b0;
          message_checkpoint_valid <= 1'b0;
          payload_flush <= 1'b1;
          tx_state <= TX_IDLE;
        end
      end else begin
        case (tx_state)
        TX_IDLE: begin
          timeout_count <= 32'd0;
          if (!inflight_valid && !fault) begin
            if (stop_requested && !pending_commit && !logical_wr_active &&
                (physical_message_remaining == 32'd0) &&
                payload_buffer_empty) begin
              // A stop is complete only after a final release record is ACKed.
              // Publish even when the last periodic record covered every byte;
              // the zero-byte final marker lets the host tear down its MR/QP.
              pending_commit <= 1'b1;
              pending_commit_total_bytes <= fast_mode_active ? issued_bytes : acked_bytes;
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
              inflight_psn <= session_tx_psn;
              inflight_benchmark_sequence <= 32'd0;
              inflight_commit_total_bytes <= pending_commit_total_bytes;
              inflight_commit_end_offset <= pending_commit_end_offset;
              inflight_commit_interval_bytes <= pending_commit_interval_bytes;
              inflight_commit_sequence <= pending_commit_sequence;
              inflight_commit_final <= pending_commit_final;
              inflight_ip_identification <= next_ip_identification;
              next_ip_identification <= next_ip_identification + 16'd1;
              tx_state <= TX_PREPARE;
            end else if (configured &&
                         (replay_active ||
                          (available_credit_bytes >= 32'd4096)) &&
                         (logical_wr_active || (run_enable && !stop_request) ||
                          (session_use_external_payload &&
                           (stop_requested || stop_request) &&
                           !payload_buffer_empty)) &&
                         (!session_use_external_payload ||
                          (payload_packet_valid && !payload_packet_release &&
                           !payload_flush))) begin
              select_has_reth <= (physical_message_remaining == 32'd0) ||
                                 replay_message_start;
              select_physical_remaining <= physical_message_remaining;
              select_laddr <= local_byte_address;
              select_remote_address <= session_remote_base +
                                       {16'd0, ring_offset};
              select_credit_remaining <= replay_active ?
                                         32'hFFFF_FFFF :
                                         available_credit_bytes;
              if ((physical_message_remaining == 32'd0) ||
                  replay_message_start) begin
                if (replay_message_start) begin
                  select_logical_remaining <= message_checkpoint_work_length;
                  select_ring_remaining <= message_checkpoint_work_length;
                  select_notification_remaining <= message_checkpoint_work_length;
                end else begin
                  select_logical_remaining <= logical_wr_active ?
                                              logical_wr_remaining : session_wr_size;
                  select_ring_remaining <= session_ring_size - ring_offset;
                  select_notification_remaining <=
                    (session_notify_interval_bytes == 32'd0) ?
                    32'hFFFF_FFFF :
                    session_notify_interval_bytes - bytes_since_commit;
                end
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
          select_work_length <= selected_work_length;
          tx_state <= TX_SELECT_LENGTH;
        end

        TX_SELECT_LENGTH: begin
          if (select_work_length == 32'd0) begin
            tx_state <= TX_IDLE;
          end else if (session_use_external_payload &&
                       (!payload_packet_valid ||
                        payload_packet_length !=
                          selected_payload_length[15:0])) begin
            tx_underflow_count <= sat_inc32(tx_underflow_count);
            fault <= 1'b1;
            fault_reason <= 32'h0000_0201;
            run_enable <= 1'b0;
            abort_pending <= 1'b1;
            payload_flush <= 1'b1;
            tx_state <= TX_IDLE;
          end else begin
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
            inflight_psn <= session_tx_psn;
            inflight_benchmark_sequence <= data_packet_sequence;
            inflight_commit_total_bytes <= 64'd0;
            inflight_commit_end_offset <= 32'd0;
            inflight_commit_interval_bytes <= 32'd0;
            inflight_commit_sequence <= 64'd0;
            inflight_commit_final <= 1'b0;
            inflight_ip_identification <= next_ip_identification;
            next_ip_identification <= next_ip_identification + 16'd1;
            replay_message_start <= 1'b0;
            if (select_has_reth && !replay_active) begin
              message_checkpoint_valid <= 1'b1;
              message_checkpoint_psn <= session_tx_psn;
              message_checkpoint_ring_offset <= ring_offset;
              message_checkpoint_local_address <= local_byte_address;
              message_checkpoint_data_sequence <= data_packet_sequence;
              message_checkpoint_interval_bytes <= bytes_since_commit;
              message_checkpoint_logical_remaining <= select_logical_remaining;
              message_checkpoint_work_length <= select_work_length;
              message_recovery_attempts <= '0;
            end
            if (select_has_reth && !logical_wr_active) begin
              logical_wr_active <= 1'b1;
              logical_wr_remaining <= session_wr_size;
            end
            tx_state <= TX_PREPARE;
          end
        end

        TX_PREPARE: begin
          inflight_udp_length <= prepared_udp_length;
          inflight_ip_total_length <= prepared_ip_total_length;
          inflight_icrc_data_bytes <= prepared_ip_total_length - 16'd4;
          inflight_packet_bytes <= 13'd14 + prepared_ip_total_length[12:0];
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
          inflight_ip_checksum <= ~checksum_refold[15:0];

          tx_packet_last_beat <= packet_last_offset[12:6];
          tx_packet_last_valid_bytes <= last_valid_bytes;
          tx_packet_last_keep <= packet_keep_mask(last_valid_bytes);
          crc_state <= ICRC_INIT;
          crc_offset <= 16'd0;
          fast_tx_beat <= 7'd0;
          fast_crc_after_header0 <= ICRC_INIT;
          fast_crc_ahead_state <= ICRC_INIT;
          fast_zero_full_count <= 6'd0;
          fast_zero_full_target <= fast_zero_target(packet_last_offset[12:6]);
          fast_penultimate_beat <= packet_last_offset[12:6] - 7'd1;
          fast_last_keep <= packet_keep_mask(last_valid_bytes);
          fast_icrc_valid <= 1'b0;
          tx_state <= TX_CRC;
        end

        TX_CRC: begin
          if (fast_data_path) begin
            fast_header_word0 <= fast_header_word0_next;
            fast_header_word1 <= fast_header_word1_next;
            tx_state <= TX_CRC_UPDATE;
          end else if (session_use_external_payload && !inflight_is_commit) begin
            if (external_builder_done) begin
              packet_icrc <= external_builder_icrc;
              tx_packet_read_address <= 7'd0;
              tx_state <= TX_LOAD;
            end
          end else begin
            // Address decode and the CRC recurrence are separate cycles. This
            // is outside the AXIS data path, so the extra preparation latency
            // does not reduce the one-beat-per-cycle transmit rate.
            tx_crc_byte <= packet_layout_crc_byte;
            tx_state <= TX_CRC_UPDATE;
          end
        end

        TX_CRC_UPDATE: begin
          if (fast_data_path) begin
            fast_crc_after_header0 <= fast_crc_after_header0_next;
            tx_state <= TX_BUILD;
          end else begin
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
        end

        TX_BUILD: begin
          if (fast_data_path) begin
            fast_crc_ahead_state <= fast_crc_after_header1_next;
            tx_state <= TX_SEND;
          end else begin
            if (tx_build_byte_offset < 16'd6) begin
              tx_build_region <= RDMA_PACKET_DEST_MAC;
              tx_build_region_offset <= tx_build_byte_offset;
            end else if (tx_build_byte_offset < 16'd12) begin
              tx_build_region <= RDMA_PACKET_SOURCE_MAC;
              tx_build_region_offset <= tx_build_byte_offset - 16'd6;
            end else if (tx_build_byte_offset < 16'd14) begin
              tx_build_region <= RDMA_PACKET_ETHERTYPE;
              tx_build_region_offset <= tx_build_byte_offset - 16'd12;
            end else if (tx_build_byte_offset < 16'd34) begin
              tx_build_region <= RDMA_PACKET_IPV4;
              tx_build_region_offset <= tx_build_byte_offset - 16'd14;
            end else if (tx_build_byte_offset < 16'd42) begin
              tx_build_region <= RDMA_PACKET_UDP;
              tx_build_region_offset <= tx_build_byte_offset - 16'd34;
            end else if (tx_build_byte_offset < 16'd54) begin
              tx_build_region <= RDMA_PACKET_BTH;
              tx_build_region_offset <= tx_build_byte_offset - 16'd42;
            end else if (inflight_has_reth && (tx_build_byte_offset < 16'd70)) begin
              tx_build_region <= RDMA_PACKET_RETH;
              tx_build_region_offset <= tx_build_byte_offset - 16'd54;
            end else if (inflight_has_immediate && (tx_build_byte_offset < payload_start)) begin
              tx_build_region <= RDMA_PACKET_IMMEDIATE;
              tx_build_region_offset <= tx_build_byte_offset - immediate_start;
            end else if (tx_build_byte_offset < icrc_start) begin
              tx_build_region <= RDMA_PACKET_PAYLOAD;
              tx_build_region_offset <= tx_build_byte_offset - payload_start;
            end else begin
              tx_build_region <= RDMA_PACKET_ICRC;
              tx_build_region_offset <= tx_build_byte_offset - icrc_start;
            end
            tx_state <= TX_BUILD_DECODE;
          end
        end

        TX_BUILD_DECODE: begin
          tx_build_byte <= packet_layout_build_byte;
          tx_state <= TX_BUILD_COMMIT;
        end

        TX_BUILD_COMMIT: begin
          tx_build_word <= completed_tx_build_word;
          tx_build_byte_offset <= tx_build_byte_offset + 16'd1;
          if ((tx_build_byte_index + 7'd1) >= tx_build_valid_bytes) begin
            tx_state <= TX_BUILD_STORE;
          end else begin
            tx_build_byte_index <= tx_build_byte_index + 7'd1;
            tx_state <= TX_BUILD;
          end
        end

        TX_BUILD_STORE: begin
          if (tx_build_beat == tx_packet_last_beat) begin
            tx_state <= TX_LOAD;
          end else begin
            tx_build_beat <= next_tx_build_beat;
            tx_build_byte_index <= 7'd0;
            tx_build_valid_bytes <= (next_tx_build_beat == tx_packet_last_beat) ?
                                    tx_packet_last_valid_bytes : 7'd64;
            tx_build_word <= 512'd0;
            tx_build_keep <= (next_tx_build_beat == tx_packet_last_beat) ?
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
          if (fast_data_path) begin
            // Run ahead independently of TREADY. The zero-filled payload lets
            // this small state machine finish ICRC preparation while the first
            // header and payload beats are still being transmitted.
            if (fast_zero_full_count < fast_zero_full_target) begin
              fast_crc_ahead_state <= fast_crc_zero64_next;
              fast_zero_full_count <= fast_zero_full_count + 6'd1;
            end else if (!fast_icrc_valid) begin
              fast_last_word <= prepared_fast_last_word;
              fast_last_keep <= prepared_fast_last_keep;
              fast_icrc_valid <= 1'b1;
            end

            if (tx_axis_tready && tx_axis_tvalid) begin
              if (fast_axis_last) begin
                fast_icrc_valid <= 1'b0;
                timeout_count <= 32'd0;
                if (replay_active) begin
                  if (replay_remaining_bytes <= inflight_payload_length) begin
                    replay_active <= 1'b0;
                    replay_remaining_bytes <= 32'd0;
                  end else begin
                    replay_remaining_bytes <=
                      replay_remaining_bytes - inflight_payload_length;
                  end
                end else begin
                  issued_bytes <= sat_add64(issued_bytes, inflight_payload_length);
                end
                inflight_issued_accounted <= 1'b1;
                session_tx_psn <= inflight_psn + 24'd1;
                inflight_valid <= 1'b0;
                retry_count <= 4'd0;
                tx_state <= TX_IDLE;

                local_byte_address <= local_byte_address +
                                      {32'd0, inflight_payload_length};
                data_packet_sequence <= data_packet_sequence + 32'd1;
                ring_offset <= post_ack_ring_offset;
                logical_wr_remaining <= post_ack_logical_remaining;
                logical_wr_active <= !final_logical_packet;
                physical_message_remaining <= inflight_remaining_after;
                bytes_since_commit <= completed_interval_bytes;

                // The commit is also the acknowledgement barrier for this
                // physical message. It keeps the checkpoint live until the
                // responder has either accepted every data PSN or requested
                // a rewind, including a missing packet at a ring boundary.
                if (data_message_done) begin
                  pending_commit <= 1'b1;
                  pending_commit_total_bytes <= replay_active ?
                    issued_bytes : sat_add64(issued_bytes, inflight_payload_length);
                  pending_commit_end_offset <= post_ack_ring_offset;
                  pending_commit_interval_bytes <= completed_interval_bytes;
                  pending_commit_sequence <= sat_inc64(producer_sequence);
                  pending_commit_final <= stop_after_ack && final_logical_packet;
                end
              end else begin
                fast_tx_beat <= fast_tx_beat + 7'd1;
              end
            end
          end else if (tx_axis_tready) begin
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
                session_tx_psn <= inflight_psn + 24'd1;
                inflight_valid <= 1'b0;
                retry_count <= 4'd0;
                tx_state <= TX_IDLE;
                if (inflight_is_commit) begin
                  if (fast_mode_active) begin
                    acked_bytes <= inflight_commit_total_bytes;
                    message_checkpoint_valid <= 1'b0;
                    message_recovery_attempts <= '0;
                  end
                  bytes_since_commit <= 32'd0;
                  published_bytes <= inflight_commit_total_bytes;
                  producer_sequence <= inflight_commit_sequence;
                  commit_count <= sat_inc32(commit_count);
                  if (inflight_has_immediate) immediate_count <= sat_inc32(immediate_count);
                  if (inflight_commit_final) begin
                    pending_commit <= 1'b0;
                    stop_requested <= 1'b0;
                    configured <= 1'b0;
                    final_commit_acked <= 1'b1;
                    if (payload_buffer_empty) payload_flush <= 1'b1;
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
                  if (session_use_external_payload)
                    payload_packet_release <= 1'b1;

                  acked_bytes <= sat_add64(acked_bytes, inflight_payload_length);
                  local_byte_address <= local_byte_address +
                                        {32'd0, inflight_payload_length};
                  data_packet_sequence <= data_packet_sequence + 32'd1;
                  ring_offset <= post_ack_ring_offset;
                  logical_wr_remaining <= post_ack_logical_remaining;
                  logical_wr_active <= !final_logical_packet;
                  physical_message_remaining <= inflight_remaining_after;
                  bytes_since_commit <= completed_interval_bytes;

                  if (data_message_done &&
                      (notification_due ||
                       (stop_after_ack && final_logical_packet &&
                        (session_notify_interval_bytes != 32'd0) &&
                        (completed_interval_bytes != 32'd0)))) begin
                    pending_commit <= 1'b1;
                    pending_commit_total_bytes <= sat_add64(acked_bytes, inflight_payload_length);
                    pending_commit_end_offset <= post_ack_ring_offset;
                    pending_commit_interval_bytes <= completed_interval_bytes;
                    pending_commit_sequence <= sat_inc64(producer_sequence);
                    pending_commit_final <= stop_after_ack && final_logical_packet;
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
                last_nak_syndrome <= response_pending_syndrome;
                last_nak_psn <= response_pending_psn;
                if (!retransmission_enable) begin
                  fault <= 1'b1;
                  fault_reason <= FAULT_RETRANSMISSION_DISABLED;
                  run_enable <= 1'b0;
                  abort_pending <= 1'b1;
                  tx_state <= TX_IDLE;
                end else if (retry_count >= MAX_RETRIES) begin
                  retry_exhausted_count <= sat_inc32(retry_exhausted_count);
                  fault <= 1'b1;
                  fault_reason <= 32'd2;
                  abort_pending <= 1'b1;
                  run_enable <= 1'b0;
                  tx_state <= TX_IDLE;
                end else begin
                  retry_count <= retry_count + 4'd1;
                  rnr_wait_cycles <= rnr_retry_delay_cycles(
                    response_pending_syndrome[4:0]);
                  tx_state <= TX_RNR_WAIT;
                end
              end
            end else if (fast_mode_active && inflight_is_commit &&
                         (response_pending_syndrome == 8'h60) &&
                         (response_pending_psn == inflight_psn)) begin
              timeout_count <= 32'd0;
              nak_count <= sat_inc32(nak_count);
              last_nak_syndrome <= response_pending_syndrome;
              last_nak_psn <= response_pending_psn;
              if (!retransmission_enable) begin
                fault <= 1'b1;
                fault_reason <= FAULT_RETRANSMISSION_DISABLED;
                run_enable <= 1'b0;
                abort_pending <= 1'b1;
                tx_state <= TX_IDLE;
              end else if (retry_count >= MAX_RETRIES) begin
                retry_exhausted_count <= sat_inc32(retry_exhausted_count);
                fault <= 1'b1;
                fault_reason <= 32'd2;
                abort_pending <= 1'b1;
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
              // PSN sequence-error recovery needs responder state that this
              // single-outstanding bring-up endpoint does not implement. It
              // and all fatal/unknown AETH syndromes stop the QP immediately.
              if (response_pending_syndrome[7:5] == 3'b011) begin
                nak_count <= sat_inc32(nak_count);
                last_nak_syndrome <= response_pending_syndrome;
                last_nak_psn <= response_pending_psn;
              end
              fault <= 1'b1;
              fault_reason <= 32'd3;
              abort_pending <= 1'b1;
              run_enable <= 1'b0;
              tx_state <= TX_IDLE;
            end
          end else if (rx_ack_pulse && inflight_valid) begin
            // The response is captured above and processed on the next cycle.
          end else if (timeout_count >= (ACK_TIMEOUT_CYCLES - 1)) begin
            timeout_count <= 32'd0;
            if (!retransmission_enable) begin
              fault <= 1'b1;
              fault_reason <= FAULT_RETRANSMISSION_DISABLED;
              run_enable <= 1'b0;
              abort_pending <= 1'b1;
              tx_state <= TX_IDLE;
            end else if (retry_count >= MAX_RETRIES) begin
              retry_exhausted_count <= sat_inc32(retry_exhausted_count);
              fault <= 1'b1;
              fault_reason <= 32'd4;
              abort_pending <= 1'b1;
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
          if (!retransmission_enable) begin
            fault <= 1'b1;
            fault_reason <= FAULT_RETRANSMISSION_DISABLED;
            run_enable <= 1'b0;
            abort_pending <= 1'b1;
            tx_state <= TX_IDLE;
          end else if (timeout_count >= (rnr_wait_cycles - 32'd1)) begin
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
  end

endmodule
