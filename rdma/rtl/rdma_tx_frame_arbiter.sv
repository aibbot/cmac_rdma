`timescale 1ps / 1ps

module cmac_usplus_0_rdma_tx_frame_arbiter (
  input  logic         clk,
  input  logic         reset,
  input  logic         control_axis_tvalid,
  output logic         control_axis_tready,
  input  logic [511:0] control_axis_tdata,
  input  logic [63:0]  control_axis_tkeep,
  input  logic         control_axis_tlast,
  input  logic         control_axis_tuser,
  input  logic         rdma_axis_tvalid,
  output logic         rdma_axis_tready,
  input  logic [511:0] rdma_axis_tdata,
  input  logic [63:0]  rdma_axis_tkeep,
  input  logic         rdma_axis_tlast,
  input  logic         rdma_axis_tuser,
  input  logic         tx_axis_tready,
  output logic         tx_axis_tvalid,
  output logic [511:0] tx_axis_tdata,
  output logic [63:0]  tx_axis_tkeep,
  output logic         tx_axis_tlast,
  output logic         tx_axis_tuser
);
  typedef enum logic [1:0] {
    SELECT_IDLE,
    SELECT_CONTROL,
    SELECT_RDMA
  } select_t;

  select_t selection;
  logic selected_control;
  logic transfer;

  always_comb begin
    selected_control = (selection == SELECT_CONTROL) ||
                       ((selection == SELECT_IDLE) && control_axis_tvalid);
    tx_axis_tvalid = selected_control ? control_axis_tvalid : rdma_axis_tvalid;
    tx_axis_tdata = selected_control ? control_axis_tdata : rdma_axis_tdata;
    tx_axis_tkeep = selected_control ? control_axis_tkeep : rdma_axis_tkeep;
    tx_axis_tlast = selected_control ? control_axis_tlast : rdma_axis_tlast;
    tx_axis_tuser = selected_control ? control_axis_tuser : rdma_axis_tuser;
    control_axis_tready = selected_control && tx_axis_tready;
    rdma_axis_tready = !selected_control && tx_axis_tready;
    transfer = tx_axis_tvalid && tx_axis_tready;
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      selection <= SELECT_IDLE;
    end else begin
      case (selection)
        SELECT_IDLE: begin
          if (transfer && tx_axis_tlast)
            selection <= SELECT_IDLE;
          else if (control_axis_tvalid)
            selection <= SELECT_CONTROL;
          else if (rdma_axis_tvalid)
            selection <= SELECT_RDMA;
        end

        default: begin
          if (transfer && tx_axis_tlast)
            selection <= SELECT_IDLE;
        end
      endcase
    end
  end
endmodule
