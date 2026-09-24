`timescale 1ps / 1ps

// Assert immediately when the source domain or clock manager requests reset,
// then release only after four destination-clock edges.
module rdma_reset_sync #(
  parameter integer STAGES = 4,
  parameter integer RESET_ACTIVE_HIGH = 1
) (
  input  logic clk,
  input  logic async_reset,
  output logic sync_reset
);

  (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] reset_pipeline;

  generate
    if (RESET_ACTIVE_HIGH) begin : g_active_high
      always_ff @(posedge clk or posedge async_reset) begin
        if (async_reset)
          reset_pipeline <= '1;
        else
          reset_pipeline <= reset_pipeline << 1;
      end
    end else begin : g_active_low
      always_ff @(posedge clk or negedge async_reset) begin
        if (!async_reset)
          reset_pipeline <= '1;
        else
          reset_pipeline <= reset_pipeline << 1;
      end
    end
  endgenerate

  assign sync_reset = reset_pipeline[STAGES-1];

endmodule
