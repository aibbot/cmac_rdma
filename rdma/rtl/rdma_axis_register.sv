`timescale 1ps / 1ps

(* KEEP_HIERARCHY = "yes" *)
module rdma_axis_register (
  input  logic         clk,
  input  logic         reset,
  input  logic         flush,
  input  logic         s_axis_tvalid,
  output logic         s_axis_tready,
  input  logic [511:0] s_axis_tdata,
  input  logic [63:0]  s_axis_tkeep,
  input  logic         s_axis_tlast,
  input  logic         s_axis_tuser,
  output logic         m_axis_tvalid,
  input  logic         m_axis_tready,
  output logic [511:0] m_axis_tdata,
  output logic [63:0]  m_axis_tkeep,
  output logic         m_axis_tlast,
  output logic         m_axis_tuser
);
  logic [1:0]   occupancy_reg;
  logic [511:0] data0_reg;
  logic [63:0]  keep0_reg;
  logic         last0_reg;
  logic         user0_reg;
  logic [511:0] data1_reg;
  logic [63:0]  keep1_reg;
  logic         last1_reg;
  logic         user1_reg;

  logic push;
  logic pop;

  assign s_axis_tready = occupancy_reg != 2;
  assign m_axis_tvalid = occupancy_reg != 0;
  assign m_axis_tdata = data0_reg;
  assign m_axis_tkeep = keep0_reg;
  assign m_axis_tlast = last0_reg;
  assign m_axis_tuser = user0_reg;
  assign push = s_axis_tvalid && s_axis_tready;
  assign pop = m_axis_tvalid && m_axis_tready;

  always_ff @(posedge clk) begin
    if (reset || flush) begin
      occupancy_reg <= 2'd0;
      data0_reg <= 512'd0;
      keep0_reg <= 64'd0;
      last0_reg <= 1'b0;
      user0_reg <= 1'b0;
      data1_reg <= 512'd0;
      keep1_reg <= 64'd0;
      last1_reg <= 1'b0;
      user1_reg <= 1'b0;
    end else begin
      case ({push, pop})
        2'b10: begin
          if (occupancy_reg == 0) begin
            data0_reg <= s_axis_tdata;
            keep0_reg <= s_axis_tkeep;
            last0_reg <= s_axis_tlast;
            user0_reg <= s_axis_tuser;
          end else begin
            data1_reg <= s_axis_tdata;
            keep1_reg <= s_axis_tkeep;
            last1_reg <= s_axis_tlast;
            user1_reg <= s_axis_tuser;
          end
          occupancy_reg <= occupancy_reg + 1'b1;
        end

        2'b01: begin
          if (occupancy_reg == 2) begin
            data0_reg <= data1_reg;
            keep0_reg <= keep1_reg;
            last0_reg <= last1_reg;
            user0_reg <= user1_reg;
          end
          occupancy_reg <= occupancy_reg - 1'b1;
        end

        2'b11: begin
          data0_reg <= s_axis_tdata;
          keep0_reg <= s_axis_tkeep;
          last0_reg <= s_axis_tlast;
          user0_reg <= s_axis_tuser;
        end

        default: begin
        end
      endcase
    end
  end
endmodule
