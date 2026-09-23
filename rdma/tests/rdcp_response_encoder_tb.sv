`timescale 1ps / 1ps

module cmac_usplus_0_rdcp_response_encoder_tb;
  import cmac_usplus_0_rdcp_pkg::*;

  localparam logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;
  localparam logic [31:0] LOCAL_IP = 32'hC0A8_110B;
  localparam logic [23:0] LOCAL_QPN = 24'h01_2345;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic response_valid = 1'b0;
  logic response_ready;
  rdcp_response_descriptor_t response_descriptor;
  logic replay_valid = 1'b0;
  logic replay_ready;
  logic cache_invalidate = 1'b0;
  logic cache_valid;
  logic [31:0] cache_transaction_id;
  logic [7:0] cache_opcode;
  logic response_done;
  logic m_axis_tvalid;
  logic m_axis_tready = 1'b0;
  logic [511:0] m_axis_tdata;
  logic [63:0] m_axis_tkeep;
  logic m_axis_tlast;
  logic m_axis_tuser;

  logic [7:0] response_bytes [0:127];
  logic [7:0] expected_bytes [0:127];
  logic [7:0] cached_bytes [0:125];
  integer response_length;

  always #1600 clk = ~clk;

  cmac_usplus_0_rdcp_response_encoder #(
    .LOCAL_MAC(LOCAL_MAC),
    .LOCAL_IP(LOCAL_IP),
    .LOCAL_QPN(LOCAL_QPN)
  ) dut (
    .clk(clk),
    .reset(reset),
    .response_valid(response_valid),
    .response_ready(response_ready),
    .response_descriptor(response_descriptor),
    .replay_valid(replay_valid),
    .replay_ready(replay_ready),
    .cache_invalidate(cache_invalidate),
    .cache_valid(cache_valid),
    .cache_transaction_id(cache_transaction_id),
    .cache_opcode(cache_opcode),
    .response_done(response_done),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser)
  );

  task automatic tick;
    begin
      @(posedge clk);
      #1;
    end
  endtask

  task automatic put_expected_be16(
    input integer offset,
    input logic [15:0] value
  );
    begin
      expected_bytes[offset] = value[15:8];
      expected_bytes[offset + 1] = value[7:0];
    end
  endtask

  task automatic put_expected_be24(
    input integer offset,
    input logic [23:0] value
  );
    begin
      expected_bytes[offset] = value[23:16];
      expected_bytes[offset + 1] = value[15:8];
      expected_bytes[offset + 2] = value[7:0];
    end
  endtask

  task automatic put_expected_be32(
    input integer offset,
    input logic [31:0] value
  );
    begin
      expected_bytes[offset] = value[31:24];
      expected_bytes[offset + 1] = value[23:16];
      expected_bytes[offset + 2] = value[15:8];
      expected_bytes[offset + 3] = value[7:0];
    end
  endtask

  task automatic put_expected_be48(
    input integer offset,
    input logic [47:0] value
  );
    begin
      expected_bytes[offset] = value[47:40];
      expected_bytes[offset + 1] = value[39:32];
      expected_bytes[offset + 2] = value[31:24];
      expected_bytes[offset + 3] = value[23:16];
      expected_bytes[offset + 4] = value[15:8];
      expected_bytes[offset + 5] = value[7:0];
    end
  endtask

  task automatic put_expected_be64(
    input integer offset,
    input logic [63:0] value
  );
    begin
      put_expected_be32(offset, value[63:32]);
      put_expected_be32(offset + 4, value[31:0]);
    end
  endtask

  function automatic logic [15:0] complemented_checksum(
    input logic [31:0] sum_value
  );
    logic [31:0] folded;
    begin
      folded = {16'd0, sum_value[15:0]} + sum_value[31:16];
      folded = {16'd0, folded[15:0]} + folded[31:16];
      folded = {16'd0, folded[15:0]} + folded[31:16];
      complemented_checksum = ~folded[15:0];
    end
  endfunction

  task automatic build_expected_response(
    input rdcp_response_descriptor_t descriptor,
    input logic [15:0] ip_id
  );
    logic [31:0] sum_value;
    logic [15:0] checksum_value;
    integer index;
    begin
      for (index = 0; index < 128; index = index + 1)
        expected_bytes[index] = 8'd0;

      put_expected_be48(0, descriptor.source.remote_mac);
      put_expected_be48(6, LOCAL_MAC);
      put_expected_be16(12, 16'h0800);
      expected_bytes[14] = 8'h45;
      put_expected_be16(16, 16'd112);
      put_expected_be16(18, ip_id);
      expected_bytes[22] = 8'd64;
      expected_bytes[23] = 8'd17;
      put_expected_be32(26, LOCAL_IP);
      put_expected_be32(30, descriptor.source.remote_ip);
      put_expected_be16(34, 16'd4792);
      put_expected_be16(36, descriptor.source.remote_port);
      put_expected_be16(38, 16'd92);
      put_expected_be32(42, 32'h5244_4350);
      expected_bytes[46] = 8'd2;
      expected_bytes[47] = descriptor.source.opcode | 8'h80;
      put_expected_be16(48, 16'd64);
      put_expected_be64(50, descriptor.source.session_id);
      put_expected_be32(58, descriptor.source.transaction_id);
      put_expected_be16(62, descriptor.result);
      expected_bytes[64] = descriptor.session_state;
      put_expected_be32(66, descriptor.reason);
      put_expected_be32(70, descriptor.status_bits);
      expected_bytes[74] = 8'd0;
      put_expected_be24(75, LOCAL_QPN);
      expected_bytes[78] = 8'd0;
      put_expected_be24(79, descriptor.current_psn);
      put_expected_be32(82, descriptor.config_generation);
      put_expected_be64(86, descriptor.issued_bytes);
      put_expected_be64(94, descriptor.acked_bytes);
      put_expected_be64(102, descriptor.published_bytes);
      put_expected_be64(110, descriptor.consumed_bytes);
      put_expected_be32(118, 32'h0000_000F);
      put_expected_be32(122, 32'd4096);

      sum_value = 32'd0;
      for (index = 14; index < 34; index = index + 2)
        sum_value = sum_value + {expected_bytes[index], expected_bytes[index + 1]};
      checksum_value = complemented_checksum(sum_value);
      put_expected_be16(24, checksum_value);

      sum_value = LOCAL_IP[31:16] + LOCAL_IP[15:0] +
                  descriptor.source.remote_ip[31:16] +
                  descriptor.source.remote_ip[15:0] + 16'd17 + 16'd92;
      for (index = 34; index < 126; index = index + 2)
        sum_value = sum_value + {expected_bytes[index], expected_bytes[index + 1]};
      checksum_value = complemented_checksum(sum_value);
      if (checksum_value == 16'd0)
        checksum_value = 16'hFFFF;
      put_expected_be16(40, checksum_value);
    end
  endtask

  task automatic append_beat(
    input logic [511:0] beat_data,
    input logic [63:0] beat_keep
  );
    integer index;
    begin
      for (index = 0; index < 64; index = index + 1) begin
        if (beat_keep[index]) begin
          response_bytes[response_length] = beat_data[index * 8 +: 8];
          response_length = response_length + 1;
        end
      end
    end
  endtask

  task automatic capture_response(
    input integer first_stall_cycles,
    input integer second_stall_cycles
  );
    logic [511:0] held_data;
    logic [63:0] held_keep;
    integer cycles;
    integer stall_index;
    begin
      response_length = 0;
      m_axis_tready = 1'b0;
      cycles = 0;
      while (!m_axis_tvalid) begin
        tick();
        cycles = cycles + 1;
        if (cycles > 300)
          $fatal(1, "timeout waiting for encoded response");
      end

      if (m_axis_tlast || m_axis_tkeep != 64'hFFFF_FFFF_FFFF_FFFF ||
          m_axis_tuser)
        $fatal(1, "invalid first AXI response beat framing");
      held_data = m_axis_tdata;
      held_keep = m_axis_tkeep;
      for (stall_index = 0; stall_index < first_stall_cycles;
           stall_index = stall_index + 1) begin
        tick();
        if (!m_axis_tvalid || m_axis_tdata !== held_data ||
            m_axis_tkeep !== held_keep || m_axis_tlast)
          $fatal(1, "first AXI response beat changed under backpressure");
      end
      append_beat(held_data, held_keep);

      m_axis_tready = 1'b1;
      tick();
      m_axis_tready = 1'b0;
      if (!m_axis_tvalid || !m_axis_tlast ||
          m_axis_tkeep != 64'h3FFF_FFFF_FFFF_FFFF || m_axis_tuser)
        $fatal(1, "invalid second AXI response beat framing");
      held_data = m_axis_tdata;
      held_keep = m_axis_tkeep;
      for (stall_index = 0; stall_index < second_stall_cycles;
           stall_index = stall_index + 1) begin
        tick();
        if (!m_axis_tvalid || m_axis_tdata !== held_data ||
            m_axis_tkeep !== held_keep || !m_axis_tlast)
          $fatal(1, "second AXI response beat changed under backpressure");
      end
      append_beat(held_data, held_keep);

      m_axis_tready = 1'b1;
      #1;
      if (!response_done)
        $fatal(1, "response_done did not identify the second AXI handshake");
      tick();
      m_axis_tready = 1'b0;
      if (response_done || m_axis_tvalid)
        $fatal(1, "response completion did not end after the second AXI handshake");
      if (response_length != 126)
        $fatal(1, "encoded response length is %0d", response_length);
    end
  endtask

  task automatic submit_response;
    integer cycles;
    begin
      response_valid = 1'b1;
      cycles = 0;
      while (!response_ready) begin
        tick();
        cycles = cycles + 1;
        if (cycles > 20)
          $fatal(1, "timeout waiting for response descriptor ready");
      end
      tick();
      response_valid = 1'b0;
    end
  endtask

  task automatic submit_replay;
    integer cycles;
    begin
      replay_valid = 1'b1;
      cycles = 0;
      while (!replay_ready) begin
        tick();
        cycles = cycles + 1;
        if (cycles > 20)
          $fatal(1, "timeout waiting for replay ready");
      end
      tick();
      replay_valid = 1'b0;
    end
  endtask

  task automatic expect_exact_response;
    integer index;
    begin
      for (index = 0; index < 126; index = index + 1) begin
        if (response_bytes[index] !== expected_bytes[index])
          $fatal(1, "response byte %0d is %02h, expected %02h",
                 index, response_bytes[index], expected_bytes[index]);
      end
    end
  endtask

  task automatic expect_valid_checksums;
    logic [31:0] sum_value;
    integer index;
    begin
      sum_value = 32'd0;
      for (index = 14; index < 34; index = index + 2)
        sum_value = sum_value + {response_bytes[index], response_bytes[index + 1]};
      if (complemented_checksum(sum_value) != 16'd0)
        $fatal(1, "IPv4 response checksum is invalid");

      sum_value = {response_bytes[26], response_bytes[27]} +
                  {response_bytes[28], response_bytes[29]} +
                  {response_bytes[30], response_bytes[31]} +
                  {response_bytes[32], response_bytes[33]} + 16'd17 + 16'd92;
      for (index = 34; index < 126; index = index + 2)
        sum_value = sum_value + {response_bytes[index], response_bytes[index + 1]};
      if (complemented_checksum(sum_value) != 16'd0)
        $fatal(1, "UDP response checksum is invalid");
    end
  endtask

  initial begin
    integer index;
    rdcp_response_descriptor_t accepted_descriptor;

    response_descriptor = '0;
    repeat (4) tick();
    reset = 1'b0;
    tick();
    if (!response_ready || replay_ready || cache_valid)
      $fatal(1, "unexpected encoder state after reset");

    response_descriptor.source.remote_mac = 48'h0A_0B_0C_0D_0E_0F;
    response_descriptor.source.remote_ip = 32'hC0A8_1164;
    response_descriptor.source.remote_port = 16'hC001;
    response_descriptor.source.session_id = 64'h1122_3344_5566_7788;
    response_descriptor.source.transaction_id = 32'h89AB_CDEF;
    response_descriptor.source.opcode = 8'd6;
    response_descriptor.result = 16'h1234;
    response_descriptor.session_state = 8'h05;
    response_descriptor.reason = 32'h1020_3040;
    response_descriptor.status_bits = 32'h5060_7080;
    response_descriptor.current_psn = 24'hA1_B2_C3;
    response_descriptor.config_generation = 32'h90A0_B0C0;
    response_descriptor.issued_bytes = 64'h0102_0304_0506_0708;
    response_descriptor.acked_bytes = 64'h1112_1314_1516_1718;
    response_descriptor.published_bytes = 64'h2122_2324_2526_2728;
    response_descriptor.consumed_bytes = 64'h3132_3334_3536_3738;
    response_descriptor.cache_enable = 1'b1;
    accepted_descriptor = response_descriptor;
    build_expected_response(accepted_descriptor, 16'd0);
    submit_response();
    response_descriptor = '1;
    capture_response(3, 4);
    expect_exact_response();
    expect_valid_checksums();

    if (response_bytes[15] != 8'd0 || response_bytes[20] != 8'd0 ||
        response_bytes[21] != 8'd0 || response_bytes[65] != 8'd0)
      $fatal(1, "reserved response bytes are not zero");
    if ({response_bytes[0], response_bytes[1], response_bytes[2],
         response_bytes[3], response_bytes[4], response_bytes[5]} !=
        accepted_descriptor.source.remote_mac ||
        {response_bytes[6], response_bytes[7], response_bytes[8],
         response_bytes[9], response_bytes[10], response_bytes[11]} != LOCAL_MAC ||
        {response_bytes[12], response_bytes[13]} != 16'h0800 ||
        response_bytes[14] != 8'h45 ||
        {response_bytes[16], response_bytes[17]} != 16'd112 ||
        {response_bytes[18], response_bytes[19]} != 16'd0 ||
        response_bytes[22] != 8'd64 || response_bytes[23] != 8'd17 ||
        {response_bytes[34], response_bytes[35]} != 16'd4792 ||
        {response_bytes[36], response_bytes[37]} != 16'hC001 ||
        {response_bytes[38], response_bytes[39]} != 16'd92 ||
        {response_bytes[42], response_bytes[43], response_bytes[44],
         response_bytes[45]} != 32'h5244_4350 ||
        response_bytes[46] != 8'd2 || response_bytes[47] != 8'h86 ||
        {response_bytes[48], response_bytes[49]} != 16'd64 ||
        {response_bytes[62], response_bytes[63]} != 16'h1234 ||
        response_bytes[64] != 8'h05)
      $fatal(1, "encoded Ethernet/IP/UDP/RDCP fields are incorrect");
    if (!cache_valid || cache_transaction_id != 32'h89AB_CDEF ||
        cache_opcode != 8'd6)
      $fatal(1, "response cache metadata is incorrect");
    for (index = 0; index < 126; index = index + 1)
      cached_bytes[index] = response_bytes[index];

    response_descriptor = '1;
    response_descriptor.source.transaction_id = 32'h0102_0304;
    response_descriptor.source.opcode = 8'd3;
    submit_replay();
    capture_response(1, 2);
    for (index = 0; index < 126; index = index + 1) begin
      if (response_bytes[index] !== cached_bytes[index])
        $fatal(1, "cached replay changed at byte %0d", index);
    end

    response_descriptor = '0;
    response_descriptor.source.remote_mac = 48'hAA_BB_CC_DD_EE_FF;
    response_descriptor.source.remote_ip = 32'h0A00_0002;
    response_descriptor.source.remote_port = 16'd55000;
    response_descriptor.source.session_id = 64'h8877_6655_4433_2211;
    response_descriptor.source.transaction_id = 32'd9;
    response_descriptor.source.opcode = 8'd1;
    response_descriptor.result = 16'd0;
    response_descriptor.session_state = 8'd2;
    response_descriptor.current_psn = 24'd7;
    response_descriptor.config_generation = 32'd3;
    response_descriptor.issued_bytes = 64'd4096;
    response_descriptor.acked_bytes = 64'd2048;
    response_descriptor.published_bytes = 64'd1024;
    response_descriptor.consumed_bytes = 64'd512;
    response_descriptor.cache_enable = 1'b0;
    build_expected_response(response_descriptor, 16'd1);
    submit_response();
    capture_response(0, 0);
    expect_exact_response();
    if (!cache_valid || cache_transaction_id != 32'h89AB_CDEF ||
        cache_opcode != 8'd6)
      $fatal(1, "uncached response changed cache metadata");

    submit_replay();
    capture_response(0, 0);
    for (index = 0; index < 126; index = index + 1) begin
      if (response_bytes[index] !== cached_bytes[index])
        $fatal(1, "second cached replay changed at byte %0d", index);
    end

    response_descriptor.source.transaction_id = 32'd10;
    response_descriptor.source.opcode = 8'd4;
    response_descriptor.status_bits = 32'h0000_0040;
    build_expected_response(response_descriptor, 16'd2);
    submit_response();
    capture_response(0, 0);
    expect_exact_response();

    cache_invalidate = 1'b1;
    tick();
    cache_invalidate = 1'b0;
    if (cache_valid || replay_ready)
      $fatal(1, "cache invalidation did not remove replay eligibility");

    $display("cmac_usplus_0_rdcp_response_encoder_tb PASS");
    $finish;
  end
endmodule
