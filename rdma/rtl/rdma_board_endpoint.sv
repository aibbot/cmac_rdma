`timescale 1ps / 1ps

`ifndef RDMA_BUILD_TAG
`define RDMA_BUILD_TAG 32'h0000_0000
`endif

// Board-facing composition for the product RoCEv2 path. The local network
// identity is fixed at build time; all session state comes from RDCP/UDP.
module cmac_usplus_0_rdma_board_endpoint #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
  parameter logic [31:0] LOCAL_IP = 32'hC0A8_110B,
  parameter logic [31:0] BUILD_TAG = `RDMA_BUILD_TAG
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
  logic [31:0] rx_classifier_drop_count;

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
  // Keep the asynchronous drain indication in the CMAC clock domain before
  // handing it to the two-stage RDMA-domain synchronizer.
  logic tx_pipeline_busy_cmac_reg;
  logic tx_pipeline_busy_cmac;
  logic tx_pipeline_empty;
  logic rdma_tx_path_empty;

  logic [63:0] consumed_bytes;

  logic configured;
  logic active;
  logic credit_stalled;
  logic stopping;
  logic drained;
  logic endpoint_drained;
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
  logic [7:0] last_nak_syndrome;
  logic [23:0] last_nak_psn;
  logic [31:0] sequence_recovery_count;
  logic replay_active;
  logic retransmission_enable;
  (* keep = "true" *) logic [31:0] build_tag_probe;

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

  // Preserve a named VIO bus instead of exposing BUILD_TAG as 32 constants.
  always_ff @(posedge rdma_clk) begin
    if (rdma_reset)
      build_tag_probe <= BUILD_TAG;
  end

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

  cmac_usplus_0_rdma_network_core #(
    .LOCAL_MAC(LOCAL_MAC),
    .LOCAL_IP(LOCAL_IP),
    .LOCAL_QPN(24'd1),
    .FAST_BENCHMARK_MODE(1'b1)
  ) i_network_core (
    .clk(rdma_clk),
    .reset(rdma_reset),
    .rx_overflow_source_count(rx_overflow_count_cmac_rdma),
    .tx_pipeline_empty(tx_pipeline_empty),
    .tx_path_empty(rdma_tx_path_empty),
    .retransmission_enable(retransmission_enable),
    .payload_external_enable(1'b0),
    .payload_axis_tvalid(1'b0),
    .payload_axis_tready(),
    .payload_axis_tdata(512'd0),
    .payload_axis_tkeep(64'd0),
    .payload_axis_tlast(1'b0),
    .payload_axis_tuser(1'b0),
    .rx_axis_tvalid(rx_fifo_m_tvalid),
    .rx_axis_tready(classifier_rx_axis_tready),
    .rx_axis_tdata(rx_fifo_m_tdata),
    .rx_axis_tkeep(rx_fifo_m_tkeep),
    .rx_axis_tlast(rx_fifo_m_tlast),
    .rx_axis_tuser(rx_fifo_m_tuser),
    .tx_axis_tready(combined_tx_axis_tready),
    .tx_axis_tvalid(combined_tx_axis_tvalid),
    .tx_axis_tdata(combined_tx_axis_tdata),
    .tx_axis_tkeep(combined_tx_axis_tkeep),
    .tx_axis_tlast(combined_tx_axis_tlast),
    .tx_axis_tuser(combined_tx_axis_tuser),
    .configured(configured),
    .active(active),
    .credit_stalled(credit_stalled),
    .stopping(stopping),
    .drained(drained),
    .endpoint_drained(endpoint_drained),
    .fault(fault),
    .fault_reason(fault_reason),
    .final_commit_acked(final_commit_acked),
    .session_state(session_state),
    .safe_to_release(safe_to_release),
    .config_generation(config_generation),
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
    .consumed_bytes(consumed_bytes),
    .last_nak_syndrome(last_nak_syndrome),
    .last_nak_psn(last_nak_psn),
    .sequence_recovery_count(sequence_recovery_count),
    .replay_active(replay_active),
    .rx_classifier_drop_count(rx_classifier_drop_count),
    .external_payload_active(),
    .payload_waiting(),
    .payload_accepted_count(),
    .payload_error_count()
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

  always_ff @(posedge cmac_clk) begin
    if (cmac_reset) begin
      tx_pipeline_busy_cmac_reg <= 1'b1;
    end else begin
      tx_pipeline_busy_cmac_reg <= tx_fifo_m_tvalid || tx_cmac_axis_tvalid;
    end
  end

  assign tx_pipeline_busy_cmac = tx_pipeline_busy_cmac_reg;

  cmac_usplus_0_rdma_tx_drain_tracker i_tx_drain_tracker (
    .clk(rdma_clk),
    .reset(rdma_reset),
    .endpoint_drained(endpoint_drained),
    .source_tvalid(combined_tx_axis_tvalid),
    .register_tvalid(tx_fifo_s_tvalid),
    .fifo_wr_data_count(tx_fifo_wr_data_count),
    .pipeline_busy_async(tx_pipeline_busy_cmac),
    .pipeline_empty(tx_pipeline_empty),
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
    .probe_in3(drained),
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
    .probe_in22(producer_sequence),
    .probe_in23(consumed_bytes),
    .probe_in24(credit_stalled),
    .probe_in25(last_nak_syndrome),
    .probe_in26(last_nak_psn),
    .probe_in27(sequence_recovery_count),
    .probe_in28(replay_active),
    .probe_in29(build_tag_probe),
    .probe_out0(retransmission_enable)
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
