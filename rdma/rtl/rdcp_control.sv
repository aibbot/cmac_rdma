`timescale 1ps / 1ps

module rdcp_control #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
  parameter logic [31:0] LOCAL_IP = 32'hC0A8_110B,
  parameter logic [23:0] LOCAL_QPN = 24'd1
) (
  input  logic         clk,
  input  logic         reset,
  input  logic         s_axis_tvalid,
  output logic         s_axis_tready,
  input  logic [511:0] s_axis_tdata,
  input  logic [63:0]  s_axis_tkeep,
  input  logic         s_axis_tlast,
  input  logic         s_axis_tuser,
  output logic         m_axis_tvalid,
  input  logic         m_axis_tready,
  output logic [511:0] m_axis_tdata,
  output logic [63:0]  m_axis_tkeep,
  output logic         m_axis_tlast,
  output logic         m_axis_tuser,

  output logic         cfg_valid,
  input  logic         cfg_ready,
  output logic [47:0]  cfg_remote_mac,
  output logic [31:0]  cfg_remote_ip,
  output logic [23:0]  cfg_remote_qpn,
  output logic [23:0]  cfg_local_psn,
  output logic [47:0]  cfg_remote_base,
  output logic [31:0]  cfg_rkey,
  output logic [31:0]  cfg_ring_size,
  output logic [31:0]  cfg_wr_size,
  output logic [31:0]  cfg_notify_interval_bytes,
  output logic [63:0]  cfg_local_base,
  output logic [47:0]  cfg_commit_remote_addr,
  output logic         cfg_enable_immediate,
  input  logic         cfg_done,
  input  logic         cfg_accepted,
  input  logic [31:0]  cfg_reject_reason,

  output logic         start_request,
  output logic         stop_request,
  output logic         abort_request,
  input  logic         endpoint_configured,
  input  logic         endpoint_active,
  input  logic         endpoint_stopping,
  input  logic         endpoint_drained,
  input  logic         endpoint_fault,
  input  logic [31:0]  endpoint_fault_reason,
  input  logic         endpoint_final_commit_acked,
  input  logic [23:0]  endpoint_current_psn,
  input  logic [63:0]  endpoint_issued_bytes,
  input  logic [63:0]  endpoint_acked_bytes,
  input  logic [63:0]  endpoint_published_bytes,
  input  logic         endpoint_credit_stalled,
  output logic [63:0]  consumed_bytes,
  output logic [3:0]   session_state,
  output logic         safe_to_release,
  output logic [31:0]  config_generation
);
  import rdcp_pkg::*;

  rdcp_validated_request_t validated_request;
  logic validated_request_valid;
  logic validated_request_ready;

  rdcp_request_descriptor_t parsed_request;
  logic parsed_request_valid;
  logic parsed_request_ready;
  logic transaction_active;
  logic capture_enable;

  rdcp_response_descriptor_t response_descriptor;
  logic response_valid;
  logic response_ready;
  logic replay_valid;
  logic replay_ready;
  logic cache_invalidate;
  logic cache_valid;
  logic [31:0] cache_transaction_id;
  logic [7:0] cache_opcode;
  logic response_done;

  rdcp_endpoint_status_t endpoint_status;
  logic command_abort_request;
  logic fault_abort_request;

  assign capture_enable = !parsed_request_valid && !transaction_active;
  assign abort_request = command_abort_request || fault_abort_request;

  always_comb begin
    endpoint_status = '0;
    endpoint_status.configured = endpoint_configured;
    endpoint_status.active = endpoint_active;
    endpoint_status.stopping = endpoint_stopping;
    endpoint_status.drained = endpoint_drained;
    endpoint_status.fault = endpoint_fault;
    endpoint_status.fault_reason = endpoint_fault_reason;
    endpoint_status.final_commit_acked = endpoint_final_commit_acked;
    endpoint_status.current_psn = endpoint_current_psn;
    endpoint_status.issued_bytes = endpoint_issued_bytes;
    endpoint_status.acked_bytes = endpoint_acked_bytes;
    endpoint_status.published_bytes = endpoint_published_bytes;
    endpoint_status.credit_stalled = endpoint_credit_stalled;
  end

  rdcp_rx_validate #(
    .LOCAL_MAC(LOCAL_MAC),
    .LOCAL_IP(LOCAL_IP)
  ) i_rx_validate (
    .clk(clk),
    .reset(reset),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .capture_enable(capture_enable),
    .request_valid(validated_request_valid),
    .request_ready(validated_request_ready),
    .request(validated_request)
  );

  rdcp_request_parser i_request_parser (
    .clk(clk),
    .reset(reset),
    .request_valid(validated_request_valid),
    .request_ready(validated_request_ready),
    .request(validated_request),
    .parsed_request_valid(parsed_request_valid),
    .parsed_request_ready(parsed_request_ready),
    .parsed_request(parsed_request)
  );

  rdcp_session_engine i_session_engine (
    .clk(clk),
    .reset(reset),
    .request_valid(parsed_request_valid),
    .request_ready(parsed_request_ready),
    .request(parsed_request),
    .transaction_active(transaction_active),
    .response_valid(response_valid),
    .response_ready(response_ready),
    .response_descriptor(response_descriptor),
    .replay_valid(replay_valid),
    .replay_ready(replay_ready),
    .cache_invalidate(cache_invalidate),
    .cache_valid(cache_valid),
    .cache_transaction_id(cache_transaction_id),
    .cache_opcode(cache_opcode),
    .response_done(response_done),
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
    .cfg_reject_reason(cfg_reject_reason),
    .start_request(start_request),
    .stop_request(stop_request),
    .command_abort_request(command_abort_request),
    .endpoint_status(endpoint_status),
    .fault_abort_request(fault_abort_request),
    .consumed_bytes(consumed_bytes),
    .session_state(session_state),
    .safe_to_release(safe_to_release),
    .config_generation(config_generation)
  );

  rdcp_response_encoder #(
    .LOCAL_MAC(LOCAL_MAC),
    .LOCAL_IP(LOCAL_IP),
    .LOCAL_QPN(LOCAL_QPN)
  ) i_response_encoder (
    .clk(clk),
    .reset(reset),
    .response_valid(response_valid),
    .response_ready(response_ready),
    .response_descriptor(response_descriptor),
    .replay_valid(replay_valid),
    .replay_ready(replay_ready),
    .cache_invalidate(cache_invalidate),
    .cache_valid(cache_valid),
    .cache_transaction_id(cache_transaction_id),
    .cache_opcode(cache_opcode),
    .response_done(response_done),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser)
  );
endmodule
