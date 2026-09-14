`timescale 1ps / 1ps

// Combinational reflected CRC32 update for a fixed number of bytes.
//
// The straightforward byte-at-a-time recurrence creates one dependent
// 8-bit LFSR step for every input byte.  That is useful for the control path,
// but it cannot close when a 512-bit AXI beat must be accepted every cycle.
// This module builds the linear transform at elaboration time and implements
// each output bit as a balanced XOR reduction of the input state and data.
module cmac_usplus_0_rdma_crc32_parallel #(
  parameter integer DATA_BYTES = 64
) (
  input  logic [31:0]             crc_in,
  input  logic [DATA_BYTES*8-1:0] data_in,
  output logic [31:0]             crc_out
);

  localparam integer DATA_BITS = DATA_BYTES * 8;
  localparam integer MATRIX_BITS = DATA_BITS + 32;
  localparam logic [31:0] CRC32_POLY = 32'hEDB8_8320;

  function automatic logic [31:0] crc32_step_bit(
    input logic [31:0] crc,
    input logic        data_bit
  );
    logic feedback;
    begin
      feedback = crc[0] ^ data_bit;
      crc32_step_bit = (crc >> 1) ^
                       (feedback ? CRC32_POLY : 32'd0);
    end
  endfunction

  // Build all input-basis masks in one constant-function invocation.  Keeping
  // this as a single matrix avoids repeating the LFSR walk once per output bit
  // during simulator elaboration.
  function automatic logic [31:0][MATRIX_BITS-1:0] build_matrix;
    integer input_bit;
    integer data_bit;
    integer output_bit;
    logic [31:0] basis_crc;
    logic [31:0][MATRIX_BITS-1:0] matrix;
    begin
      matrix = '0;
      for (input_bit = 0; input_bit < MATRIX_BITS; input_bit = input_bit + 1) begin
        basis_crc = 32'd0;
        if (input_bit < 32) begin
          basis_crc[input_bit] = 1'b1;
        end
        for (data_bit = 0; data_bit < DATA_BITS; data_bit = data_bit + 1) begin
          basis_crc = crc32_step_bit(
            basis_crc,
            (input_bit == (32 + data_bit))
          );
        end
        for (output_bit = 0; output_bit < 32; output_bit = output_bit + 1) begin
          matrix[output_bit][input_bit] = basis_crc[output_bit];
        end
      end
      build_matrix = matrix;
    end
  endfunction

  logic [MATRIX_BITS-1:0] input_vector;
  localparam logic [31:0][MATRIX_BITS-1:0] CRC_MATRIX = build_matrix();
  assign input_vector = {data_in, crc_in};

  genvar output_bit;
  generate
    for (output_bit = 0; output_bit < 32; output_bit = output_bit + 1) begin : g_crc_output
      assign crc_out[output_bit] = ^(input_vector & CRC_MATRIX[output_bit]);
    end
  endgenerate

endmodule
