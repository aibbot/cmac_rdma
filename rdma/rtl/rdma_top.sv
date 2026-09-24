`timescale 1ps / 1ps

// Thin RDMA top wrapper. The vendor example-design top remains unchanged;
// the dedicated RDMA source set selects this wrapper as its top module.
module rdma_top #(
  parameter logic [47:0] PING_LOCAL_MAC = 48'h02_00_00_00_00_01
) (
  input  logic [3:0] gt_rxp_in,
  input  logic [3:0] gt_rxn_in,
  output logic [3:0] gt_txp_out,
  output logic [3:0] gt_txn_out,
  input  logic       gt_ref_clk_p,
  input  logic       gt_ref_clk_n,
  input  logic       init_clk
);
  cmac_usplus_0_exdes #(
    .PING_LOCAL_MAC(PING_LOCAL_MAC)
  ) u_cmac_usplus_0_exdes (
    .gt_rxp_in(gt_rxp_in),
    .gt_rxn_in(gt_rxn_in),
    .gt_txp_out(gt_txp_out),
    .gt_txn_out(gt_txn_out),
    .gt_ref_clk_p(gt_ref_clk_p),
    .gt_ref_clk_n(gt_ref_clk_n),
    .init_clk(init_clk)
  );
endmodule
