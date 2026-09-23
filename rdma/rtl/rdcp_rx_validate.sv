`timescale 1ps / 1ps

module cmac_usplus_0_rdcp_rx_validate #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
  parameter logic [31:0] LOCAL_IP = 32'hC0A8_110B
) (
  input  logic         clk,
  input  logic         reset,
  input  logic         s_axis_tvalid,
  output logic         s_axis_tready,
  input  logic [511:0] s_axis_tdata,
  input  logic [63:0]  s_axis_tkeep,
  input  logic         s_axis_tlast,
  input  logic         s_axis_tuser,
  input  logic         capture_enable,

  output logic         request_valid,
  input  logic         request_ready,
  output cmac_usplus_0_rdcp_pkg::rdcp_validated_request_t request
);
  import cmac_usplus_0_rdcp_pkg::*;

  typedef enum logic [3:0] {
    RX_FIRST,
    RX_SECOND,
    RX_DRAIN,
    RX_VALIDATE_SHAPE,
    RX_VALIDATE_L2_IP,
    RX_VALIDATE_UDP,
    RX_IP_CHECKSUM,
    RX_IP_CHECKSUM_DONE,
    RX_UDP_PSEUDO_CHECKSUM,
    RX_UDP_CHECKSUM,
    RX_UDP_CHECKSUM_DONE,
    RX_HOLD
  } rx_state_t;

  rx_state_t rx_state;
  logic [511:0] request_word0;
  logic [511:0] request_word1;
  logic [63:0] request_keep0;
  logic [63:0] request_keep1;
  logic request_two_words;
  logic request_bad;
  logic [15:0] request_udp_length;
  logic [15:0] request_payload_length;
  logic request_udp_odd;
  logic [31:0] checksum_sum;
  logic [511:0] checksum_shift;
  logic [5:0] checksum_words_left;
  logic [3:0] checksum_first_words_left;
  logic [1023:0] request_words;

  assign s_axis_tready = capture_enable &&
                         (rx_state == RX_FIRST || rx_state == RX_SECOND ||
                          rx_state == RX_DRAIN);
  assign request_valid = rx_state == RX_HOLD;
  assign request.word0 = request_word0;
  assign request.word1 = request_word1;
  assign request.udp_length = request_udp_length;
  assign request.payload_length = request_payload_length;
  assign request_words = {request_word1, request_word0};

  always_ff @(posedge clk) begin
    if (reset) begin
      rx_state <= RX_FIRST;
    end else begin
      case (rx_state)
        RX_FIRST: begin
          if (s_axis_tvalid && s_axis_tready) begin
            request_word0 <= s_axis_tdata;
            request_keep0 <= s_axis_tkeep;
            request_two_words <= 1'b0;
            request_bad <= s_axis_tuser;
            request_udp_length <= {s_axis_tdata[38 * 8 +: 8],
                                   s_axis_tdata[39 * 8 +: 8]};
            request_payload_length <= {s_axis_tdata[48 * 8 +: 8],
                                       s_axis_tdata[49 * 8 +: 8]};
            if (s_axis_tlast) begin
              rx_state <= RX_VALIDATE_SHAPE;
            end else begin
              rx_state <= RX_SECOND;
            end
          end
        end

        RX_SECOND: begin
          if (s_axis_tvalid && s_axis_tready) begin
            request_word1 <= s_axis_tdata;
            request_keep1 <= s_axis_tkeep;
            request_two_words <= 1'b1;
            request_bad <= request_bad || s_axis_tuser;
            if (s_axis_tlast)
              rx_state <= RX_VALIDATE_SHAPE;
            else
              rx_state <= RX_DRAIN;
          end
        end

        RX_DRAIN: begin
          if (s_axis_tvalid && s_axis_tready && s_axis_tlast)
            rx_state <= RX_FIRST;
        end

        RX_VALIDATE_SHAPE: begin : validate_shape
          logic [15:0] actual_frame_length;
          logic shape_valid;

          actual_frame_length = 16'd14 +
            {request_word0[16 * 8 +: 8], request_word0[17 * 8 +: 8]};
          shape_valid = 1'b0;
          if (actual_frame_length <= 16'd64)
            shape_valid = !request_two_words &&
                          request_keep0 == rdcp_keep_mask(actual_frame_length[6:0]);
          else if (actual_frame_length <= 16'd128)
            shape_valid = request_two_words &&
                          request_keep0 == 64'hFFFF_FFFF_FFFF_FFFF &&
                          request_keep1 == rdcp_keep_mask(
                            actual_frame_length[6:0] - 7'd64);

          if (!request_bad && shape_valid)
            rx_state <= RX_VALIDATE_L2_IP;
          else
            rx_state <= RX_FIRST;
        end

        RX_VALIDATE_L2_IP: begin
          if (rdcp_load_be48(request_words, 0) == LOCAL_MAC &&
              rdcp_load_be48(request_words, 6) != 48'd0 &&
              rdcp_load_be16(request_words, 12) == 16'h0800 &&
              rdcp_load_be8(request_words, 14) == 8'h45 &&
              rdcp_load_be16(request_words, 16) >= 16'd48 &&
              (rdcp_load_be16(request_words, 20) & 16'h3FFF) == 16'd0 &&
              rdcp_load_be8(request_words, 23) == 8'd17)
            rx_state <= RX_VALIDATE_UDP;
          else
            rx_state <= RX_FIRST;
        end

        RX_VALIDATE_UDP: begin
          if (rdcp_load_be32(request_words, 26) != 32'd0 &&
              rdcp_load_be32(request_words, 30) == LOCAL_IP &&
              rdcp_load_be16(request_words, 36) == RDCP_CONTROL_PORT &&
              request_udp_length >= 16'd28 &&
              request_udp_length <= 16'd84 &&
              rdcp_load_be16(request_words, 16) ==
                request_udp_length + 16'd20 &&
              rdcp_load_be16(request_words, 40) != 16'd0 &&
              rdcp_load_be32(request_words, 42) == RDCP_MAGIC) begin
            request_udp_odd <= request_udp_length[0];
            checksum_sum <= 32'd0;
            checksum_shift <= request_word0 >> 112;
            checksum_words_left <= 6'd10;
            checksum_first_words_left <= 4'd0;
            rx_state <= RX_IP_CHECKSUM;
          end else begin
            rx_state <= RX_FIRST;
          end
        end

        RX_IP_CHECKSUM: begin : ip_checksum
          logic [15:0] checksum_word;

          checksum_word = {checksum_shift[7:0], checksum_shift[15:8]};
          checksum_sum <= checksum_sum + {16'd0, checksum_word};
          checksum_shift <= checksum_shift >> 16;
          checksum_words_left <= checksum_words_left - 6'd1;
          if (checksum_words_left == 6'd1)
            rx_state <= RX_IP_CHECKSUM_DONE;
        end

        RX_IP_CHECKSUM_DONE: begin
          if (rdcp_fold_checksum(checksum_sum) != 16'hFFFF) begin
            rx_state <= RX_FIRST;
          end else begin
            checksum_sum <= 32'd0;
            checksum_shift <= {
              416'd0,
              request_word0[38 * 8 +: 16],
              16'h1100,
              request_word0[30 * 8 +: 32],
              request_word0[26 * 8 +: 32]
            };
            checksum_words_left <= 6'd6;
            rx_state <= RX_UDP_PSEUDO_CHECKSUM;
          end
        end

        RX_UDP_PSEUDO_CHECKSUM: begin : udp_pseudo_checksum
          logic [15:0] checksum_word;

          checksum_word = {checksum_shift[7:0], checksum_shift[15:8]};
          checksum_sum <= checksum_sum + {16'd0, checksum_word};
          if (checksum_words_left == 6'd1) begin
            checksum_shift <= request_word0 >> 272;
            checksum_words_left <= request_udp_length[6:1] +
                                   {5'd0, request_udp_length[0]};
            checksum_first_words_left <= 4'd15;
            rx_state <= RX_UDP_CHECKSUM;
          end else begin
            checksum_shift <= checksum_shift >> 16;
            checksum_words_left <= checksum_words_left - 6'd1;
          end
        end

        RX_UDP_CHECKSUM: begin : udp_checksum
          logic [15:0] checksum_word;

          if (checksum_words_left == 6'd1 && request_udp_odd)
            checksum_word = {checksum_shift[7:0], 8'd0};
          else
            checksum_word = {checksum_shift[7:0], checksum_shift[15:8]};
          checksum_sum <= checksum_sum + {16'd0, checksum_word};
          if (checksum_words_left == 6'd1) begin
            checksum_words_left <= 6'd0;
            rx_state <= RX_UDP_CHECKSUM_DONE;
          end else begin
            checksum_words_left <= checksum_words_left - 6'd1;
            if (checksum_first_words_left == 4'd1) begin
              checksum_shift <= request_word1;
              checksum_first_words_left <= 4'd0;
            end else begin
              checksum_shift <= checksum_shift >> 16;
              if (checksum_first_words_left != 4'd0)
                checksum_first_words_left <= checksum_first_words_left - 4'd1;
            end
          end
        end

        RX_UDP_CHECKSUM_DONE: begin
          if (rdcp_fold_checksum(checksum_sum) == 16'hFFFF)
            rx_state <= RX_HOLD;
          else
            rx_state <= RX_FIRST;
        end

        RX_HOLD: begin
          if (request_ready)
            rx_state <= RX_FIRST;
        end

        default: rx_state <= RX_FIRST;
      endcase
    end
  end
endmodule
