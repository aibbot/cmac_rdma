`timescale 1ps / 1ps

// Stable IP-packager boundary for the portable single-clock transport core.
// AXI-Stream ports stay flat so Vivado can infer standard bus interfaces.
(* X_CORE_INFO = "cmac_usplus_0_rdma_transport_ip,Vivado 2025.2" *)
module cmac_usplus_0_rdma_transport_ip #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
  parameter logic [23:0] LOCAL_QPN = 24'd1,
  parameter integer ACLK_FREQ_HZ = 250_000_000,
  parameter integer ACK_TIMEOUT_CYCLES = ACLK_FREQ_HZ / 1_000,
  parameter integer MAX_RETRIES = 12,
  parameter integer MAX_SEQUENCE_RECOVERIES = 12,
  parameter integer SEQUENCE_RECOVERY_QUIET_CYCLES = 4096,
  parameter integer RNR_TIMER_10US_CYCLES = ACLK_FREQ_HZ / 100_000,
  parameter bit FAST_BENCHMARK_MODE = 1'b0,
  parameter logic [31:0] BUILD_TAG = 32'd0
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, FREQ_HZ 250000000, ASSOCIATED_BUSIF S_AXIS_PAYLOAD:S_AXIS_RX:M_AXIS_TX, ASSOCIATED_RESET aresetn" *)
  input  logic         aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
  input  logic         aresetn,

  input  logic [31:0]  local_ip,
  input  logic [31:0]  rx_overflow_source_count,

  input  logic         cfg_valid,
  output logic         cfg_ready,
  output logic         cfg_done,
  output logic         cfg_accepted,
  input  logic [47:0]  cfg_remote_mac,
  input  logic [31:0]  cfg_remote_ip,
  input  logic [23:0]  cfg_remote_qpn,
  input  logic [23:0]  cfg_local_psn,
  input  logic [47:0]  cfg_remote_base,
  input  logic [31:0]  cfg_rkey,
  input  logic [31:0]  cfg_ring_size,
  input  logic [31:0]  cfg_wr_size,
  input  logic [63:0]  cfg_local_base,
  input  logic         cfg_enable_immediate,
  input  logic [31:0]  cfg_notify_interval_bytes,
  input  logic [47:0]  cfg_commit_remote_addr,
  input  logic         cfg_use_external_payload,
  input  logic         start_request,
  input  logic         stop_request,
  input  logic         abort_request,
  input  logic [63:0]  consumed_bytes,
  input  logic         tx_path_idle,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_PAYLOAD TVALID" *)
  input  logic         s_axis_payload_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_PAYLOAD TREADY" *)
  output logic         s_axis_payload_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_PAYLOAD TDATA" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS_PAYLOAD, TDATA_NUM_BYTES 64, HAS_TKEEP 1, HAS_TLAST 1, TUSER_WIDTH 1" *)
  input  logic [511:0] s_axis_payload_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_PAYLOAD TKEEP" *)
  input  logic [63:0]  s_axis_payload_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_PAYLOAD TLAST" *)
  input  logic         s_axis_payload_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_PAYLOAD TUSER" *)
  input  logic         s_axis_payload_tuser,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_RX TVALID" *)
  input  logic         s_axis_rx_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_RX TREADY" *)
  output logic         s_axis_rx_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_RX TDATA" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS_RX, TDATA_NUM_BYTES 64, HAS_TKEEP 1, HAS_TLAST 1, TUSER_WIDTH 1" *)
  input  logic [511:0] s_axis_rx_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_RX TKEEP" *)
  input  logic [63:0]  s_axis_rx_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_RX TLAST" *)
  input  logic         s_axis_rx_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_RX TUSER" *)
  input  logic         s_axis_rx_tuser,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TX TVALID" *)
  output logic         m_axis_tx_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TX TREADY" *)
  input  logic         m_axis_tx_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TX TDATA" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS_TX, TDATA_NUM_BYTES 64, HAS_TKEEP 1, HAS_TLAST 1, TUSER_WIDTH 1" *)
  output logic [511:0] m_axis_tx_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TX TKEEP" *)
  output logic [63:0]  m_axis_tx_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TX TLAST" *)
  output logic         m_axis_tx_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TX TUSER" *)
  output logic         m_axis_tx_tuser,

  output logic [31:0]  build_tag,
  output logic         configured,
  output logic         active,
  output logic         credit_stalled,
  output logic         stopping,
  output logic         drained,
  output logic         fault,
  output logic [31:0]  fault_reason,
  output logic         final_commit_acked,
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
  output logic [7:0]   last_nak_syndrome,
  output logic [23:0]  last_nak_psn,
  output logic [31:0]  sequence_recovery_count,
  output logic         replay_active,
  output logic         external_payload_active,
  output logic         payload_waiting,
  output logic [31:0]  payload_accepted_count,
  output logic [31:0]  payload_error_count
);
  logic reset;
  logic core_cfg_ready;
  logic core_payload_tready;
  logic core_rx_tready;
  logic core_tx_tvalid;

  localparam logic [3:0] TRANSPORT_STATE_RESET = 4'd0;
  localparam logic [3:0] TRANSPORT_STATE_UNCONFIGURED = 4'd1;
  localparam logic [3:0] TRANSPORT_STATE_READY = 4'd2;
  localparam logic [3:0] TRANSPORT_STATE_RUNNING = 4'd3;
  localparam logic [3:0] TRANSPORT_STATE_STOPPING = 4'd4;
  localparam logic [3:0] TRANSPORT_STATE_FAULT = 4'd5;

  initial begin : validate_parameters
    if (LOCAL_QPN == 24'd0)
      $fatal(1, "RDMA_IP_PARAMETER_ERROR: LOCAL_QPN");
    if (ACLK_FREQ_HZ < 100_000)
      $fatal(1, "RDMA_IP_PARAMETER_ERROR: ACLK_FREQ_HZ");
    if (ACK_TIMEOUT_CYCLES < 1)
      $fatal(1, "RDMA_IP_PARAMETER_ERROR: ACK_TIMEOUT_CYCLES");
    if ((MAX_RETRIES < 0) || (MAX_RETRIES > 15))
      $fatal(1, "RDMA_IP_PARAMETER_ERROR: MAX_RETRIES");
    if ((MAX_SEQUENCE_RECOVERIES < 0) ||
        (MAX_SEQUENCE_RECOVERIES > 65535))
      $fatal(1, "RDMA_IP_PARAMETER_ERROR: MAX_SEQUENCE_RECOVERIES");
    if (SEQUENCE_RECOVERY_QUIET_CYCLES < 1)
      $fatal(1, "RDMA_IP_PARAMETER_ERROR: SEQUENCE_RECOVERY_QUIET_CYCLES");
    if (RNR_TIMER_10US_CYCLES < 1)
      $fatal(1, "RDMA_IP_PARAMETER_ERROR: RNR_TIMER_10US_CYCLES");
  end

  assign build_tag = BUILD_TAG;
  assign cfg_ready = !reset && core_cfg_ready;
  assign s_axis_payload_tready = !reset && core_payload_tready;
  assign s_axis_rx_tready = !reset && core_rx_tready;
  assign m_axis_tx_tvalid = !reset && core_tx_tvalid;
  assign debug_state = reset ? TRANSPORT_STATE_RESET :
                       fault ? TRANSPORT_STATE_FAULT :
                       stopping ? TRANSPORT_STATE_STOPPING :
                       active ? TRANSPORT_STATE_RUNNING :
                       configured ? TRANSPORT_STATE_READY :
                       TRANSPORT_STATE_UNCONFIGURED;

  cmac_usplus_0_rdma_reset_sync #(
    .STAGES(4),
    .RESET_ACTIVE_HIGH(0)
  ) i_reset_sync (
    .clk(aclk),
    .async_reset(aresetn),
    .sync_reset(reset)
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
    .clk(aclk),
    .reset(reset),
    .local_ip(local_ip),
    .rx_overflow_source_count(rx_overflow_source_count),
    .cfg_valid(cfg_valid),
    .cfg_ready(core_cfg_ready),
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
    .cfg_use_external_payload(cfg_use_external_payload),
    .start_request(start_request),
    .stop_request(stop_request),
    .abort_request(abort_request),
    .consumed_bytes(consumed_bytes),
    .tx_path_idle(tx_path_idle),
    .retransmission_enable(1'b1),
    .payload_axis_tvalid(s_axis_payload_tvalid),
    .payload_axis_tready(core_payload_tready),
    .payload_axis_tdata(s_axis_payload_tdata),
    .payload_axis_tkeep(s_axis_payload_tkeep),
    .payload_axis_tlast(s_axis_payload_tlast),
    .payload_axis_tuser(s_axis_payload_tuser),
    .rx_axis_tvalid(s_axis_rx_tvalid),
    .rx_axis_tready(core_rx_tready),
    .rx_axis_tdata(s_axis_rx_tdata),
    .rx_axis_tkeep(s_axis_rx_tkeep),
    .rx_axis_tlast(s_axis_rx_tlast),
    .rx_axis_tuser(s_axis_rx_tuser),
    .tx_axis_tready(m_axis_tx_tready),
    .tx_axis_tvalid(core_tx_tvalid),
    .tx_axis_tdata(m_axis_tx_tdata),
    .tx_axis_tkeep(m_axis_tx_tkeep),
    .tx_axis_tlast(m_axis_tx_tlast),
    .tx_axis_tuser(m_axis_tx_tuser),
    .configured(configured),
    .active(active),
    .credit_stalled(credit_stalled),
    .stopping(stopping),
    .drained(drained),
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
    .debug_state(),
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
endmodule
