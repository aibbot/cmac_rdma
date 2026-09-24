`timescale 1ps / 1ps

module rdcp_response_encoder #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
  parameter logic [31:0] LOCAL_IP = 32'hC0A8_110B,
  parameter logic [23:0] LOCAL_QPN = 24'd1
) (
  input  logic         clk,
  input  logic         reset,

  input  logic         response_valid,
  output logic         response_ready,
  input  rdcp_pkg::rdcp_response_descriptor_t response_descriptor,

  input  logic         replay_valid,
  output logic         replay_ready,
  input  logic         cache_invalidate,
  output logic         cache_valid,
  output logic [31:0]  cache_transaction_id,
  output logic [7:0]   cache_opcode,
  output logic         response_done,

  output logic         m_axis_tvalid,
  input  logic         m_axis_tready,
  output logic [511:0] m_axis_tdata,
  output logic [63:0]  m_axis_tkeep,
  output logic         m_axis_tlast,
  output logic         m_axis_tuser
);
  import rdcp_pkg::*;

  localparam logic [15:0] RESPONSE_IP_LENGTH = 16'd112;
  localparam logic [15:0] RESPONSE_UDP_LENGTH = 16'd92;
  localparam logic [15:0] RESPONSE_FRAME_LENGTH = 16'd126;
  localparam logic [6:0] RESPONSE_LAST_BYTES =
    RESPONSE_FRAME_LENGTH[6:0] - 7'd64;
  localparam logic [31:0] CAPABILITIES = 32'h0000_000F;
  localparam logic [31:0] PMTU_BYTES = 32'd4096;

  typedef enum logic [3:0] {
    ENCODER_IDLE,
    ENCODER_IP_CHECKSUM,
    ENCODER_IP_CHECKSUM_DONE,
    ENCODER_IP_CHECKSUM_RESULT,
    ENCODER_UDP_PSEUDO_CHECKSUM,
    ENCODER_UDP_CHECKSUM,
    ENCODER_UDP_CHECKSUM_DONE,
    ENCODER_UDP_CHECKSUM_RESULT,
    ENCODER_FINALIZE,
    ENCODER_SEND_FIRST,
    ENCODER_SEND_SECOND
  } encoder_state_t;

  encoder_state_t encoder_state;
  logic [15:0] next_response_ip_id;
  logic [511:0] response_word0;
  logic [511:0] response_word1;
  logic [511:0] cache_word0;
  logic [511:0] cache_word1;
  logic response_cache_enable;
  logic [31:0] checksum_sum;
  logic [511:0] checksum_shift;
  logic [5:0] checksum_words_left;
  logic [3:0] checksum_first_words_left;
  logic [15:0] checksum_result;

  assign response_ready = encoder_state == ENCODER_IDLE;
  assign replay_ready = encoder_state == ENCODER_IDLE && !response_valid && cache_valid;
  assign m_axis_tvalid = (encoder_state == ENCODER_SEND_FIRST) ||
                         (encoder_state == ENCODER_SEND_SECOND);
  assign m_axis_tdata = (encoder_state == ENCODER_SEND_FIRST) ?
                        response_word0 : response_word1;
  assign m_axis_tkeep = (encoder_state == ENCODER_SEND_FIRST) ?
                        64'hFFFF_FFFF_FFFF_FFFF :
                        rdcp_keep_mask(RESPONSE_LAST_BYTES);
  assign m_axis_tlast = encoder_state == ENCODER_SEND_SECOND;
  assign m_axis_tuser = 1'b0;
  assign response_done = m_axis_tvalid && m_axis_tready && m_axis_tlast;

  always_ff @(posedge clk) begin
    logic [15:0] checksum_word;
    logic [15:0] checksum_value;
    logic [511:0] built_word0;
    logic [511:0] built_word1;
    logic [511:0] completed_word;

    if (reset) begin
      encoder_state <= ENCODER_IDLE;
      next_response_ip_id <= 16'd0;
      cache_valid <= 1'b0;
      cache_transaction_id <= 32'd0;
      cache_opcode <= 8'd0;
      response_cache_enable <= 1'b0;
      checksum_sum <= 32'd0;
      checksum_words_left <= 6'd0;
      checksum_first_words_left <= 4'd0;
      checksum_result <= 16'd0;
    end else begin
      case (encoder_state)
        ENCODER_IDLE: begin
          if (response_valid) begin
            built_word0 = 512'd0;
            built_word0[0 * 8 +: 48] =
              rdcp_store_be48(response_descriptor.source.remote_mac);
            built_word0[6 * 8 +: 48] = rdcp_store_be48(LOCAL_MAC);
            built_word0[12 * 8 +: 16] = rdcp_store_be16(16'h0800);
            built_word0[14 * 8 +: 8] = 8'h45;
            built_word0[16 * 8 +: 16] = rdcp_store_be16(RESPONSE_IP_LENGTH);
            built_word0[18 * 8 +: 16] = rdcp_store_be16(next_response_ip_id);
            built_word0[22 * 8 +: 8] = 8'd64;
            built_word0[23 * 8 +: 8] = 8'd17;
            built_word0[26 * 8 +: 32] = rdcp_store_be32(LOCAL_IP);
            built_word0[30 * 8 +: 32] =
              rdcp_store_be32(response_descriptor.source.remote_ip);
            built_word0[34 * 8 +: 16] =
              rdcp_store_be16(RDCP_CONTROL_PORT);
            built_word0[36 * 8 +: 16] =
              rdcp_store_be16(response_descriptor.source.remote_port);
            built_word0[38 * 8 +: 16] =
              rdcp_store_be16(RESPONSE_UDP_LENGTH);
            built_word0[42 * 8 +: 32] = rdcp_store_be32(RDCP_MAGIC);
            built_word0[46 * 8 +: 8] = RDCP_VERSION;
            built_word0[47 * 8 +: 8] = response_descriptor.source.opcode | 8'h80;
            built_word0[48 * 8 +: 16] = rdcp_store_be16(16'd64);
            built_word0[50 * 8 +: 64] =
              rdcp_store_be64(response_descriptor.source.session_id);
            built_word0[58 * 8 +: 32] =
              rdcp_store_be32(response_descriptor.source.transaction_id);
            built_word0[62 * 8 +: 16] =
              rdcp_store_be16(response_descriptor.result);

            built_word1 = 512'd0;
            built_word1[0 * 8 +: 8] = response_descriptor.session_state;
            built_word1[2 * 8 +: 32] =
              rdcp_store_be32(response_descriptor.reason);
            built_word1[6 * 8 +: 32] =
              rdcp_store_be32(response_descriptor.status_bits);
            built_word1[10 * 8 +: 32] =
              rdcp_store_be32({8'd0, LOCAL_QPN});
            built_word1[14 * 8 +: 32] =
              rdcp_store_be32({8'd0, response_descriptor.current_psn});
            built_word1[18 * 8 +: 32] =
              rdcp_store_be32(response_descriptor.config_generation);
            built_word1[22 * 8 +: 64] =
              rdcp_store_be64(response_descriptor.issued_bytes);
            built_word1[30 * 8 +: 64] =
              rdcp_store_be64(response_descriptor.acked_bytes);
            built_word1[38 * 8 +: 64] =
              rdcp_store_be64(response_descriptor.published_bytes);
            built_word1[46 * 8 +: 64] =
              rdcp_store_be64(response_descriptor.consumed_bytes);
            built_word1[54 * 8 +: 32] = rdcp_store_be32(CAPABILITIES);
            built_word1[58 * 8 +: 32] = rdcp_store_be32(PMTU_BYTES);

            response_word0 <= built_word0;
            response_word1 <= built_word1;
            response_cache_enable <= response_descriptor.cache_enable;
            next_response_ip_id <= next_response_ip_id + 16'd1;
            checksum_sum <= 32'd0;
            checksum_shift <= built_word0 >> 112;
            checksum_words_left <= 6'd10;
            checksum_first_words_left <= 4'd0;
            encoder_state <= ENCODER_IP_CHECKSUM;
          end else if (replay_valid && cache_valid) begin
            response_word0 <= cache_word0;
            response_word1 <= cache_word1;
            encoder_state <= ENCODER_SEND_FIRST;
          end
        end

        ENCODER_IP_CHECKSUM: begin
          checksum_word = {checksum_shift[7:0], checksum_shift[15:8]};
          checksum_sum <= checksum_sum + {16'd0, checksum_word};
          checksum_shift <= checksum_shift >> 16;
          checksum_words_left <= checksum_words_left - 6'd1;
          if (checksum_words_left == 6'd1)
            encoder_state <= ENCODER_IP_CHECKSUM_DONE;
        end

        ENCODER_IP_CHECKSUM_DONE: begin
          checksum_result <= ~rdcp_fold_checksum(checksum_sum);
          encoder_state <= ENCODER_IP_CHECKSUM_RESULT;
        end

        ENCODER_IP_CHECKSUM_RESULT: begin
          completed_word = response_word0;
          completed_word[24 * 8 +: 16] =
            rdcp_store_be16(checksum_result);
          response_word0 <= completed_word;
          checksum_sum <= 32'd0;
          checksum_shift <= {
            416'd0,
            rdcp_store_be16(RESPONSE_UDP_LENGTH),
            16'h1100,
            response_word0[30 * 8 +: 32],
            rdcp_store_be32(LOCAL_IP)
          };
          checksum_words_left <= 6'd6;
          encoder_state <= ENCODER_UDP_PSEUDO_CHECKSUM;
        end

        ENCODER_UDP_PSEUDO_CHECKSUM: begin
          checksum_word = {checksum_shift[7:0], checksum_shift[15:8]};
          checksum_sum <= checksum_sum + {16'd0, checksum_word};
          if (checksum_words_left == 6'd1) begin
            checksum_shift <= response_word0 >> 272;
            checksum_words_left <= 6'd46;
            checksum_first_words_left <= 4'd15;
            encoder_state <= ENCODER_UDP_CHECKSUM;
          end else begin
            checksum_shift <= checksum_shift >> 16;
            checksum_words_left <= checksum_words_left - 6'd1;
          end
        end

        ENCODER_UDP_CHECKSUM: begin
          checksum_word = {checksum_shift[7:0], checksum_shift[15:8]};
          checksum_sum <= checksum_sum + {16'd0, checksum_word};
          if (checksum_words_left == 6'd1) begin
            checksum_words_left <= 6'd0;
            encoder_state <= ENCODER_UDP_CHECKSUM_DONE;
          end else begin
            checksum_words_left <= checksum_words_left - 6'd1;
            if (checksum_first_words_left == 4'd1) begin
              checksum_shift <= response_word1;
              checksum_first_words_left <= 4'd0;
            end else begin
              checksum_shift <= checksum_shift >> 16;
              if (checksum_first_words_left != 4'd0)
                checksum_first_words_left <= checksum_first_words_left - 4'd1;
            end
          end
        end

        ENCODER_UDP_CHECKSUM_DONE: begin
          checksum_result <= ~rdcp_fold_checksum(checksum_sum);
          encoder_state <= ENCODER_UDP_CHECKSUM_RESULT;
        end

        ENCODER_UDP_CHECKSUM_RESULT: begin
          checksum_value = checksum_result;
          if (checksum_value == 16'd0)
            checksum_value = 16'hFFFF;
          completed_word = response_word0;
          completed_word[40 * 8 +: 16] =
            rdcp_store_be16(checksum_value);
          response_word0 <= completed_word;
          encoder_state <= ENCODER_FINALIZE;
        end

        ENCODER_FINALIZE: begin
          if (response_cache_enable) begin
            cache_word0 <= response_word0;
            cache_word1 <= response_word1;
            cache_transaction_id <=
              rdcp_load_be32({response_word1, response_word0}, 58);
            cache_opcode <= response_word0[47 * 8 +: 8] & 8'h7F;
            cache_valid <= 1'b1;
          end
          encoder_state <= ENCODER_SEND_FIRST;
        end

        ENCODER_SEND_FIRST: begin
          if (m_axis_tready)
            encoder_state <= ENCODER_SEND_SECOND;
        end

        ENCODER_SEND_SECOND: begin
          if (m_axis_tready)
            encoder_state <= ENCODER_IDLE;
        end

        default: encoder_state <= ENCODER_IDLE;
      endcase

      if (cache_invalidate)
        cache_valid <= 1'b0;
    end
  end
endmodule
