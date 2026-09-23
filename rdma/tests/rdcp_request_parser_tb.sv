`timescale 1ns / 1ps

module cmac_usplus_0_rdcp_request_parser_tb;
  import cmac_usplus_0_rdcp_pkg::*;

  localparam logic [47:0] HOST_MAC_A = 48'h02_11_22_33_44_55;
  localparam logic [31:0] HOST_IP_A = 32'hC0A8_110A;
  localparam logic [15:0] HOST_PORT_A = 16'd55000;
  localparam logic [63:0] SESSION_A = 64'h1122_3344_5566_7788;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic request_valid = 1'b0;
  logic request_ready;
  rdcp_validated_request_t request;
  logic parsed_request_valid;
  logic parsed_request_ready = 1'b1;
  rdcp_request_descriptor_t parsed_request;

  always #2 clk = ~clk;

  cmac_usplus_0_rdcp_request_parser dut (
    .clk(clk),
    .reset(reset),
    .request_valid(request_valid),
    .request_ready(request_ready),
    .request(request),
    .parsed_request_valid(parsed_request_valid),
    .parsed_request_ready(parsed_request_ready),
    .parsed_request(parsed_request)
  );

  task automatic set_byte(input integer offset, input logic [7:0] value);
    begin
      if (offset < 64)
        request.word0[offset * 8 +: 8] = value;
      else
        request.word1[(offset - 64) * 8 +: 8] = value;
    end
  endtask

  task automatic set_be16(input integer offset, input logic [15:0] value);
    begin
      set_byte(offset, value[15:8]);
      set_byte(offset + 1, value[7:0]);
    end
  endtask

  task automatic set_be32(input integer offset, input logic [31:0] value);
    begin
      set_byte(offset, value[31:24]);
      set_byte(offset + 1, value[23:16]);
      set_byte(offset + 2, value[15:8]);
      set_byte(offset + 3, value[7:0]);
    end
  endtask

  task automatic set_be48(input integer offset, input logic [47:0] value);
    begin
      set_byte(offset, value[47:40]);
      set_byte(offset + 1, value[39:32]);
      set_byte(offset + 2, value[31:24]);
      set_byte(offset + 3, value[23:16]);
      set_byte(offset + 4, value[15:8]);
      set_byte(offset + 5, value[7:0]);
    end
  endtask

  task automatic set_be64(input integer offset, input logic [63:0] value);
    begin
      set_be32(offset, value[63:32]);
      set_be32(offset + 4, value[31:0]);
    end
  endtask

  task automatic build_request(
    input logic [7:0] version,
    input logic [7:0] opcode,
    input logic [15:0] payload_length,
    input logic [15:0] udp_length,
    input logic [31:0] transaction_id
  );
    begin
      request = '0;
      request.udp_length = udp_length;
      request.payload_length = payload_length;
      set_be48(6, HOST_MAC_A);
      set_be32(26, HOST_IP_A);
      set_be16(34, HOST_PORT_A);
      set_byte(46, version);
      set_byte(47, opcode);
      set_be16(48, payload_length);
      set_be64(50, SESSION_A);
      set_be32(58, transaction_id);
    end
  endtask

  initial begin
    rdcp_request_descriptor_t held_request;

    request = '0;
    repeat (4) @(posedge clk);
    reset = 1'b0;

    build_request(RDCP_VERSION, RDCP_OP_HELLO, 16'd0, 16'd28,
                  32'h0102_0304);
    @(negedge clk);
    request_valid = 1'b1;
    #1;
    if (!request_ready || !parsed_request_valid)
      $fatal(1, "parser did not expose a ready HELLO transaction");
    if (parsed_request.identity.remote_mac != HOST_MAC_A ||
        parsed_request.identity.remote_ip != HOST_IP_A ||
        parsed_request.identity.remote_port != HOST_PORT_A ||
        parsed_request.identity.session_id != SESSION_A ||
        parsed_request.identity.transaction_id != 32'h0102_0304 ||
        parsed_request.identity.opcode != RDCP_OP_HELLO ||
        parsed_request.parse_result != RDCP_RESULT_OK)
      $fatal(1, "HELLO identity decode is wrong");
    @(posedge clk);
    @(negedge clk);
    request_valid = 1'b0;

    build_request(RDCP_VERSION, RDCP_OP_CONFIG, 16'd56, 16'd84,
                  32'h1112_1314);
    set_be32(62, 32'h0012_3456);
    set_be32(66, 32'h00AB_CDEF);
    set_be64(70, 64'h0123_4567_89AB_CDEF);
    set_be32(78, 32'h89AB_CDEF);
    set_be32(82, 32'h4000_0000);
    set_be32(86, 32'h00A0_0000);
    set_be32(90, 32'h0010_0000);
    set_be64(94, 64'h1020_3040_5060_7080);
    set_be64(102, 64'h0000_1234_9678_9000);
    set_be32(110, 32'h0000_0001);
    set_be32(114, 32'hDEAD_BEEF);
    @(negedge clk);
    request_valid = 1'b1;
    #1;
    if (parsed_request.config_fields.remote_qpn != 32'h0012_3456 ||
        parsed_request.config_fields.local_psn != 32'h00AB_CDEF ||
        parsed_request.config_fields.remote_base != 64'h0123_4567_89AB_CDEF ||
        parsed_request.config_fields.rkey != 32'h89AB_CDEF ||
        parsed_request.config_fields.ring_size != 32'h4000_0000 ||
        parsed_request.config_fields.wr_size != 32'h00A0_0000 ||
        parsed_request.config_fields.notify_interval_bytes != 32'h0010_0000 ||
        parsed_request.config_fields.local_base != 64'h1020_3040_5060_7080 ||
        parsed_request.config_fields.commit_address != 64'h0000_1234_9678_9000 ||
        parsed_request.config_fields.flags != 32'h0000_0001 ||
        parsed_request.config_fields.reserved != 32'hDEAD_BEEF ||
        parsed_request.parse_result != RDCP_RESULT_OK)
      $fatal(1, "CONFIG fixed-field decode is wrong");
    @(posedge clk);
    @(negedge clk);
    request_valid = 1'b0;

    build_request(RDCP_VERSION, RDCP_OP_CONSUME, 16'd8, 16'd36,
                  32'h2122_2324);
    set_be64(62, 64'h8877_6655_4433_2211);
    @(negedge clk);
    request_valid = 1'b1;
    #1;
    if ({parsed_request.config_fields.remote_qpn,
         parsed_request.config_fields.local_psn} !=
        64'h8877_6655_4433_2211 ||
         parsed_request.parse_result != RDCP_RESULT_OK)
      $fatal(1, "CONSUME value decode is wrong");
    @(posedge clk);
    @(negedge clk);
    request_valid = 1'b0;

    build_request(8'd1, 8'd0, 16'd9, 16'd28, 32'd30);
    request_valid = 1'b1;
    #1;
    if (parsed_request.parse_result != RDCP_RESULT_BAD_VERSION)
      $fatal(1, "bad version was not reported");
    @(posedge clk);
    @(negedge clk);
    request_valid = 1'b0;

    build_request(RDCP_VERSION, 8'd0, 16'd9, 16'd28, 32'd31);
    request_valid = 1'b1;
    #1;
    if (parsed_request.parse_result != RDCP_RESULT_BAD_OPCODE)
      $fatal(1, "bad opcode was not reported");
    @(posedge clk);
    @(negedge clk);
    request_valid = 1'b0;

    build_request(RDCP_VERSION, RDCP_OP_HELLO, 16'd0, 16'd29, 32'd32);
    request_valid = 1'b1;
    #1;
    if (parsed_request.parse_result != RDCP_RESULT_BAD_LENGTH)
      $fatal(1, "bad length was not reported");
    @(posedge clk);
    @(negedge clk);
    request_valid = 1'b0;

    build_request(RDCP_VERSION, RDCP_OP_CONFIG, 16'd55, 16'd83, 32'd33);
    request_valid = 1'b1;
    #1;
    if (parsed_request.parse_result != RDCP_RESULT_BAD_LENGTH)
      $fatal(1, "bad config length was not reported");
    @(posedge clk);
    @(negedge clk);
    request_valid = 1'b0;

    build_request(RDCP_VERSION, RDCP_OP_CONSUME, 16'd7, 16'd35, 32'd34);
    request_valid = 1'b1;
    #1;
    if (parsed_request.parse_result != RDCP_RESULT_BAD_LENGTH)
      $fatal(1, "bad consume length was not reported");
    @(posedge clk);
    @(negedge clk);
    request_valid = 1'b0;

    build_request(RDCP_VERSION, RDCP_OP_START, 16'd1, 16'd29, 32'd35);
    request_valid = 1'b1;
    #1;
    if (parsed_request.parse_result != RDCP_RESULT_BAD_LENGTH)
      $fatal(1, "bad start length was not reported");
    @(posedge clk);
    @(negedge clk);
    request_valid = 1'b0;

    build_request(RDCP_VERSION, RDCP_OP_STATUS, 16'd0, 16'd28,
                  32'hA1A2_A3A4);
    parsed_request_ready = 1'b0;
    request_valid = 1'b1;
    #1;
    if (!parsed_request_valid || request_ready)
      $fatal(1, "parser ignored downstream backpressure");
    held_request = parsed_request;
    repeat (4) begin
      @(posedge clk);
      #1;
      if (!parsed_request_valid || request_ready || parsed_request !== held_request)
        $fatal(1, "parser did not honor downstream backpressure");
    end
    @(negedge clk);
    request_valid = 1'b0;
    parsed_request_ready = 1'b1;
    #1;
    if (!request_ready || parsed_request_valid)
      $fatal(1, "parser did not release backpressure");

    $display("cmac_usplus_0_rdcp_request_parser_tb PASS");
    $finish;
  end
endmodule
