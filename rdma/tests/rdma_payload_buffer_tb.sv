`timescale 1ns / 1ps

module cmac_usplus_0_rdma_payload_buffer_tb;
  localparam integer PACKET_BYTES = 4096;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic enable = 1'b1;
  logic flush = 1'b0;
  logic s_axis_tvalid = 1'b0;
  logic s_axis_tready;
  logic [511:0] s_axis_tdata = 512'd0;
  logic [63:0] s_axis_tkeep = 64'd0;
  logic s_axis_tlast = 1'b0;
  logic s_axis_tuser = 1'b0;
  logic packet_valid;
  logic [15:0] packet_length;
  logic packet_release = 1'b0;
  logic buffer_empty;
  logic read_enable = 1'b0;
  logic [5:0] read_address = 6'd0;
  logic [511:0] read_data;
  logic [31:0] accepted_packet_count;
  logic [31:0] error_packet_count;

  always #2 clk = ~clk;

  cmac_usplus_0_rdma_payload_buffer #(
    .PACKET_BYTES(PACKET_BYTES)
  ) dut (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .flush(flush),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .packet_valid(packet_valid),
    .packet_length(packet_length),
    .packet_release(packet_release),
    .buffer_empty(buffer_empty),
    .read_enable(read_enable),
    .read_address(read_address),
    .read_data(read_data),
    .accepted_packet_count(accepted_packet_count),
    .error_packet_count(error_packet_count)
  );

  function automatic logic [511:0] payload_word(input integer beat_index);
    integer lane;
    begin
      payload_word = 512'd0;
      for (lane = 0; lane < 64; lane = lane + 1)
        payload_word[lane * 8 +: 8] = (beat_index * 64 + lane) & 8'hFF;
    end
  endfunction

  task automatic send_beat(
    input logic [511:0] data,
    input logic [63:0] keep,
    input logic last,
    input logic user_value
  );
    begin
      @(negedge clk);
      s_axis_tdata = data;
      s_axis_tkeep = keep;
      s_axis_tlast = last;
      s_axis_tuser = user_value;
      s_axis_tvalid = 1'b1;
      do @(posedge clk); while (!s_axis_tready);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
    end
  endtask

  task automatic expect_word(
    input logic [5:0] address,
    input logic [511:0] expected
  );
    begin
      @(negedge clk);
      read_address = address;
      read_enable = 1'b1;
      @(posedge clk);
      @(negedge clk);
      read_enable = 1'b0;
      if (read_data != expected)
        $fatal(1, "payload beat %0d mismatch", address);
    end
  endtask

  integer beat;
  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    for (beat = 0; beat < 64; beat = beat + 1)
      send_beat(payload_word(beat), 64'hFFFF_FFFF_FFFF_FFFF,
                beat == 63, 1'b0);

    if (!packet_valid || packet_length != PACKET_BYTES || s_axis_tready ||
        accepted_packet_count != 32'd1 || error_packet_count != 32'd0)
      $fatal(1, "valid payload frame was not retained");

    expect_word(6'd0, payload_word(0));
    expect_word(6'd1, payload_word(1));
    expect_word(6'd3, payload_word(3));
    expect_word(6'd63, payload_word(63));

    @(negedge clk);
    packet_release = 1'b1;
    @(posedge clk);
    @(negedge clk);
    packet_release = 1'b0;
    if (packet_valid || !s_axis_tready)
      $fatal(1, "released payload slot did not become available");

    send_beat(payload_word(0), 64'hFFFF_FFFF_FFFF_FFFE, 1'b1, 1'b0);
    if (packet_valid || error_packet_count != 32'd1)
      $fatal(1, "invalid tkeep was accepted");

    send_beat(payload_word(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1, 1'b0);
    if (packet_valid || error_packet_count != 32'd2)
      $fatal(1, "short payload frame was accepted");

    for (beat = 0; beat < 64; beat = beat + 1)
      send_beat(payload_word(beat), 64'hFFFF_FFFF_FFFF_FFFF,
                beat == 63, 1'b0);
    if (!packet_valid)
      $fatal(1, "second valid payload frame was not retained");

    @(negedge clk);
    flush = 1'b1;
    @(posedge clk);
    @(negedge clk);
    flush = 1'b0;
    #1ps;
    if (packet_valid || !s_axis_tready ||
        accepted_packet_count != 32'd2 || error_packet_count != 32'd3)
      $fatal(1, "nonempty flush mismatch valid=%0b ready=%0b accepted=%0d errors=%0d",
             packet_valid, s_axis_tready, accepted_packet_count,
             error_packet_count);

    send_beat(payload_word(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b0, 1'b1);
    if (packet_valid || error_packet_count != 32'd4 || !s_axis_tready)
      $fatal(1, "tuser frame was not counted and drained");
    send_beat(payload_word(1), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1, 1'b0);
    if (packet_valid || error_packet_count != 32'd4 || !s_axis_tready)
      $fatal(1, "tuser drop did not finish at TLAST");

    for (beat = 0; beat < 64; beat = beat + 1)
      send_beat(payload_word(beat), 64'hFFFF_FFFF_FFFF_FFFF,
                1'b0, 1'b0);
    if (packet_valid || error_packet_count != 32'd5 || !s_axis_tready)
      $fatal(1, "missing TLAST was not counted and drained");
    send_beat(payload_word(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1, 1'b0);
    if (packet_valid || error_packet_count != 32'd5 || !s_axis_tready)
      $fatal(1, "late TLAST did not complete drop drain");

    for (beat = 0; beat < 32; beat = beat + 1)
      send_beat(payload_word(beat), 64'hFFFF_FFFF_FFFF_FFFF,
                1'b0, 1'b0);
    @(negedge clk);
    enable = 1'b0;
    #1ps;
    if (!s_axis_tready)
      $fatal(1, "enable withdrawal interrupted an in-progress frame");
    for (beat = 32; beat < 64; beat = beat + 1)
      send_beat(payload_word(beat), 64'hFFFF_FFFF_FFFF_FFFF,
                beat == 63, 1'b0);
    if (!packet_valid || packet_length != PACKET_BYTES ||
        accepted_packet_count != 32'd3 || error_packet_count != 32'd5)
      $fatal(1, "frame did not complete after enable withdrawal");

    @(negedge clk);
    packet_release = 1'b1;
    @(posedge clk);
    @(negedge clk);
    packet_release = 1'b0;
    enable = 1'b1;
    #1ps;
    if (packet_valid || !s_axis_tready)
      $fatal(1, "slot did not reopen after held frame release");

    for (beat = 0; beat < 4; beat = beat + 1)
      send_beat(payload_word(beat), 64'hFFFF_FFFF_FFFF_FFFF,
                1'b0, 1'b0);
    @(negedge clk);
    flush = 1'b1;
    #1ps;
    if (!s_axis_tready)
      $fatal(1, "flush interrupted an in-progress AXIS frame");
    @(posedge clk);
    @(negedge clk);
    flush = 1'b0;
    if (error_packet_count != 32'd6 || !s_axis_tready)
      $fatal(1, "partial flush was not counted and drained");
    send_beat(payload_word(0), 64'hFFFF_FFFF_FFFF_FFFF, 1'b1, 1'b0);
    if (packet_valid || error_packet_count != 32'd6 || !s_axis_tready)
      $fatal(1, "partial flush drop did not finish at TLAST");

    $display("cmac_usplus_0_rdma_payload_buffer_tb PASS");
    $finish;
  end
endmodule
