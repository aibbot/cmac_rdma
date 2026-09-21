`timescale 1ns / 1ps

module cmac_usplus_0_rdma_tx_drain_tracker_tb;
  logic clk = 1'b0;
  logic reset = 1'b1;
  logic endpoint_drained = 1'b0;
  logic source_tvalid = 1'b0;
  logic register_tvalid = 1'b0;
  logic [31:0] fifo_wr_data_count = 32'd0;
  logic pipeline_busy_async = 1'b0;
  logic pipeline_empty;
  logic tx_path_empty;

  always #2 clk = ~clk;

  cmac_usplus_0_rdma_tx_drain_tracker dut (
    .clk(clk),
    .reset(reset),
    .endpoint_drained(endpoint_drained),
    .source_tvalid(source_tvalid),
    .register_tvalid(register_tvalid),
    .fifo_wr_data_count(fifo_wr_data_count),
    .pipeline_busy_async(pipeline_busy_async),
    .pipeline_empty(pipeline_empty),
    .tx_path_empty(tx_path_empty)
  );

  task automatic wait_until_empty(input integer minimum_cycles);
    integer cycles;
    begin
      cycles = 0;
      while (!tx_path_empty && (cycles < 40)) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (!tx_path_empty || cycles < minimum_cycles) begin
        $fatal(1, "TX path empty timing is wrong: empty=%b cycles=%0d minimum=%0d",
               tx_path_empty, cycles, minimum_cycles);
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    endpoint_drained = 1'b1;
    pipeline_busy_async = 1'b1;
    repeat (20) @(posedge clk);
    if (tx_path_empty) $fatal(1, "CMAC-side pending data was reported empty");

    // Model the final CMAC beat completing. Two CDC stages plus the stable
    // empty window must pass before the control plane can release the MR.
    @(negedge clk);
    pipeline_busy_async = 1'b0;
    wait_until_empty(17);

    @(negedge clk);
    fifo_wr_data_count = 32'd1;
    @(posedge clk);
    @(negedge clk);
    if (tx_path_empty) $fatal(1, "FIFO residue did not revoke safe release");
    fifo_wr_data_count = 32'd0;
    wait_until_empty(15);

    @(negedge clk);
    source_tvalid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (tx_path_empty) $fatal(1, "arbiter output did not revoke safe release");
    source_tvalid = 1'b0;
    wait_until_empty(15);

    @(negedge clk);
    register_tvalid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (tx_path_empty) $fatal(1, "TX register data did not revoke safe release");
    register_tvalid = 1'b0;
    wait_until_empty(15);

    @(negedge clk);
    endpoint_drained = 1'b0;
    @(posedge clk);
    @(negedge clk);
    if (tx_path_empty || !pipeline_empty)
      $fatal(1, "active endpoint confused pipeline idle with safe release");

    $display("cmac_usplus_0_rdma_tx_drain_tracker_tb PASS");
    $finish;
  end
endmodule
