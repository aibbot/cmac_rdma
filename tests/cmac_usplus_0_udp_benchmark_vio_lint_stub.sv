`timescale 1ps / 1ps

// Lint-only declaration for the generated VIO. Do not add this file to
// the Vivado source set; implementation uses udp_benchmark_vio.xci.
module udp_benchmark_vio (
  input  logic        clk,
  input  logic [31:0] probe_in0,
  input  logic [39:0] probe_in1,
  input  logic [31:0] probe_in2,
  output logic        probe_out0,
  output logic        probe_out1,
  output logic [15:0] probe_out2,
  output logic [31:0] probe_out3,
  output logic [47:0] probe_out4,
  output logic [31:0] probe_out5,
  output logic [15:0] probe_out6,
  output logic [15:0] probe_out7,
  output logic [3:0]  probe_out8
);
  assign probe_out0 = 1'b0;
  assign probe_out1 = 1'b0;
  assign probe_out2 = 16'd0;
  assign probe_out3 = 32'd0;
  assign probe_out4 = 48'd0;
  assign probe_out5 = 32'd0;
  assign probe_out6 = 16'd0;
  assign probe_out7 = 16'd0;
  assign probe_out8 = 4'd0;
endmodule
