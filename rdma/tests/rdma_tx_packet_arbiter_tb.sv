`timescale 1ns / 1ps

module cmac_usplus_0_rdma_tx_packet_arbiter_tb;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic rdma_abort = 1'b0;
  logic rdma_flush;
  logic reply_axis_tready;
  logic reply_axis_tvalid = 1'b0;
  logic [511:0] reply_axis_tdata = 512'd0;
  logic [63:0] reply_axis_tkeep = 64'd0;
  logic reply_axis_tlast = 1'b0;
  logic reply_axis_tuser = 1'b0;
  logic rdma_axis_tready;
  logic rdma_axis_tvalid = 1'b0;
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

  logic [511:0] observed_data [0:7];
  logic [63:0] observed_keep [0:7];
  logic observed_last [0:7];
  logic observed_user [0:7];
  integer observed_count = 0;
  integer wait_cycles;

  always #2 clk = ~clk;

  cmac_usplus_0_rdma_tx_packet_arbiter dut (
    .clk(clk),
    .reset(reset),
    .rdma_abort(rdma_abort),
    .rdma_flush(rdma_flush),
    .reply_axis_tready(reply_axis_tready),
    .reply_axis_tvalid(reply_axis_tvalid),
    .reply_axis_tdata(reply_axis_tdata),
    .reply_axis_tkeep(reply_axis_tkeep),
    .reply_axis_tlast(reply_axis_tlast),
    .reply_axis_tuser(reply_axis_tuser),
    .rdma_axis_tready(rdma_axis_tready),
    .rdma_axis_tvalid(rdma_axis_tvalid),
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

  always @(posedge clk) begin
    if (tx_axis_tvalid && tx_axis_tready) begin
      observed_data[observed_count] = tx_axis_tdata;
      observed_keep[observed_count] = tx_axis_tkeep;
      observed_last[observed_count] = tx_axis_tlast;
      observed_user[observed_count] = tx_axis_tuser;
      observed_count = observed_count + 1;
    end
  end

  task automatic wait_for_observed_count(input integer expected_count);
    integer cycles;
    begin
      cycles = 0;
      while ((observed_count < expected_count) && (cycles < 20)) begin
        @(negedge clk);
        cycles = cycles + 1;
      end
      if (observed_count != expected_count) begin
        $fatal(1, "arbiter output count timeout: expected=%0d actual=%0d",
               expected_count, observed_count);
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    // Begin a multi-beat RDMA frame, then emulate loss of the RDMA MMCM lock.
    @(negedge clk);
    rdma_axis_tvalid = 1'b1;
    rdma_axis_tdata = 512'hA5;
    rdma_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
    rdma_axis_tlast = 1'b0;
    wait_for_observed_count(1);
    rdma_axis_tvalid = 1'b0;
    rdma_abort = 1'b1;
    wait_for_observed_count(2);

    if (observed_data[0] != 512'hA5 || observed_last[0] || observed_user[0] ||
        observed_data[1] != 512'd0 || observed_keep[1] != 64'h1 ||
        !observed_last[1] || !observed_user[1]) begin
      $fatal(1, "mid-frame RDMA abort did not emit one explicit bad TLAST beat");
    end

    @(negedge clk);
    rdma_abort = 1'b0;

    // The packet boundary is released after the abort, so replies and a later
    // RDMA frame can both make forward progress.
    reply_axis_tvalid = 1'b1;
    reply_axis_tdata = 512'hC3;
    reply_axis_tkeep = 64'h0000_0000_0000_00FF;
    reply_axis_tlast = 1'b1;
    wait_for_observed_count(3);
    reply_axis_tvalid = 1'b0;

    @(negedge clk);
    rdma_axis_tvalid = 1'b1;
    rdma_axis_tdata = 512'h5A;
    rdma_axis_tkeep = 64'h0000_0000_0000_FFFF;
    rdma_axis_tlast = 1'b1;
    wait_for_observed_count(4);
    rdma_axis_tvalid = 1'b0;

    if (observed_data[2] != 512'hC3 || !observed_last[2] || observed_user[2] ||
        observed_data[3] != 512'h5A || !observed_last[3] || observed_user[3]) begin
      $fatal(1, "arbiter did not recover after the RDMA abort boundary");
    end

    // An asynchronous lock-loss indication must not withdraw or alter a beat
    // that has already been presented while the CMAC is applying backpressure.
    @(negedge clk);
    tx_axis_tready = 1'b0;
    rdma_axis_tvalid = 1'b1;
    rdma_axis_tdata = 512'hD4;
    rdma_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
    rdma_axis_tlast = 1'b0;
    rdma_axis_tuser = 1'b0;
    wait_cycles = 0;
    while (!tx_axis_tvalid && (wait_cycles < 10)) begin
      @(negedge clk);
      wait_cycles = wait_cycles + 1;
    end
    if (!tx_axis_tvalid) $fatal(1, "arbiter did not present the stalled RDMA beat");

    #1 rdma_abort = 1'b1;
    #0.1;
    if (!tx_axis_tvalid || tx_axis_tdata != 512'hD4 ||
        tx_axis_tkeep != 64'hFFFF_FFFF_FFFF_FFFF || tx_axis_tlast || tx_axis_tuser) begin
      $fatal(1, "RDMA abort changed an AXIS beat before its handshake");
    end

    repeat (5) begin
      @(negedge clk);
      if (!tx_axis_tvalid || tx_axis_tdata != 512'hD4 ||
          tx_axis_tkeep != 64'hFFFF_FFFF_FFFF_FFFF || tx_axis_tlast ||
          tx_axis_tuser || rdma_flush) begin
        $fatal(1, "stalled RDMA beat was not held until abort handshake");
      end
    end

    tx_axis_tready = 1'b1;
    wait_for_observed_count(6);
    rdma_axis_tvalid = 1'b0;
    if (observed_data[4] != 512'hD4 || observed_last[4] || observed_user[4] ||
        observed_data[5] != 512'd0 || observed_keep[5] != 64'h1 ||
        !observed_last[5] || !observed_user[5]) begin
      $fatal(1, "synchronized RDMA abort did not preserve the beat and close the frame");
    end

    $display("cmac_usplus_0_rdma_tx_packet_arbiter_tb PASS");
    $finish;
  end

endmodule
