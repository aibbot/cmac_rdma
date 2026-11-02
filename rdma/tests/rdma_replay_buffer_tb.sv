`timescale 1ns / 1ps

module rdma_replay_buffer_tb;
  logic clk = 1'b0;
  logic reset = 1'b1;
  logic write_enable = 1'b0;
  logic [2:0] write_address = 3'd0;
  logic [15:0] write_data = 16'd0;
  logic read_enable = 1'b0;
  logic [2:0] read_address = 3'd0;
  logic [15:0] read_data;

  always #2 clk = ~clk;

  rdma_replay_buffer #(
    .DATA_WIDTH(16),
    .DEPTH(8),
    .ADDRESS_WIDTH(3)
  ) dut (
    .clk(clk),
    .reset(reset),
    .write_enable(write_enable),
    .write_address(write_address),
    .write_data(write_data),
    .read_enable(read_enable),
    .read_address(read_address),
    .read_data(read_data)
  );

  task automatic write_word(input logic [2:0] address,
                            input logic [15:0] data);
    begin
      @(negedge clk);
      write_enable = 1'b1;
      write_address = address;
      write_data = data;
      @(negedge clk);
      write_enable = 1'b0;
    end
  endtask

  task automatic read_word(input logic [2:0] address,
                           input logic [15:0] expected);
    begin
      @(negedge clk);
      read_enable = 1'b1;
      read_address = address;
      @(posedge clk);
      #1;
      if (read_data !== expected)
        $fatal(1, "read mismatch address=%0d expected=%h actual=%h",
               address, expected, read_data);
      @(negedge clk);
      read_enable = 1'b0;
    end
  endtask

  initial begin
    repeat (2) @(posedge clk);
    reset = 1'b0;

    write_word(3'd2, 16'h1234);
    write_word(3'd5, 16'hABCD);
    read_word(3'd2, 16'h1234);

    repeat (2) @(posedge clk);
    if (read_data !== 16'h1234)
      $fatal(1, "read data changed while read_enable was low");

    reset = 1'b1;
    @(posedge clk);
    #1;
    if (read_data !== 16'd0)
      $fatal(1, "reset did not clear registered read output");
    reset = 1'b0;

    read_word(3'd5, 16'hABCD);
    $display("rdma_replay_buffer_tb PASS");
    $finish;
  end
endmodule
