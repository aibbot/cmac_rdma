`timescale 1ps / 1ps

import cmac_usplus_0_network_types_pkg::*;

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
        if (tx_axis_tready && (word_index_q == frame_last_word_index_q) &&
            !counter_reset && enable_q && !frame_start_inhibit &&
            (frame_gap_cycles_q == 32'd0) && descriptor_valid) begin
          frame_load          = 1'b1;
          frame_load_sequence = packet_count + 1'b1;
        end
      end
      ST_GAP: begin
        if (!counter_reset && enable_q && !frame_start_inhibit &&
            (gap_remaining_q <= 32'd1) && descriptor_valid)
          frame_load = 1'b1;
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
