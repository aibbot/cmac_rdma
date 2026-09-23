`timescale 1ps / 1ps

module cmac_usplus_0_rdma_transport_ip_parameter_tb;
  cmac_usplus_0_rdma_transport_ip dut ();

  initial begin
    #10ps;
    $display("cmac_usplus_0_rdma_transport_ip_parameter_tb PASS");
    $finish;
  end
endmodule

module cmac_usplus_0_rdma_transport_ip_frequency_tb;
  cmac_usplus_0_rdma_transport_ip #(
    .ACLK_FREQ_HZ(100_000_000)
  ) dut ();

  initial begin
    #10ps;
    if (dut.ACK_TIMEOUT_CYCLES != 100_000 ||
        dut.RNR_TIMER_10US_CYCLES != 1_000)
      $fatal(1, "frequency-derived timer defaults are incorrect");
    $display("cmac_usplus_0_rdma_transport_ip_frequency_tb PASS");
    $finish;
  end
endmodule

module cmac_usplus_0_rdma_transport_ip_reset_contract_tb;
  logic clk = 1'b0;
  logic aresetn = 1'b0;

  always #2ns clk = !clk;

  cmac_usplus_0_rdma_transport_ip dut (
    .aclk(clk),
    .aresetn(aresetn)
  );

  initial begin
    #1ps;
    if (dut.reset !== 1'b1)
      $fatal(1, "active-low reset did not assert");
    repeat (2) @(posedge clk);
    @(negedge clk);
    aresetn = 1'b1;
    #1ps;
    if (dut.reset !== 1'b1)
      $fatal(1, "reset release was not synchronized");
    repeat (3) begin
      @(posedge clk);
      @(negedge clk);
      if (dut.reset !== 1'b1)
        $fatal(1, "reset released before four aclk edges");
    end
    @(posedge clk);
    @(negedge clk);
    if (dut.reset !== 1'b0)
      $fatal(1, "reset did not release after four aclk edges");
    #1ns;
    aresetn = 1'b0;
    #1ps;
    if (dut.reset !== 1'b1)
      $fatal(1, "reset did not assert asynchronously");
    $display("cmac_usplus_0_rdma_transport_ip_reset_contract_tb PASS");
    $finish;
  end
endmodule

module cmac_usplus_0_rdma_transport_ip_ack_timeout_zero_tb;
  cmac_usplus_0_rdma_transport_ip #(
    .ACK_TIMEOUT_CYCLES(0)
  ) dut ();

  initial begin
    #10ps;
    $fatal(1, "INVALID_PARAMETER_ACCEPTED: ACK_TIMEOUT_CYCLES");
  end
endmodule

module cmac_usplus_0_rdma_transport_ip_retry_overflow_tb;
  cmac_usplus_0_rdma_transport_ip #(
    .MAX_RETRIES(16)
  ) dut ();

  initial begin
    #10ps;
    $fatal(1, "INVALID_PARAMETER_ACCEPTED: MAX_RETRIES");
  end
endmodule

module cmac_usplus_0_rdma_transport_ip_retry_negative_tb;
  cmac_usplus_0_rdma_transport_ip #(
    .MAX_RETRIES(-1)
  ) dut ();

  initial begin
    #10ps;
    $fatal(1, "INVALID_PARAMETER_ACCEPTED: MAX_RETRIES");
  end
endmodule

module cmac_usplus_0_rdma_transport_ip_recovery_negative_tb;
  cmac_usplus_0_rdma_transport_ip #(
    .MAX_SEQUENCE_RECOVERIES(-1)
  ) dut ();

  initial begin
    #10ps;
    $fatal(1, "INVALID_PARAMETER_ACCEPTED: MAX_SEQUENCE_RECOVERIES");
  end
endmodule

module cmac_usplus_0_rdma_transport_ip_recovery_quiet_zero_tb;
  cmac_usplus_0_rdma_transport_ip #(
    .SEQUENCE_RECOVERY_QUIET_CYCLES(0)
  ) dut ();

  initial begin
    #10ps;
    $fatal(1, "INVALID_PARAMETER_ACCEPTED: SEQUENCE_RECOVERY_QUIET_CYCLES");
  end
endmodule

module cmac_usplus_0_rdma_transport_ip_rnr_timer_zero_tb;
  cmac_usplus_0_rdma_transport_ip #(
    .RNR_TIMER_10US_CYCLES(0)
  ) dut ();

  initial begin
    #10ps;
    $fatal(1, "INVALID_PARAMETER_ACCEPTED: RNR_TIMER_10US_CYCLES");
  end
endmodule

module cmac_usplus_0_rdma_transport_ip_local_qpn_zero_tb;
  cmac_usplus_0_rdma_transport_ip #(
    .LOCAL_QPN(24'd0)
  ) dut ();

  initial begin
    #10ps;
    $fatal(1, "INVALID_PARAMETER_ACCEPTED: LOCAL_QPN");
  end
endmodule
