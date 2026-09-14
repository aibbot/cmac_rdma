`timescale 1ns / 1ps

module cmac_usplus_0_rdma_crc32_parallel_tb;
  logic [31:0] crc_in;
  logic [47:0] data6;
  logic [79:0] data10;
  logic [399:0] data50;
  logic [431:0] data54;
  logic [511:0] data64;
  logic [31:0] crc6;
  logic [31:0] crc10;
  logic [31:0] crc50;
  logic [31:0] crc54;
  logic [31:0] crc64;
  integer byte_index;
  integer trial;

  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(6)) dut6 (
    .crc_in(crc_in), .data_in(data6), .crc_out(crc6)
  );
  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(10)) dut10 (
    .crc_in(crc_in), .data_in(data10), .crc_out(crc10)
  );
  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(50)) dut50 (
    .crc_in(crc_in), .data_in(data50), .crc_out(crc50)
  );
  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(54)) dut54 (
    .crc_in(crc_in), .data_in(data54), .crc_out(crc54)
  );
  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(64)) dut64 (
    .crc_in(crc_in), .data_in(data64), .crc_out(crc64)
  );

  function automatic logic [31:0] crc32_byte_ref(
    input logic [31:0] crc_seed,
    input logic [7:0] data_byte
  );
    integer bit_index;
    logic [31:0] crc_value;
    begin
      crc_value = crc_seed ^ {24'd0, data_byte};
      for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
        crc_value = crc_value[0] ?
                    ((crc_value >> 1) ^ 32'hEDB8_8320) :
                    (crc_value >> 1);
      end
      crc32_byte_ref = crc_value;
    end
  endfunction

  function automatic logic [31:0] crc32_ref(
    input logic [31:0] crc_seed,
    input logic [511:0] data_value,
    input integer byte_count
  );
    integer index;
    logic [31:0] crc_value;
    begin
      crc_value = crc_seed;
      for (index = 0; index < byte_count; index = index + 1) begin
        crc_value = crc32_byte_ref(crc_value, data_value[index * 8 +: 8]);
      end
      crc32_ref = crc_value;
    end
  endfunction

  initial begin
    crc_in = 32'd0;
    data64 = 512'd0;
    data6 = 48'd0;
    data10 = 80'd0;
    data50 = 400'd0;
    data54 = 432'd0;
    #1;
    if (crc6 !== crc32_ref(crc_in, data64, 6) ||
        crc10 !== crc32_ref(crc_in, data64, 10) ||
        crc50 !== crc32_ref(crc_in, data64, 50) ||
        crc54 !== crc32_ref(crc_in, data64, 54) ||
        crc64 !== crc32_ref(crc_in, data64, 64)) begin
      $fatal(1, "zero-vector CRC mismatch");
    end

    for (trial = 0; trial < 100; trial = trial + 1) begin
      crc_in = $urandom;
      for (byte_index = 0; byte_index < 64; byte_index = byte_index + 1) begin
        data64[byte_index * 8 +: 8] = $urandom;
      end
      data6 = data64[47:0];
      data10 = data64[79:0];
      data50 = data64[399:0];
      data54 = data64[431:0];
      #1;
      if (crc6 !== crc32_ref(crc_in, data64, 6) ||
          crc10 !== crc32_ref(crc_in, data64, 10) ||
          crc50 !== crc32_ref(crc_in, data64, 50) ||
          crc54 !== crc32_ref(crc_in, data64, 54) ||
          crc64 !== crc32_ref(crc_in, data64, 64)) begin
        $fatal(1, "CRC mismatch at trial %0d", trial);
      end
    end

    $display("cmac_usplus_0_rdma_crc32_parallel_tb PASS");
    $finish;
  end
endmodule
