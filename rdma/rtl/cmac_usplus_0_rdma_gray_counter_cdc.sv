`timescale 1ps / 1ps

// Transfers a monotonically incrementing counter without exposing a torn
// multi-bit value in the destination clock domain.
(* DONT_TOUCH = "yes", KEEP_HIERARCHY = "yes" *)
module cmac_usplus_0_rdma_gray_counter_cdc #(
  parameter integer WIDTH = 32
) (
  input  logic             src_clk,
  input  logic             src_reset,
  input  logic [WIDTH-1:0] src_count,
  input  logic             dst_clk,
  input  logic             dst_reset,
  output logic [WIDTH-1:0] dst_count
);
  logic [WIDTH-1:0] src_gray;
  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] dst_gray_sync1;
  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] dst_gray_sync2;

  function automatic logic [WIDTH-1:0] gray_to_binary(
    input logic [WIDTH-1:0] gray_value
  );
    integer bit_index;
    begin
      gray_to_binary[WIDTH-1] = gray_value[WIDTH-1];
      for (bit_index = WIDTH - 2; bit_index >= 0; bit_index = bit_index - 1)
        gray_to_binary[bit_index] = gray_to_binary[bit_index + 1] ^ gray_value[bit_index];
    end
  endfunction

  always_ff @(posedge src_clk) begin
    if (src_reset) src_gray <= '0;
    else src_gray <= src_count ^ (src_count >> 1);
  end

  always_ff @(posedge dst_clk) begin
    if (dst_reset) begin
      dst_gray_sync1 <= '0;
      dst_gray_sync2 <= '0;
      dst_count <= '0;
    end else begin
      dst_gray_sync1 <= src_gray;
      dst_gray_sync2 <= dst_gray_sync1;
      dst_count <= gray_to_binary(dst_gray_sync2);
    end
  end
endmodule
