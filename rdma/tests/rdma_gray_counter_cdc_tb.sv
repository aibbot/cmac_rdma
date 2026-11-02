`timescale 1ns / 1ps

module rdma_gray_counter_cdc_tb;
  localparam integer WIDTH = 8;

  logic src_clk = 1'b0;
  logic src_reset = 1'b1;
  logic [WIDTH-1:0] src_count = '0;
  logic dst_clk = 1'b0;
  logic dst_reset = 1'b1;
  logic [WIDTH-1:0] dst_count;

  always #5 src_clk = !src_clk;
  always #7 dst_clk = !dst_clk;

  rdma_gray_counter_cdc #(
    .WIDTH(WIDTH)
  ) dut (
    .src_clk(src_clk),
    .src_reset(src_reset),
    .src_count(src_count),
    .dst_clk(dst_clk),
    .dst_reset(dst_reset),
    .dst_count(dst_count)
  );

  task automatic wait_for_destination(input logic [WIDTH-1:0] expected);
    repeat (4) @(posedge dst_clk);
    #1;
    assert (dst_count == expected)
      else $fatal(1, "destination count mismatch: expected=%0d actual=%0d", expected, dst_count);
  endtask

  initial begin
    repeat (3) @(posedge src_clk);
    repeat (2) @(posedge dst_clk);
    #1;
    assert (dst_count == '0)
      else $fatal(1, "destination count must reset to zero");

    src_reset = 1'b0;
    dst_reset = 1'b0;

    @(negedge src_clk);
    src_count = 8'd1;
    @(posedge src_clk);
    wait_for_destination(8'd1);

    for (int value = 2; value <= 19; value++) begin
      @(negedge src_clk);
      src_count = value[WIDTH-1:0];
    end
    @(posedge src_clk);
    wait_for_destination(8'd19);

    dst_reset = 1'b1;
    @(posedge dst_clk);
    #1;
    assert (dst_count == '0)
      else $fatal(1, "destination reset must clear the synchronized count");
    dst_reset = 1'b0;
    wait_for_destination(8'd19);

    @(negedge src_clk);
    src_reset = 1'b1;
    src_count = '0;
    @(posedge src_clk);
    src_reset = 1'b0;
    wait_for_destination('0);

    $display("rdma_gray_counter_cdc_tb PASS");
    $finish;
  end
endmodule
