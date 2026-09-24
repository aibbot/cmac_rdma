`timescale 1ns / 1ps

module cmac_usplus_0_rdma_packet_layout_tb;
  import cmac_usplus_0_rdma_endpoint_pkg::*;

  rdma_packet_context_t packet_context;
  logic fast_mode;
  rdma_packet_region_t build_region;
  logic [15:0] build_region_offset;
  logic [15:0] crc_offset;
  logic [31:0] packet_icrc;
  logic [7:0] build_byte;
  logic [7:0] crc_byte;
  logic [511:0] fast_header_word0;
  logic [511:0] fast_header_word1;
  logic [399:0] fast_header_word0_masked;

  cmac_usplus_0_rdma_packet_layout #(
    .LOCAL_MAC(48'h02_00_00_00_00_01)
  ) dut (
    .packet_context(packet_context),
    .fast_mode(fast_mode),
    .build_region(build_region),
    .build_region_offset(build_region_offset),
    .crc_offset(crc_offset),
    .packet_icrc(packet_icrc),
    .build_byte(build_byte),
    .crc_byte(crc_byte),
    .fast_header_word0(fast_header_word0),
    .fast_header_word1(fast_header_word1),
    .fast_header_word0_masked(fast_header_word0_masked)
  );

  task automatic expect_build_byte(
    input rdma_packet_region_t region,
    input logic [15:0] offset,
    input logic [7:0] expected
  );
    begin
      build_region = region;
      build_region_offset = offset;
      #1;
      if (build_byte !== expected)
        $fatal(1, "region=%0d offset=%0d expected=%h actual=%h",
               region, offset, expected, build_byte);
    end
  endtask

  initial begin
    packet_context = '0;
    packet_context.remote_mac = 48'h11_22_33_44_55_66;
    packet_context.local_ip = 32'hC0A8_0101;
    packet_context.remote_ip = 32'hC0A8_0102;
    packet_context.local_qpn = 14'h1234;
    packet_context.remote_qpn = 24'hA1_B2_C3;
    packet_context.rkey = 32'h1122_3344;
    packet_context.opcode = 8'h0A;
    packet_context.has_reth = 1'b1;
    packet_context.payload_length = 32'd4096;
    packet_context.work_length = 32'd8192;
    packet_context.local_address = 64'h1000;
    packet_context.remote_address = 48'h01_02_03_04_05_06;
    packet_context.psn = 24'h0A_0B_0C;
    packet_context.benchmark_sequence = 32'h1234_5678;
    packet_context.commit_total_bytes = 64'h0102_0304_0506_0708;
    packet_context.commit_end_offset = 32'h1122_3344;
    packet_context.commit_interval_bytes = 32'h5566_7788;
    packet_context.commit_sequence = 64'hA1A2_A3A4_A5A6_A7A8;
    packet_context.commit_final = 1'b1;
    packet_context.ip_identification = 16'hBEEF;
    packet_context.ip_checksum = 16'hCAFE;
    packet_context.udp_length = 16'h1040;
    packet_context.ip_total_length = 16'h1054;
    fast_mode = 1'b1;
    packet_icrc = 32'hA1B2_C3D4;
    build_region = RDMA_PACKET_DEST_MAC;
    build_region_offset = 16'd0;
    crc_offset = 16'd0;
    #1;

    if (fast_header_word0[7:0] !== 8'h11 ||
        fast_header_word0[47:40] !== 8'h66 ||
        fast_header_word0[103:96] !== 8'h08 ||
        fast_header_word0[119:112] !== 8'h45 ||
        fast_header_word0[295:288] !== 8'h12 ||
        fast_header_word0[303:296] !== 8'hB7 ||
        fast_header_word0[343:336] !== 8'h0A ||
        fast_header_word0[407:400] !== 8'h00)
      $fatal(1, "fast header word0 byte layout mismatch");
    if (fast_header_word1[7:0] !== 8'h33 ||
        fast_header_word1[15:8] !== 8'h44 ||
        fast_header_word1[55:48] !== 8'h52 ||
        fast_header_word1[63:56] !== 8'h46)
      $fatal(1, "fast header word1 RETH/RFSO layout mismatch");

    expect_build_byte(RDMA_PACKET_DEST_MAC, 16'd0, 8'h11);
    expect_build_byte(RDMA_PACKET_SOURCE_MAC, 16'd0, 8'h02);
    expect_build_byte(RDMA_PACKET_IPV4, 16'd10, 8'hCA);
    expect_build_byte(RDMA_PACKET_UDP, 16'd2, 8'h12);
    expect_build_byte(RDMA_PACKET_BTH, 16'd10, 8'h0B);
    expect_build_byte(RDMA_PACKET_RETH, 16'd2, 8'h01);
    expect_build_byte(RDMA_PACKET_PAYLOAD, 16'd0, 8'h52);
    expect_build_byte(RDMA_PACKET_ICRC, 16'd0, 8'hD4);

    crc_offset = 16'd0;
    #1;
    if (crc_byte !== 8'h45) $fatal(1, "unexpected IPv4 first CRC byte");
    crc_offset = 16'd1;
    #1;
    if (crc_byte !== 8'hFF) $fatal(1, "ICRC mask byte was not substituted");

    packet_context.is_commit = 1'b1;
    expect_build_byte(RDMA_PACKET_PAYLOAD, 16'd20, 8'h41);
    expect_build_byte(RDMA_PACKET_PAYLOAD, 16'd40, 8'hA8);

    $display("cmac_usplus_0_rdma_packet_layout_tb PASS");
    $finish;
  end
endmodule
