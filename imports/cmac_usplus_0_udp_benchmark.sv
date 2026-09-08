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
      checksum_pair_a_q          <= 19'h0_852D + {3'd0, control_payload_length_clamped_q} + {3'd0, control_local_ip_q[31:16]};
      checksum_pair_b_q          <= {3'd0, control_local_ip_q[15:0]} + {3'd0, control_destination_ip_q[31:16]} + {3'd0, control_destination_ip_q[15:0]};

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

// Per-flow sender. Common VIO/ARP processing is intentionally outside this
// module so four streams do not duplicate its wide comparison and checksum
// pipeline.
module cmac_usplus_0_udp_benchmark_core #(
    parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
    parameter int unsigned STATS_CLOCK_HZ = 322_265_625,
    parameter logic [15:0] DESTINATION_PORT_OFFSET = 16'd0
) (
    input logic                  clk,
    input logic                  reset,
    input logic                  enable,
    input logic                  counter_reset,
    input logic                  frame_start_inhibit,
    input logic                  descriptor_valid,
    input udp_frame_descriptor_t descriptor,

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

  localparam logic [15:0] BENCHMARK_HEADER_LENGTH = 16'd24;
  localparam logic [15:0] MIN_FRAME_LENGTH = 16'd60;
  localparam logic [31:0] BENCHMARK_MAGIC = 32'h5246_534F;  // "RFSO"
  localparam logic [15:0] BENCHMARK_VERSION = 16'd1;
  localparam integer STATS_CYCLE_COUNTER_WIDTH = (STATS_CLOCK_HZ <= 1) ? 1 : $clog2(STATS_CLOCK_HZ);
  localparam logic [STATS_CYCLE_COUNTER_WIDTH-1:0] STATS_WINDOW_LAST_CYCLE = STATS_CLOCK_HZ - 1;

  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_SEND = 2'd1,
    ST_GAP  = 2'd2
  } state_t;

  state_t                                 state_q;
  logic                                   enable_q;
  logic   [                         47:0] frame_destination_mac_q;
  logic   [                         31:0] frame_local_ip_q;
  logic   [                         31:0] frame_destination_ip_q;
  logic   [                         15:0] frame_source_port_q;
  logic   [                         15:0] frame_destination_port_q;
  logic   [                         15:0] frame_payload_length_q;
  logic   [                         15:0] frame_ip_total_length_q;
  logic   [                         15:0] frame_udp_length_q;
  logic   [                         15:0] frame_ip_checksum_q;
  logic   [                         31:0] frame_gap_cycles_q;
  logic   [                         31:0] frame_sequence_q;
  logic   [                          7:0] frame_last_word_index_q;
  logic   [                         63:0] frame_last_word_keep_q;
  logic   [                          7:0] word_index_q;
  logic   [                         31:0] gap_remaining_q;

  logic   [STATS_CYCLE_COUNTER_WIDTH-1:0] tx_rate_cycle_q;
  logic   [                         39:0] tx_rate_bytes_q;
  logic                                   tx_packet_complete;
  logic   [                         39:0] tx_completed_frame_bytes;
  logic                                   tx_packet_complete_q;
  logic   [                         39:0] tx_completed_frame_bytes_q;
  logic                                   tx_completed_frame_error_q;
  logic                                   frame_load;
  logic   [                         31:0] frame_load_sequence;

  function automatic logic [15:0] make_frame_length(input logic [15:0] udp_payload_length);
    logic [16:0] frame_length;
    begin
      frame_length = {1'b0, udp_payload_length} + 17'd42;
      if (frame_length < MIN_FRAME_LENGTH) make_frame_length = MIN_FRAME_LENGTH;
      else make_frame_length = frame_length[15:0];
    end
  endfunction

  assign tx_packet_complete       = (state_q == ST_SEND) && tx_axis_tready && (word_index_q == frame_last_word_index_q);
  assign tx_completed_frame_bytes = {{24{1'b0}}, make_frame_length(frame_payload_length_q)};

  always_ff @(posedge clk) begin
    if (reset) enable_q <= 1'b0;
    else enable_q <= enable;
  end

  always_comb begin
    frame_load          = 1'b0;
    frame_load_sequence = packet_count;

    case (state_q)
      ST_IDLE: begin
        if (!counter_reset && enable_q && !frame_start_inhibit && descriptor_valid) frame_load = 1'b1;
      end
      ST_SEND: begin
        if (tx_axis_tready && (word_index_q == frame_last_word_index_q) && !counter_reset && enable_q && !frame_start_inhibit && (frame_gap_cycles_q == 32'd0) && descriptor_valid) begin
          frame_load          = 1'b1;
          frame_load_sequence = packet_count + 1'b1;
        end
      end
      ST_GAP: begin
        if (!counter_reset && enable_q && !frame_start_inhibit && (gap_remaining_q <= 32'd1) && descriptor_valid) frame_load = 1'b1;
      end
      default: frame_load = 1'b0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      frame_destination_mac_q  <= 48'd0;
      frame_local_ip_q         <= 32'd0;
      frame_destination_ip_q   <= 32'd0;
      frame_source_port_q      <= 16'd0;
      frame_destination_port_q <= 16'd0;
      frame_payload_length_q   <= BENCHMARK_HEADER_LENGTH;
      frame_ip_total_length_q  <= 16'd0;
      frame_udp_length_q       <= 16'd0;
      frame_ip_checksum_q      <= 16'd0;
      frame_gap_cycles_q       <= 32'd0;
      frame_sequence_q         <= 32'd0;
      frame_last_word_index_q  <= 8'd0;
      frame_last_word_keep_q   <= 64'd0;
    end else if (frame_load) begin
      frame_destination_mac_q  <= descriptor.destination_mac;
      frame_local_ip_q         <= descriptor.local_ip;
      frame_destination_ip_q   <= descriptor.destination_ip;
      frame_source_port_q      <= descriptor.source_port;
      frame_destination_port_q <= descriptor.destination_port + DESTINATION_PORT_OFFSET;
      frame_payload_length_q   <= descriptor.payload_length;
      frame_ip_total_length_q  <= descriptor.ip_total_length;
      frame_udp_length_q       <= descriptor.udp_length;
      frame_ip_checksum_q      <= descriptor.ip_checksum;
      frame_gap_cycles_q       <= descriptor.gap_cycles;
      frame_sequence_q         <= frame_load_sequence;
      frame_last_word_index_q  <= descriptor.last_word_index;
      frame_last_word_keep_q   <= descriptor.last_word_keep;
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      state_q         <= ST_IDLE;
      word_index_q    <= 8'd0;
      gap_remaining_q <= 32'd0;
      packet_count    <= 32'd0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          word_index_q    <= 8'd0;
          gap_remaining_q <= 32'd0;
          if (counter_reset) packet_count <= 32'd0;
          else if (frame_load) state_q <= ST_SEND;
        end
        ST_SEND: begin
          if (!enable_q) begin
            word_index_q <= 8'd0;
            state_q      <= ST_IDLE;
          end else if (tx_axis_tready) begin
            if (word_index_q == frame_last_word_index_q) begin
              word_index_q <= 8'd0;
              if (counter_reset) begin
                packet_count <= 32'd0;
                state_q      <= ST_IDLE;
              end else begin
                packet_count <= packet_count + 1'b1;
                if (!enable_q) state_q <= ST_IDLE;
                else if (frame_gap_cycles_q != 32'd0) begin
                  gap_remaining_q <= frame_gap_cycles_q;
                  state_q         <= ST_GAP;
                end else if (frame_load) state_q <= ST_SEND;
                else state_q <= ST_IDLE;
              end
            end else begin
              word_index_q <= word_index_q + 1'b1;
            end
          end
        end
        ST_GAP: begin
          word_index_q <= 8'd0;
          if (counter_reset) begin
            packet_count    <= 32'd0;
            gap_remaining_q <= 32'd0;
            state_q         <= ST_IDLE;
          end else if (!enable_q) begin
            gap_remaining_q <= 32'd0;
            state_q         <= ST_IDLE;
          end else if (gap_remaining_q > 32'd1) begin
            gap_remaining_q <= gap_remaining_q - 1'b1;
          end else if (frame_load) begin
            gap_remaining_q <= 32'd0;
            state_q         <= ST_SEND;
          end
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (reset || counter_reset) begin
      tx_packet_complete_q       <= 1'b0;
      tx_completed_frame_bytes_q <= 40'd0;
      tx_completed_frame_error_q <= 1'b0;
    end else begin
      tx_packet_complete_q       <= tx_packet_complete;
      tx_completed_frame_bytes_q <= tx_completed_frame_bytes;
      tx_completed_frame_error_q <= tx_axis_tuser;
    end
  end

  always_ff @(posedge clk) begin
    if (reset || counter_reset) begin
      tx_rate_cycle_q          <= '0;
      tx_rate_bytes_q          <= 40'd0;
      tx_rate_bytes_per_second <= 40'd0;
      tx_local_drop_count      <= 32'd0;
    end else begin
      if (tx_rate_cycle_q == STATS_WINDOW_LAST_CYCLE) begin
        tx_rate_cycle_q          <= '0;
        tx_rate_bytes_per_second <= tx_rate_bytes_q + (tx_packet_complete_q ? tx_completed_frame_bytes_q : 40'd0);
        tx_rate_bytes_q          <= 40'd0;
      end else begin
        tx_rate_cycle_q <= tx_rate_cycle_q + 1'b1;
        if (tx_packet_complete_q) tx_rate_bytes_q <= tx_rate_bytes_q + tx_completed_frame_bytes_q;
      end

      if (tx_packet_complete_q && tx_completed_frame_error_q) tx_local_drop_count <= tx_local_drop_count + 1'b1;
    end
  end

  always_comb begin
    tx_axis_tvalid = 1'b0;
    tx_axis_tdata  = 512'd0;
    tx_axis_tlast  = 1'b0;
    tx_axis_tkeep  = 64'd0;
    tx_axis_tuser  = 1'b0;

    if (state_q == ST_SEND) begin
      tx_axis_tvalid = 1'b1;
      tx_axis_tlast  = (word_index_q == frame_last_word_index_q);
      tx_axis_tkeep  = tx_axis_tlast ? frame_last_word_keep_q : 64'hFFFF_FFFF_FFFF_FFFF;

      if (word_index_q == 8'd0) begin
        tx_axis_tdata[0*8+:8]  = frame_destination_mac_q[47:40];
        tx_axis_tdata[1*8+:8]  = frame_destination_mac_q[39:32];
        tx_axis_tdata[2*8+:8]  = frame_destination_mac_q[31:24];
        tx_axis_tdata[3*8+:8]  = frame_destination_mac_q[23:16];
        tx_axis_tdata[4*8+:8]  = frame_destination_mac_q[15:8];
        tx_axis_tdata[5*8+:8]  = frame_destination_mac_q[7:0];
        tx_axis_tdata[6*8+:8]  = LOCAL_MAC[47:40];
        tx_axis_tdata[7*8+:8]  = LOCAL_MAC[39:32];
        tx_axis_tdata[8*8+:8]  = LOCAL_MAC[31:24];
        tx_axis_tdata[9*8+:8]  = LOCAL_MAC[23:16];
        tx_axis_tdata[10*8+:8] = LOCAL_MAC[15:8];
        tx_axis_tdata[11*8+:8] = LOCAL_MAC[7:0];
        tx_axis_tdata[12*8+:8] = 8'h08;
        tx_axis_tdata[13*8+:8] = 8'h00;
        tx_axis_tdata[14*8+:8] = 8'h45;
        tx_axis_tdata[15*8+:8] = 8'h00;
        tx_axis_tdata[16*8+:8] = frame_ip_total_length_q[15:8];
        tx_axis_tdata[17*8+:8] = frame_ip_total_length_q[7:0];
        tx_axis_tdata[22*8+:8] = 8'h40;
        tx_axis_tdata[23*8+:8] = 8'h11;
        tx_axis_tdata[24*8+:8] = frame_ip_checksum_q[15:8];
        tx_axis_tdata[25*8+:8] = frame_ip_checksum_q[7:0];
        tx_axis_tdata[26*8+:8] = frame_local_ip_q[31:24];
        tx_axis_tdata[27*8+:8] = frame_local_ip_q[23:16];
        tx_axis_tdata[28*8+:8] = frame_local_ip_q[15:8];
        tx_axis_tdata[29*8+:8] = frame_local_ip_q[7:0];
        tx_axis_tdata[30*8+:8] = frame_destination_ip_q[31:24];
        tx_axis_tdata[31*8+:8] = frame_destination_ip_q[23:16];
        tx_axis_tdata[32*8+:8] = frame_destination_ip_q[15:8];
        tx_axis_tdata[33*8+:8] = frame_destination_ip_q[7:0];
        tx_axis_tdata[34*8+:8] = frame_source_port_q[15:8];
        tx_axis_tdata[35*8+:8] = frame_source_port_q[7:0];
        tx_axis_tdata[36*8+:8] = frame_destination_port_q[15:8];
        tx_axis_tdata[37*8+:8] = frame_destination_port_q[7:0];
        tx_axis_tdata[38*8+:8] = frame_udp_length_q[15:8];
        tx_axis_tdata[39*8+:8] = frame_udp_length_q[7:0];
        tx_axis_tdata[42*8+:8] = BENCHMARK_MAGIC[31:24];
        tx_axis_tdata[43*8+:8] = BENCHMARK_MAGIC[23:16];
        tx_axis_tdata[44*8+:8] = BENCHMARK_MAGIC[15:8];
        tx_axis_tdata[45*8+:8] = BENCHMARK_MAGIC[7:0];
        tx_axis_tdata[46*8+:8] = frame_sequence_q[31:24];
        tx_axis_tdata[47*8+:8] = frame_sequence_q[23:16];
        tx_axis_tdata[48*8+:8] = frame_sequence_q[15:8];
        tx_axis_tdata[49*8+:8] = frame_sequence_q[7:0];
        tx_axis_tdata[50*8+:8] = BENCHMARK_VERSION[15:8];
        tx_axis_tdata[51*8+:8] = BENCHMARK_VERSION[7:0];
        tx_axis_tdata[52*8+:8] = BENCHMARK_HEADER_LENGTH[15:8];
        tx_axis_tdata[53*8+:8] = BENCHMARK_HEADER_LENGTH[7:0];
        tx_axis_tdata[54*8+:8] = 8'h00;
        tx_axis_tdata[55*8+:8] = 8'h00;
        tx_axis_tdata[56*8+:8] = frame_payload_length_q[15:8];
        tx_axis_tdata[57*8+:8] = frame_payload_length_q[7:0];
      end
    end
  end

endmodule

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
