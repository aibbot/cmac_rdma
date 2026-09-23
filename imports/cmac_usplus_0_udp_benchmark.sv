`timescale 1ps / 1ps

import cmac_usplus_0_network_types_pkg::*;

// Compatibility wrapper for direct single-flow users and the standalone RTL
// testbench. The four-flow endpoint instantiates the shared pipeline once and
// uses cmac_usplus_0_udp_benchmark_core directly.
module cmac_usplus_0_udp_benchmark #(
    parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
    parameter int unsigned STATS_CLOCK_HZ = 322_265_625
) (
    input logic        clk,
    input logic        reset,
    input logic        enable,
    input logic        counter_reset,
    input logic        frame_start_inhibit,
    input logic [31:0] local_ip,
    input logic [47:0] destination_mac,
    input logic [31:0] destination_ip,
    input logic [15:0] source_port,
    input logic [15:0] destination_port,
    input logic [15:0] payload_length,
    input logic [31:0] gap_cycles,

    input  logic         tx_axis_tready,
    output logic         tx_axis_tvalid,
    output logic [511:0] tx_axis_tdata,
    output logic         tx_axis_tlast,
    output logic [ 63:0] tx_axis_tkeep,
    output logic         tx_axis_tuser,

    output logic [31:0] packet_count,
    output logic [39:0] tx_rate_bytes_per_second,
    output logic [31:0] tx_local_drop_count
);

  logic                  descriptor_valid;
  udp_frame_descriptor_t descriptor;

  cmac_usplus_0_udp_config_pipeline i_udp_config_pipeline (
      .clk             (clk),
      .reset           (reset),
      .local_ip        (local_ip),
      .destination_mac (destination_mac),
      .destination_ip  (destination_ip),
      .source_port     (source_port),
      .destination_port(destination_port),
      .payload_length  (payload_length),
      .gap_cycles      (gap_cycles),
      .descriptor_valid(descriptor_valid),
      .descriptor      (descriptor)
  );

  cmac_usplus_0_udp_benchmark_core #(
      .LOCAL_MAC(LOCAL_MAC),
      .STATS_CLOCK_HZ(STATS_CLOCK_HZ)
  ) i_udp_benchmark_core (
      .clk                     (clk),
      .reset                   (reset),
      .enable                  (enable),
      .counter_reset           (counter_reset),
      .frame_start_inhibit     (frame_start_inhibit),
      .descriptor_valid        (descriptor_valid),
      .descriptor              (descriptor),
      .tx_axis_tready          (tx_axis_tready),
      .tx_axis_tvalid          (tx_axis_tvalid),
      .tx_axis_tdata           (tx_axis_tdata),
      .tx_axis_tlast           (tx_axis_tlast),
      .tx_axis_tkeep           (tx_axis_tkeep),
      .tx_axis_tuser           (tx_axis_tuser),
      .packet_count            (packet_count),
      .tx_rate_bytes_per_second(tx_rate_bytes_per_second),
      .tx_local_drop_count     (tx_local_drop_count)
  );

endmodule
