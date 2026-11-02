`timescale 1ps / 1ps

import cmac_usplus_0_network_types_pkg::*;

// Builds one stable descriptor from the shared VIO/ARP configuration. The
// generation tag prevents a checksum computed for an older configuration from
// being consumed by any UDP stream.
module cmac_usplus_0_udp_config_pipeline (
    input logic        clk,
    input logic        reset,
    input logic [31:0] local_ip,
    input logic [47:0] destination_mac,
    input logic [31:0] destination_ip,
    input logic [15:0] source_port,
    input logic [15:0] destination_port,
    input logic [15:0] payload_length,
    input logic [31:0] gap_cycles,

    output logic                  descriptor_valid,
    output udp_frame_descriptor_t descriptor
);

  localparam logic [15:0] BENCHMARK_HEADER_LENGTH = 16'd24;
  localparam logic [15:0] MIN_PAYLOAD_LENGTH = BENCHMARK_HEADER_LENGTH;
  localparam logic [15:0] MAX_PAYLOAD_LENGTH = 16'd9554;
  localparam logic [15:0] MIN_FRAME_LENGTH = 16'd60;

  logic                  [47:0] control_destination_mac_q;
  logic                  [31:0] control_local_ip_q;
  logic                  [31:0] control_destination_ip_q;
  logic                  [15:0] control_source_port_q;
  logic                  [15:0] control_destination_port_q;
  logic                  [15:0] control_payload_length_q;
  logic                  [15:0] control_payload_length_clamped_q;
  logic                  [31:0] control_gap_cycles_q;
  logic                  [31:0] control_generation_q;
  logic                         control_changed;
  logic                         control_changed_q;
  logic                  [15:0] control_frame_length;

  logic                         checksum_pair_valid_q;
  logic                  [31:0] checksum_pair_generation_q;
  logic                  [18:0] checksum_pair_a_q;
  logic                  [18:0] checksum_pair_b_q;
  logic                         checksum_sum_valid_q;
  logic                  [31:0] checksum_sum_generation_q;
  logic                  [19:0] checksum_sum_q;
  logic                         checksum_valid_q;
  logic                  [31:0] checksum_generation_q;
  logic                  [15:0] checksum_q;

  logic                         descriptor_valid_q;
  udp_frame_descriptor_t        descriptor_q;

  function automatic logic [15:0] clamp_payload_length(input logic [15:0] requested_length);
    begin
      if (requested_length < MIN_PAYLOAD_LENGTH) clamp_payload_length = MIN_PAYLOAD_LENGTH;
      else if (requested_length > MAX_PAYLOAD_LENGTH) clamp_payload_length = MAX_PAYLOAD_LENGTH;
      else clamp_payload_length = requested_length;
    end
  endfunction

  function automatic logic [15:0] make_frame_length(input logic [15:0] udp_payload_length);
    logic [16:0] frame_length;
    begin
      frame_length = {1'b0, udp_payload_length} + 17'd42;
      if (frame_length < MIN_FRAME_LENGTH) make_frame_length = MIN_FRAME_LENGTH;
      else make_frame_length = frame_length[15:0];
    end
  endfunction

  function automatic logic [7:0] make_last_word_index(input logic [15:0] frame_length);
    begin
      make_last_word_index = (frame_length - 16'd1) >> 6;
    end
  endfunction

  function automatic logic [63:0] make_last_word_keep(input logic [15:0] frame_length);
    logic [5:0] valid_byte_count;
    begin
      valid_byte_count = frame_length[5:0];
      if (valid_byte_count == 6'd0) make_last_word_keep = 64'hFFFF_FFFF_FFFF_FFFF;
      else make_last_word_keep = (64'h1 << valid_byte_count) - 1'b1;
    end
  endfunction

  function automatic logic [15:0] fold_ipv4_checksum(input logic [19:0] sum);
    logic [16:0] first_fold;
    logic [16:0] final_fold;
    begin
      first_fold         = {1'b0, sum[15:0]} + sum[19:16];
      final_fold         = {1'b0, first_fold[15:0]} + first_fold[16];
      fold_ipv4_checksum = ~final_fold[15:0];
    end
  endfunction

  always_comb begin
    control_changed =
            (control_destination_mac_q != destination_mac) ||
            (control_local_ip_q != local_ip) ||
            (control_destination_ip_q != destination_ip) ||
            (control_source_port_q != source_port) ||
            (control_destination_port_q != destination_port) ||
            (control_payload_length_q != payload_length) ||
            (control_gap_cycles_q != gap_cycles);
    control_frame_length = make_frame_length(control_payload_length_clamped_q);

    descriptor = descriptor_q;
    descriptor_valid = descriptor_valid_q && !control_changed_q && (descriptor_q.generation == control_generation_q);
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      control_destination_mac_q        <= 48'd0;
      control_local_ip_q               <= 32'd0;
      control_destination_ip_q         <= 32'd0;
      control_source_port_q            <= 16'd0;
      control_destination_port_q       <= 16'd0;
      control_payload_length_q         <= 16'd0;
      control_payload_length_clamped_q <= MIN_PAYLOAD_LENGTH;
      control_gap_cycles_q             <= 32'd0;
      control_generation_q             <= 32'd0;
      control_changed_q                <= 1'b0;
    end else begin
      control_destination_mac_q        <= destination_mac;
      control_local_ip_q               <= local_ip;
      control_destination_ip_q         <= destination_ip;
      control_source_port_q            <= source_port;
      control_destination_port_q       <= destination_port;
      control_payload_length_q         <= payload_length;
      control_payload_length_clamped_q <= clamp_payload_length(payload_length);
      control_gap_cycles_q             <= gap_cycles;
      control_changed_q                <= control_changed;
      if (control_changed_q) control_generation_q <= control_generation_q + 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      checksum_pair_valid_q      <= 1'b0;
      checksum_pair_generation_q <= 32'd0;
      checksum_pair_a_q          <= 19'd0;
      checksum_pair_b_q          <= 19'd0;
      checksum_sum_valid_q       <= 1'b0;
      checksum_sum_generation_q  <= 32'd0;
      checksum_sum_q             <= 20'd0;
      checksum_valid_q           <= 1'b0;
      checksum_generation_q      <= 32'd0;
      checksum_q                 <= 16'd0;
    end else begin
      checksum_pair_valid_q      <= 1'b1;
      checksum_pair_generation_q <= control_generation_q;
      // 0x852d is 0x4500 + 0x4011 + fixed IPv4/UDP overhead.
      checksum_pair_a_q <= 19'h0_852D +
        {3'd0, control_payload_length_clamped_q} +
        {3'd0, control_local_ip_q[31:16]};
      checksum_pair_b_q <= {3'd0, control_local_ip_q[15:0]} +
        {3'd0, control_destination_ip_q[31:16]} +
        {3'd0, control_destination_ip_q[15:0]};

      checksum_sum_valid_q       <= checksum_pair_valid_q;
      checksum_sum_generation_q  <= checksum_pair_generation_q;
      checksum_sum_q             <= {1'b0, checksum_pair_a_q} + {1'b0, checksum_pair_b_q};

      checksum_valid_q           <= checksum_sum_valid_q;
      checksum_generation_q      <= checksum_sum_generation_q;
      checksum_q                 <= fold_ipv4_checksum(checksum_sum_q);
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      descriptor_valid_q <= 1'b0;
      descriptor_q       <= '0;
    end else begin
      descriptor_valid_q            <= checksum_valid_q;
      descriptor_q.generation       <= checksum_generation_q;
      descriptor_q.destination_mac  <= control_destination_mac_q;
      descriptor_q.local_ip         <= control_local_ip_q;
      descriptor_q.destination_ip   <= control_destination_ip_q;
      descriptor_q.source_port      <= control_source_port_q;
      descriptor_q.destination_port <= control_destination_port_q;
      descriptor_q.payload_length   <= control_payload_length_clamped_q;
      descriptor_q.ip_total_length  <= control_payload_length_clamped_q + 16'd28;
      descriptor_q.udp_length       <= control_payload_length_clamped_q + 16'd8;
      descriptor_q.ip_checksum      <= checksum_q;
      descriptor_q.gap_cycles       <= control_gap_cycles_q;
      descriptor_q.last_word_index  <= make_last_word_index(control_frame_length);
      descriptor_q.last_word_keep   <= make_last_word_keep(control_frame_length);
    end
  end

endmodule
