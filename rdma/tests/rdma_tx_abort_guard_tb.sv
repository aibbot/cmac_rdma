`timescale 1ns / 1ps

module rdma_tx_abort_guard_tb;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic rdma_abort = 1'b0;
  logic rdma_flush;

  logic source_tvalid = 1'b0;
  logic source_tready;
  logic [511:0] source_tdata = 512'd0;
  logic [63:0] source_tkeep = 64'd0;
  logic source_tlast = 1'b0;
  logic source_tuser = 1'b0;

  logic buffered_tvalid;
  logic buffered_tready;
  logic [511:0] buffered_tdata;
  logic [63:0] buffered_tkeep;
  logic buffered_tlast;
  logic buffered_tuser;

  logic reply_tready;
  logic tx_tready = 1'b1;
  logic tx_tvalid;
  logic [511:0] tx_tdata;
  logic [63:0] tx_tkeep;
  logic tx_tlast;
  logic tx_tuser;

  logic [511:0] observed_data [0:3];
  logic [63:0] observed_keep [0:3];
  logic observed_last [0:3];
  logic observed_user [0:3];
  integer observed_count = 0;
  integer wait_cycles;

  always #2 clk = ~clk;

  rdma_axis_register i_cmac_tx_axis_register (
    .clk(clk),
    .reset(reset),
    .flush(rdma_flush),
    .s_axis_tvalid(source_tvalid),
    .s_axis_tready(source_tready),
    .s_axis_tdata(source_tdata),
    .s_axis_tkeep(source_tkeep),
    .s_axis_tlast(source_tlast),
    .s_axis_tuser(source_tuser),
    .m_axis_tvalid(buffered_tvalid),
    .m_axis_tready(buffered_tready),
    .m_axis_tdata(buffered_tdata),
    .m_axis_tkeep(buffered_tkeep),
    .m_axis_tlast(buffered_tlast),
    .m_axis_tuser(buffered_tuser)
  );

  rdma_tx_packet_arbiter i_tx_packet_arbiter (
    .clk(clk),
    .reset(reset),
    .rdma_abort(rdma_abort),
    .rdma_flush(rdma_flush),
    .reply_axis_tready(reply_tready),
    .reply_axis_tvalid(1'b0),
    .reply_axis_tdata(512'd0),
    .reply_axis_tkeep(64'd0),
    .reply_axis_tlast(1'b0),
    .reply_axis_tuser(1'b0),
    .rdma_axis_tready(buffered_tready),
    .rdma_axis_tvalid(buffered_tvalid),
    .rdma_axis_tdata(buffered_tdata),
    .rdma_axis_tkeep(buffered_tkeep),
    .rdma_axis_tlast(buffered_tlast),
    .rdma_axis_tuser(buffered_tuser),
    .tx_axis_tready(tx_tready),
    .tx_axis_tvalid(tx_tvalid),
    .tx_axis_tdata(tx_tdata),
    .tx_axis_tkeep(tx_tkeep),
    .tx_axis_tlast(tx_tlast),
    .tx_axis_tuser(tx_tuser)
  );

  always @(posedge clk) begin
    if (tx_tvalid && tx_tready) begin
      observed_data[observed_count] = tx_tdata;
      observed_keep[observed_count] = tx_tkeep;
      observed_last[observed_count] = tx_tlast;
      observed_user[observed_count] = tx_tuser;
      observed_count = observed_count + 1;
    end
  end

  task automatic push_beat(input logic [511:0] data, input logic last);
    begin
      @(negedge clk);
      wait_cycles = 0;
      while (!source_tready && (wait_cycles < 20)) begin
        @(negedge clk);
        wait_cycles = wait_cycles + 1;
      end
      if (!source_tready) $fatal(1, "CMAC guard buffer did not accept a source beat");
      source_tvalid = 1'b1;
      source_tdata = data;
      source_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
      source_tlast = last;
      source_tuser = 1'b0;
      @(posedge clk);
      #0.1 source_tvalid = 1'b0;
    end
  endtask

  task automatic wait_for_observed_count(input integer expected_count);
    begin
      wait_cycles = 0;
      while ((observed_count < expected_count) && (wait_cycles < 30)) begin
        @(negedge clk);
        wait_cycles = wait_cycles + 1;
      end
      if (observed_count != expected_count) begin
        $fatal(1, "guard output count timeout: expected=%0d actual=%0d",
               expected_count, observed_count);
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (4) @(posedge clk);

    push_beat(512'hA1, 1'b0);
    wait_for_observed_count(1);

    // B2 is already presented to a stalled CMAC; C3 is queued behind it and
    // must be discarded once the abort handshake safely retires B2.
    @(negedge clk);
    tx_tready = 1'b0;
    push_beat(512'hB2, 1'b0);
    push_beat(512'hC3, 1'b1);
    wait_cycles = 0;
    while (!tx_tvalid && (wait_cycles < 10)) begin
      @(negedge clk);
      wait_cycles = wait_cycles + 1;
    end
    if (!tx_tvalid || tx_tdata != 512'hB2 || tx_tlast || tx_tuser) begin
      $fatal(1, "guard did not present the expected stalled beat");
    end

    #1 rdma_abort = 1'b1;
    repeat (6) begin
      @(negedge clk);
      if (!tx_tvalid || tx_tdata != 512'hB2 || tx_tlast || tx_tuser || rdma_flush) begin
        $fatal(1, "guard changed or flushed the presented beat before handshake");
      end
    end

    tx_tready = 1'b1;
    wait_for_observed_count(3);
    if (observed_data[0] != 512'hA1 || observed_last[0] || observed_user[0] ||
        observed_data[1] != 512'hB2 || observed_last[1] || observed_user[1] ||
        observed_data[2] != 512'd0 || observed_keep[2] != 64'h1 ||
        !observed_last[2] || !observed_user[2]) begin
      $fatal(1, "guard did not preserve B2, discard C3, and emit the bad TLAST");
    end
    if (buffered_tvalid) $fatal(1, "guard flush left a stale beat buffered");

    $display("rdma_tx_abort_guard_tb PASS");
    $finish;
  end

endmodule
