`timescale 1ps / 1ps

// Board-facing composition for the independent RoCEv2 bring-up path.
// CMAC remains in its native user-clock domain. RX is admitted before the
// asynchronous FIFO because CMAC RX has no tready; the protocol endpoint and
// VIO run at 250 MHz; TX returns through a packet-mode FIFO and is arbitrated
// with ARP/ICMP only at frame boundaries.
module cmac_usplus_0_rdma_board_endpoint #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01
) (
  input  logic         cmac_clk,
  input  logic         cmac_reset,
  input  logic [31:0]  local_ip,
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

  (* ASYNC_REG = "TRUE" *) logic [31:0] local_ip_sync1;
  (* ASYNC_REG = "TRUE" *) logic [31:0] local_ip_rdma;

  logic arp_sender_update;
  logic [47:0] arp_sender_mac;
  logic [31:0] arp_sender_ip;
  logic reply_tx_axis_tready;
  logic reply_tx_axis_tvalid;
  logic [511:0] reply_tx_axis_tdata;
  logic [63:0] reply_tx_axis_tkeep;
  logic reply_tx_axis_tlast;
  logic reply_tx_axis_tuser;

  logic learned_remote_valid;
  logic [47:0] learned_remote_mac;
  logic [31:0] learned_remote_ip;

  logic rx_fifo_s_tvalid;
  logic [511:0] rx_fifo_s_tdata;
  logic [63:0] rx_fifo_s_tkeep;
  logic rx_fifo_s_tlast;
  logic rx_fifo_s_tuser;
  logic rx_fifo_s_tready;
  logic [31:0] rx_fifo_wr_data_count;
  logic rx_fifo_m_tvalid;
  logic rx_fifo_m_tready;
  logic [511:0] rx_fifo_m_tdata;
  logic [63:0] rx_fifo_m_tkeep;
  logic rx_fifo_m_tlast;
  logic rx_fifo_m_tuser;
  logic [31:0] rx_overflow_count_cmac;
  logic [31:0] rx_overflow_count_cmac_rdma;

  logic rdma_tx_axis_tready;
  logic rdma_tx_axis_tvalid;
  logic [511:0] rdma_tx_axis_tdata;
  logic [63:0] rdma_tx_axis_tkeep;
  logic rdma_tx_axis_tlast;
  logic rdma_tx_axis_tuser;
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
  logic tx_cmac_axis_tvalid;
  logic tx_cmac_axis_tready;
  logic [511:0] tx_cmac_axis_tdata;
  logic [63:0] tx_cmac_axis_tkeep;
  logic tx_cmac_axis_tlast;
  logic tx_cmac_axis_tuser;
  logic rdma_tx_flush_cmac;

  logic cfg_apply;
  logic cfg_start;
  logic cfg_stop;
  logic cfg_clear_stats;
  logic cfg_force_remote_mac;
  logic [47:0] cfg_remote_mac;
  logic [31:0] cfg_remote_ip;
  logic [23:0] cfg_local_qpn;
  logic [23:0] cfg_remote_qpn;
  logic [23:0] cfg_local_psn;
  logic [23:0] cfg_remote_psn;
  logic [47:0] cfg_remote_base;
  logic [31:0] cfg_rkey;
  logic [31:0] cfg_ring_size;
  logic [31:0] cfg_wr_size;
  logic [63:0] cfg_local_base;
  logic cfg_enable_immediate;
  logic [31:0] cfg_notify_interval_bytes;
  logic [47:0] cfg_commit_remote_addr;
  logic cfg_allow_ring_wrap;

  logic configured;
  logic active;
  logic drained;
  logic fault;
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

  always_ff @(posedge rdma_clk) begin
    if (rdma_reset) begin
      local_ip_sync1 <= 32'd0;
      local_ip_rdma <= 32'd0;
    end else begin
      local_ip_sync1 <= local_ip;
      local_ip_rdma <= local_ip_sync1;
    end
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
    .local_ip(local_ip),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tkeep(rx_axis_tkeep),
    .rx_axis_tuser(rx_axis_tuser),
    .arp_sender_update(arp_sender_update),
    .arp_sender_mac(arp_sender_mac),
    .arp_sender_ip(arp_sender_ip),
    .tx_axis_tready(reply_tx_axis_tready),
    .tx_axis_tvalid(reply_tx_axis_tvalid),
    .tx_axis_tdata(reply_tx_axis_tdata),
    .tx_axis_tlast(reply_tx_axis_tlast),
    .tx_axis_tkeep(reply_tx_axis_tkeep),
    .tx_axis_tuser(reply_tx_axis_tuser)
  );

  cmac_usplus_0_rdma_arp_snapshot_cdc i_arp_snapshot_cdc (
    .src_clk(cmac_clk),
    .src_reset(cmac_reset),
    .src_update(arp_sender_update),
    .src_mac(arp_sender_mac),
    .src_ip(arp_sender_ip),
    .dst_clk(rdma_clk),
    .dst_reset(rdma_reset),
    .dst_valid(learned_remote_valid),
    .dst_mac(learned_remote_mac),
    .dst_ip(learned_remote_ip)
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
    .m_axis_tready(rx_fifo_m_tready),
    .m_axis_tdata(rx_fifo_m_tdata),
    .m_axis_tkeep(rx_fifo_m_tkeep),
    .m_axis_tlast(rx_fifo_m_tlast),
    .m_axis_tuser(rx_fifo_m_tuser)
  );

  cmac_usplus_0_rdma_endpoint #(
    .LOCAL_MAC(LOCAL_MAC),
    .FAST_BENCHMARK_MODE(1'b1)
  ) i_rdma_endpoint (
    .clk(rdma_clk),
    .reset(rdma_reset),
    .local_ip(local_ip_rdma),
    .learned_remote_valid(learned_remote_valid),
    .learned_remote_mac(learned_remote_mac),
    .learned_remote_ip(learned_remote_ip),
    .rx_overflow_source_count(rx_overflow_count_cmac_rdma),
    .cfg_apply(cfg_apply),
    .cfg_start(cfg_start),
    .cfg_stop(cfg_stop),
    .cfg_clear_stats(cfg_clear_stats),
    .cfg_force_remote_mac(cfg_force_remote_mac),
    .cfg_remote_mac(cfg_remote_mac),
    .cfg_remote_ip(cfg_remote_ip),
    .cfg_local_qpn(cfg_local_qpn),
    .cfg_remote_qpn(cfg_remote_qpn),
    .cfg_local_psn(cfg_local_psn),
    .cfg_remote_psn(cfg_remote_psn),
    .cfg_remote_base(cfg_remote_base),
    .cfg_rkey(cfg_rkey),
    .cfg_ring_size(cfg_ring_size),
    .cfg_wr_size(cfg_wr_size),
    .cfg_local_base(cfg_local_base),
    .cfg_enable_immediate(cfg_enable_immediate),
    .cfg_notify_interval_bytes(cfg_notify_interval_bytes),
    .cfg_commit_remote_addr(cfg_commit_remote_addr),
    .cfg_allow_ring_wrap(cfg_allow_ring_wrap),
    .rx_axis_tvalid(rx_fifo_m_tvalid),
    .rx_axis_tready(rx_fifo_m_tready),
    .rx_axis_tdata(rx_fifo_m_tdata),
    .rx_axis_tkeep(rx_fifo_m_tkeep),
    .rx_axis_tlast(rx_fifo_m_tlast),
    .rx_axis_tuser(rx_fifo_m_tuser),
    .tx_axis_tready(rdma_tx_axis_tready),
    .tx_axis_tvalid(rdma_tx_axis_tvalid),
    .tx_axis_tdata(rdma_tx_axis_tdata),
    .tx_axis_tkeep(rdma_tx_axis_tkeep),
    .tx_axis_tlast(rdma_tx_axis_tlast),
    .tx_axis_tuser(rdma_tx_axis_tuser),
    .configured(configured),
    .active(active),
    .drained(drained),
    .fault(fault),
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

  cmac_usplus_0_rdma_axis_register i_rdma_tx_axis_register (
    .clk(rdma_clk),
    .reset(rdma_reset),
    .flush(1'b0),
    .s_axis_tvalid(rdma_tx_axis_tvalid),
    .s_axis_tready(rdma_tx_axis_tready),
    .s_axis_tdata(rdma_tx_axis_tdata),
    .s_axis_tkeep(rdma_tx_axis_tkeep),
    .s_axis_tlast(rdma_tx_axis_tlast),
    .s_axis_tuser(rdma_tx_axis_tuser),
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
    .m_axis_aclk(cmac_clk),
    .m_axis_tvalid(tx_fifo_m_tvalid),
    .m_axis_tready(tx_fifo_m_tready),
    .m_axis_tdata(tx_fifo_m_tdata),
    .m_axis_tkeep(tx_fifo_m_tkeep),
    .m_axis_tlast(tx_fifo_m_tlast),
    .m_axis_tuser(tx_fifo_m_tuser)
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
    .probe_in2(drained),
    .probe_in3(fault),
    .probe_in4(config_reject_count),
    .probe_in5(icrc_drop_count),
    .probe_in6(invalid_psn_count),
    .probe_in7(nak_count),
    .probe_in8(retrans_count),
    .probe_in9(retry_exhausted_count),
    .probe_in10(rx_overflow_count),
    .probe_in11(tx_underflow_count),
    .probe_in12(issued_bytes),
    .probe_in13(acked_bytes),
    .probe_in14(ring_offset),
    .probe_in15(current_psn),
    .probe_in16(debug_state),
    .probe_in17(rx_overflow_count_cmac_rdma),
    .probe_in18(commit_count),
    .probe_in19(immediate_count),
    .probe_in20(published_bytes),
    .probe_in21(producer_sequence),
    .probe_in22(config_reject_reason),
    .probe_out0(cfg_apply),
    .probe_out1(cfg_start),
    .probe_out2(cfg_stop),
    .probe_out3(cfg_clear_stats),
    .probe_out4(cfg_force_remote_mac),
    .probe_out5(cfg_remote_mac),
    .probe_out6(cfg_remote_ip),
    .probe_out7(cfg_local_qpn),
    .probe_out8(cfg_remote_qpn),
    .probe_out9(cfg_local_psn),
    .probe_out10(cfg_remote_psn),
    .probe_out11(cfg_remote_base),
    .probe_out12(cfg_rkey),
    .probe_out13(cfg_ring_size),
    .probe_out14(cfg_wr_size),
    .probe_out15(cfg_local_base),
    .probe_out16(cfg_enable_immediate),
    .probe_out17(cfg_notify_interval_bytes),
    .probe_out18(cfg_commit_remote_addr),
    .probe_out19(cfg_allow_ring_wrap)
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
