`timescale 1ns / 1ps

module cmac_usplus_0_rdma_reset_sync_tb;

  localparam integer STAGES = 4;

  logic clk = 1'b0;
  logic async_reset_high = 1'b0;
  logic async_reset_low = 1'b1;
  logic sync_reset_high;
  logic sync_reset_low;

  always #2 clk = !clk;

  cmac_usplus_0_rdma_reset_sync #(
    .STAGES(STAGES)
  ) dut (
    .clk(clk),
    .async_reset(async_reset_high),
    .sync_reset(sync_reset_high)
  );

  cmac_usplus_0_rdma_reset_sync #(
    .STAGES(STAGES),
    .RESET_ACTIVE_HIGH(0)
  ) dut_active_low (
    .clk(clk),
    .async_reset(async_reset_low),
    .sync_reset(sync_reset_low)
  );

  initial begin
    // Assertion must not wait for a destination-clock edge.
    #1;
    async_reset_high = 1'b1;
    async_reset_low = 1'b0;
    #1;
    if (sync_reset_high !== 1'b1 || sync_reset_low !== 1'b1)
      $fatal(1, "resets did not assert asynchronously");

    // Deassertion must remain active until every synchronizer stage clears.
    @(negedge clk);
    async_reset_high = 1'b0;
    async_reset_low = 1'b1;
    repeat (STAGES - 1) begin
      @(posedge clk);
      #1;
      if (sync_reset_high !== 1'b1 || sync_reset_low !== 1'b1)
        $fatal(1, "resets released before %0d destination-clock edges", STAGES);
    end
    @(posedge clk);
    #1;
    if (sync_reset_high !== 1'b0 || sync_reset_low !== 1'b0)
      $fatal(1, "resets did not release after %0d destination-clock edges", STAGES);

    // A later asynchronous assertion must take effect between clock edges too.
    @(negedge clk);
    #1;
    async_reset_high = 1'b1;
    async_reset_low = 1'b0;
    #1;
    if (sync_reset_high !== 1'b1 || sync_reset_low !== 1'b1)
      $fatal(1, "runtime reset assertions waited for a clock edge");

    $display("cmac_usplus_0_rdma_reset_sync_tb PASS");
    $finish;
  end

endmodule
