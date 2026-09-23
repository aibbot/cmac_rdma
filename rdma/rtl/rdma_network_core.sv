`timescale 1ps / 1ps

// Portable single-clock Ethernet/RDCP/RoCE composition. The raw Ethernet
// ports connect to a MAC-side adapter; no clock-generation, CDC, or debug IP
// is instantiated here.
module cmac_usplus_0_rdma_network_core #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
  parameter logic [31:0] LOCAL_IP = 32'hC0A8_110B,
  parameter logic [23:0] LOCAL_QPN = 24'd1,
  parameter integer ACK_TIMEOUT_CYCLES = 250_000,
  parameter integer MAX_RETRIES = 12,
  parameter integer MAX_SEQUENCE_RECOVERIES = 12,
  parameter integer SEQUENCE_RECOVERY_QUIET_CYCLES = 4096,
  parameter integer RNR_TIMER_10US_CYCLES = 2_500,
  parameter bit FAST_BENCHMARK_MODE = 1'b0
) (
  input  logic         clk,
  input  logic         reset,
  input  logic [31:0]  rx_overflow_source_count,
  input  logic         tx_pipeline_empty,
  input  logic         tx_path_empty,
  input  logic         retransmission_enable,

  input  logic         payload_external_enable,
  input  logic         payload_axis_tvalid,
  output logic         payload_axis_tready,
  input  logic [511:0] payload_axis_tdata,
  input  logic [63:0]  payload_axis_tkeep,
  input  logic         payload_axis_tlast,
  input  logic         payload_axis_tuser,

  input  logic         rx_axis_tvalid,
  output logic         rx_axis_tready,
  input  logic [511:0] rx_axis_tdata,
  input  logic [63:0]  rx_axis_tkeep,
  input  logic         rx_axis_tlast,
  input  logic         rx_axis_tuser,

  input  logic         tx_axis_tready,
  output logic         tx_axis_tvalid,
  output logic [511:0] tx_axis_tdata,
  output logic [63:0]  tx_axis_tkeep,
  output logic         tx_axis_tlast,
  output logic         tx_axis_tuser,

  output logic         configured,
  output logic         active,
  output logic         credit_stalled,
  output logic         stopping,
  output logic         drained,
  output logic         endpoint_drained,
  output logic         fault,
  output logic [31:0]  fault_reason,
  output logic         final_commit_acked,
  output logic [3:0]   session_state,
  output logic         safe_to_release,
  output logic [31:0]  config_generation,
  output logic [31:0]  config_reject_count,
  output logic [31:0]  config_reject_reason,
  output logic [31:0]  icrc_drop_count,
  output logic [31:0]  invalid_psn_count,
  output logic [31:0]  nak_count,
  output logic [31:0]  retrans_count,
  output logic [31:0]  retry_exhausted_count,
  output logic [31:0]  rx_overflow_count,
  output logic [31:0]  tx_underflow_count,
  output logic [63:0]  issued_bytes,
  output logic [63:0]  acked_bytes,
  output logic [31:0]  ring_offset,
  output logic [23:0]  current_psn,
  output logic [3:0]   debug_state,
  output logic [31:0]  commit_count,
  output logic [31:0]  immediate_count,
  output logic [63:0]  published_bytes,
  output logic [63:0]  producer_sequence,
  output logic [63:0]  consumed_bytes,
  output logic [7:0]   last_nak_syndrome,
  output logic [23:0]  last_nak_psn,
  output logic [31:0]  sequence_recovery_count,
  output logic         replay_active,
  output logic [31:0]  rx_classifier_drop_count,
  output logic         external_payload_active,
  output logic         payload_waiting,
  output logic [31:0]  payload_accepted_count,
  output logic [31:0]  payload_error_count
);
  logic rdma_rx_axis_tvalid;
  logic rdma_rx_axis_tready;
  logic [511:0] rdma_rx_axis_tdata;
  logic [63:0] rdma_rx_axis_tkeep;
  logic rdma_rx_axis_tlast;
  logic rdma_rx_axis_tuser;
  logic control_rx_axis_tvalid;
  logic control_rx_axis_tready;
  logic [511:0] control_rx_axis_tdata;
  logic [63:0] control_rx_axis_tkeep;
  logic control_rx_axis_tlast;
  logic control_rx_axis_tuser;

  logic rdma_tx_axis_tvalid;
  logic rdma_tx_axis_tready;
  logic [511:0] rdma_tx_axis_tdata;
  logic [63:0] rdma_tx_axis_tkeep;
  logic rdma_tx_axis_tlast;
  logic rdma_tx_axis_tuser;
  logic control_tx_axis_tvalid;
  logic control_tx_axis_tready;
  logic [511:0] control_tx_axis_tdata;
  logic [63:0] control_tx_axis_tkeep;
  logic control_tx_axis_tlast;
  logic control_tx_axis_tuser;

  logic cfg_valid;
  logic cfg_ready;
  logic cfg_done;
  logic cfg_accepted;
  logic [47:0] cfg_remote_mac;
  logic [31:0] cfg_remote_ip;
  logic [23:0] cfg_remote_qpn;
  logic [23:0] cfg_local_psn;
  logic [47:0] cfg_remote_base;
  logic [31:0] cfg_rkey;
  logic [31:0] cfg_ring_size;
  logic [31:0] cfg_wr_size;
  logic [31:0] cfg_notify_interval_bytes;
  logic [63:0] cfg_local_base;
  logic [47:0] cfg_commit_remote_addr;
  logic cfg_enable_immediate;
  logic start_request;
  logic stop_request;
  logic abort_request;
  logic transport_drained;

  assign endpoint_drained = transport_drained;
  assign drained = transport_drained && tx_path_empty;

  cmac_usplus_0_rdma_rx_classifier i_rx_classifier (
    .clk(clk),
    .reset(reset),
    .s_axis_tvalid(rx_axis_tvalid),
    .s_axis_tready(rx_axis_tready),
    .s_axis_tdata(rx_axis_tdata),
    .s_axis_tkeep(rx_axis_tkeep),
    .s_axis_tlast(rx_axis_tlast),
    .s_axis_tuser(rx_axis_tuser),
    .rdma_axis_tvalid(rdma_rx_axis_tvalid),
    .rdma_axis_tready(rdma_rx_axis_tready),
    .rdma_axis_tdata(rdma_rx_axis_tdata),
    .rdma_axis_tkeep(rdma_rx_axis_tkeep),
    .rdma_axis_tlast(rdma_rx_axis_tlast),
    .rdma_axis_tuser(rdma_rx_axis_tuser),
    .control_axis_tvalid(control_rx_axis_tvalid),
    .control_axis_tready(control_rx_axis_tready),
    .control_axis_tdata(control_rx_axis_tdata),
    .control_axis_tkeep(control_rx_axis_tkeep),
    .control_axis_tlast(control_rx_axis_tlast),
    .control_axis_tuser(control_rx_axis_tuser),
    .drop_count(rx_classifier_drop_count)
  );

  cmac_usplus_0_rdcp_control #(
    .LOCAL_MAC(LOCAL_MAC),
    .LOCAL_IP(LOCAL_IP),
    .LOCAL_QPN(LOCAL_QPN)
  ) i_rdcp_control (
    .clk(clk),
    .reset(reset),
    .s_axis_tvalid(control_rx_axis_tvalid),
    .s_axis_tready(control_rx_axis_tready),
    .s_axis_tdata(control_rx_axis_tdata),
    .s_axis_tkeep(control_rx_axis_tkeep),
    .s_axis_tlast(control_rx_axis_tlast),
    .s_axis_tuser(control_rx_axis_tuser),
    .m_axis_tvalid(control_tx_axis_tvalid),
    .m_axis_tready(control_tx_axis_tready),
    .m_axis_tdata(control_tx_axis_tdata),
    .m_axis_tkeep(control_tx_axis_tkeep),
    .m_axis_tlast(control_tx_axis_tlast),
    .m_axis_tuser(control_tx_axis_tuser),
    .cfg_valid(cfg_valid),
    .cfg_ready(cfg_ready),
    .cfg_remote_mac(cfg_remote_mac),
    .cfg_remote_ip(cfg_remote_ip),
    .cfg_remote_qpn(cfg_remote_qpn),
    .cfg_local_psn(cfg_local_psn),
    .cfg_remote_base(cfg_remote_base),
    .cfg_rkey(cfg_rkey),
    .cfg_ring_size(cfg_ring_size),
    .cfg_wr_size(cfg_wr_size),
    .cfg_notify_interval_bytes(cfg_notify_interval_bytes),
    .cfg_local_base(cfg_local_base),
    .cfg_commit_remote_addr(cfg_commit_remote_addr),
    .cfg_enable_immediate(cfg_enable_immediate),
    .cfg_done(cfg_done),
    .cfg_accepted(cfg_accepted),
    .cfg_reject_reason(config_reject_reason),
    .start_request(start_request),
    .stop_request(stop_request),
    .abort_request(abort_request),
    .endpoint_configured(configured),
    .endpoint_active(active),
    .endpoint_stopping(stopping),
    .endpoint_drained(drained),
    .endpoint_fault(fault),
    .endpoint_fault_reason(fault_reason),
    .endpoint_final_commit_acked(final_commit_acked),
    .endpoint_current_psn(current_psn),
    .endpoint_issued_bytes(issued_bytes),
    .endpoint_acked_bytes(acked_bytes),
    .endpoint_published_bytes(published_bytes),
    .endpoint_credit_stalled(credit_stalled),
    .consumed_bytes(consumed_bytes),
    .session_state(session_state),
    .safe_to_release(safe_to_release),
    .config_generation(config_generation)
  );

  cmac_usplus_0_rdma_transport_core #(
    .LOCAL_MAC(LOCAL_MAC),
    .LOCAL_QPN(LOCAL_QPN),
    .ACK_TIMEOUT_CYCLES(ACK_TIMEOUT_CYCLES),
    .MAX_RETRIES(MAX_RETRIES),
    .MAX_SEQUENCE_RECOVERIES(MAX_SEQUENCE_RECOVERIES),
    .SEQUENCE_RECOVERY_QUIET_CYCLES(SEQUENCE_RECOVERY_QUIET_CYCLES),
    .RNR_TIMER_10US_CYCLES(RNR_TIMER_10US_CYCLES),
    .FAST_BENCHMARK_MODE(FAST_BENCHMARK_MODE)
  ) i_transport_core (
    .clk(clk),
    .reset(reset),
    .local_ip(LOCAL_IP),
    .rx_overflow_source_count(rx_overflow_source_count),
    .cfg_valid(cfg_valid),
    .cfg_ready(cfg_ready),
    .cfg_done(cfg_done),
    .cfg_accepted(cfg_accepted),
    .cfg_remote_mac(cfg_remote_mac),
    .cfg_remote_ip(cfg_remote_ip),
    .cfg_remote_qpn(cfg_remote_qpn),
    .cfg_local_psn(cfg_local_psn),
    .cfg_remote_base(cfg_remote_base),
    .cfg_rkey(cfg_rkey),
    .cfg_ring_size(cfg_ring_size),
    .cfg_wr_size(cfg_wr_size),
    .cfg_local_base(cfg_local_base),
    .cfg_enable_immediate(cfg_enable_immediate),
    .cfg_notify_interval_bytes(cfg_notify_interval_bytes),
    .cfg_commit_remote_addr(cfg_commit_remote_addr),
    .cfg_use_external_payload(payload_external_enable),
    .start_request(start_request),
    .stop_request(stop_request),
    .abort_request(abort_request),
    .consumed_bytes(consumed_bytes),
    .tx_path_idle(tx_pipeline_empty),
    .retransmission_enable(retransmission_enable),
    .payload_axis_tvalid(payload_axis_tvalid),
    .payload_axis_tready(payload_axis_tready),
    .payload_axis_tdata(payload_axis_tdata),
    .payload_axis_tkeep(payload_axis_tkeep),
    .payload_axis_tlast(payload_axis_tlast),
    .payload_axis_tuser(payload_axis_tuser),
    .rx_axis_tvalid(rdma_rx_axis_tvalid),
    .rx_axis_tready(rdma_rx_axis_tready),
    .rx_axis_tdata(rdma_rx_axis_tdata),
    .rx_axis_tkeep(rdma_rx_axis_tkeep),
    .rx_axis_tlast(rdma_rx_axis_tlast),
    .rx_axis_tuser(rdma_rx_axis_tuser),
    .tx_axis_tready(rdma_tx_axis_tready),
    .tx_axis_tvalid(rdma_tx_axis_tvalid),
    .tx_axis_tdata(rdma_tx_axis_tdata),
    .tx_axis_tkeep(rdma_tx_axis_tkeep),
    .tx_axis_tlast(rdma_tx_axis_tlast),
    .tx_axis_tuser(rdma_tx_axis_tuser),
    .configured(configured),
    .active(active),
    .credit_stalled(credit_stalled),
    .stopping(stopping),
    .drained(transport_drained),
    .fault(fault),
    .fault_reason(fault_reason),
    .final_commit_acked(final_commit_acked),
    .config_reject_count(config_reject_count),
    .config_reject_reason(config_reject_reason),
    .icrc_drop_count(icrc_drop_count),
    .invalid_psn_count(invalid_psn_count),
    .nak_count(nak_count),
    .retrans_count(retrans_count),
    .retry_exhausted_count(retry_exhausted_count),
    .rx_overflow_count(rx_overflow_count),
    .tx_underflow_count(tx_underflow_count),
    .issued_bytes(issued_bytes),
    .acked_bytes(acked_bytes),
    .ring_offset(ring_offset),
    .current_psn(current_psn),
    .debug_state(debug_state),
    .commit_count(commit_count),
    .immediate_count(immediate_count),
    .published_bytes(published_bytes),
    .producer_sequence(producer_sequence),
    .last_nak_syndrome(last_nak_syndrome),
    .last_nak_psn(last_nak_psn),
    .sequence_recovery_count(sequence_recovery_count),
    .replay_active(replay_active),
    .external_payload_active(external_payload_active),
    .payload_waiting(payload_waiting),
    .payload_accepted_count(payload_accepted_count),
    .payload_error_count(payload_error_count)
  );

  cmac_usplus_0_rdma_tx_frame_arbiter i_tx_frame_arbiter (
    .clk(clk),
    .reset(reset),
    .control_axis_tvalid(control_tx_axis_tvalid),
    .control_axis_tready(control_tx_axis_tready),
    .control_axis_tdata(control_tx_axis_tdata),
    .control_axis_tkeep(control_tx_axis_tkeep),
    .control_axis_tlast(control_tx_axis_tlast),
    .control_axis_tuser(control_tx_axis_tuser),
    .rdma_axis_tvalid(rdma_tx_axis_tvalid),
    .rdma_axis_tready(rdma_tx_axis_tready),
    .rdma_axis_tdata(rdma_tx_axis_tdata),
    .rdma_axis_tkeep(rdma_tx_axis_tkeep),
    .rdma_axis_tlast(rdma_tx_axis_tlast),
    .rdma_axis_tuser(rdma_tx_axis_tuser),
    .tx_axis_tvalid(tx_axis_tvalid),
    .tx_axis_tready(tx_axis_tready),
    .tx_axis_tdata(tx_axis_tdata),
    .tx_axis_tkeep(tx_axis_tkeep),
    .tx_axis_tlast(tx_axis_tlast),
    .tx_axis_tuser(tx_axis_tuser)
  );
endmodule
