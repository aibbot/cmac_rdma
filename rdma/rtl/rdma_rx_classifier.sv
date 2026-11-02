`timescale 1ps / 1ps

module rdma_rx_classifier (
  input  logic         clk,
  input  logic         reset,
  input  logic         s_axis_tvalid,
  output logic         s_axis_tready,
  input  logic [511:0] s_axis_tdata,
  input  logic [63:0]  s_axis_tkeep,
  input  logic         s_axis_tlast,
  input  logic         s_axis_tuser,
  output logic         rdma_axis_tvalid,
  input  logic         rdma_axis_tready,
  output logic [511:0] rdma_axis_tdata,
  output logic [63:0]  rdma_axis_tkeep,
  output logic         rdma_axis_tlast,
  output logic         rdma_axis_tuser,
  output logic         control_axis_tvalid,
  input  logic         control_axis_tready,
  output logic [511:0] control_axis_tdata,
  output logic [63:0]  control_axis_tkeep,
  output logic         control_axis_tlast,
  output logic         control_axis_tuser,
  output logic [31:0]  drop_count
);
  typedef enum logic [1:0] {
    ROUTE_DROP,
    ROUTE_RDMA,
    ROUTE_CONTROL
  } route_t;

  logic holding_valid;
  logic [511:0] holding_data;
  logic [63:0] holding_keep;
  logic holding_last;
  logic holding_user;
  route_t holding_route;
  route_t frame_route;
  logic in_frame;
  logic holding_pop;
  route_t first_route;

  function automatic logic [7:0] get_byte(
    input logic [511:0] data,
    input integer index
  );
    get_byte = data[index * 8 +: 8];
  endfunction

  always_comb begin
    first_route = ROUTE_DROP;
    if (!s_axis_tuser && s_axis_tkeep[37] &&
        get_byte(s_axis_tdata, 12) == 8'h08 &&
        get_byte(s_axis_tdata, 13) == 8'h00 &&
        get_byte(s_axis_tdata, 14) == 8'h45 &&
        get_byte(s_axis_tdata, 23) == 8'h11) begin
      if ({get_byte(s_axis_tdata, 36), get_byte(s_axis_tdata, 37)} == 16'd4791)
        first_route = ROUTE_RDMA;
      else if ({get_byte(s_axis_tdata, 36), get_byte(s_axis_tdata, 37)} == 16'd4792)
        first_route = ROUTE_CONTROL;
    end
  end

  assign holding_pop = holding_valid &&
    ((holding_route == ROUTE_DROP) ||
     ((holding_route == ROUTE_RDMA) && rdma_axis_tready) ||
     ((holding_route == ROUTE_CONTROL) && control_axis_tready));
  assign s_axis_tready = !holding_valid || holding_pop;

  assign rdma_axis_tvalid = holding_valid && (holding_route == ROUTE_RDMA);
  assign control_axis_tvalid = holding_valid && (holding_route == ROUTE_CONTROL);
  assign rdma_axis_tdata = holding_data;
  assign rdma_axis_tkeep = holding_keep;
  assign rdma_axis_tlast = holding_last;
  assign rdma_axis_tuser = holding_user;
  assign control_axis_tdata = holding_data;
  assign control_axis_tkeep = holding_keep;
  assign control_axis_tlast = holding_last;
  assign control_axis_tuser = holding_user;

  always_ff @(posedge clk) begin
    if (reset) begin
      holding_valid <= 1'b0;
      holding_data <= 512'd0;
      holding_keep <= 64'd0;
      holding_last <= 1'b0;
      holding_user <= 1'b0;
      holding_route <= ROUTE_DROP;
      frame_route <= ROUTE_DROP;
      in_frame <= 1'b0;
      drop_count <= 32'd0;
    end else begin
      if (holding_pop) holding_valid <= 1'b0;
      if (s_axis_tvalid && s_axis_tready) begin
        holding_valid <= 1'b1;
        holding_data <= s_axis_tdata;
        holding_keep <= s_axis_tkeep;
        holding_last <= s_axis_tlast;
        holding_user <= s_axis_tuser;
        // Keep every beat of a selected frame on one route. CMAC can assert
        // tuser only with TLAST; the selected parser receives that indication
        // and discards the complete frame without being left mid-packet.
        holding_route <= in_frame ? frame_route : first_route;
        if (!in_frame) begin
          frame_route <= first_route;
          if (first_route == ROUTE_DROP) drop_count <= drop_count + 32'd1;
        end
        if (s_axis_tlast) begin
          in_frame <= 1'b0;
        end else begin
          in_frame <= 1'b1;
        end
      end
    end
  end
endmodule
