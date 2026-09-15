`timescale 1ps / 1ps

// Board-facing composition for the product RoCEv2 path. The local network
// identity is fixed at build time; all session state comes from RDCP/UDP.
module cmac_usplus_0_rdma_board_endpoint #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
  parameter logic [31:0] LOCAL_IP = 32'hC0A8_110B
) (
  input  logic         cmac_clk,
  input  logic         cmac_reset,
  input  logic         rx_axis_tvalid,
  input  logic [511:0] rx_axis_tdata,
  input  logic [63:0]  rx_axis_tkeep,
  input  logic         rx_axis_tlast,
  input  logic         rx_axis_tuser,
  input  logic         tx_axis_tready,
  output logic         tx_axis_tvalid,
  output logic [511:0] tx_axis_tdata,
  output logic [63:0]  tx_axis_tkeep,
  output logic         tx_axis_tlast,
  output logic         tx_axis_tuser
);

  logic rdma_clk;
  logic rdma_clk_locked;
  logic cmac_reset_rdma;
  logic lock_reset_rdma;
  logic rdma_reset;
  logic rdma_unavailable_cmac;

  logic reply_tx_axis_tready;
  logic reply_tx_axis_tvalid;
  logic [511:0] reply_tx_axis_tdata;
  logic [63:0] reply_tx_axis_tkeep;
  logic reply_tx_axis_tlast;
  logic reply_tx_axis_tuser;

  logic rx_fifo_s_tvalid;
  logic [511:0] rx_fifo_s_tdata;
  logic [63:0] rx_fifo_s_tkeep;
  logic rx_fifo_s_tlast;
  logic rx_fifo_s_tuser;
  logic rx_fifo_s_tready;
  logic [31:0] rx_fifo_wr_data_count;
  logic rx_fifo_m_tvalid;
  logic [511:0] rx_fifo_m_tdata;
  logic [63:0] rx_fifo_m_tkeep;
  logic rx_fifo_m_tlast;
  logic rx_fifo_m_tuser;
  logic [31:0] rx_overflow_count_cmac;
  logic [31:0] rx_overflow_count_cmac_rdma;

  logic classifier_rx_axis_tready;
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
  logic [31:0] rx_classifier_drop_count;

  logic rdma_tx_axis_tready;
  logic rdma_tx_axis_tvalid;
  logic [511:0] rdma_tx_axis_tdata;
  logic [63:0] rdma_tx_axis_tkeep;
  logic rdma_tx_axis_tlast;
  logic rdma_tx_axis_tuser;
  logic control_tx_axis_tready;
  logic control_tx_axis_tvalid;
  logic [511:0] control_tx_axis_tdata;
  logic [63:0] control_tx_axis_tkeep;
  logic control_tx_axis_tlast;
  logic control_tx_axis_tuser;
  logic combined_tx_axis_tready;
  logic combined_tx_axis_tvalid;
  logic [511:0] combined_tx_axis_tdata;
  logic [63:0] combined_tx_axis_tkeep;
  logic combined_tx_axis_tlast;
  logic combined_tx_axis_tuser;
  logic tx_fifo_s_tvalid;
  logic tx_fifo_s_tready;
  logic [511:0] tx_fifo_s_tdata;
  logic [63:0] tx_fifo_s_tkeep;
  logic tx_fifo_s_tlast;
  logic tx_fifo_s_tuser;
  logic tx_fifo_m_tvalid;
  logic tx_fifo_m_tready;
  logic [511:0] tx_fifo_m_tdata;
  logic [63:0] tx_fifo_m_tkeep;
  logic tx_fifo_m_tlast;
  logic tx_fifo_m_tuser;
  logic [31:0] tx_fifo_wr_data_count;
  logic tx_cmac_axis_tvalid;
  logic tx_cmac_axis_tready;
  logic [511:0] tx_cmac_axis_tdata;
  logic [63:0] tx_cmac_axis_tkeep;
  logic tx_cmac_axis_tlast;
  logic tx_cmac_axis_tuser;
  logic rdma_tx_flush_cmac;
  logic tx_pipeline_busy_cmac;
  logic rdma_tx_path_empty;

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
  logic [63:0] cfg_local_base;
  logic cfg_enable_immediate;
  logic [31:0] cfg_notify_interval_bytes;
  logic [47:0] cfg_commit_remote_addr;
  logic start_request;
  logic stop_request;
  logic abort_request;

  logic configured;
  logic active;
  logic stopping;
  logic drained;
  logic fault;
  logic [31:0] fault_reason;
  logic final_commit_acked;
  logic [3:0] session_state;
  logic safe_to_release;
  logic [31:0] config_generation;
  logic [31:0] config_reject_count;
  logic [31:0] config_reject_reason;
  logic [31:0] icrc_drop_count;
  logic [31:0] invalid_psn_count;
  logic [31:0] nak_count;
  logic [31:0] retrans_count;
  logic [31:0] retry_exhausted_count;
  logic [31:0] rx_overflow_count;
  logic [31:0] tx_underflow_count;
  logic [63:0] issued_bytes;
  logic [63:0] acked_bytes;
  logic [31:0] ring_offset;
  logic [23:0] current_psn;
  logic [3:0] debug_state;
  logic [31:0] commit_count;
  logic [31:0] immediate_count;
  logic [63:0] published_bytes;
  logic [63:0] producer_sequence;

  clk_wiz_rdma_250 i_clk_wiz_rdma_250 (
    .clk_in1(cmac_clk),
    .reset(cmac_reset),
    .clk_out1(rdma_clk),
    .locked(rdma_clk_locked)
  );

  cmac_usplus_0_rdma_reset_sync i_cmac_reset_sync (
    .clk(rdma_clk),
    .async_reset(cmac_reset),
    .sync_reset(cmac_reset_rdma)
  );

  cmac_usplus_0_rdma_reset_sync #(
    .RESET_ACTIVE_HIGH(0)
  ) i_lock_reset_sync (
    .clk(rdma_clk),
    .async_reset(rdma_clk_locked),
    .sync_reset(lock_reset_rdma)
  );

  cmac_usplus_0_rdma_reset_sync #(
    .RESET_ACTIVE_HIGH(0)
  ) i_lock_reset_cmac_sync (
    .clk(cmac_clk),
    .async_reset(rdma_clk_locked),
    .sync_reset(rdma_unavailable_cmac)
  );

  assign rdma_reset = cmac_reset_rdma || lock_reset_rdma;

  cmac_usplus_0_rdma_gray_counter_cdc #(
    .WIDTH(32)
  ) i_rx_overflow_counter_cdc (
    .src_clk(cmac_clk),
    .src_reset(cmac_reset),
    .src_count(rx_overflow_count_cmac),
    .dst_clk(rdma_clk),
    .dst_reset(rdma_reset),
    .dst_count(rx_overflow_count_cmac_rdma)
  );

  cmac_usplus_0_ping_reply_engine #(
    .LOCAL_MAC(LOCAL_MAC)
  ) i_ping_reply_engine (
    .clk(cmac_clk),
    .reset(cmac_reset),
    .local_ip(LOCAL_IP),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tkeep(rx_axis_tkeep),
    .rx_axis_tuser(rx_axis_tuser),
    .arp_sender_update(),
    .arp_sender_mac(),
    .arp_sender_ip(),
    .tx_axis_tready(reply_tx_axis_tready),
    .tx_axis_tvalid(reply_tx_axis_tvalid),
    .tx_axis_tdata(reply_tx_axis_tdata),
    .tx_axis_tlast(reply_tx_axis_tlast),
    .tx_axis_tkeep(reply_tx_axis_tkeep),
    .tx_axis_tuser(reply_tx_axis_tuser)
  );

  cmac_usplus_0_rdma_rx_admission #(
    .FIFO_DEPTH_BEATS(2048),
    .MAX_FRAME_BEATS(150),
    .WR_COUNT_WIDTH(32)
  ) i_rx_admission (
    .clk(cmac_clk),
    .reset(cmac_reset),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tkeep(rx_axis_tkeep),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tuser(rx_axis_tuser),
    .fifo_axis_tready(rx_fifo_s_tready),
    .fifo_wr_data_count(rx_fifo_wr_data_count),
    .fifo_axis_tvalid(rx_fifo_s_tvalid),
    .fifo_axis_tdata(rx_fifo_s_tdata),
    .fifo_axis_tkeep(rx_fifo_s_tkeep),
    .fifo_axis_tlast(rx_fifo_s_tlast),
    .fifo_axis_tuser(rx_fifo_s_tuser),
    .overflow_event(),
    .overflow_count(rx_overflow_count_cmac)
  );

  axis_data_fifo_rdma_rx i_axis_data_fifo_rdma_rx (
    .s_axis_aclk(cmac_clk),
    .s_axis_aresetn(!cmac_reset),
    .s_axis_tvalid(rx_fifo_s_tvalid),
    .s_axis_tready(rx_fifo_s_tready),
    .s_axis_tdata(rx_fifo_s_tdata),
    .s_axis_tkeep(rx_fifo_s_tkeep),
    .s_axis_tlast(rx_fifo_s_tlast),
    .s_axis_tuser(rx_fifo_s_tuser),
    .axis_wr_data_count(rx_fifo_wr_data_count),
    .m_axis_aclk(rdma_clk),
    .m_axis_tvalid(rx_fifo_m_tvalid),
    .m_axis_tready(classifier_rx_axis_tready),
    .m_axis_tdata(rx_fifo_m_tdata),
    .m_axis_tkeep(rx_fifo_m_tkeep),
    .m_axis_tlast(rx_fifo_m_tlast),
    .m_axis_tuser(rx_fifo_m_tuser)
  );

  cmac_usplus_0_rdma_rx_classifier i_rx_classifier (
    .clk(rdma_clk),
    .reset(rdma_reset),
    .s_axis_tvalid(rx_fifo_m_tvalid),
    .s_axis_tready(classifier_rx_axis_tready),
    .s_axis_tdata(rx_fifo_m_tdata),
    .s_axis_tkeep(rx_fifo_m_tkeep),
    .s_axis_tlast(rx_fifo_m_tlast),
    .s_axis_tuser(rx_fifo_m_tuser),
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
    .LOCAL_QPN(24'd1)
  ) i_rdcp_control (
    .clk(rdma_clk),
    .reset(rdma_reset),
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
    .endpoint_drained(drained && rdma_tx_path_empty),
    .endpoint_fault(fault),
    .endpoint_fault_reason(fault_reason),
    .endpoint_final_commit_acked(final_commit_acked),
    .endpoint_current_psn(current_psn),
    .endpoint_issued_bytes(issued_bytes),
    .endpoint_acked_bytes(acked_bytes),
    .endpoint_published_bytes(published_bytes),
    .endpoint_producer_sequence(producer_sequence),
    .session_state(session_state),
    .safe_to_release(safe_to_release),
    .config_generation(config_generation)
  );

  cmac_usplus_0_rdma_endpoint #(
    .LOCAL_MAC(LOCAL_MAC),
    .FAST_BENCHMARK_MODE(1'b1)
  ) i_rdma_endpoint (
    .clk(rdma_clk),
    .reset(rdma_reset),
    .local_ip(LOCAL_IP),
    .rx_overflow_source_count(rx_overflow_count_cmac_rdma),
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
    .start_request(start_request),
    .stop_request(stop_request),
    .abort_request(abort_request),
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
    .debug_state(debug_state),
    .commit_count(commit_count),
    .immediate_count(immediate_count),
    .published_bytes(published_bytes),
    .producer_sequence(producer_sequence)
  );

  cmac_usplus_0_rdma_tx_frame_arbiter i_tx_frame_arbiter (
    .clk(rdma_clk),
    .reset(rdma_reset),
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
    .tx_axis_tvalid(combined_tx_axis_tvalid),
    .tx_axis_tready(combined_tx_axis_tready),
    .tx_axis_tdata(combined_tx_axis_tdata),
    .tx_axis_tkeep(combined_tx_axis_tkeep),
    .tx_axis_tlast(combined_tx_axis_tlast),
    .tx_axis_tuser(combined_tx_axis_tuser)
  );

  cmac_usplus_0_rdma_axis_register i_rdma_tx_axis_register (
    .clk(rdma_clk),
    .reset(rdma_reset),
    .flush(1'b0),
    .s_axis_tvalid(combined_tx_axis_tvalid),
    .s_axis_tready(combined_tx_axis_tready),
    .s_axis_tdata(combined_tx_axis_tdata),
    .s_axis_tkeep(combined_tx_axis_tkeep),
    .s_axis_tlast(combined_tx_axis_tlast),
    .s_axis_tuser(combined_tx_axis_tuser),
    .m_axis_tvalid(tx_fifo_s_tvalid),
    .m_axis_tready(tx_fifo_s_tready),
    .m_axis_tdata(tx_fifo_s_tdata),
    .m_axis_tkeep(tx_fifo_s_tkeep),
    .m_axis_tlast(tx_fifo_s_tlast),
    .m_axis_tuser(tx_fifo_s_tuser)
  );

  axis_data_fifo_rdma_tx i_axis_data_fifo_rdma_tx (
    .s_axis_aclk(rdma_clk),
    .s_axis_aresetn(!rdma_reset),
    .s_axis_tvalid(tx_fifo_s_tvalid),
    .s_axis_tready(tx_fifo_s_tready),
    .s_axis_tdata(tx_fifo_s_tdata),
    .s_axis_tkeep(tx_fifo_s_tkeep),
    .s_axis_tlast(tx_fifo_s_tlast),
    .s_axis_tuser(tx_fifo_s_tuser),
    .axis_wr_data_count(tx_fifo_wr_data_count),
    .m_axis_aclk(cmac_clk),
    .m_axis_tvalid(tx_fifo_m_tvalid),
    .m_axis_tready(tx_fifo_m_tready),
    .m_axis_tdata(tx_fifo_m_tdata),
    .m_axis_tkeep(tx_fifo_m_tkeep),
    .m_axis_tlast(tx_fifo_m_tlast),
    .m_axis_tuser(tx_fifo_m_tuser)
  );

  assign tx_pipeline_busy_cmac = tx_fifo_m_tvalid || tx_cmac_axis_tvalid;

  cmac_usplus_0_rdma_tx_drain_tracker i_tx_drain_tracker (
    .clk(rdma_clk),
    .reset(rdma_reset),
    .endpoint_drained(drained),
    .source_tvalid(combined_tx_axis_tvalid),
    .register_tvalid(tx_fifo_s_tvalid),
    .fifo_wr_data_count(tx_fifo_wr_data_count),
    .pipeline_busy_async(tx_pipeline_busy_cmac),
    .tx_path_empty(rdma_tx_path_empty)
  );

  cmac_usplus_0_rdma_axis_register i_cmac_tx_axis_register (
    .clk(cmac_clk),
    .reset(cmac_reset),
    .flush(rdma_tx_flush_cmac),
    .s_axis_tvalid(tx_fifo_m_tvalid),
    .s_axis_tready(tx_fifo_m_tready),
    .s_axis_tdata(tx_fifo_m_tdata),
    .s_axis_tkeep(tx_fifo_m_tkeep),
    .s_axis_tlast(tx_fifo_m_tlast),
    .s_axis_tuser(tx_fifo_m_tuser),
    .m_axis_tvalid(tx_cmac_axis_tvalid),
    .m_axis_tready(tx_cmac_axis_tready),
    .m_axis_tdata(tx_cmac_axis_tdata),
    .m_axis_tkeep(tx_cmac_axis_tkeep),
    .m_axis_tlast(tx_cmac_axis_tlast),
    .m_axis_tuser(tx_cmac_axis_tuser)
  );

  cmac_usplus_0_rdma_tx_packet_arbiter i_tx_packet_arbiter (
    .clk(cmac_clk),
    .reset(cmac_reset),
    .rdma_abort(rdma_unavailable_cmac),
    .rdma_flush(rdma_tx_flush_cmac),
    .reply_axis_tready(reply_tx_axis_tready),
    .reply_axis_tvalid(reply_tx_axis_tvalid),
    .reply_axis_tdata(reply_tx_axis_tdata),
    .reply_axis_tkeep(reply_tx_axis_tkeep),
    .reply_axis_tlast(reply_tx_axis_tlast),
    .reply_axis_tuser(reply_tx_axis_tuser),
    .rdma_axis_tready(tx_cmac_axis_tready),
    .rdma_axis_tvalid(tx_cmac_axis_tvalid),
    .rdma_axis_tdata(tx_cmac_axis_tdata),
    .rdma_axis_tkeep(tx_cmac_axis_tkeep),
    .rdma_axis_tlast(tx_cmac_axis_tlast),
    .rdma_axis_tuser(tx_cmac_axis_tuser),
    .tx_axis_tready(tx_axis_tready),
    .tx_axis_tvalid(tx_axis_tvalid),
    .tx_axis_tdata(tx_axis_tdata),
    .tx_axis_tkeep(tx_axis_tkeep),
    .tx_axis_tlast(tx_axis_tlast),
    .tx_axis_tuser(tx_axis_tuser)
  );

  rdma_vio i_rdma_vio (
    .clk(rdma_clk),
    .probe_in0(configured),
    .probe_in1(active),
    .probe_in2(stopping),
    .probe_in3(drained && rdma_tx_path_empty),
    .probe_in4(fault),
    .probe_in5(safe_to_release),
    .probe_in6(final_commit_acked),
    .probe_in7(session_state),
    .probe_in8(fault_reason),
    .probe_in9(config_generation),
    .probe_in10(config_reject_count),
    .probe_in11(config_reject_reason),
    .probe_in12(icrc_drop_count),
    .probe_in13(invalid_psn_count),
    .probe_in14(nak_count),
    .probe_in15(retrans_count),
    .probe_in16(retry_exhausted_count),
    .probe_in17(rx_overflow_count),
    .probe_in18(tx_underflow_count),
    .probe_in19(issued_bytes),
    .probe_in20(acked_bytes),
    .probe_in21(published_bytes),
    .probe_in22(producer_sequence)
  );

  ila_rdma i_ila_rdma (
    .clk(rdma_clk),
    .probe0(debug_state),
    .probe1(current_psn),
    .probe2(icrc_drop_count),
    .probe3(invalid_psn_count),
    .probe4(retrans_count),
    .probe5(rx_overflow_count),
    .probe6(issued_bytes),
    .probe7(acked_bytes),
    .probe8(ring_offset),
    .probe9(fault),
    .probe10(active)
  );

endmodule

(* KEEP_HIERARCHY = "yes" *)
module cmac_usplus_0_rdma_tx_drain_tracker (
  input  logic        clk,
  input  logic        reset,
  input  logic        endpoint_drained,
  input  logic        source_tvalid,
  input  logic        register_tvalid,
  input  logic [31:0] fifo_wr_data_count,
  input  logic        pipeline_busy_async,
  output logic        tx_path_empty
);
  (* ASYNC_REG = "TRUE" *) logic pipeline_busy_sync1;
  (* ASYNC_REG = "TRUE" *) logic pipeline_busy_sync2;
  logic [3:0] empty_stable_count;

  always_ff @(posedge clk) begin
    if (reset) begin
      pipeline_busy_sync1 <= 1'b1;
      pipeline_busy_sync2 <= 1'b1;
      empty_stable_count <= 4'd0;
    end else begin
      pipeline_busy_sync1 <= pipeline_busy_async;
      pipeline_busy_sync2 <= pipeline_busy_sync1;
      if (!endpoint_drained || source_tvalid || register_tvalid ||
          (fifo_wr_data_count != 32'd0) || pipeline_busy_sync2) begin
        empty_stable_count <= 4'd0;
      end else if (!(&empty_stable_count)) begin
        empty_stable_count <= empty_stable_count + 4'd1;
      end
    end
  end

  assign tx_path_empty = &empty_stable_count;
endmodule

(* KEEP_HIERARCHY = "yes" *)
module cmac_usplus_0_rdma_axis_register (
  input  logic         clk,
  input  logic         reset,
  input  logic         flush,
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
  output logic         m_axis_tuser
);
  logic [1:0]   occupancy_reg;
  logic [511:0] data0_reg;
  logic [63:0]  keep0_reg;
  logic         last0_reg;
  logic         user0_reg;
  logic [511:0] data1_reg;
  logic [63:0]  keep1_reg;
  logic         last1_reg;
  logic         user1_reg;

  logic push;
  logic pop;

  assign s_axis_tready = occupancy_reg != 2;
  assign m_axis_tvalid = occupancy_reg != 0;
  assign m_axis_tdata = data0_reg;
  assign m_axis_tkeep = keep0_reg;
  assign m_axis_tlast = last0_reg;
  assign m_axis_tuser = user0_reg;
  assign push = s_axis_tvalid && s_axis_tready;
  assign pop = m_axis_tvalid && m_axis_tready;

  always_ff @(posedge clk) begin
    if (reset || flush) begin
      occupancy_reg <= 2'd0;
      data0_reg <= 512'd0;
      keep0_reg <= 64'd0;
      last0_reg <= 1'b0;
      user0_reg <= 1'b0;
      data1_reg <= 512'd0;
      keep1_reg <= 64'd0;
      last1_reg <= 1'b0;
      user1_reg <= 1'b0;
    end else begin
      case ({push, pop})
        2'b10: begin
          if (occupancy_reg == 0) begin
            data0_reg <= s_axis_tdata;
            keep0_reg <= s_axis_tkeep;
            last0_reg <= s_axis_tlast;
            user0_reg <= s_axis_tuser;
          end else begin
            data1_reg <= s_axis_tdata;
            keep1_reg <= s_axis_tkeep;
            last1_reg <= s_axis_tlast;
            user1_reg <= s_axis_tuser;
          end
          occupancy_reg <= occupancy_reg + 1'b1;
        end

        2'b01: begin
          if (occupancy_reg == 2) begin
            data0_reg <= data1_reg;
            keep0_reg <= keep1_reg;
            last0_reg <= last1_reg;
            user0_reg <= user1_reg;
          end
          occupancy_reg <= occupancy_reg - 1'b1;
        end

        2'b11: begin
          data0_reg <= s_axis_tdata;
          keep0_reg <= s_axis_tkeep;
          last0_reg <= s_axis_tlast;
          user0_reg <= s_axis_tuser;
        end

        default: begin
        end
      endcase
    end
  end
endmodule
