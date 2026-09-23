`timescale 1ps / 1ps

(* KEEP_HIERARCHY = "yes" *)
module cmac_usplus_0_rdma_tx_drain_tracker (
  input  logic        clk,
  input  logic        reset,
  input  logic        endpoint_drained,
  input  logic        source_tvalid,
  input  logic        register_tvalid,
  input  logic [31:0] fifo_wr_data_count,
  input  logic        pipeline_busy_async,
  output logic        pipeline_empty,
  output logic        tx_path_empty
);
  (* ASYNC_REG = "TRUE" *) logic pipeline_busy_sync1;
  (* ASYNC_REG = "TRUE" *) logic pipeline_busy_sync2;
  logic [3:0] empty_stable_count;

  always_ff @(posedge clk) begin
    if (reset) begin
      pipeline_busy_sync1 <= 1'b1;
      pipeline_busy_sync2 <= 1'b1;
      empty_stable_count <= 4'd0;
    end else begin
      pipeline_busy_sync1 <= pipeline_busy_async;
      pipeline_busy_sync2 <= pipeline_busy_sync1;
      if (source_tvalid || register_tvalid ||
          (fifo_wr_data_count != 32'd0) || pipeline_busy_sync2) begin
        empty_stable_count <= 4'd0;
      end else if (!(&empty_stable_count)) begin
        empty_stable_count <= empty_stable_count + 4'd1;
      end
    end
  end

  assign pipeline_empty = &empty_stable_count;
  assign tx_path_empty = endpoint_drained && pipeline_empty;
endmodule
