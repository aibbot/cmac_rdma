`timescale 1ns / 1ps

module cmac_usplus_0_rdma_rx_classifier_tb;
  logic clk = 1'b0;
  logic reset = 1'b1;
  logic s_axis_tvalid = 1'b0;
  logic s_axis_tready;
  logic [511:0] s_axis_tdata = 512'd0;
  logic [63:0] s_axis_tkeep = 64'd0;
  logic s_axis_tlast = 1'b0;
  logic s_axis_tuser = 1'b0;
  logic rdma_axis_tvalid;
  logic rdma_axis_tready = 1'b1;
  logic [511:0] rdma_axis_tdata;
  logic [63:0] rdma_axis_tkeep;
  logic rdma_axis_tlast;
  logic rdma_axis_tuser;
  logic control_axis_tvalid;
  logic control_axis_tready = 1'b1;
  logic [511:0] control_axis_tdata;
  logic [63:0] control_axis_tkeep;
  logic control_axis_tlast;
  logic control_axis_tuser;
  logic [31:0] drop_count;
  integer rdma_transfer_count = 0;
  integer control_transfer_count = 0;
  integer control_error_transfer_count = 0;

  always #2 clk = ~clk;

  always @(posedge clk) begin
    if (rdma_axis_tvalid && rdma_axis_tready)
      rdma_transfer_count <= rdma_transfer_count + 1;
    if (control_axis_tvalid && control_axis_tready) begin
      control_transfer_count <= control_transfer_count + 1;
      if (control_axis_tuser)
        control_error_transfer_count <= control_error_transfer_count + 1;
    end
  end

  cmac_usplus_0_rdma_rx_classifier dut (
    .clk(clk),
    .reset(reset),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .rdma_axis_tvalid(rdma_axis_tvalid),
    .rdma_axis_tready(rdma_axis_tready),
    .rdma_axis_tdata(rdma_axis_tdata),
    .rdma_axis_tkeep(rdma_axis_tkeep),
    .rdma_axis_tlast(rdma_axis_tlast),
    .rdma_axis_tuser(rdma_axis_tuser),
    .control_axis_tvalid(control_axis_tvalid),
    .control_axis_tready(control_axis_tready),
    .control_axis_tdata(control_axis_tdata),
    .control_axis_tkeep(control_axis_tkeep),
    .control_axis_tlast(control_axis_tlast),
    .control_axis_tuser(control_axis_tuser),
    .drop_count(drop_count)
  );

  task automatic set_byte(
    inout logic [511:0] data,
    input integer index,
    input logic [7:0] value
  );
    data[index * 8 +: 8] = value;
  endtask

  task automatic send_two_beat_control_error;
    logic [511:0] frame;
    begin
      frame = 512'd0;
      set_byte(frame, 12, 8'h08);
      set_byte(frame, 13, 8'h00);
      set_byte(frame, 14, 8'h45);
      set_byte(frame, 23, 8'h11);
      set_byte(frame, 36, 8'h12);
      set_byte(frame, 37, 8'hB8);
      @(negedge clk);
      s_axis_tdata = frame;
      s_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
      s_axis_tlast = 1'b0;
      s_axis_tuser = 1'b0;
      s_axis_tvalid = 1'b1;
      do @(posedge clk); while (!s_axis_tready);
      @(negedge clk);
      s_axis_tdata = 512'hA5;
      s_axis_tkeep = 64'h0000_0000_0000_0001;
      s_axis_tlast = 1'b1;
      s_axis_tuser = 1'b1;
      do @(posedge clk); while (!s_axis_tready);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      s_axis_tuser = 1'b0;
    end
  endtask

  task automatic send_udp(input logic [15:0] destination_port,
                          input logic error_frame);
    logic [511:0] frame;
    begin
      frame = 512'd0;
      set_byte(frame, 12, 8'h08);
      set_byte(frame, 13, 8'h00);
      set_byte(frame, 14, 8'h45);
      set_byte(frame, 20, 8'h00);
      set_byte(frame, 21, 8'h00);
      set_byte(frame, 23, 8'h11);
      set_byte(frame, 36, destination_port[15:8]);
      set_byte(frame, 37, destination_port[7:0]);
      @(negedge clk);
      s_axis_tdata = frame;
      s_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
      s_axis_tlast = 1'b1;
      s_axis_tuser = error_frame;
      s_axis_tvalid = 1'b1;
      do @(posedge clk); while (!s_axis_tready);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      s_axis_tuser = 1'b0;
    end
  endtask

  initial begin
    logic [511:0] back_to_back_frame;
    integer rdma_before;
    integer control_before;

    repeat (4) @(posedge clk);
    reset = 1'b0;

    send_udp(16'd4791, 1'b0);
    wait (rdma_axis_tvalid);
    if (!rdma_axis_tlast || rdma_axis_tdata[37 * 8 +: 8] != 8'hB7)
      $fatal(1, "RoCE frame was not routed to the RDMA output");
    @(posedge clk);

    control_axis_tready = 1'b0;
    send_udp(16'd4792, 1'b0);
    wait (control_axis_tvalid);
    repeat (3) begin
      @(posedge clk);
      if (!control_axis_tvalid || control_axis_tdata[37 * 8 +: 8] != 8'hB8)
        $fatal(1, "control frame changed under backpressure");
    end
    control_axis_tready = 1'b1;
    @(posedge clk);

    send_udp(16'd5000, 1'b0);
    send_udp(16'd4792, 1'b1);
    repeat (8) @(posedge clk);
    if (rdma_axis_tvalid || control_axis_tvalid || drop_count != 32'd2)
      $fatal(1, "drop classification/count is wrong");

    control_before = control_transfer_count;
    send_two_beat_control_error();
    repeat (4) @(posedge clk);
    if (control_transfer_count != control_before + 2 ||
        control_error_transfer_count != 1)
      $fatal(1, "last-beat CMAC error truncated the routed control frame");

    // The registered classifier must sustain one accepted beat per cycle.
    rdma_before = rdma_transfer_count;
    control_before = control_transfer_count;
    back_to_back_frame = 512'd0;
    set_byte(back_to_back_frame, 12, 8'h08);
    set_byte(back_to_back_frame, 13, 8'h00);
    set_byte(back_to_back_frame, 14, 8'h45);
    set_byte(back_to_back_frame, 23, 8'h11);
    set_byte(back_to_back_frame, 36, 8'h12);
    set_byte(back_to_back_frame, 37, 8'hB7);
    @(negedge clk);
    s_axis_tdata = back_to_back_frame;
    s_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
    s_axis_tlast = 1'b1;
    s_axis_tvalid = 1'b1;
    if (!s_axis_tready) $fatal(1, "classifier was not ready for first full-rate beat");
    @(negedge clk);
    set_byte(back_to_back_frame, 37, 8'hB8);
    s_axis_tdata = back_to_back_frame;
    if (!s_axis_tready) $fatal(1, "classifier inserted a bubble between ready outputs");
    @(negedge clk);
    s_axis_tvalid = 1'b0;
    repeat (4) @(posedge clk);
    if (rdma_transfer_count != rdma_before + 1 ||
        control_transfer_count != control_before + 1)
      $fatal(1, "back-to-back routes were not both delivered");

    $display("cmac_usplus_0_rdma_rx_classifier_tb PASS");
    $finish;
  end
endmodule
