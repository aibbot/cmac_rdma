`timescale 1ps / 1ps

// Builds one 4096-byte external-payload RoCEv2 frame into the replay RAM.
// CRC transforms are supplied by the endpoint so this path shares the existing
// parallel CRC hardware with the mutually exclusive benchmark packetizer.
module cmac_usplus_0_rdma_external_packet_builder (
  input  logic         clk,
  input  logic         reset,
  input  logic         start,
  output logic         busy,
  output logic         done,

  input  logic         header_has_reth,
  input  logic [511:0] header_word0,
  input  logic [47:0]  header_word1_prefix,

  output logic         payload_read_enable,
  output logic [5:0]   payload_read_address,
  input  logic [511:0] payload_read_data,

  output logic         packet_write_enable,
  output logic [6:0]   packet_write_address,
  output logic [511:0] packet_write_data,
  output logic [63:0]  packet_write_keep,
  output logic         packet_write_last,
  output logic [31:0]  packet_icrc,

  output logic [399:0] crc_header_data,
  input  logic [31:0]  crc_header_result,
  output logic [31:0]  crc_body_seed,
  output logic [511:0] crc_body_data,
  input  logic [31:0]  crc_body_result,
  output logic [31:0]  crc_tail_seed,
  output logic [47:0]  crc_tail_data,
  input  logic [31:0]  crc_tail_result,
  output logic [31:0]  crc_tail54_seed,
  output logic [431:0] crc_tail54_data,
  input  logic [31:0]  crc_tail54_result
);
  typedef enum logic [2:0] {
    BUILD_IDLE,
    BUILD_PRIME,
    BUILD_HEADER,
    BUILD_BODY,
    BUILD_TAIL_CRC,
    BUILD_TAIL_WRITE
  } build_state_t;

  build_state_t build_state;
  logic header_has_reth_reg;
  logic [511:0] header_word0_reg;
  logic [47:0] header_word1_prefix_reg;
  logic [5:0] body_index;
  logic [511:80] previous_payload_word;
  logic [31:0] crc_state;

  assign busy = build_state != BUILD_IDLE;

  always_comb begin
    if (header_has_reth_reg)
      crc_header_data = header_word0_reg[511:112];
    else
      crc_header_data = {payload_read_data[79:0],
                         header_word0_reg[431:112]};
    crc_header_data[15:8] = 8'hFF;
    crc_header_data[71:64] = 8'hFF;
    crc_header_data[87:80] = 8'hFF;
    crc_header_data[95:88] = 8'hFF;
    crc_header_data[215:208] = 8'hFF;
    crc_header_data[223:216] = 8'hFF;
    crc_header_data[263:256] = 8'hFF;

    payload_read_enable = 1'b0;
    payload_read_address = 6'd0;
    packet_write_enable = 1'b0;
    packet_write_address = 7'd0;
    packet_write_data = 512'd0;
    packet_write_keep = 64'hFFFF_FFFF_FFFF_FFFF;
    packet_write_last = 1'b0;
    crc_body_seed = crc_state;
    crc_body_data = 512'd0;
    crc_tail_seed = crc_state;
    crc_tail_data = previous_payload_word[511:464];
    crc_tail54_seed = crc_state;
    crc_tail54_data = previous_payload_word[511:80];

    case (build_state)
      BUILD_PRIME: begin
        payload_read_enable = 1'b1;
        payload_read_address = 6'd0;
      end

      BUILD_HEADER: begin
        payload_read_enable = 1'b1;
        payload_read_address = header_has_reth_reg ? 6'd0 : 6'd1;
        packet_write_enable = 1'b1;
        packet_write_data = header_word0_reg;
        if (!header_has_reth_reg)
          packet_write_data[511:432] = payload_read_data[79:0];
      end

      BUILD_BODY: begin
        packet_write_enable = 1'b1;
        packet_write_address = {1'b0, body_index} + 7'd1;
        if (header_has_reth_reg) begin
          if (body_index == 6'd0) begin
            packet_write_data[47:0] = header_word1_prefix_reg;
          end else begin
            packet_write_data[47:0] = previous_payload_word[511:464];
          end
          packet_write_data[511:48] = payload_read_data[463:0];
          if (body_index != 6'd63) begin
            payload_read_enable = 1'b1;
            payload_read_address = body_index + 6'd1;
          end
        end else begin
          packet_write_data[431:0] = previous_payload_word[511:80];
          packet_write_data[511:432] = payload_read_data[79:0];
          if (body_index != 6'd62) begin
            payload_read_enable = 1'b1;
            payload_read_address = body_index + 6'd2;
          end
        end
        crc_body_data = packet_write_data;
      end

      BUILD_TAIL_WRITE: begin
        packet_write_enable = 1'b1;
        if (header_has_reth_reg) begin
          packet_write_address = 7'd65;
          packet_write_data[47:0] = previous_payload_word[511:464];
          packet_write_data[79:48] = packet_icrc;
          packet_write_keep = 64'h0000_0000_0000_03FF;
        end else begin
          packet_write_address = 7'd64;
          packet_write_data[431:0] = previous_payload_word[511:80];
          packet_write_data[463:432] = packet_icrc;
          packet_write_keep = 64'h03FF_FFFF_FFFF_FFFF;
        end
        packet_write_last = 1'b1;
      end

      default: begin
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      build_state <= BUILD_IDLE;
      done <= 1'b0;
      header_has_reth_reg <= 1'b0;
      header_word0_reg <= 512'd0;
      header_word1_prefix_reg <= 48'd0;
      body_index <= 6'd0;
      previous_payload_word <= '0;
      crc_state <= 32'd0;
      packet_icrc <= 32'd0;
    end else begin
      done <= 1'b0;
      case (build_state)
        BUILD_IDLE: begin
          if (start) begin
            header_has_reth_reg <= header_has_reth;
            header_word0_reg <= header_word0;
            header_word1_prefix_reg <= header_word1_prefix;
            body_index <= 6'd0;
            build_state <= header_has_reth ? BUILD_HEADER : BUILD_PRIME;
          end
        end

        BUILD_PRIME: build_state <= BUILD_HEADER;

        BUILD_HEADER: begin
          crc_state <= crc_header_result;
          if (!header_has_reth_reg)
            previous_payload_word <= payload_read_data[511:80];
          build_state <= BUILD_BODY;
        end

        BUILD_BODY: begin
          previous_payload_word <= payload_read_data[511:80];
          crc_state <= crc_body_result;
          if ((header_has_reth_reg && (body_index == 6'd63)) ||
              (!header_has_reth_reg && (body_index == 6'd62))) begin
            build_state <= BUILD_TAIL_CRC;
          end else begin
            body_index <= body_index + 6'd1;
          end
        end

        BUILD_TAIL_CRC: begin
          packet_icrc <= header_has_reth_reg ?
                         ~crc_tail_result : ~crc_tail54_result;
          build_state <= BUILD_TAIL_WRITE;
        end

        BUILD_TAIL_WRITE: begin
          done <= 1'b1;
          build_state <= BUILD_IDLE;
        end

        default: build_state <= BUILD_IDLE;
      endcase
    end
  end
endmodule
