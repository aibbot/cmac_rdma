`timescale 1ps / 1ps

// Single-write/synchronous-read storage for a byte-identical retransmit image.
// The data array is intentionally not reset so Vivado can infer block RAM.
module cmac_usplus_0_rdma_replay_buffer #(
  parameter integer DATA_WIDTH = 577,
  parameter integer DEPTH = 128,
  parameter integer ADDRESS_WIDTH = $clog2(DEPTH)
) (
  input  logic                     clk,
  input  logic                     reset,
  input  logic                     write_enable,
  input  logic [ADDRESS_WIDTH-1:0] write_address,
  input  logic [DATA_WIDTH-1:0]    write_data,
  input  logic                     read_enable,
  input  logic [ADDRESS_WIDTH-1:0] read_address,
  output logic [DATA_WIDTH-1:0]    read_data
);
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0]
    // verilog_lint: waive unpacked-dimensions-range-ordering
    storage [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (write_enable) storage[write_address] <= write_data;
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      read_data <= '0;
    end else if (read_enable) begin
      read_data <= storage[read_address];
    end
  end
endmodule
