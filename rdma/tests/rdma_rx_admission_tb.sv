`timescale 1ns / 1ps

module rdma_rx_admission_tb;

  localparam integer FIFO_DEPTH_BEATS = 2048;
  localparam integer MAX_FRAME_BEATS = 150;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic rx_axis_tvalid = 1'b0;
  logic [511:0] rx_axis_tdata = 512'd0;
  logic [63:0] rx_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
  logic rx_axis_tlast = 1'b0;
  logic rx_axis_tuser = 1'b0;
  logic fifo_axis_tready = 1'b1;
  logic [11:0] fifo_wr_data_count = 12'd0;
  logic fifo_axis_tvalid;
  logic [511:0] fifo_axis_tdata;
  logic [63:0] fifo_axis_tkeep;
  logic fifo_axis_tlast;
  logic fifo_axis_tuser;
  logic overflow_event;
  logic [31:0] overflow_count;
  integer forwarded_beats = 0;

  always #2 clk = ~clk;

  rdma_rx_admission #(
    .FIFO_DEPTH_BEATS(FIFO_DEPTH_BEATS),
    .WR_COUNT_WIDTH(12)
  ) dut (
    .clk(clk),
    .reset(reset),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tkeep(rx_axis_tkeep),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tuser(rx_axis_tuser),
    .fifo_axis_tready(fifo_axis_tready),
    .fifo_wr_data_count(fifo_wr_data_count),
    .fifo_axis_tvalid(fifo_axis_tvalid),
    .fifo_axis_tdata(fifo_axis_tdata),
    .fifo_axis_tkeep(fifo_axis_tkeep),
    .fifo_axis_tlast(fifo_axis_tlast),
    .fifo_axis_tuser(fifo_axis_tuser),
    .overflow_event(overflow_event),
    .overflow_count(overflow_count)
  );

  always @(posedge clk) begin
    if (fifo_axis_tvalid && fifo_axis_tready) forwarded_beats = forwarded_beats + 1;
  end

  task automatic drive_frame(input integer beat_count, input integer initial_occupancy);
    integer beat_index;
    begin
      for (beat_index = 0; beat_index < beat_count; beat_index = beat_index + 1) begin
        @(negedge clk);
        fifo_wr_data_count = initial_occupancy + beat_index;
        rx_axis_tvalid = 1'b1;
        rx_axis_tdata = beat_index;
        rx_axis_tlast = (beat_index == (beat_count - 1));
      end
      @(negedge clk);
      rx_axis_tvalid = 1'b0;
      rx_axis_tlast = 1'b0;
      fifo_wr_data_count = 12'd0;
    end
  endtask

  initial begin
    integer forwarded_before;

    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    // Exactly 150 free entries admits the complete maximum-sized frame.
    forwarded_before = forwarded_beats;
    drive_frame(MAX_FRAME_BEATS, FIFO_DEPTH_BEATS - MAX_FRAME_BEATS);
    repeat (2) @(posedge clk);
    if ((forwarded_beats - forwarded_before) != MAX_FRAME_BEATS || overflow_count != 32'd0) begin
      $fatal(1, "150-beat frame was not admitted at the exact reservation boundary");
    end

    // One fewer free entry drops the whole frame and counts one frame event.
    forwarded_before = forwarded_beats;
    drive_frame(3, FIFO_DEPTH_BEATS - MAX_FRAME_BEATS + 1);
    repeat (2) @(posedge clk);
    if (forwarded_beats != forwarded_before || overflow_count != 32'd1) begin
      $fatal(1, "frame was not dropped atomically below the 150-beat boundary");
    end

    $display("rdma_rx_admission_tb PASS");
    $finish;
  end

endmodule
