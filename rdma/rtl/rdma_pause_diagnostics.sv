`timescale 1ps / 1ps

module rdma_pause_diagnostics #(
  parameter integer COUNTER_WIDTH = 32
) (
  input  logic                     clk,
  input  logic                     reset,
  input  logic                     stat_rx_pause,
  input  logic [8:0]               stat_rx_pause_req,
  input  logic [8:0]               stat_rx_pause_valid,
  input  logic [15:0]              stat_rx_pause_quanta8,
  input  logic                     stat_rx_multicast,
  input  logic                     stat_rx_packet_64_bytes,
  input  logic [2:0]               stat_rx_total_packets,
  input  logic                     stat_rx_user_pause,
  output logic [COUNTER_WIDTH-1:0] pause_frame_count,
  output logic [COUNTER_WIDTH-1:0] pause_valid8_count,
  output logic [COUNTER_WIDTH-1:0] pause_req8_rise_count,
  output logic [COUNTER_WIDTH-1:0] rx_multicast_count,
  output logic [COUNTER_WIDTH-1:0] rx_packet_64_count,
  output logic [COUNTER_WIDTH-1:0] rx_total_packet_count,
  output logic [COUNTER_WIDTH-1:0] rx_user_pause_count,
  output logic                     pause_seen_sticky,
  output logic                     pause_req8_seen_sticky,
  output logic [15:0]              last_pause_quanta8
);

  localparam logic [COUNTER_WIDTH-1:0] COUNTER_MAX =
      {COUNTER_WIDTH{1'b1}};

  logic pause_req8_d;

  always_ff @(posedge clk) begin
    if (reset) begin
      pause_frame_count <= {COUNTER_WIDTH{1'b0}};
      pause_valid8_count <= {COUNTER_WIDTH{1'b0}};
      pause_req8_rise_count <= {COUNTER_WIDTH{1'b0}};
      rx_multicast_count <= {COUNTER_WIDTH{1'b0}};
      rx_packet_64_count <= {COUNTER_WIDTH{1'b0}};
      rx_total_packet_count <= {COUNTER_WIDTH{1'b0}};
      rx_user_pause_count <= {COUNTER_WIDTH{1'b0}};
      pause_seen_sticky <= 1'b0;
      pause_req8_seen_sticky <= 1'b0;
      last_pause_quanta8 <= 16'h0000;
      pause_req8_d <= 1'b0;
    end else begin
      pause_req8_d <= stat_rx_pause_req[8];

      if (stat_rx_pause) begin
        pause_seen_sticky <= 1'b1;
        if (pause_frame_count != COUNTER_MAX) begin
          pause_frame_count <= pause_frame_count +
                               {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};
        end
      end

      if (stat_rx_pause_valid[8]) begin
        last_pause_quanta8 <= stat_rx_pause_quanta8;
        if (pause_valid8_count != COUNTER_MAX) begin
          pause_valid8_count <= pause_valid8_count +
                                {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};
        end
      end

      if (stat_rx_pause_req[8]) begin
        pause_req8_seen_sticky <= 1'b1;
      end

      if (stat_rx_pause_req[8] && !pause_req8_d &&
          (pause_req8_rise_count != COUNTER_MAX)) begin
        pause_req8_rise_count <= pause_req8_rise_count +
                                 {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};
      end

      if (stat_rx_multicast && (rx_multicast_count != COUNTER_MAX)) begin
        rx_multicast_count <= rx_multicast_count +
                              {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};
      end

      if (stat_rx_packet_64_bytes && (rx_packet_64_count != COUNTER_MAX)) begin
        rx_packet_64_count <= rx_packet_64_count +
                              {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};
      end

      if (stat_rx_total_packets != 3'd0) begin
        if (rx_total_packet_count >
            COUNTER_MAX - {{(COUNTER_WIDTH-3){1'b0}}, stat_rx_total_packets}) begin
          rx_total_packet_count <= COUNTER_MAX;
        end else begin
          rx_total_packet_count <= rx_total_packet_count +
              {{(COUNTER_WIDTH-3){1'b0}}, stat_rx_total_packets};
        end
      end

      if (stat_rx_user_pause && (rx_user_pause_count != COUNTER_MAX)) begin
        rx_user_pause_count <= rx_user_pause_count +
                               {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};
      end
    end
  end

endmodule
