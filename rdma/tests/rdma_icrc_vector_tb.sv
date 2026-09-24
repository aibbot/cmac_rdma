`timescale 1ns / 1ps

module rdma_icrc_vector_tb;

  localparam integer PACKET_BYTES = 62;
  localparam logic [PACKET_BYTES * 8 - 1:0] GOLDEN_PACKET =
    496'h0200000000010200000000A0080045000030002040004011B737C0A8010AC0A8010B12B7C001001C00001100FFFF0000000100FFFFFE1F00000082C0E68E;

  function automatic logic [7:0] golden_byte(input integer index);
    begin
      golden_byte = GOLDEN_PACKET[(PACKET_BYTES - 1 - index) * 8 +: 8];
    end
  endfunction

  function automatic logic [31:0] crc32_byte_ref(
    input logic [31:0] seed,
    input logic [7:0] data_byte
  );
    logic [31:0] crc;
    integer bit_index;
    begin
      crc = seed ^ {24'd0, data_byte};
      for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
        crc = crc[0] ? ((crc >> 1) ^ 32'hEDB8_8320) : (crc >> 1);
      end
      crc32_byte_ref = crc;
    end
  endfunction

  initial begin
    logic [31:0] crc;
    logic [7:0] data_byte;
    integer index;

    crc = 32'hDEBB_20E3;
    for (index = 0; index < 44; index = index + 1) begin
      data_byte = golden_byte(14 + index);
      case (index)
        1, 8, 10, 11, 26, 27, 32: data_byte = 8'hFF;
        default: data_byte = data_byte;
      endcase
      crc = crc32_byte_ref(crc, data_byte);
    end

    if (~crc != 32'h8EE6_C082) begin
      $fatal(1, "golden ICRC mismatch: expected=8ee6c082 actual=%h", ~crc);
    end
    if (golden_byte(58) != 8'h82 || golden_byte(59) != 8'hC0 ||
        golden_byte(60) != 8'hE6 || golden_byte(61) != 8'h8E) begin
      $fatal(1, "golden ICRC is not serialized least-significant byte first");
    end

    $display("rdma_icrc_vector_tb PASS");
    $finish;
  end

endmodule
