`timescale 1ns / 1ps

module cmac_usplus_0_rdcp_rx_validate_tb;
  import cmac_usplus_0_rdcp_pkg::*;

  localparam logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;
  localparam logic [31:0] LOCAL_IP = 32'hC0A8_110B;
  localparam logic [47:0] HOST_MAC = 48'h02_00_00_00_00_A0;
  localparam logic [31:0] HOST_IP = 32'hC0A8_110A;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic s_axis_tvalid = 1'b0;
  logic s_axis_tready;
  logic [511:0] s_axis_tdata = 512'd0;
  logic [63:0] s_axis_tkeep = 64'd0;
  logic s_axis_tlast = 1'b0;
  logic s_axis_tuser = 1'b0;
  logic capture_enable = 1'b1;
  logic request_valid;
  logic request_ready = 1'b0;
  rdcp_validated_request_t request;

  logic [7:0] frame_bytes [0:127];
  integer frame_length;

  always #2 clk = ~clk;

  cmac_usplus_0_rdcp_rx_validate #(
    .LOCAL_MAC(LOCAL_MAC),
    .LOCAL_IP(LOCAL_IP)
  ) dut (
    .clk(clk),
    .reset(reset),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .capture_enable(capture_enable),
    .request_valid(request_valid),
    .request_ready(request_ready),
    .request(request)
  );

  task automatic clear_frame;
    integer index;
    begin
      for (index = 0; index < 128; index = index + 1)
        frame_bytes[index] = 8'd0;
    end
  endtask

  task automatic set_be16(input integer offset, input logic [15:0] value);
    begin
      frame_bytes[offset] = value[15:8];
      frame_bytes[offset + 1] = value[7:0];
    end
  endtask

  task automatic set_be32(input integer offset, input logic [31:0] value);
    begin
      frame_bytes[offset] = value[31:24];
      frame_bytes[offset + 1] = value[23:16];
      frame_bytes[offset + 2] = value[15:8];
      frame_bytes[offset + 3] = value[7:0];
    end
  endtask

  task automatic set_be48(input integer offset, input logic [47:0] value);
    begin
      frame_bytes[offset] = value[47:40];
      frame_bytes[offset + 1] = value[39:32];
      frame_bytes[offset + 2] = value[31:24];
      frame_bytes[offset + 3] = value[23:16];
      frame_bytes[offset + 4] = value[15:8];
      frame_bytes[offset + 5] = value[7:0];
    end
  endtask

  task automatic set_be64(input integer offset, input logic [63:0] value);
    begin
      set_be32(offset, value[63:32]);
      set_be32(offset + 4, value[31:0]);
    end
  endtask

  task automatic build_request(input logic [15:0] payload_length);
    logic [15:0] ip_length;
    logic [15:0] udp_length;
    begin
      clear_frame();
      frame_length = 62 + payload_length;
      ip_length = 16'd48 + payload_length;
      udp_length = 16'd28 + payload_length;
      set_be48(0, LOCAL_MAC);
      set_be48(6, HOST_MAC);
      set_be16(12, 16'h0800);
      frame_bytes[14] = 8'h45;
      set_be16(16, ip_length);
      set_be16(18, 16'h0102);
      set_be16(20, 16'd0);
      frame_bytes[22] = 8'd64;
      frame_bytes[23] = 8'd17;
      set_be32(26, HOST_IP);
      set_be32(30, LOCAL_IP);
      set_be16(34, 16'd55000);
      set_be16(36, 16'd4792);
      set_be16(38, udp_length);
      set_be32(42, 32'h5244_4350);
      frame_bytes[46] = 8'd2;
      frame_bytes[47] = 8'd1;
      set_be16(48, payload_length);
      set_be64(50, 64'd0);
      set_be32(58, 32'd1);
    end
  endtask

  task automatic finish_checksums;
    integer index;
    integer sum;
    logic [15:0] checksum;
    logic [15:0] udp_length;
    begin
      set_be16(24, 16'd0);
      sum = 0;
      for (index = 14; index < 34; index = index + 2)
        sum = sum + {frame_bytes[index], frame_bytes[index + 1]};
      sum = (sum & 16'hFFFF) + (sum >> 16);
      sum = (sum & 16'hFFFF) + (sum >> 16);
      checksum = ~sum[15:0];
      set_be16(24, checksum);

      set_be16(40, 16'd0);
      udp_length = {frame_bytes[38], frame_bytes[39]};
      sum = {frame_bytes[26], frame_bytes[27]} +
            {frame_bytes[28], frame_bytes[29]} +
            {frame_bytes[30], frame_bytes[31]} +
            {frame_bytes[32], frame_bytes[33]} + 16'd17 + udp_length;
      for (index = 34; index < frame_length; index = index + 2) begin
        if (index + 1 < frame_length)
          sum = sum + {frame_bytes[index], frame_bytes[index + 1]};
        else
          sum = sum + {frame_bytes[index], 8'd0};
      end
      sum = (sum & 16'hFFFF) + (sum >> 16);
      sum = (sum & 16'hFFFF) + (sum >> 16);
      checksum = ~sum[15:0];
      if (checksum == 16'd0)
        checksum = 16'hFFFF;
      set_be16(40, checksum);
    end
  endtask

  task automatic send_frame;
    integer offset;
    integer index;
    integer valid_bytes;
    integer ready_cycles;
    logic [511:0] word;
    logic [63:0] keep;
    begin
      offset = 0;
      while (offset < frame_length) begin
        word = 512'd0;
        keep = 64'd0;
        valid_bytes = frame_length - offset;
        if (valid_bytes > 64)
          valid_bytes = 64;
        for (index = 0; index < valid_bytes; index = index + 1) begin
          word[index * 8 +: 8] = frame_bytes[offset + index];
          keep[index] = 1'b1;
        end
        @(negedge clk);
        s_axis_tdata = word;
        s_axis_tkeep = keep;
        s_axis_tlast = offset + valid_bytes == frame_length;
        s_axis_tvalid = 1'b1;
        ready_cycles = 0;
        do begin
          @(posedge clk);
          ready_cycles = ready_cycles + 1;
          if (ready_cycles == 400)
            $fatal(1, "timeout waiting for validator input ready");
        end while (!s_axis_tready);
        offset = offset + valid_bytes;
      end
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      s_axis_tkeep = 64'd0;
    end
  endtask

  task automatic drive_beat(
    input logic [511:0] word,
    input logic [63:0] keep,
    input logic last,
    input logic user
  );
    integer cycles;
    begin
      @(negedge clk);
      s_axis_tdata = word;
      s_axis_tkeep = keep;
      s_axis_tlast = last;
      s_axis_tuser = user;
      s_axis_tvalid = 1'b1;
      cycles = 0;
      do begin
        @(posedge clk);
        cycles = cycles + 1;
        if (cycles == 400)
          $fatal(1, "timeout waiting for validator input ready");
      end while (!s_axis_tready);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      s_axis_tuser = 1'b0;
      s_axis_tkeep = 64'd0;
    end
  endtask

  task automatic send_one_beat_custom(
    input logic [63:0] keep,
    input logic user
  );
    integer index;
    logic [511:0] word;
    begin
      word = 512'd0;
      for (index = 0; index < frame_length; index = index + 1)
        word[index * 8 +: 8] = frame_bytes[index];
      drive_beat(word, keep, 1'b1, user);
    end
  endtask

  task automatic send_two_beat_custom(
    input logic [63:0] keep0,
    input logic [63:0] keep1,
    input logic user0,
    input logic user1
  );
    integer index;
    logic [511:0] word0;
    logic [511:0] word1;
    begin
      word0 = 512'd0;
      word1 = 512'd0;
      for (index = 0; index < 64; index = index + 1)
        word0[index * 8 +: 8] = frame_bytes[index];
      for (index = 64; index < frame_length; index = index + 1)
        word1[(index - 64) * 8 +: 8] = frame_bytes[index];
      drive_beat(word0, keep0, 1'b0, user0);
      drive_beat(word1, keep1, 1'b1, user1);
    end
  endtask

  task automatic expect_silent_drop(input integer cycles);
    integer index;
    begin
      for (index = 0; index < cycles; index = index + 1) begin
        @(posedge clk);
        if (request_valid)
          $fatal(1, "invalid frame produced a validated request");
      end
      if (!s_axis_tready)
        $fatal(1, "validator did not return to receive after invalid frame");
    end
  endtask

  task automatic send_and_expect_drop;
    begin
      send_frame();
      expect_silent_drop(90);
    end
  endtask

  task automatic retire_request;
    begin
      @(negedge clk);
      request_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      request_ready = 1'b0;
    end
  endtask

  task automatic wait_request_valid;
    integer cycles;
    begin
      cycles = 0;
      while (!request_valid && cycles < 400) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (!request_valid)
        $fatal(1, "valid one-beat request was not accepted");
    end
  endtask

  initial begin
    rdcp_validated_request_t held_request;

    repeat (5) @(posedge clk);
    reset = 1'b0;

    @(negedge clk);
    capture_enable = 1'b0;
    #1;
    if (s_axis_tready)
      $fatal(1, "capture_enable low did not close validator AXI input");
    repeat (3) begin
      @(posedge clk);
      if (s_axis_tready)
        $fatal(1, "validator AXI input reopened while capture was disabled");
    end
    @(negedge clk);
    capture_enable = 1'b1;
    #1;
    if (!s_axis_tready)
      $fatal(1, "validator AXI input did not reopen when capture was enabled");

    build_request(16'd0);
    finish_checksums();
    send_frame();
    wait_request_valid();
    if (request.udp_length != 16'd28 || request.payload_length != 16'd0 ||
        request.word0[42 * 8 +: 32] != 32'h5043_4452)
      $fatal(1, "validated one-beat request data is wrong");
    retire_request();

    build_request(16'd56);
    finish_checksums();
    send_frame();
    wait_request_valid();
    if (request.udp_length != 16'd84 || request.payload_length != 16'd56 ||
        request.word1[0 +: 8] != frame_bytes[64] ||
        request.word1[53 * 8 +: 8] != frame_bytes[117])
      $fatal(1, "validated two-beat request data is wrong");
    held_request = request;

    @(negedge clk);
    s_axis_tdata = ~request.word0;
    s_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
    s_axis_tlast = 1'b1;
    s_axis_tvalid = 1'b1;
    repeat (4) begin
      @(posedge clk);
      if (!request_valid || s_axis_tready || request !== held_request)
        $fatal(1, "request changed or RX reopened under request backpressure");
    end
    @(negedge clk);
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    retire_request();
    if (request_valid || !s_axis_tready)
      $fatal(1, "request handshake did not release the receiver");

    build_request(16'd0);
    finish_checksums();
    send_frame();
    wait_request_valid();
    if (request.udp_length != 16'd28)
      $fatal(1, "receiver did not accept a frame after request retirement");
    retire_request();

    drive_beat(512'h1, 64'hFFFF_FFFF_FFFF_FFFF, 1'b0, 1'b0);
    drive_beat(512'h2, 64'hFFFF_FFFF_FFFF_FFFF, 1'b0, 1'b0);
    drive_beat(512'h3, 64'h0000_0000_0000_0001, 1'b1, 1'b0);
    expect_silent_drop(20);

    build_request(16'd0);
    finish_checksums();
    send_one_beat_custom(64'hFFFF_FFFF_FFFF_FFFF, 1'b0);
    expect_silent_drop(20);

    build_request(16'd56);
    finish_checksums();
    send_two_beat_custom(64'h7FFF_FFFF_FFFF_FFFF,
                         64'h003F_FFFF_FFFF_FFFF, 1'b0, 1'b0);
    expect_silent_drop(20);

    build_request(16'd56);
    finish_checksums();
    send_two_beat_custom(64'hFFFF_FFFF_FFFF_FFFF,
                         64'h001F_FFFF_FFFF_FFFF, 1'b0, 1'b0);
    expect_silent_drop(20);

    build_request(16'd56);
    finish_checksums();
    send_two_beat_custom(64'hFFFF_FFFF_FFFF_FFFF,
                         64'h003F_FFFF_FFFF_FFFF, 1'b1, 1'b0);
    expect_silent_drop(20);

    build_request(16'd56);
    finish_checksums();
    send_two_beat_custom(64'hFFFF_FFFF_FFFF_FFFF,
                         64'h003F_FFFF_FFFF_FFFF, 1'b0, 1'b1);
    expect_silent_drop(20);

    build_request(16'd0);
    frame_bytes[14] = 8'h46;
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd0);
    set_be16(20, 16'h2000);
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd0);
    set_be48(0, LOCAL_MAC ^ 48'h1);
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd0);
    set_be48(6, 48'd0);
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd0);
    set_be16(12, 16'h86DD);
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd0);
    frame_bytes[23] = 8'd6;
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd0);
    set_be32(30, LOCAL_IP ^ 32'h1);
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd0);
    set_be32(26, 32'd0);
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd0);
    set_be16(36, 16'd4793);
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd0);
    set_be32(42, 32'h5244_4351);
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd0);
    set_be16(16, 16'd49);
    frame_length = 63;
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd0);
    set_be16(16, 16'd47);
    set_be16(38, 16'd27);
    frame_length = 61;
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd56);
    set_be16(16, 16'd105);
    set_be16(38, 16'd85);
    frame_length = 119;
    finish_checksums();
    send_and_expect_drop();

    build_request(16'd1);
    frame_bytes[62] = 8'hA5;
    finish_checksums();
    send_frame();
    wait_request_valid();
    if (request.udp_length != 16'd29 || request.payload_length != 16'd1)
      $fatal(1, "odd-length UDP request metadata is wrong");
    retire_request();

    build_request(16'd0);
    finish_checksums();
    frame_bytes[24] = frame_bytes[24] ^ 8'h01;
    send_frame();
    expect_silent_drop(120);

    build_request(16'd0);
    finish_checksums();
    set_be16(40, 16'd0);
    send_frame();
    expect_silent_drop(120);

    build_request(16'd56);
    finish_checksums();
    frame_bytes[40] = frame_bytes[40] ^ 8'h01;
    send_frame();
    expect_silent_drop(120);

    $display("cmac_usplus_0_rdcp_rx_validate_tb PASS");
    $finish;
  end
endmodule
