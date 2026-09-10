`timescale 1ns / 1ps

module cmac_usplus_0_rdma_arp_snapshot_cdc_tb;

  localparam logic [47:0] MAC_A = 48'h02_00_00_00_00_A1;
  localparam logic [47:0] MAC_B = 48'h02_00_00_00_00_B2;
  localparam logic [47:0] MAC_C = 48'h02_00_00_00_00_C3;
  localparam logic [47:0] MAC_D = 48'h02_00_00_00_00_D4;
  localparam logic [31:0] IP_A = 32'hC0A8_0101;
  localparam logic [31:0] IP_B = 32'hC0A8_0102;
  localparam logic [31:0] IP_C = 32'hC0A8_0103;
  localparam logic [31:0] IP_D = 32'hC0A8_0104;

  logic src_clk = 1'b0;
  logic src_reset = 1'b1;
  logic src_update = 1'b0;
  logic [47:0] src_mac = 48'd0;
  logic [31:0] src_ip = 32'd0;
  logic dst_clk = 1'b0;
  logic dst_reset = 1'b1;
  logic dst_valid;
  logic [47:0] dst_mac;
  logic [31:0] dst_ip;
  logic saw_mac_b = 1'b0;

  always #2 src_clk = ~src_clk;
  always #11 dst_clk = ~dst_clk;

  cmac_usplus_0_rdma_arp_snapshot_cdc dut (
    .src_clk(src_clk),
    .src_reset(src_reset),
    .src_update(src_update),
    .src_mac(src_mac),
    .src_ip(src_ip),
    .dst_clk(dst_clk),
    .dst_reset(dst_reset),
    .dst_valid(dst_valid),
    .dst_mac(dst_mac),
    .dst_ip(dst_ip)
  );

  always @(posedge dst_clk) begin
    if (dst_valid && (dst_mac == MAC_B)) saw_mac_b = 1'b1;
  end

  task automatic pulse_update(input logic [47:0] mac, input logic [31:0] ip);
    begin
      @(negedge src_clk);
      src_mac = mac;
      src_ip = ip;
      src_update = 1'b1;
      @(negedge src_clk);
      src_update = 1'b0;
    end
  endtask

  task automatic wait_for_value(input logic [47:0] mac, input logic [31:0] ip);
    integer cycles;
    begin
      cycles = 0;
      while ((!dst_valid || (dst_mac != mac) || (dst_ip != ip)) && (cycles < 100)) begin
        @(posedge dst_clk);
        cycles = cycles + 1;
      end
      if (!dst_valid || (dst_mac != mac) || (dst_ip != ip)) begin
        $fatal(1, "ARP snapshot timeout: expected mac=%h ip=%h actual mac=%h ip=%h valid=%b",
               mac, ip, dst_mac, dst_ip, dst_valid);
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge src_clk);
    @(negedge src_clk);
    src_reset = 1'b0;
    repeat (2) @(posedge dst_clk);
    @(negedge dst_clk);
    dst_reset = 1'b0;

    pulse_update(MAC_A, IP_A);
    while (!dut.src_request) @(posedge src_clk);
    pulse_update(MAC_B, IP_B);
    pulse_update(MAC_C, IP_C);
    wait_for_value(MAC_A, IP_A);
    wait_for_value(MAC_C, IP_C);
    if (saw_mac_b) $fatal(1, "busy mailbox did not coalesce updates to the latest ARP value");

    // A destination-only reset clears its output, then requests a replay of
    // the latest source-domain value without another ARP event.
    @(negedge dst_clk);
    dst_reset = 1'b1;
    repeat (3) @(posedge dst_clk);
    if (dst_valid) $fatal(1, "destination reset did not clear the ARP snapshot");
    @(negedge dst_clk);
    dst_reset = 1'b0;
    wait_for_value(MAC_C, IP_C);

    pulse_update(MAC_D, IP_D);
    wait_for_value(MAC_D, IP_D);

    $display("cmac_usplus_0_rdma_arp_snapshot_cdc_tb PASS");
    $finish;
  end

endmodule
