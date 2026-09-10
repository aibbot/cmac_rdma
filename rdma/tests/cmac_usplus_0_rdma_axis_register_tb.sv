`timescale 1ns / 1ps

module cmac_usplus_0_rdma_axis_register_tb;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic flush = 1'b0;
  logic s_axis_tvalid = 1'b0;
  logic s_axis_tready;
  logic [511:0] s_axis_tdata = 512'd0;
  logic [63:0] s_axis_tkeep = 64'd0;
  logic s_axis_tlast = 1'b0;
  logic s_axis_tuser = 1'b0;
  logic m_axis_tvalid;
  logic m_axis_tready = 1'b0;
  logic [511:0] m_axis_tdata;
  logic [63:0] m_axis_tkeep;
  logic m_axis_tlast;
  logic m_axis_tuser;

  logic [511:0] observed_data [0:3];
  integer observed_count = 0;

  always #2 clk = ~clk;

  cmac_usplus_0_rdma_axis_register dut (
    .clk(clk),
    .reset(reset),
    .flush(flush),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser)
  );

  always @(posedge clk) begin
    if (m_axis_tvalid && m_axis_tready) begin
      observed_data[observed_count] = m_axis_tdata;
      observed_count = observed_count + 1;
    end
  end

  task automatic present_beat(
    input logic [511:0] data,
    input logic [63:0] keep,
    input logic last,
    input logic user
  );
    begin
      @(negedge clk);
      s_axis_tvalid = 1'b1;
      s_axis_tdata = data;
      s_axis_tkeep = keep;
      s_axis_tlast = last;
      s_axis_tuser = user;
      if (!s_axis_tready) $fatal(1, "axis register unexpectedly backpressured an available slot");
      @(posedge clk);
      #1;
      s_axis_tvalid = 1'b0;
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    // Two entries absorb downstream backpressure without exposing a
    // combinational m_axis_tready -> s_axis_tready path.
    present_beat(512'hA1, 64'hFFFF_FFFF_FFFF_FFFF, 1'b0, 1'b0);
    if (!m_axis_tvalid || m_axis_tdata != 512'hA1 || !s_axis_tready) begin
      $fatal(1, "axis register did not retain one output beat and one free slot");
    end

    present_beat(512'hB2, 64'h0000_0000_0000_00FF, 1'b1, 1'b0);
    if (!m_axis_tvalid || m_axis_tdata != 512'hA1 || s_axis_tready) begin
      $fatal(1, "axis register did not report a full two-entry buffer");
    end

    @(negedge clk);
    m_axis_tready = 1'b1;
    #1;
    if (s_axis_tready) begin
      $fatal(1, "upstream ready changed combinationally with downstream ready");
    end

    @(posedge clk);
    #1;
    if (!m_axis_tvalid || m_axis_tdata != 512'hB2 || !s_axis_tready) begin
      $fatal(1, "axis register did not advance to the second buffered beat");
    end

    @(negedge clk);
    s_axis_tvalid = 1'b1;
    s_axis_tdata = 512'hC3;
    s_axis_tkeep = 64'h1;
    s_axis_tlast = 1'b1;
    s_axis_tuser = 1'b1;
    @(posedge clk);
    #1;
    s_axis_tvalid = 1'b0;
    if (!m_axis_tvalid || m_axis_tdata != 512'hC3) begin
      $fatal(1, "axis register did not sustain simultaneous dequeue and enqueue");
    end

    @(posedge clk);
    #1;
    if (m_axis_tvalid || observed_count != 3 ||
        observed_data[0] != 512'hA1 || observed_data[1] != 512'hB2 ||
        observed_data[2] != 512'hC3) begin
      $fatal(1, "axis register reordered or lost data under backpressure");
    end

    // A synchronous flush discards stale beats after a coordinated abort.
    m_axis_tready = 1'b0;
    present_beat(512'hD4, 64'h1, 1'b1, 1'b0);
    @(negedge clk);
    flush = 1'b1;
    @(posedge clk);
    #1;
    if (m_axis_tvalid || !s_axis_tready) begin
      $fatal(1, "axis register flush did not discard buffered data");
    end
    flush = 1'b0;

    $display("cmac_usplus_0_rdma_axis_register_tb PASS");
    $finish;
  end

endmodule
