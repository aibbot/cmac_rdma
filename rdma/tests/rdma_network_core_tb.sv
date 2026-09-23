`timescale 1ns / 1ps

module cmac_usplus_0_rdma_network_core_tb;
  logic clk = 1'b0;
  logic reset = 1'b1;
  logic rx_axis_tvalid = 1'b0;
  logic rx_axis_tready;
  logic [511:0] rx_axis_tdata = 512'd0;
  logic [63:0] rx_axis_tkeep = 64'd0;
  logic rx_axis_tlast = 1'b0;
  logic rx_axis_tuser = 1'b0;
  logic tx_axis_tvalid;
  logic [511:0] tx_axis_tdata;
  logic [63:0] tx_axis_tkeep;
  logic tx_axis_tlast;
  logic tx_axis_tuser;
  logic payload_axis_tready;
  logic configured;
  logic active;
  logic drained;
  logic [31:0] rx_classifier_drop_count;

  always #2 clk = ~clk;

  cmac_usplus_0_rdma_network_core #(
    .FAST_BENCHMARK_MODE(1'b1)
  ) dut (
    .clk(clk),
    .reset(reset),
    .rx_overflow_source_count(32'd0),
    .tx_pipeline_empty(1'b1),
    .tx_path_empty(1'b1),
    .retransmission_enable(1'b1),
    .payload_external_enable(1'b0),
    .payload_axis_tvalid(1'b0),
    .payload_axis_tready(payload_axis_tready),
    .payload_axis_tdata(512'd0),
    .payload_axis_tkeep(64'd0),
    .payload_axis_tlast(1'b0),
    .payload_axis_tuser(1'b0),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tready(rx_axis_tready),
    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tkeep(rx_axis_tkeep),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tuser(rx_axis_tuser),
    .tx_axis_tready(1'b1),
    .tx_axis_tvalid(tx_axis_tvalid),
    .tx_axis_tdata(tx_axis_tdata),
    .tx_axis_tkeep(tx_axis_tkeep),
    .tx_axis_tlast(tx_axis_tlast),
    .tx_axis_tuser(tx_axis_tuser),
    .configured(configured),
    .active(active),
    .credit_stalled(),
    .stopping(),
    .drained(drained),
    .endpoint_drained(),
    .fault(),
    .fault_reason(),
    .final_commit_acked(),
    .session_state(),
    .safe_to_release(),
    .config_generation(),
    .config_reject_count(),
    .config_reject_reason(),
    .icrc_drop_count(),
    .invalid_psn_count(),
    .nak_count(),
    .retrans_count(),
    .retry_exhausted_count(),
    .rx_overflow_count(),
    .tx_underflow_count(),
    .issued_bytes(),
    .acked_bytes(),
    .ring_offset(),
    .current_psn(),
    .debug_state(),
    .commit_count(),
    .immediate_count(),
    .published_bytes(),
    .producer_sequence(),
    .consumed_bytes(),
    .last_nak_syndrome(),
    .last_nak_psn(),
    .sequence_recovery_count(),
    .replay_active(),
    .rx_classifier_drop_count(rx_classifier_drop_count),
    .external_payload_active(),
    .payload_waiting(),
    .payload_accepted_count(),
    .payload_error_count()
  );

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    if (!drained || configured || active || tx_axis_tvalid ||
        payload_axis_tready || !rx_axis_tready)
      $fatal(1, "network core reset contract failed");

    rx_axis_tdata = 512'd0;
    rx_axis_tkeep = 64'h0000_0000_0000_3FFF;
    rx_axis_tlast = 1'b1;
    rx_axis_tvalid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rx_axis_tvalid = 1'b0;
    repeat (3) @(posedge clk);
    if (rx_classifier_drop_count != 32'd1)
      $fatal(1, "network core did not route invalid frame to drop accounting");

    $display("cmac_usplus_0_rdma_network_core_tb PASS");
    $finish;
  end
endmodule
