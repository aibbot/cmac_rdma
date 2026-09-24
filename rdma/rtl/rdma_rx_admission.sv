`timescale 1ps / 1ps

// CMAC RX has no AXI ready signal. Admit or drop a complete frame at its
// first beat, reserving enough asynchronous-FIFO space for the largest
// supported 9600-byte Ethernet frame. The reservation makes tready remain high
// for every accepted frame; a mid-frame violation is counted and is visible
// in the RDMA debug path.
module rdma_rx_admission #(
  parameter integer FIFO_DEPTH_BEATS = 2048,
  parameter integer MAX_FRAME_BEATS = 150,
  parameter integer WR_COUNT_WIDTH = 12
) (
  input  logic                      clk,
  input  logic                      reset,
  input  logic                      rx_axis_tvalid,
  input  logic [511:0]              rx_axis_tdata,
  input  logic [63:0]               rx_axis_tkeep,
  input  logic                      rx_axis_tlast,
  input  logic                      rx_axis_tuser,

  input  logic                      fifo_axis_tready,
  input  logic [WR_COUNT_WIDTH-1:0] fifo_wr_data_count,
  output logic                      fifo_axis_tvalid,
  output logic [511:0]              fifo_axis_tdata,
  output logic [63:0]               fifo_axis_tkeep,
  output logic                      fifo_axis_tlast,
  output logic                      fifo_axis_tuser,

  output logic                      overflow_event,
  output logic [31:0]               overflow_count
);

  logic in_frame;
  logic forward_frame;
  logic admit_new_frame;

  function automatic logic [31:0] sat_inc32(input logic [31:0] value);
    begin
      sat_inc32 = (&value) ? value : value + 32'd1;
    end
  endfunction

  always_comb begin
    admit_new_frame = fifo_axis_tready &&
                      (fifo_wr_data_count <= (FIFO_DEPTH_BEATS - MAX_FRAME_BEATS));
    fifo_axis_tvalid = rx_axis_tvalid && (in_frame ? forward_frame : admit_new_frame);
    fifo_axis_tdata = rx_axis_tdata;
    fifo_axis_tkeep = rx_axis_tkeep;
    fifo_axis_tlast = rx_axis_tlast;
    fifo_axis_tuser = rx_axis_tuser;
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      in_frame <= 1'b0;
      forward_frame <= 1'b0;
      overflow_event <= 1'b0;
      overflow_count <= 32'd0;
    end else begin
      overflow_event <= 1'b0;
      if (rx_axis_tvalid) begin
        if (!in_frame) begin
          forward_frame <= admit_new_frame;
          in_frame <= !rx_axis_tlast;
          if (!admit_new_frame) begin
            overflow_event <= 1'b1;
            overflow_count <= sat_inc32(overflow_count);
          end
        end else begin
          if (forward_frame && !fifo_axis_tready) begin
            // This cannot happen after a valid reservation. Count it rather
            // than forwarding a partial frame silently.
            forward_frame <= 1'b0;
            overflow_event <= 1'b1;
            overflow_count <= sat_inc32(overflow_count);
          end
          if (rx_axis_tlast) begin
            in_frame <= 1'b0;
            forward_frame <= 1'b0;
          end
        end
      end
    end
  end

endmodule
