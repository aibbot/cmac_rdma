`timescale 1ns / 1ps

module cmac_usplus_0_rdma_tx_frame_arbiter_tb;
  logic clk = 1'b0;
  logic reset = 1'b1;
  logic control_axis_tvalid = 1'b0;
  logic control_axis_tready;
  logic [511:0] control_axis_tdata = 512'd0;
  logic [63:0] control_axis_tkeep = 64'd0;
  logic control_axis_tlast = 1'b0;
  logic control_axis_tuser = 1'b0;
  logic rdma_axis_tvalid = 1'b0;
  logic rdma_axis_tready;
  logic [511:0] rdma_axis_tdata = 512'd0;
  logic [63:0] rdma_axis_tkeep = 64'd0;
  logic rdma_axis_tlast = 1'b0;
  logic rdma_axis_tuser = 1'b0;
  logic tx_axis_tready = 1'b1;
  logic tx_axis_tvalid;
  logic [511:0] tx_axis_tdata;
  logic [63:0] tx_axis_tkeep;
  logic tx_axis_tlast;
  logic tx_axis_tuser;

  always #2 clk = ~clk;

  cmac_usplus_0_rdma_tx_frame_arbiter dut (
    .clk(clk),
    .reset(reset),
    .control_axis_tvalid(control_axis_tvalid),
    .control_axis_tready(control_axis_tready),
    .control_axis_tdata(control_axis_tdata),
    .control_axis_tkeep(control_axis_tkeep),
    .control_axis_tlast(control_axis_tlast),
    .control_axis_tuser(control_axis_tuser),
    .rdma_axis_tvalid(rdma_axis_tvalid),
    .rdma_axis_tready(rdma_axis_tready),
    .rdma_axis_tdata(rdma_axis_tdata),
    .rdma_axis_tkeep(rdma_axis_tkeep),
    .rdma_axis_tlast(rdma_axis_tlast),
    .rdma_axis_tuser(rdma_axis_tuser),
    .tx_axis_tready(tx_axis_tready),
    .tx_axis_tvalid(tx_axis_tvalid),
    .tx_axis_tdata(tx_axis_tdata),
    .tx_axis_tkeep(tx_axis_tkeep),
    .tx_axis_tlast(tx_axis_tlast),
    .tx_axis_tuser(tx_axis_tuser)
  );

  initial begin
    repeat (4) @(posedge clk);
    reset = 1'b0;

    // Once an idle source presents VALID, hold that source through
    // backpressure even if the higher-priority control source arrives later.
    @(negedge clk);
    tx_axis_tready = 1'b0;
    rdma_axis_tvalid = 1'b1;
    rdma_axis_tdata = 512'hD3;
    rdma_axis_tkeep = 64'h1;
    rdma_axis_tlast = 1'b1;
    @(posedge clk);
    if (!tx_axis_tvalid || tx_axis_tdata != 512'hD3)
      $fatal(1, "RDMA first beat was not presented before backpressure");

    @(negedge clk);
    control_axis_tvalid = 1'b1;
    control_axis_tdata = 512'hC3;
    control_axis_tkeep = 64'h1;
    control_axis_tlast = 1'b1;
    @(posedge clk);
    if (!tx_axis_tvalid || tx_axis_tdata != 512'hD3 ||
        rdma_axis_tready || control_axis_tready)
      $fatal(1, "arbiter changed source while the first RDMA beat was stalled");

    @(negedge clk);
    tx_axis_tready = 1'b1;
    @(posedge clk);
    if (!rdma_axis_tready || control_axis_tready || tx_axis_tdata != 512'hD3)
      $fatal(1, "stalled RDMA beat was not transferred first");

    @(negedge clk);
    rdma_axis_tvalid = 1'b0;
    @(posedge clk);
    if (!control_axis_tready || tx_axis_tdata != 512'hC3)
      $fatal(1, "control response did not follow the stalled RDMA frame");

    @(negedge clk);
    control_axis_tvalid = 1'b0;

    @(negedge clk);
    control_axis_tvalid = 1'b1;
    control_axis_tdata = 512'hC0;
    control_axis_tkeep = 64'h1;
    control_axis_tlast = 1'b1;
    rdma_axis_tvalid = 1'b1;
    rdma_axis_tdata = 512'hD0;
    rdma_axis_tkeep = 64'h1;
    rdma_axis_tlast = 1'b0;
    @(posedge clk);
    if (!tx_axis_tvalid || tx_axis_tdata != 512'hC0 || !control_axis_tready || rdma_axis_tready)
      $fatal(1, "control response did not win an idle-frame tie");

    @(negedge clk);
    control_axis_tvalid = 1'b0;
    rdma_axis_tdata = 512'hD1;
    @(posedge clk);
    if (!tx_axis_tvalid || tx_axis_tdata != 512'hD1 || !rdma_axis_tready)
      $fatal(1, "RDMA frame did not start after the control frame");

    @(negedge clk);
    control_axis_tvalid = 1'b1;
    control_axis_tdata = 512'hC1;
    control_axis_tlast = 1'b1;
    rdma_axis_tdata = 512'hD2;
    rdma_axis_tlast = 1'b1;
    @(posedge clk);
    if (!tx_axis_tvalid || tx_axis_tdata != 512'hD2 || !rdma_axis_tready || control_axis_tready)
      $fatal(1, "control response interleaved into an RDMA frame");

    @(negedge clk);
    rdma_axis_tvalid = 1'b0;
    @(posedge clk);
    if (!tx_axis_tvalid || tx_axis_tdata != 512'hC1 || !control_axis_tready)
      $fatal(1, "queued control response was not selected at the boundary");

    $display("cmac_usplus_0_rdma_tx_frame_arbiter_tb PASS");
    $finish;
  end
endmodule
