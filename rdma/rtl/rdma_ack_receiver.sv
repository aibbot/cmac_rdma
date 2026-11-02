`timescale 1ps / 1ps

module rdma_ack_receiver #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
  parameter logic [23:0] LOCAL_QPN = 24'd1
) (
  input  logic clk,
  input  logic reset,
  input  logic clear_counters,
  input  logic [47:0] remote_mac,
  input  logic [31:0] local_ip,
  input  logic [31:0] remote_ip,
  input  logic rx_axis_tvalid,
  output logic rx_axis_tready,
  input  logic [511:0] rx_axis_tdata,
  input  logic [63:0] rx_axis_tkeep,
  input  logic rx_axis_tlast,
  input  logic rx_axis_tuser,
  output logic event_valid,
  output logic [23:0] event_psn,
  output logic [7:0] event_syndrome,
  output logic event_is_nak,
  output logic invalid_packet_pulse,
  output logic [31:0] icrc_drop_count
);
  import rdma_endpoint_pkg::*;

  localparam logic [63:0] ACK_KEEP = 64'h3FFF_FFFF_FFFF_FFFF;
  localparam logic [5:0] ACK_ICRC_DATA_BYTES = 6'd44;

  typedef enum logic [2:0] {
    RX_IDLE,
    RX_CRC,
    RX_VERIFY,
    RX_REPORT,
    RX_DROP
  } rx_state_t;

  rx_state_t state;
  logic [511:0] frame_data;
  logic [5:0] crc_index;
  logic [31:0] crc_state;
  logic [31:0] crc_final;
  logic [31:0] received_icrc;
  logic header_valid;

  assign rx_axis_tready = (state == RX_IDLE) || (state == RX_DROP);
  assign event_is_nak = (event_syndrome[7:5] != 3'b000);

  function automatic logic [31:0] crc32_byte(
    input logic [31:0] seed,
    input logic [7:0] data_byte
  );
    logic [31:0] crc;
    integer bit_index;
    begin
      crc = seed ^ {24'd0, data_byte};
      for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
        crc = crc[0] ? ((crc >> 1) ^ 32'hEDB8_8320) : (crc >> 1);
      crc32_byte = crc;
    end
  endfunction

  function automatic logic [7:0] icrc_byte(input logic [5:0] index);
    begin
      case (index)
      6'd1, 6'd8, 6'd10, 6'd11, 6'd26, 6'd27, 6'd32:
          icrc_byte = 8'hFF;
        default: icrc_byte = rdma_load_axis_byte(frame_data, 14 + index);
      endcase
    end
  endfunction

  function automatic logic valid_header;
    rdma_ethernet_header_t ethernet_header;
    rdma_ipv4_header_t ipv4_header;
    rdma_udp_header_t udp_header;
    rdma_bth_t bth_header;
    begin
      ethernet_header = rdma_decode_ethernet(frame_data, 0);
      ipv4_header = rdma_decode_ipv4(frame_data, 14);
      udp_header = rdma_decode_udp(frame_data, 34);
      bth_header = rdma_decode_bth(frame_data, 42);
      valid_header =
        (ethernet_header.destination == LOCAL_MAC) &&
        (ethernet_header.source == remote_mac) &&
        (ethernet_header.ethertype == 16'h0800) &&
        (ipv4_header.version_ihl == 8'h45) &&
        ((ipv4_header.flags_fragment & 16'h3FFF) == 16'd0) &&
        (ipv4_header.protocol == 8'd17) &&
        (ipv4_header.destination == local_ip) &&
        (ipv4_header.source == remote_ip) &&
        (udp_header.destination_port == RDMA_ROCE_UDP_PORT) &&
        (udp_header.length == 16'd28) &&
        (bth_header.opcode == RDMA_RC_ACK) &&
        (bth_header.destination_qpn == LOCAL_QPN);
    end
  endfunction

  function automatic logic [31:0] sat_inc32(input logic [31:0] value);
    sat_inc32 = (&value) ? value : value + 32'd1;
  endfunction

  always_ff @(posedge clk) begin
    if (reset) begin
      state <= RX_IDLE;
      frame_data <= 512'd0;
      crc_index <= 6'd0;
      crc_state <= RDMA_ICRC_INIT;
      crc_final <= 32'd0;
      received_icrc <= 32'd0;
      header_valid <= 1'b0;
      event_valid <= 1'b0;
      event_psn <= 24'd0;
      event_syndrome <= 8'd0;
      invalid_packet_pulse <= 1'b0;
      icrc_drop_count <= 32'd0;
    end else begin
      event_valid <= 1'b0;
      invalid_packet_pulse <= 1'b0;

      case (state)
        RX_IDLE: begin
          if (rx_axis_tvalid && rx_axis_tready) begin
            frame_data <= rx_axis_tdata;
            if (!rx_axis_tlast) begin
              state <= RX_DROP;
            end else if (rx_axis_tuser || (rx_axis_tkeep != ACK_KEEP)) begin
              invalid_packet_pulse <= 1'b1;
            end else begin
              received_icrc <= {
                rx_axis_tdata[495:488], rx_axis_tdata[487:480],
                rx_axis_tdata[479:472], rx_axis_tdata[471:464]
              };
              crc_state <= RDMA_ICRC_INIT;
              crc_index <= 6'd0;
              state <= RX_CRC;
            end
          end
        end

        RX_CRC: begin
          if (crc_index + 6'd1 >= ACK_ICRC_DATA_BYTES) begin
            crc_final <= ~crc32_byte(crc_state, icrc_byte(crc_index));
            state <= RX_VERIFY;
          end else begin
            crc_state <= crc32_byte(crc_state, icrc_byte(crc_index));
            crc_index <= crc_index + 6'd1;
          end
        end

        RX_VERIFY: begin
          rdma_ack_payload_t ack_payload;
          header_valid <= valid_header();
          ack_payload = rdma_decode_ack(frame_data, 42);
          event_psn <= ack_payload.psn;
          event_syndrome <= ack_payload.syndrome;
          state <= RX_REPORT;
        end

        RX_REPORT: begin
          if (received_icrc != crc_final) begin
            icrc_drop_count <= sat_inc32(icrc_drop_count);
          end else if (header_valid) begin
            event_valid <= 1'b1;
          end else begin
            invalid_packet_pulse <= 1'b1;
          end
          state <= RX_IDLE;
        end

        RX_DROP: begin
          if (rx_axis_tvalid && rx_axis_tready && rx_axis_tlast)
            state <= RX_IDLE;
        end

        default: state <= RX_IDLE;
      endcase

      if (clear_counters) icrc_drop_count <= 32'd0;
    end
  end
endmodule
