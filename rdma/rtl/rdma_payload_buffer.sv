`timescale 1ps / 1ps

// One replay-safe application payload slot. A frame is accepted only when it
// is exactly PACKET_BYTES bytes, uses contiguous full-width beats, and has no
// source error. Data storage is intentionally not reset so it can infer RAM.
module rdma_payload_buffer #(
  parameter integer PACKET_BYTES = 4096
) (
  input  logic         clk,
  input  logic         reset,
  input  logic         enable,
  input  logic         flush,

  input  logic         s_axis_tvalid,
  output logic         s_axis_tready,
  input  logic [511:0] s_axis_tdata,
  input  logic [63:0]  s_axis_tkeep,
  input  logic         s_axis_tlast,
  input  logic         s_axis_tuser,

  output logic         packet_valid,
  output logic [15:0]  packet_length,
  input  logic         packet_release,
  output logic         buffer_empty,

  input  logic         read_enable,
  input  logic [5:0]   read_address,
  output logic [511:0] read_data,

  output logic [31:0]  accepted_packet_count,
  output logic [31:0]  error_packet_count
);
  localparam integer PACKET_BEATS = PACKET_BYTES / 64;
  localparam integer BEAT_ADDRESS_WIDTH = $clog2(PACKET_BEATS);
  localparam logic [BEAT_ADDRESS_WIDTH-1:0] LAST_BEAT = PACKET_BEATS - 1;

  typedef enum logic [1:0] {
    BUFFER_CAPTURE,
    BUFFER_HOLD,
    BUFFER_DROP
  } buffer_state_t;

  buffer_state_t buffer_state;
  logic [BEAT_ADDRESS_WIDTH-1:0] write_address;
  logic payload_write_enable;

  (* ram_style = "block" *) logic [511:0]
    payload_memory [PACKET_BEATS];

  assign s_axis_tready = (buffer_state == BUFFER_DROP) ||
    ((buffer_state == BUFFER_CAPTURE) &&
     ((write_address != '0) || (enable && !flush)));
  assign buffer_empty = (buffer_state == BUFFER_CAPTURE) &&
                         (write_address == '0) && !packet_valid;
  assign payload_write_enable = (buffer_state == BUFFER_CAPTURE) && !flush &&
    s_axis_tvalid && s_axis_tready && !s_axis_tuser && (&s_axis_tkeep) &&
    (s_axis_tlast == (write_address == LAST_BEAT));

  function automatic logic [31:0] sat_inc32(input logic [31:0] value);
    sat_inc32 = (&value) ? value : value + 32'd1;
  endfunction

  // Keep data storage out of the control/reset process so Vivado can infer a
  // simple dual-port BRAM. Only validity, pointers, and counters are reset.
  always_ff @(posedge clk) begin
    if (payload_write_enable)
      payload_memory[write_address] <= s_axis_tdata;
  end

  always_ff @(posedge clk) begin
    if (read_enable)
      read_data <= payload_memory[read_address];
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      buffer_state <= BUFFER_CAPTURE;
      write_address <= '0;
      packet_valid <= 1'b0;
      packet_length <= 16'd0;
      accepted_packet_count <= 32'd0;
      error_packet_count <= 32'd0;
    end else begin
      case (buffer_state)
        BUFFER_CAPTURE: begin
          if (flush) begin
            packet_valid <= 1'b0;
            packet_length <= 16'd0;
            if (write_address != '0) begin
              error_packet_count <= sat_inc32(error_packet_count);
              write_address <= '0;
              if (s_axis_tvalid && s_axis_tready && s_axis_tlast)
                buffer_state <= BUFFER_CAPTURE;
              else
                buffer_state <= BUFFER_DROP;
            end
          end else if (s_axis_tvalid && s_axis_tready) begin
            if (s_axis_tuser || !(&s_axis_tkeep)) begin
              error_packet_count <= sat_inc32(error_packet_count);
              write_address <= '0;
              if (!s_axis_tlast)
                buffer_state <= BUFFER_DROP;
            end else if (write_address == LAST_BEAT) begin
              write_address <= '0;
              if (s_axis_tlast) begin
                packet_valid <= 1'b1;
                packet_length <= PACKET_BYTES;
                accepted_packet_count <= sat_inc32(accepted_packet_count);
                buffer_state <= BUFFER_HOLD;
              end else begin
                error_packet_count <= sat_inc32(error_packet_count);
                buffer_state <= BUFFER_DROP;
              end
            end else if (s_axis_tlast) begin
              error_packet_count <= sat_inc32(error_packet_count);
              write_address <= '0;
            end else begin
              write_address <= write_address + 1'b1;
            end
          end
        end

        BUFFER_HOLD: begin
          if (packet_release) begin
            packet_valid <= 1'b0;
            packet_length <= 16'd0;
            write_address <= '0;
            buffer_state <= BUFFER_CAPTURE;
          end else if (flush) begin
            packet_valid <= 1'b0;
            packet_length <= 16'd0;
            write_address <= '0;
            error_packet_count <= sat_inc32(error_packet_count);
            buffer_state <= BUFFER_CAPTURE;
          end
        end

        BUFFER_DROP: begin
          if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
            write_address <= '0;
            buffer_state <= BUFFER_CAPTURE;
          end
        end

        default: begin
          packet_valid <= 1'b0;
          packet_length <= 16'd0;
          write_address <= '0;
          buffer_state <= BUFFER_CAPTURE;
        end
      endcase
    end
  end
endmodule
